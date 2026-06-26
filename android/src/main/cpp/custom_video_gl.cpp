// AHardwareBuffer (AHB) -> EGLImage -> OES GL texture import + sync-fd GPU
// fence wait for the Android custom-video-track.
//
// libwebrtc (org.jitsi:webrtc) encodes from a GL texture, not an AHardwareBuffer.
// So per pooled AHB we build, ONCE, a GL_TEXTURE_EXTERNAL_OES texture that aliases
// the AHB's pixels (eglGetNativeClientBufferANDROID -> eglCreateImageKHR ->
// glEGLImageTargetTexture2DOES) and hand the texture id to a TextureBufferImpl on
// the Java side. Every subsequent frame reuses the cached {EGLImage, texId} for
// that index; we only re-wait the GPU fence and re-deliver.
//
// EVERY entry point in this file MUST be called on the one dedicated GL thread
// whose EGL context is current (the SurfaceTextureHelper handler thread created
// with WebRTC's root EGL context). Cross-thread GL is invalid and these calls
// silently corrupt state if run elsewhere. The Java side (CustomVideoFrameDelivery)
// guarantees this by posting every native call onto that handler.
//
// The functions used here are EGL/GLES *extensions*, not part of the core NDK
// link surface, so they are resolved at runtime via eglGetProcAddress:
//   - eglGetNativeClientBufferANDROID   (EGL_ANDROID_get_native_client_buffer)
//   - eglCreateImageKHR / eglDestroyImageKHR (EGL_KHR_image_base)
//   - glEGLImageTargetTexture2DOES      (GL_OES_EGL_image)
//   - eglCreateSyncKHR / eglWaitSyncKHR / eglDestroySyncKHR
//                                       (EGL_KHR_fence_sync + EGL_ANDROID_native_fence_sync)
//
// None of these are __INTRODUCED_IN-versioned NDK symbols (they are all resolved
// through eglGetProcAddress function pointers), so no __builtin_available guard is
// required here even when compiling against minSdk 24.

#include <android/hardware_buffer.h>
#include <jni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <unistd.h>

namespace {

// Lazily-resolved extension entry points. Resolved once on first use from the
// GL thread (where an EGL display/context are current). They are process-global
// function pointers, so a plain one-shot init is safe.
PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC eglGetNativeClientBufferANDROIDFn = nullptr;
PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHRFn = nullptr;
PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHRFn = nullptr;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOESFn = nullptr;
PFNEGLCREATESYNCKHRPROC eglCreateSyncKHRFn = nullptr;
PFNEGLWAITSYNCKHRPROC eglWaitSyncKHRFn = nullptr;
PFNEGLDESTROYSYNCKHRPROC eglDestroySyncKHRFn = nullptr;
bool extensionsResolved = false;

bool resolveExtensions() {
    if (extensionsResolved) {
        return eglGetNativeClientBufferANDROIDFn != nullptr && eglCreateImageKHRFn != nullptr &&
                glEGLImageTargetTexture2DOESFn != nullptr;
    }
    extensionsResolved = true;

    eglGetNativeClientBufferANDROIDFn = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
            eglGetProcAddress("eglGetNativeClientBufferANDROID"));
    eglCreateImageKHRFn =
            reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    eglDestroyImageKHRFn =
            reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
    glEGLImageTargetTexture2DOESFn = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    eglCreateSyncKHRFn =
            reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(eglGetProcAddress("eglCreateSyncKHR"));
    eglWaitSyncKHRFn =
            reinterpret_cast<PFNEGLWAITSYNCKHRPROC>(eglGetProcAddress("eglWaitSyncKHR"));
    eglDestroySyncKHRFn =
            reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(eglGetProcAddress("eglDestroySyncKHR"));

    return eglGetNativeClientBufferANDROIDFn != nullptr && eglCreateImageKHRFn != nullptr &&
            glEGLImageTargetTexture2DOESFn != nullptr;
}

}  // namespace

