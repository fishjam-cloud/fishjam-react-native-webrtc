#include "FJAudioPushInstaller.h"

#include <fbjni/ByteBuffer.h>

// facebook::jni::ThreadScope is declared in <fbjni/detail/Environment.h>, pulled
// in transitively by <fbjni/fbjni.h> (included from FJAudioPushInstaller.h).

namespace jni = facebook::jni;

namespace fishjam {

FJAudioPushInstaller::FJAudioPushInstaller(jni::alias_ref<jhybridobject> javaThis,
                                           std::shared_ptr<FJAudioPush> push)
    : javaPart_(jni::make_global(javaThis)), push_(std::move(push)) {}

jni::local_ref<FJAudioPushInstaller::jhybriddata> FJAudioPushInstaller::initHybrid(
    jni::alias_ref<jhybridobject> javaThis,
    jni::alias_ref<facebook::react::CallInvokerHolder::javaobject> callInvokerHolder) {
    // FJAudioPush only needs the JS CallInvoker; it acquires the jsi::Runtime
    // itself inside invokeAsync, so no runtime pointer is required here.
    auto callInvoker = callInvokerHolder->cthis()->getCallInvoker();
    return makeCxxInstance(javaThis, std::make_shared<FJAudioPush>(callInvoker));
}

void FJAudioPushInstaller::installPush() {
    // FJAudioPush::install sets the global on the JS thread and then runs this
    // callback (also on the JS thread). We notify the Java peer there so the
    // Promise resolves strictly after the global exists.
    auto javaPart = javaPart_;
    push_->install([javaPart] {
        static const auto onPushInstalled = javaPart->getClass()->getMethod<void()>("onPushInstalled");
        onPushInstalled(javaPart);
    });
}

void FJAudioPushInstaller::nativeRegisterTrack(jni::alias_ref<jstring> trackId,
                                               jint sampleRateHz,
                                               jint channelCount,
                                               jint maxBufferedDurationMs) {
    auto javaPart = javaPart_;
    std::string trackIdString = trackId->toStdString();
    int channels = channelCount;
    // The scheduler feeder thread runs this emit callback with one 10 ms frame
    // per call. It is NOT attached to the JVM, so establish a ThreadScope before
    // touching any JNIEnv. The direct ByteBuffer wraps the scheduler's scratch
    // (no copy); the Java peer's emitAudioFrame consumes it synchronously (the
    // external audio source copies the samples), so reusing the scratch next
    // tick is safe.
    push_->registerTrack(
        trackIdString, sampleRateHz, channels, maxBufferedDurationMs,
        [javaPart, trackIdString, channels](const int16_t *interleavedSamples, size_t numberOfFrames) {
            facebook::jni::ThreadScope threadScope;
            size_t byteLength = numberOfFrames * static_cast<size_t>(channels) * sizeof(int16_t);
            auto directBuffer = jni::JByteBuffer::wrapBytes(
                reinterpret_cast<uint8_t *>(const_cast<int16_t *>(interleavedSamples)), byteLength);
            static const auto emitAudioFrame =
                javaPart->getClass()
                    ->getMethod<void(jni::alias_ref<jstring>, jni::alias_ref<jni::JByteBuffer>, jint)>(
                        "emitAudioFrame");
            emitAudioFrame(javaPart, jni::make_jstring(trackIdString), directBuffer,
                           static_cast<jint>(numberOfFrames));
        });
}

void FJAudioPushInstaller::nativeUnregisterTrack(jni::alias_ref<jstring> trackId) {
    push_->unregisterTrack(trackId->toStdString());
}

void FJAudioPushInstaller::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJAudioPushInstaller::initHybrid),
        makeNativeMethod("installPush", FJAudioPushInstaller::installPush),
        makeNativeMethod("nativeRegisterTrack", FJAudioPushInstaller::nativeRegisterTrack),
        makeNativeMethod("nativeUnregisterTrack", FJAudioPushInstaller::nativeUnregisterTrack),
    });
}

}  // namespace fishjam

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    return facebook::jni::initialize(vm, [] { fishjam::FJAudioPushInstaller::registerNatives(); });
}
