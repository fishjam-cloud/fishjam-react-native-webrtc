// fbjni HybridClass backing com.oney.WebRTCModule.FJAudioSinkInstaller.
//
// Installs the JS global `__fishjamWebrtcSetAudioSink` on the JS thread (via the
// CallInvoker), then notifies the Java peer so the install Promise resolves only
// once the global actually exists.
#pragma once

#include <ReactCommon/CallInvokerHolder.h>
#include <fbjni/fbjni.h>

#include <memory>

#include "FJAudioSinkJSI.h"

namespace fishjam {

class FJAudioSinkInstaller : public facebook::jni::HybridClass<FJAudioSinkInstaller> {
   public:
    static constexpr auto kJavaDescriptor = "Lcom/oney/WebRTCModule/FJAudioSinkInstaller;";

    static facebook::jni::local_ref<jhybriddata> initHybrid(
        facebook::jni::alias_ref<jhybridobject> javaThis,
        facebook::jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder);

    static void registerNatives();

    // Sets the JS global on the JS thread, then calls the Java peer's
    // onSinkInstalled() once it is in place.
    void installSink();

    bool isInstalled();

   private:
    friend HybridBase;

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJAudioSink> sink_;

    FJAudioSinkInstaller(facebook::jni::alias_ref<jhybridobject> javaThis,
                         std::shared_ptr<FJAudioSink> sink);
};

}  // namespace fishjam
