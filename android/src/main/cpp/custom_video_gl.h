// EGL / GLES extension entry points shared by the custom-video-track delivery
// path (custom_video_gl.cpp) and the camera frame tap (FJCameraFrameTap.cpp).
//
// Every function here is resolved through eglGetProcAddress, so nothing is a
// versioned NDK link symbol and no __builtin_available guard is needed. Resolve
// and use them only on the SurfaceTextureHelper GL thread: the pointers are
// written once without synchronisation and the calls need that thread's EGL
// context to be current.
#pragma once

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

namespace fishjam::video::gl {

struct EglExtensions {
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC eglGetNativeClientBufferANDROID = nullptr;
    PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES = nullptr;
    PFNEGLCREATESYNCKHRPROC eglCreateSyncKHR = nullptr;
    PFNEGLCLIENTWAITSYNCKHRPROC eglClientWaitSyncKHR = nullptr;
    PFNEGLWAITSYNCKHRPROC eglWaitSyncKHR = nullptr;
    PFNEGLDESTROYSYNCKHRPROC eglDestroySyncKHR = nullptr;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC eglDupNativeFenceFDANDROID = nullptr;

    // The image import trio every caller needs; the sync functions are optional
    // and checked individually.
    bool canImportImages() const {
        return eglGetNativeClientBufferANDROID != nullptr && eglCreateImageKHR != nullptr &&
               glEGLImageTargetTexture2DOES != nullptr;
    }
};

// Resolves once (on first call) and returns the process-wide table.
const EglExtensions &eglExtensions();

}  // namespace fishjam::video::gl
