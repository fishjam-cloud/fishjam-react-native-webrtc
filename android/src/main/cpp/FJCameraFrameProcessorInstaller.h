// fbjni HybridClass backing com.oney.WebRTCModule.FJCameraFrameProcessorInstaller.
//
// Owns the shared FJCameraFrameProcessorChannel that installs
// `__fishjamWebrtcGetCameraFrameProcessor(trackId)` on the JS runtime, and
// routes the channel's attach / detach / statistics calls to the Java peer,
// which resolves the track and its CameraFrameTapProcessor on the module
// executor.
#pragma once

#include <ReactCommon/CallInvokerHolder.h>
#include <fbjni/fbjni.h>

#include <memory>

#include "FJCameraFrameProcessorJSI.h"

namespace fishjam::video {

class FJCameraFrameProcessorInstaller : public facebook::jni::HybridClass<FJCameraFrameProcessorInstaller> {
   public:
    static constexpr auto kJavaDescriptor = "Lcom/oney/WebRTCModule/FJCameraFrameProcessorInstaller;";

    static facebook::jni::local_ref<jhybriddata> initHybrid(
        facebook::jni::alias_ref<jhybridobject> javaThis,
        facebook::jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder);

    static void registerNatives();

    // Sets the JS global on the JS thread, then calls the Java peer's
    // onInstalled() once it is in place.
    void install();

   private:
    friend HybridBase;

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJCameraFrameProcessorChannel> channel_;

    FJCameraFrameProcessorInstaller(facebook::jni::alias_ref<jhybridobject> javaThis,
                                    std::shared_ptr<FJCameraFrameProcessorChannel> channel);
};

}  // namespace fishjam::video
