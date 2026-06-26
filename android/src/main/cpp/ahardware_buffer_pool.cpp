// AHardwareBuffer (AHB) pool primitives for the Android custom-video-track.
//
// Allocates an AHardwareBuffer that is BOTH GPU-renderable (GPU_FRAMEBUFFER) and
// GPU-sampleable (GPU_SAMPLED_IMAGE), hands its pointer to JS as a jlong, and
// releases it later. JS/WebGPU imports that pointer via react-native-webgpu's
// importSharedTextureMemory({handle}) and renders into it; the rendered AHB is
// then delivered to WebRTC by custom_video_gl.cpp.
//
// The AHardwareBuffer_* APIs are __INTRODUCED_IN(26), so every call is wrapped in
// __builtin_available(android 26, *) to compile against minSdk 24. Callers
// (WebRTCModule / GetUserMediaImpl) reject on SDK_INT < 26 before reaching here,
// so the runtime-unavailable branches are never taken on older devices.

#include <android/hardware_buffer.h>
#include <jni.h>

extern "C" {

// Allocates a single RGBA8 AHardwareBuffer usable as both a GPU render target
// and a GPU sampled image, acquires an extra reference so it outlives this call,
// and returns the AHardwareBuffer* reinterpreted as a jlong (64-bit). Returns 0
// on failure.
//
// Usage flags:
//   AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE  -> importable + sampleable by Dawn
//   AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER    -> renderable (RENDER_ATTACHMENT)
// No CPU usage is requested: this is a pure-GPU buffer.
JNIEXPORT jlong JNICALL
Java_com_oney_WebRTCModule_AHardwareBufferPool_allocateFramebufferAHB(
        JNIEnv* /* env */, jclass /* clazz */, jint width, jint height) {
    if (width <= 0 || height <= 0) {
        return 0;
    }

    if (__builtin_available(android 26, *)) {
        AHardwareBuffer_Desc desc = {};
        desc.width = static_cast<uint32_t>(width);
        desc.height = static_cast<uint32_t>(height);
        desc.layers = 1;
        desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
        desc.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;

        AHardwareBuffer* buffer = nullptr;
        int status = AHardwareBuffer_allocate(&desc, &buffer);
        if (status != 0 || buffer == nullptr) {
            return 0;
        }

        // Acquire one extra reference so the buffer survives past this JNI call.
        // The JS side holds the raw pointer (as a decimal string) and the Java
        // pool owns the lifetime; releaseAHB() balances both allocate() and
        // acquire().
        AHardwareBuffer_acquire(buffer);
        return reinterpret_cast<jlong>(buffer);
    }
    return 0;
}

// Releases the two references taken in allocateFramebufferAHB (the +1 from
// AHardwareBuffer_allocate and the +1 from AHardwareBuffer_acquire). Safe to
// call once per allocated handle; passing 0 is a no-op.
//
// NOTE: the raw AHB pointer handed to JS (as a long) is a dangling pointer once
// this returns — it must NOT be imported/used by JS/WebGPU after releaseAHB().
// The Java pool nulls its handle here so no further frame can reference it.
JNIEXPORT void JNICALL
Java_com_oney_WebRTCModule_AHardwareBufferPool_releaseAHB(
        JNIEnv* /* env */, jclass /* clazz */, jlong handle) {
    if (handle == 0) {
        return;
    }
    if (__builtin_available(android 26, *)) {
        AHardwareBuffer* buffer = reinterpret_cast<AHardwareBuffer*>(handle);
        // Balance AHardwareBuffer_acquire(), then AHardwareBuffer_allocate().
        AHardwareBuffer_release(buffer);
        AHardwareBuffer_release(buffer);
    }
}

}  // extern "C"
