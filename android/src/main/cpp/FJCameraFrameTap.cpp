#include "FJCameraFrameTap.h"

#include <android/log.h>
#include <unistd.h>

#include "custom_video_gl.h"

namespace jni = facebook::jni;

namespace fishjam::video {

namespace {

constexpr const char *kLogTag = "WebRTCModule";

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
    std::lock_guard<std::mutex> lock(consumerMutex_);
    consumer_ = std::move(consumer);
    core_->attach();
}

void FJCameraFrameTap::detachConsumer() {
    std::lock_guard<std::mutex> lock(consumerMutex_);
    consumer_.reset();
    core_->detach();
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
    if (offer.result == FJCameraFrameProcessorCore::OfferResult::Detached) {
        if (!loggedDetachedOffer_) {
            loggedDetachedOffer_ = true;
            logWarning("camera frames arrive but no consumer is attached");
        }
        return -1;
    }
    if (offer.result != FJCameraFrameProcessorCore::OfferResult::Accepted) {
        return -1;
    }

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY || eglGetCurrentContext() == EGL_NO_CONTEXT) {
        if (!loggedNoContext_) {
            loggedNoContext_ = true;
            logWarning("no EGL context is current on the capture thread; frames cannot be blitted");
        }
        core_->abandoned(offer.token);
        return -1;
    }

    const int slotIndex = acquireSlot();
    if (slotIndex < 0) {
        core_->abandoned(offer.token);
        return -1;
    }
    // The slot is marked in use, so a consumer release running concurrently
    // cannot touch it while its buffer is (re)built here outside the lock.
    Slot &slot = slotState_->slots[slotIndex];
    if (!prepareSlot(slot, width, height, display)) {
        releaseSlot(*slotState_, slotIndex);
        core_->abandoned(offer.token);
        return -1;
    }
    pendingSlot_ = slotIndex;
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

    // Held through delivery: a detach that lands now waits for onFrame to
    // return, and one that already landed left consumer_ empty.
    std::lock_guard<std::mutex> lock(consumerMutex_);
    if (!consumer_) {
        releaseSlot(*slotState_, slotIndex);
        core_->abandoned(token);
        return;
    }

    const std::optional<int32_t> acquireFence = createAcquireFence(eglGetCurrentDisplay());
    if (!acquireFence) {
        releaseSlot(*slotState_, slotIndex);
        core_->abandoned(token);
        return;
    }

    const Slot &slot = slotState_->slots[slotIndex];
    AHardwareBuffer *buffer = slot.buffer;
    if (__builtin_available(android 26, *)) {
        AHardwareBuffer_acquire(buffer);
    }
    const auto nativeBuffer = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(buffer));
    const int32_t acquireFenceFileDescriptor = *acquireFence;

    std::shared_ptr<SlotState> slotState = slotState_;
    std::shared_ptr<FJCameraFrameProcessorCore> core = core_;
    auto frame =
        std::make_shared<FJCameraFrame>(nativeBuffer,
                                        slot.width,
                                        slot.height,
                                        static_cast<int32_t>(rotationDegrees),
                                        isFrontCamera == JNI_TRUE,
                                        static_cast<int64_t>(timestampNanoseconds),
                                        FJCameraPixelFormat::RGBA8,
                                        acquireFenceFileDescriptor,
                                        [slotState, core, slotIndex, token, acquireFenceFileDescriptor, buffer]() {
                                            close(acquireFenceFileDescriptor);
                                            if (__builtin_available(android 26, *)) {
                                                AHardwareBuffer_release(buffer);
                                            }
                                            releaseSlot(*slotState, slotIndex);
                                            core->completed(token);
                                        });
    consumer_->onFrame(std::move(frame));
}

void FJCameraFrameTap::abortBlit() {
    if (pendingSlot_ < 0) {
        return;
    }
    const int slotIndex = pendingSlot_;
    const uint64_t token = pendingToken_;
    pendingSlot_ = -1;
    releaseSlot(*slotState_, slotIndex);
    core_->abandoned(token);
}

int FJCameraFrameTap::acquireSlot() {
    std::lock_guard<std::mutex> lock(slotState_->mutex);
    for (int step = 0; step < kSlotCount; ++step) {
        const int candidate = (slotState_->nextSlot + step) % kSlotCount;
        Slot &slot = slotState_->slots[candidate];
        if (!slot.inUse) {
            slot.inUse = true;
            slotState_->nextSlot = (candidate + 1) % kSlotCount;
            return candidate;
        }
    }
    return -1;
}

void FJCameraFrameTap::releaseSlot(SlotState &slotState, int slotIndex) {
    std::lock_guard<std::mutex> lock(slotState.mutex);
    slotState.slots[slotIndex].inUse = false;
}

void FJCameraFrameTap::releaseGl() {
    detachConsumer();
    pendingSlot_ = -1;
    EGLDisplay display = eglGetCurrentDisplay();
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
    slot.image = clientBuffer == nullptr
                     ? EGL_NO_IMAGE_KHR
                     : extensions.eglCreateImageKHR(
                           display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, clientBuffer, imageAttributes);
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
            __android_log_print(ANDROID_LOG_WARN,
                                kLogTag,
                                "CameraFrameTap: slot setup failed (glError=0x%x, framebufferStatus=0x%x)",
                                textureError,
                                framebufferStatus);
        }
        destroySlot(slot, display);
        return false;
    }

    slot.width = width;
    slot.height = height;
    slot.loggedFailure = false;
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

std::optional<int32_t> FJCameraFrameTap::createAcquireFence(EGLDisplay display) {
    const gl::EglExtensions &extensions = gl::eglExtensions();
    const bool hasNativeFenceSync = display != EGL_NO_DISPLAY && extensions.eglCreateSyncKHR != nullptr &&
                                    extensions.eglDupNativeFenceFDANDROID != nullptr &&
                                    extensions.eglDestroySyncKHR != nullptr;
    EGLSyncKHR sync = hasNativeFenceSync ? extensions.eglCreateSyncKHR(display, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr)
                                         : EGL_NO_SYNC_KHR;
    if (sync == EGL_NO_SYNC_KHR) {
        if (!loggedNoNativeFence_) {
            loggedNoNativeFence_ = true;
            logWarning(
                "EGL_ANDROID_native_fence_sync unavailable; this device has no native fence sync, so camera frames "
                "will not be processed");
        }
        return std::nullopt;
    }
    glFlush();
    const EGLint fileDescriptor = extensions.eglDupNativeFenceFDANDROID(display, sync);
    extensions.eglDestroySyncKHR(display, sync);
    if (fileDescriptor < 0) {
        if (!loggedNoNativeFence_) {
            loggedNoNativeFence_ = true;
            logWarning("eglDupNativeFenceFDANDROID failed; camera frames will not be processed");
        }
        return std::nullopt;
    }
    return fileDescriptor;
}

void FJCameraFrameTap::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJCameraFrameTap::initHybrid),
        makeNativeMethod("beginBlit", FJCameraFrameTap::beginBlit),
        makeNativeMethod("endBlit", FJCameraFrameTap::endBlit),
        makeNativeMethod("abortBlit", FJCameraFrameTap::abortBlit),
        makeNativeMethod("releaseGl", FJCameraFrameTap::releaseGl),
    });
}

}  // namespace fishjam::video
