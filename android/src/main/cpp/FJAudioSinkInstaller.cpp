#include "FJAudioSinkInstaller.h"

namespace jni = facebook::jni;

namespace fishjam {

FJAudioSinkInstaller::FJAudioSinkInstaller(jni::alias_ref<jhybridobject> javaThis,
                                           std::shared_ptr<FJAudioSink> sink)
    : javaPart_(jni::make_global(javaThis)), sink_(std::move(sink)) {}

jni::local_ref<FJAudioSinkInstaller::jhybriddata> FJAudioSinkInstaller::initHybrid(
    jni::alias_ref<jhybridobject> javaThis,
    jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder) {
    // FJAudioSink only needs the JS CallInvoker; it acquires the jsi::Runtime
    // itself inside invokeAsync, so no runtime pointer is required here.
    auto callInvoker = callInvokerHolder->cthis()->getCallInvoker();
    return makeCxxInstance(javaThis, std::make_shared<FJAudioSink>(callInvoker));
}

void FJAudioSinkInstaller::installSink() {
    // FJAudioSink::install sets the global on the JS thread and then runs this
    // callback (also on the JS thread). We notify the Java peer there so the
    // Promise resolves strictly after the global exists. Capturing the
    // global_ref keeps the Java peer alive until the callback runs.
    auto javaPart = javaPart_;
    sink_->install([javaPart] {
        static const auto onSinkInstalled = javaPart->getClass()->getMethod<void()>("onSinkInstalled");
        onSinkInstalled(javaPart);
    });
}

bool FJAudioSinkInstaller::isInstalled() {
    return sink_->isInstalled();
}

void FJAudioSinkInstaller::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJAudioSinkInstaller::initHybrid),
        makeNativeMethod("installSink", FJAudioSinkInstaller::installSink),
        makeNativeMethod("isInstalled", FJAudioSinkInstaller::isInstalled),
    });
}

}  // namespace fishjam

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    return facebook::jni::initialize(vm, [] { fishjam::FJAudioSinkInstaller::registerNatives(); });
}
