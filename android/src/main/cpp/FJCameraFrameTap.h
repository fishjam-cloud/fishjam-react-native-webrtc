// fbjni HybridClass backing com.oney.WebRTCModule.CameraFrameTapProcessor.
//
// The Java peer sits in the VideoSource's VideoProcessor slot and, for every
// camera frame it forwards to WebRTC, asks this class whether a consumer wants
// it. When the admission core says yes, the Java side renders the camera's OES
// texture into one slot of a small ring of RGBA8 AHardwareBuffers (an EGLImage
// backed framebuffer prepared here) and this class hands that buffer to the
// consumer as an FJCameraFrame, together with a native fence that signals once
// the GPU finished the copy.
//
// Threads: beginBlit / endBlit / releaseGl run on the SurfaceTextureHelper GL
// thread only. Frame releases arrive from the consumer's thread and only touch
// the slot bookkeeping, never GL or JNI.
#pragma once

#include <android/hardware_buffer.h>
#include <fbjni/fbjni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <array>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>

#include "FJCameraFrame.h"
#include "FJCameraFrameProcessorCore.h"

namespace fishjam::video {

class FJCameraFrameTap : public facebook::jni::HybridClass<FJCameraFrameTap> {
   public:
    static constexpr auto kJavaDescriptor = "Lcom/oney/WebRTCModule/CameraFrameTapProcessor;";
    static constexpr int kSlotCount = 3;

    static facebook::jni::local_ref<jhybriddata> initHybrid(facebook::jni::alias_ref<jhybridobject> javaThis);
    static void registerNatives();

    // Consumer side, called from the JSI handlers (JS thread).
    void attachConsumer(std::shared_ptr<FJCameraFrameConsumer> consumer);
    void detachConsumer();
    FJCameraFrameProcessorCore::Statistics statistics() const;

    // GL thread. Returns the framebuffer to render the camera frame into, or -1
    // when the frame should not be copied (nothing attached, consumer busy, no
    // free slot, or the slot could not be prepared).
    jint beginBlit(jint width, jint height);
    // GL thread, after the render into the framebuffer returned by beginBlit.
    void endBlit(jint rotationDegrees, jboolean isFrontCamera, jlong timestampNanoseconds);
    // GL thread. Waits (bounded) for in-flight frames, then frees every slot.
    void releaseGl();

   private:
    friend HybridBase;

    struct Slot {
        AHardwareBuffer *buffer = nullptr;
        EGLImageKHR image = EGL_NO_IMAGE_KHR;
        GLuint texture = 0;
        GLuint framebuffer = 0;
        int32_t width = 0;
        int32_t height = 0;
        bool inUse = false;
        bool loggedFailure = false;
    };

    // Shared with every outstanding frame's release callback, so a release that
    // arrives after the Java peer is gone still finds live bookkeeping.
    struct SlotState {
        std::mutex mutex;
        std::condition_variable released;
        std::array<Slot, kSlotCount> slots;
        int nextSlot = 0;
        int inFlight = 0;
    };

    explicit FJCameraFrameTap(facebook::jni::alias_ref<jhybridobject> javaThis);

    bool prepareSlot(Slot &slot, int32_t width, int32_t height, EGLDisplay display);
    void destroySlot(Slot &slot, EGLDisplay display);
    int32_t createAcquireFence(EGLDisplay display);

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJCameraFrameProcessorCore> core_;
    std::shared_ptr<SlotState> slotState_;

    mutable std::mutex consumerMutex_;
    std::shared_ptr<FJCameraFrameConsumer> consumer_;

    // The blit in progress between beginBlit and endBlit (GL thread only).
    int pendingSlot_ = -1;
    uint64_t pendingToken_ = 0;
};

}  // namespace fishjam::video
