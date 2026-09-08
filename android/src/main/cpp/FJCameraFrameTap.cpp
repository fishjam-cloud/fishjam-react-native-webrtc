#include "FJCameraFrameTap.h"

#include <android/log.h>
#include <unistd.h>

#include <chrono>

#include "custom_video_gl.h"

namespace jni = facebook::jni;

namespace fishjam::video {

namespace {

constexpr const char *kLogTag = "WebRTCModule";
constexpr auto kReleaseDrainTimeout = std::chrono::seconds(2);

void logWarning(const char *message) {
    __android_log_print(ANDROID_LOG_WARN, kLogTag, "CameraFrameTap: %s", message);
}

}  // namespace

FJCameraFrameTap::FJCameraFrameTap(jni::alias_ref<jhybridobject> javaThis)
    : javaPart_(jni::make_global(javaThis)),
      core_(std::make_shared<FJCameraFrameProcessorCore>()),
      slotState_(std::make_shared<SlotState>()) {}

jni::local_ref<FJCameraFrameTap::jhybriddata> FJCameraFrameTap::initHybrid(jni::alias_ref<jhybridobject> javaThis) {
    return makeCxxInstance(javaThis);
}

void FJCameraFrameTap::attachConsumer(std::shared_ptr<FJCameraFrameConsumer> consumer) {
    {
        std::lock_guard<std::mutex> lock(consumerMutex_);
        consumer_ = std::move(consumer);
    }
    core_->attach();
}

void FJCameraFrameTap::detachConsumer() {
    core_->detach();
    std::lock_guard<std::mutex> lock(consumerMutex_);
    consumer_.reset();
}

FJCameraFrameProcessorCore::Statistics FJCameraFrameTap::statistics() const {
    return core_->statistics();
}

jint FJCameraFrameTap::beginBlit(jint width, jint height) {
    pendingSlot_ = -1;
    if (width <= 0 || height <= 0) {
        return -1;
    }
    FJCameraFrameProcessorCore::Offer offer = core_->offer();
    if (offer.result != FJCameraFrameProcessorCore::OfferResult::Accepted) {
        return -1;
    }

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY || eglGetCurrentContext() == EGL_NO_CONTEXT) {
        core_->completed(offer.token);
        return -1;
    }

    std::lock_guard<std::mutex> lock(slotState_->mutex);
    int chosen = -1;
    for (int step = 0; step < kSlotCount; ++step) {
        int candidate = (slotState_->nextSlot + step) % kSlotCount;
        if (!slotState_->slots[candidate].inUse) {
            chosen = candidate;
            break;
        }
    }
    if (chosen < 0) {
        core_->completed(offer.token);
        return -1;
    }
    Slot &slot = slotState_->slots[chosen];
    if (!prepareSlot(slot, width, height, display)) {
        core_->completed(offer.token);
        return -1;
    }
    slot.inUse = true;
    slotState_->inFlight += 1;
    slotState_->nextSlot = (chosen + 1) % kSlotCount;
    pendingSlot_ = chosen;
    pendingToken_ = offer.token;
    return static_cast<jint>(slot.framebuffer);
}

void FJCameraFrameTap::endBlit(jint rotationDegrees, jboolean isFrontCamera, jlong timestampNanoseconds) {
    if (pendingSlot_ < 0) {
        return;
    }
    const int slotIndex = pendingSlot_;
    const uint64_t token = pendingToken_;
    pendingSlot_ = -1;

    EGLDisplay display = eglGetCurrentDisplay();
    const int32_t acquireFence = createAcquireFence(display);

    uint64_t nativeBuffer = 0;
    int32_t width = 0;
    int32_t height = 0;
    {
        std::lock_guard<std::mutex> lock(slotState_->mutex);
        const Slot &slot = slotState_->slots[slotIndex];
        nativeBuffer = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(slot.buffer));
        width = slot.width;
        height = slot.height;
    }

    std::shared_ptr<SlotState> slotState = slotState_;
    std::shared_ptr<FJCameraFrameProcessorCore> core = core_;
    auto frame = std::make_shared<FJCameraFrame>(
        nativeBuffer, width, height, static_cast<int32_t>(rotationDegrees), isFrontCamera == JNI_TRUE,
        static_cast<int64_t>(timestampNanoseconds), FJCameraPixelFormat::RGBA8, acquireFence,
        [slotState, core, slotIndex, token, acquireFence]() {
            if (acquireFence >= 0) {
                close(acquireFence);
            }
            {
                std::lock_guard<std::mutex> lock(slotState->mutex);
                slotState->slots[slotIndex].inUse = false;
                slotState->inFlight -= 1;
            }
            slotState->released.notify_all();
            core->completed(token);
        });

    std::shared_ptr<FJCameraFrameConsumer> consumer;
    {
        std::lock_guard<std::mutex> lock(consumerMutex_);
        consumer = consumer_;
    }
    if (consumer) {
        consumer->onFrame(std::move(frame));
    }
    // Without a consumer the frame is dropped here and its release callback
    // reopens the gate.
}

void FJCameraFrameTap::releaseGl() {
    pendingSlot_ = -1;
    EGLDisplay display = eglGetCurrentDisplay();
    std::unique_lock<std::mutex> lock(slotState_->mutex);
    if (!slotState_->released.wait_for(lock, kReleaseDrainTimeout, [this] { return slotState_->inFlight == 0; })) {
        logWarning("timed out waiting for the consumer to release the last frame; freeing slots anyway");
    }
    for (Slot &slot : slotState_->slots) {
        destroySlot(slot, display);
    }
}

