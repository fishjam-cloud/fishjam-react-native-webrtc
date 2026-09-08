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
// Ownership: every delivered frame holds its own AHardwareBuffer reference, so
// the buffer outlives the slot it came from. releaseGl frees the slots' GL
// objects and the slots' own buffer references at once, without waiting for the
// consumer; a frame still in flight keeps its buffer alive and, on release,
// only touches the shared SlotState bookkeeping.
//
// Threads: beginBlit / endBlit / abortBlit / releaseGl run on the
// SurfaceTextureHelper GL thread only, so a slot's buffer and GL objects are
// GL-thread state and need no lock. Frame releases arrive from the consumer's
// thread and only touch the slot bookkeeping under SlotState::mutex, never GL,
// JNI, or the Slot::buffer field (a frame drops its own buffer reference
// instead). Delivery happens under consumerMutex_, so
// a detach waits for an onFrame in progress and no frame reaches a consumer
// that was detached before the blit finished.
#pragma once

#include <android/hardware_buffer.h>
#include <fbjni/fbjni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>

#include "FJCameraFrame.h"
#include "FJCameraFrameProcessorCore.h"

namespace fishjam::video {

class FJCameraFrameTap : public facebook::jni::HybridClass<FJCameraFrameTap> {
   public:
    static constexpr auto kJavaDescriptor = "Lcom/oney/WebRTCModule/CameraFrameTapProcessor;";
    static constexpr int kSlotCount = 3;

    static facebook::jni::local_ref<jhybriddata> initHybrid(facebook::jni::alias_ref<jhybridobject> javaThis);
    static void registerNatives();

    // Consumer side, called from the JSI handlers (JS thread); detachConsumer
    // also runs from releaseGl on the GL thread. Lock order is consumerMutex_
    // then the core's mutex, never the reverse.
    void attachConsumer(std::shared_ptr<FJCameraFrameConsumer> consumer);
    void detachConsumer();
    FJCameraFrameProcessorCore::Statistics statistics() const;

    // GL thread. Returns the framebuffer to render the camera frame into, or -1
    // when the frame should not be copied (nothing attached, consumer busy, no
    // free slot, or the slot could not be prepared).
    jint beginBlit(jint width, jint height);
    // GL thread, after the render into the framebuffer returned by beginBlit.
    void endBlit(jint rotationDegrees, jboolean isFrontCamera, jlong timestampNanoseconds);
    // GL thread, instead of endBlit when the render failed: frees the slot and
    // reopens the gate without delivering anything.
    void abortBlit();
    // GL thread. Detaches the consumer, then frees every slot's GL objects and
    // buffer reference immediately; frames the consumer still holds stay valid
    // through their own reference.
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
        // Guarded by SlotState::mutex; everything above is GL-thread state.
        bool inUse = false;
        bool loggedFailure = false;
    };

    // Shared with every outstanding frame's release callback, so a release that
    // arrives after the Java peer is gone still finds live bookkeeping.
    struct SlotState {
        std::mutex mutex;
        std::array<Slot, kSlotCount> slots;
        int nextSlot = 0;
    };

    explicit FJCameraFrameTap(facebook::jni::alias_ref<jhybridobject> javaThis);

    // Marks the next free slot in use and returns its index, or -1 when every
    // slot is held by the consumer.
    int acquireSlot();
    // Marks a slot free again. Any thread.
    static void releaseSlot(SlotState &slotState, int slotIndex);
    bool prepareSlot(Slot &slot, int32_t width, int32_t height, EGLDisplay display);
    void destroySlot(Slot &slot, EGLDisplay display);
    // A sync file descriptor that signals when the GPU finished every command
    // issued so far on this context, or nullopt when the device has no native
    // fence sync.
    std::optional<int32_t> createAcquireFence(EGLDisplay display);

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJCameraFrameProcessorCore> core_;
    std::shared_ptr<SlotState> slotState_;

    mutable std::mutex consumerMutex_;
    std::shared_ptr<FJCameraFrameConsumer> consumer_;

    // The blit in progress between beginBlit and endBlit/abortBlit (GL thread only).
    int pendingSlot_ = -1;
    bool loggedDetachedOffer_ = false;
    bool loggedNoContext_ = false;
    bool loggedNoNativeFence_ = false;
    uint64_t pendingToken_ = 0;
};

}  // namespace fishjam::video
