#include "FJCameraFrameProcessorInstaller.h"

#include "FJCameraFrameTap.h"

namespace jni = facebook::jni;

namespace fishjam::video {

FJCameraFrameProcessorInstaller::FJCameraFrameProcessorInstaller(jni::alias_ref<jhybridobject> javaThis,
                                                                 std::shared_ptr<FJCameraFrameProcessorChannel> channel)
    : javaPart_(jni::make_global(javaThis)), channel_(std::move(channel)) {
    // The handlers run on the JS thread (a JVM-attached thread), so plain JNI
    // calls are fine. The Java peer hops to the module executor and blocks until
    // the tap is installed, mirroring dispatch_sync on the iOS worker queue.
    auto javaPart = javaPart_;
    FJCameraFrameProcessorChannel::Handlers handlers;
    handlers.attach = [javaPart](const std::string &trackId, std::shared_ptr<FJCameraFrameConsumer> consumer) {
        static const auto attachCameraFrameTap =
            javaPart->getClass()->getMethod<jstring(jni::alias_ref<jstring>)>("attachCameraFrameTap");
        static const auto getCameraFrameTap =
            javaPart->getClass()->getMethod<FJCameraFrameTap::javaobject(jni::alias_ref<jstring>)>(
                "getCameraFrameTap");
        jni::local_ref<jstring> errorCode = attachCameraFrameTap(javaPart, jni::make_jstring(trackId));
        std::string code = errorCode ? errorCode->toStdString() : std::string("E_ATTACH_FAILED");
        if (!code.empty()) {
            return code;
        }
        jni::local_ref<FJCameraFrameTap::javaobject> tap = getCameraFrameTap(javaPart, jni::make_jstring(trackId));
        if (!tap) {
            return std::string("E_NOT_A_CAMERA_TRACK");
        }
        tap->cthis()->attachConsumer(std::move(consumer));
        return std::string();
    };
    handlers.detach = [javaPart](const std::string &trackId) {
        static const auto detachCameraFrameTap =
            javaPart->getClass()->getMethod<void(jni::alias_ref<jstring>)>("detachCameraFrameTap");
        detachCameraFrameTap(javaPart, jni::make_jstring(trackId));
    };
    handlers.statistics = [javaPart](const std::string &trackId, FJCameraFrameProcessorCore::Statistics &out) {
        static const auto getCameraFrameTap =
            javaPart->getClass()->getMethod<FJCameraFrameTap::javaobject(jni::alias_ref<jstring>)>(
                "getCameraFrameTap");
        jni::local_ref<FJCameraFrameTap::javaobject> tap = getCameraFrameTap(javaPart, jni::make_jstring(trackId));
        if (!tap) {
            return false;
        }
        out = tap->cthis()->statistics();
        return true;
    };
    channel_->setHandlers(std::move(handlers));
}

jni::local_ref<FJCameraFrameProcessorInstaller::jhybriddata> FJCameraFrameProcessorInstaller::initHybrid(
    jni::alias_ref<jhybridobject> javaThis,
    jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder) {
    auto callInvoker = callInvokerHolder->cthis()->getCallInvoker();
    return makeCxxInstance(javaThis, std::make_shared<FJCameraFrameProcessorChannel>(callInvoker));
}

void FJCameraFrameProcessorInstaller::install() {
    auto javaPart = javaPart_;
    channel_->install([javaPart] {
        static const auto onInstalled = javaPart->getClass()->getMethod<void()>("onInstalled");
        onInstalled(javaPart);
    });
}

void FJCameraFrameProcessorInstaller::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJCameraFrameProcessorInstaller::initHybrid),
        makeNativeMethod("installNative", FJCameraFrameProcessorInstaller::install),
    });
}

}  // namespace fishjam::video