extern "C" {

// Imports the AHardwareBuffer at `ahbHandle` (an AHardwareBuffer* as a jlong) into
// a freshly-created GL_TEXTURE_EXTERNAL_OES texture that aliases its pixels, and
// returns the {eglImage, texId} packed for the Java cache.
//
// Returns a jlongArray of length 2: [0] = EGLImageKHR (as jlong, for later
// destroy), [1] = GLuint texture id (as jlong, fed to TextureBufferImpl). On any
// failure returns null. MUST run on the shared-context GL thread.
//
// Caching is the caller's responsibility: call this exactly once per pool index
// and reuse the returned {eglImage, texId} for every frame at that index.
JNIEXPORT jlongArray JNICALL
Java_com_oney_WebRTCModule_CustomVideoFrameDelivery_nativeImportAhbToOesTexture(
        JNIEnv* env, jclass /* clazz */, jlong ahbHandle) {
    if (ahbHandle == 0) {
        return nullptr;
    }
    if (!resolveExtensions()) {
        return nullptr;
    }

    // A current EGL context is required: the SurfaceTextureHelper handler thread
    // makes the shared context current on itself, so this is non-null only when we
    // are actually on the GL thread. Both are needed (display for eglCreateImageKHR,
    // context for the GL texture calls).
    if (eglGetCurrentContext() == EGL_NO_CONTEXT) {
        return nullptr;
    }
    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) {
        return nullptr;
    }

    AHardwareBuffer* buffer = reinterpret_cast<AHardwareBuffer*>(ahbHandle);
    EGLClientBuffer clientBuffer = eglGetNativeClientBufferANDROIDFn(buffer);
    if (clientBuffer == nullptr) {
        return nullptr;
    }

    // EGL_IMAGE_PRESERVED_KHR=TRUE keeps the AHB's existing contents (the WebGPU
    // render output) when the EGLImage is created, rather than leaving them
    // undefined.
    const EGLint imageAttribs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR eglImage = eglCreateImageKHRFn(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                                               clientBuffer, imageAttribs);
    if (eglImage == EGL_NO_IMAGE_KHR) {
        return nullptr;
    }

    GLuint texId = 0;
    glGenTextures(1, &texId);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texId);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glEGLImageTargetTexture2DOESFn(GL_TEXTURE_EXTERNAL_OES,
                                   static_cast<GLeglImageOES>(eglImage));
    GLenum glError = glGetError();
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    if (glError != GL_NO_ERROR) {
        glDeleteTextures(1, &texId);
        eglDestroyImageKHRFn(display, eglImage);
        return nullptr;
    }

    jlongArray result = env->NewLongArray(2);
    if (result == nullptr) {
        glDeleteTextures(1, &texId);
        eglDestroyImageKHRFn(display, eglImage);
        return nullptr;
    }
    jlong values[2] = {reinterpret_cast<jlong>(eglImage), static_cast<jlong>(texId)};
    env->SetLongArrayRegion(result, 0, 2, values);
    return result;
}

// Server-side wait for the GPU fence behind `fenceFd` (a dup'd sync-fd file
// descriptor, or -1 for no fence). Makes the encoder GL thread block (on the GPU
// timeline) until the WebGPU render that produced the AHB contents has completed,
// BEFORE the encoder samples the OES texture. EGL takes ownership of the fd inside
// eglCreateSyncKHR, so we must NOT close it ourselves on the success path.
//
// MUST run on the shared-context GL thread (the same one that will sample the
// texture). fenceFd < 0 means no fence supplied -> no-op (deliver immediately,
// accepting the render may not be finished).
JNIEXPORT void JNICALL
Java_com_oney_WebRTCModule_CustomVideoFrameDelivery_nativeWaitSyncFd(
        JNIEnv* /* env */, jclass /* clazz */, jint fenceFd) {
    if (fenceFd < 0) {
        return;  // no-fence fallback
    }
    if (!resolveExtensions() || eglCreateSyncKHRFn == nullptr || eglWaitSyncKHRFn == nullptr) {
        close(fenceFd);
        return;
    }

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) {
        close(fenceFd);
        return;
    }

    // EGL takes ownership of the fd on success and closes it when the sync is
    // destroyed; on failure ownership stays with us, so we close it ourselves.
    const EGLint syncAttribs[] = {EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fenceFd, EGL_NONE};
    EGLSyncKHR sync = eglCreateSyncKHRFn(display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
    if (sync == EGL_NO_SYNC_KHR) {
        close(fenceFd);
        return;
    }

    // Server-side wait: schedules the GPU to wait, does not block the CPU thread.
    eglWaitSyncKHRFn(display, sync, 0);
    if (eglDestroySyncKHRFn != nullptr) {
        eglDestroySyncKHRFn(display, sync);
    }
}

// Destroys one cached {EGLImage, texId} pair created by nativeImportAhbToOesTexture.
// MUST run on the shared-context GL thread (glDeleteTextures needs the context;
// eglDestroyImageKHR needs the display). No-op on zero handles.
JNIEXPORT void JNICALL
Java_com_oney_WebRTCModule_CustomVideoFrameDelivery_nativeReleaseImportedTexture(
        JNIEnv* /* env */, jclass /* clazz */, jlong eglImageHandle, jint texId) {
    EGLDisplay display = eglGetCurrentDisplay();
    if (texId != 0) {
        GLuint id = static_cast<GLuint>(texId);
        glDeleteTextures(1, &id);
    }
    if (eglImageHandle != 0 && display != EGL_NO_DISPLAY && resolveExtensions() &&
            eglDestroyImageKHRFn != nullptr) {
        eglDestroyImageKHRFn(display, reinterpret_cast<EGLImageKHR>(eglImageHandle));
    }
}

// Closes a raw fence fd that never reached EGL ownership (Java error/bailout
// paths). Touches no GL/EGL state, so it is safe to call from any thread. No-op
// on a negative fd.
JNIEXPORT void JNICALL
Java_com_oney_WebRTCModule_CustomVideoFrameDelivery_nativeCloseFd(
        JNIEnv* /* env */, jclass /* clazz */, jint fenceFd) {
    if (fenceFd >= 0) {
        close(fenceFd);
    }
}

}  // extern "C"
