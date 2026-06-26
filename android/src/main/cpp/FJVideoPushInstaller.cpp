#include "FJVideoPushInstaller.h"

namespace jni = facebook::jni;

namespace fishjam {

FJVideoPushInstaller::FJVideoPushInstaller(jni::alias_ref<jhybridobject> javaThis,
                                           std::shared_ptr<FJVideoPush> push)
    : javaPart_(jni::make_global(javaThis)), push_(std::move(push)) {
    // Route every JS-pushed frame back to the Java peer, which forwards it to the
    // matching CustomVideoFrameDelivery. The deliver callback runs on the JS
    // thread (a JVM thread), so calling into Java via JNI here is valid. On
    // Android the fence is a sync-fd carried in fenceHandle; fenceSignaledValue is
    // unused (the fd already encodes the signal) but is forwarded for parity with
    // the shared DeliverFn contract. Capturing the global_ref keeps the Java peer
    // alive for the lifetime of the callback.
    auto javaPart = javaPart_;
    push_->setDeliver([javaPart](const std::string &trackId, int bufferIndex, uint64_t timestampNs,
                                 int rotation, uint64_t fenceHandle, uint64_t fenceSignaledValue) {
        static const auto deliverFrame =
            javaPart->getClass()
                ->getMethod<void(jni::alias_ref<jstring>, jint, jlong, jint, jlong, jlong)>(
                    "deliverFrame");
        deliverFrame(javaPart, jni::make_jstring(trackId), static_cast<jint>(bufferIndex),
                     static_cast<jlong>(timestampNs), static_cast<jint>(rotation),
                     static_cast<jlong>(fenceHandle), static_cast<jlong>(fenceSignaledValue));
    });
}

jni::local_ref<FJVideoPushInstaller::jhybriddata> FJVideoPushInstaller::initHybrid(
    jni::alias_ref<jhybridobject> javaThis,
    jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder) {
    // FJVideoPush only needs the JS CallInvoker; it acquires the jsi::Runtime
    // itself inside invokeAsync, so no runtime pointer is required here.
    auto callInvoker = callInvokerHolder->cthis()->getCallInvoker();
    return makeCxxInstance(javaThis, std::make_shared<FJVideoPush>(callInvoker));
}

void FJVideoPushInstaller::installPush() {
    // FJVideoPush::install sets the global on the JS thread and then runs this
    // callback (also on the JS thread). We notify the Java peer there so the
    // Promise resolves strictly after the global exists. Capturing the global_ref
    // keeps the Java peer alive until the callback runs.
    auto javaPart = javaPart_;
    push_->install([javaPart] {
        static const auto onPushInstalled = javaPart->getClass()->getMethod<void()>("onPushInstalled");
        onPushInstalled(javaPart);
    });
}

bool FJVideoPushInstaller::isInstalled() {
    return push_->isInstalled();
}

void FJVideoPushInstaller::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJVideoPushInstaller::initHybrid),
        makeNativeMethod("installPush", FJVideoPushInstaller::installPush),
        makeNativeMethod("isInstalled", FJVideoPushInstaller::isInstalled),
    });
}

}  // namespace fishjam

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    return facebook::jni::initialize(vm, [] { fishjam::FJVideoPushInstaller::registerNatives(); });
}
