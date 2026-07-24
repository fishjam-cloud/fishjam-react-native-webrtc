// fbjni HybridClass backing com.oney.WebRTCModule.FJAudioPushInstaller.
//
// Installs the JS global `__fishjamWebrtcGetCustomAudioSink` on the JS thread
// (via the CallInvoker), then notifies the Java peer so the install Promise
// resolves only once the global exists. Owns the per-track pacing schedulers:
// registerTrack starts one (whose feeder thread calls the Java peer's
// emitAudioFrame(...) with each 10 ms frame), unregisterTrack stops it.
#pragma once

#include <ReactCommon/CallInvokerHolder.h>
#include <fbjni/fbjni.h>

#include <memory>

#include "FJAudioPushJSI.h"

namespace fishjam {

class FJAudioPushInstaller : public facebook::jni::HybridClass<FJAudioPushInstaller> {
   public:
    static constexpr auto kJavaDescriptor = "Lcom/oney/WebRTCModule/FJAudioPushInstaller;";

    static facebook::jni::local_ref<jhybriddata> initHybrid(
        facebook::jni::alias_ref<jhybridobject> javaThis,
        facebook::jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder);

    static void registerNatives();

    // Sets the JS global on the JS thread, then calls the Java peer's
    // onPushInstalled() once it is in place.
    void installPush();

    // Starts the pacing scheduler for trackId; its feeder thread emits 10 ms
    // frames back to the Java peer via emitAudioFrame.
    void nativeRegisterTrack(facebook::jni::alias_ref<jstring> trackId,
                             jint sampleRateHz,
                             jint channelCount,
                             jint maxBufferedDurationMs);

    // Stops the feeder thread and removes the scheduler.
    void nativeUnregisterTrack(facebook::jni::alias_ref<jstring> trackId);

   private:
    friend HybridBase;

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJAudioPush> push_;

    FJAudioPushInstaller(facebook::jni::alias_ref<jhybridobject> javaThis, std::shared_ptr<FJAudioPush> push);
};

}  // namespace fishjam