bool FJCameraFrameTap::prepareSlot(Slot &slot, int32_t width, int32_t height, EGLDisplay display) {
    if (slot.buffer != nullptr && slot.width == width && slot.height == height) {
        return true;
    }
    destroySlot(slot, display);

    const gl::EglExtensions &extensions = gl::eglExtensions();
    if (!extensions.canImportImages()) {
        if (!slot.loggedFailure) {
            slot.loggedFailure = true;
            logWarning("EGL image extensions unavailable; camera frames cannot be shared with the GPU consumer");
        }
        return false;
    }

    if (__builtin_available(android 26, *)) {
        AHardwareBuffer_Desc description = {};
        description.width = static_cast<uint32_t>(width);
        description.height = static_cast<uint32_t>(height);
        description.layers = 1;
        description.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
        description.usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;
        if (AHardwareBuffer_allocate(&description, &slot.buffer) != 0 || slot.buffer == nullptr) {
            slot.buffer = nullptr;
            if (!slot.loggedFailure) {
                slot.loggedFailure = true;
                logWarning("AHardwareBuffer allocation failed");
            }
            return false;
        }
    } else {
        return false;
    }

    EGLClientBuffer clientBuffer = extensions.eglGetNativeClientBufferANDROID(slot.buffer);
    const EGLint imageAttributes[] = {EGL_NONE};
    slot.image = clientBuffer == nullptr ? EGL_NO_IMAGE_KHR
                                         : extensions.eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                                                                        clientBuffer, imageAttributes);
    if (slot.image == EGL_NO_IMAGE_KHR) {
        destroySlot(slot, display);
        if (!slot.loggedFailure) {
            slot.loggedFailure = true;
            logWarning("eglCreateImageKHR failed for the camera frame slot");
        }
        return false;
    }

    while (glGetError() != GL_NO_ERROR) {
    }
    glGenTextures(1, &slot.texture);
    glBindTexture(GL_TEXTURE_2D, slot.texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    extensions.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, static_cast<GLeglImageOES>(slot.image));
    GLenum textureError = glGetError();
    glBindTexture(GL_TEXTURE_2D, 0);

    glGenFramebuffers(1, &slot.framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, slot.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.texture, 0);
    GLenum framebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    if (textureError != GL_NO_ERROR || framebufferStatus != GL_FRAMEBUFFER_COMPLETE) {
        if (!slot.loggedFailure) {
            slot.loggedFailure = true;
            __android_log_print(ANDROID_LOG_WARN, kLogTag,
                                "CameraFrameTap: slot setup failed (glError=0x%x, framebufferStatus=0x%x)",
                                textureError, framebufferStatus);
        }
        destroySlot(slot, display);
        return false;
    }

    slot.width = width;
    slot.height = height;
    return true;
}

void FJCameraFrameTap::destroySlot(Slot &slot, EGLDisplay display) {
    const gl::EglExtensions &extensions = gl::eglExtensions();
    if (slot.framebuffer != 0) {
        glDeleteFramebuffers(1, &slot.framebuffer);
        slot.framebuffer = 0;
    }
    if (slot.texture != 0) {
        glDeleteTextures(1, &slot.texture);
        slot.texture = 0;
    }
    if (slot.image != EGL_NO_IMAGE_KHR) {
        if (display != EGL_NO_DISPLAY && extensions.eglDestroyImageKHR != nullptr) {
            extensions.eglDestroyImageKHR(display, slot.image);
        }
        slot.image = EGL_NO_IMAGE_KHR;
    }
    if (slot.buffer != nullptr) {
        if (__builtin_available(android 26, *)) {
            AHardwareBuffer_release(slot.buffer);
        }
        slot.buffer = nullptr;
    }
    slot.width = 0;
    slot.height = 0;
}

// Returns a sync file descriptor that signals when the GPU has finished every
// command issued so far on this context, or -1 after a CPU-side glFinish when
// native fences are unavailable.
int32_t FJCameraFrameTap::createAcquireFence(EGLDisplay display) {
    const gl::EglExtensions &extensions = gl::eglExtensions();
    if (display != EGL_NO_DISPLAY && extensions.eglCreateSyncKHR != nullptr &&
        extensions.eglDupNativeFenceFDANDROID != nullptr && extensions.eglDestroySyncKHR != nullptr) {
        EGLSyncKHR sync = extensions.eglCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
        if (sync != EGL_NO_SYNC_KHR) {
            glFlush();
            EGLint fileDescriptor = extensions.eglDupNativeFenceFDANDROID(display, sync);
            extensions.eglDestroySyncKHR(display, sync);
            if (fileDescriptor >= 0) {
                return fileDescriptor;
            }
        }
    }
    glFinish();
    return -1;
}

void FJCameraFrameTap::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJCameraFrameTap::initHybrid),
        makeNativeMethod("beginBlit", FJCameraFrameTap::beginBlit),
        makeNativeMethod("endBlit", FJCameraFrameTap::endBlit),
        makeNativeMethod("releaseGl", FJCameraFrameTap::releaseGl),
    });
}

}  // namespace fishjam::video
