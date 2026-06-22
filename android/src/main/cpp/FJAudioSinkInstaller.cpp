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

void FJAudioSinkInstaller::configureTrack(jint pcId, jni::alias_ref<jstring> trackId, jint outRate,
                                          jint outChannels, jboolean formatF32, jint lpfOrder,
                                          jdouble batchMs) {
    std::lock_guard<std::mutex> lock(tracksMutex_);
    // Replace any existing entry's config; tear down its converter first so a
    // re-start with different options doesn't leak the old miniaudio state.
    TrackConverter &state = tracks_[trackId->toStdString()];
    if (state.ready) {
        ma_data_converter_uninit(&state.converter, nullptr);
        state.ready = false;
        state.inRate = 0;
        state.inChannels = 0;
    }
    state.pcId = pcId;
    state.requestedOutRate = outRate;
    state.outRate = outRate;
    state.outChannels = outChannels;
    state.outFormat = formatF32 ? ma_format_f32 : ma_format_s16;
    state.lpfOrder = lpfOrder;
    state.batchMs = batchMs;
    state.inputBuffer.clear();
}

// Mirrors iOS -ensureConverterForRate:channels:. Caller holds tracksMutex_.
void FJAudioSinkInstaller::ensureConverter(TrackConverter &state, int sampleRate, int channels) {
    if (state.ready && sampleRate == state.inRate && channels == state.inChannels) {
        return;
    }
    if (state.ready) {
        ma_data_converter_uninit(&state.converter, nullptr);
        state.ready = false;
    }
    state.inRate = sampleRate;
    state.inChannels = channels;
    int outRate = state.requestedOutRate > 0 ? state.requestedOutRate : sampleRate;  // outRate 0 => keep input rate

    ma_data_converter_config config = ma_data_converter_config_init(
        ma_format_s16, state.outFormat, static_cast<ma_uint32>(channels),
        static_cast<ma_uint32>(state.outChannels), static_cast<ma_uint32>(sampleRate),
        static_cast<ma_uint32>(outRate));
    config.resampling.algorithm = ma_resample_algorithm_linear;
    config.resampling.linear.lpfOrder = static_cast<ma_uint32>(state.lpfOrder);

    state.ready = (ma_data_converter_init(&config, nullptr, &state.converter) == MA_SUCCESS);
    state.outRate = outRate;
}

// Mirrors iOS -flush. Caller holds tracksMutex_.
void FJAudioSinkInstaller::flush(const std::string &trackId, TrackConverter &state) {
    if (!sink_->isInstalled() || !state.ready) {
        state.inputBuffer.clear();
        return;
    }

    size_t outBytesPerSample =
        (state.outFormat == ma_format_f32) ? sizeof(float) : sizeof(int16_t);
    const uint8_t *readPtr = state.inputBuffer.data();
    ma_uint64 framesRemaining = state.inputBuffer.size() / (state.inChannels * sizeof(int16_t));

    // One process call usually drains everything (the output is sized from the
    // expected frame count); loop defensively in case it doesn't.
    std::vector<uint8_t> output;
    while (framesRemaining > 0) {
        ma_uint64 expectedFrames = 0;
        ma_data_converter_get_expected_output_frame_count(&state.converter, framesRemaining,
                                                          &expectedFrames);
        if (expectedFrames == 0) {
            break;
        }
        size_t writeOffset = output.size();
        output.resize(writeOffset +
                      static_cast<size_t>(expectedFrames * state.outChannels * outBytesPerSample));

        ma_uint64 framesIn = framesRemaining;
        ma_uint64 framesOut = expectedFrames;
        if (ma_data_converter_process_pcm_frames(&state.converter, readPtr, &framesIn,
                                                 output.data() + writeOffset,
                                                 &framesOut) != MA_SUCCESS) {
            break;
        }
        output.resize(writeOffset +
                      static_cast<size_t>(framesOut * state.outChannels * outBytesPerSample));

        if (framesIn == 0) {
            break;  // made no progress; avoid spinning
        }
        readPtr += framesIn * state.inChannels * sizeof(int16_t);
        framesRemaining -= framesIn;
    }

    state.inputBuffer.clear();
    if (output.empty()) {
        return;
    }
    sink_->deliver(state.pcId, trackId, state.outRate, state.outChannels,
                   state.outFormat == ma_format_f32 ? "f32" : "s16", std::move(output));
}

void FJAudioSinkInstaller::onAudioData(jni::alias_ref<jstring> trackId,
                                       jni::alias_ref<jni::JByteBuffer> audioData, jint sampleRate,
                                       jint channels, jint frames) {
    // Wrapped in try/catch so a converter / JSI error drops the batch (mirroring
    // iOS dropping on JSError) rather than crossing back into the JVM.
    try {
        if (channels <= 0 || frames <= 0 || audioData == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(tracksMutex_);
        auto it = tracks_.find(trackId->toStdString());
        if (it == tracks_.end()) {
            return;
        }
        TrackConverter &state = it->second;

        ensureConverter(state, sampleRate, channels);

        // The direct ByteBuffer is backed by native memory that is only valid for
        // the duration of this call, so the int16 bytes are copied into inputBuffer.
        const uint8_t *src = static_cast<const uint8_t *>(audioData->getDirectAddress());
        size_t available = static_cast<size_t>(audioData->getDirectSize());
        size_t wanted = static_cast<size_t>(frames) * channels * sizeof(int16_t);
        size_t copyLen = wanted < available ? wanted : available;
        if (src == nullptr || copyLen == 0) {
            return;
        }
        state.inputBuffer.insert(state.inputBuffer.end(), src, src + copyLen);

        size_t bytesPerBatch = static_cast<size_t>(state.inRate * state.batchMs / 1000.0) *
                               state.inChannels * sizeof(int16_t);
        if (bytesPerBatch > 0 && state.inputBuffer.size() >= bytesPerBatch) {
            flush(it->first, state);
        }
    } catch (...) {
        // Drop this batch.
    }
}

void FJAudioSinkInstaller::removeTrack(jni::alias_ref<jstring> trackId) {
    std::lock_guard<std::mutex> lock(tracksMutex_);
    auto it = tracks_.find(trackId->toStdString());
    if (it == tracks_.end()) {
        return;
    }
    if (it->second.ready) {
        ma_data_converter_uninit(&it->second.converter, nullptr);
    }
    tracks_.erase(it);
}

void FJAudioSinkInstaller::registerNatives() {
    registerHybrid({
        makeNativeMethod("initHybrid", FJAudioSinkInstaller::initHybrid),
        makeNativeMethod("installSink", FJAudioSinkInstaller::installSink),
        makeNativeMethod("isInstalled", FJAudioSinkInstaller::isInstalled),
        makeNativeMethod("configureTrack", FJAudioSinkInstaller::configureTrack),
        makeNativeMethod("onAudioData", FJAudioSinkInstaller::onAudioData),
        makeNativeMethod("removeTrack", FJAudioSinkInstaller::removeTrack),
    });
}

}  // namespace fishjam

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    return facebook::jni::initialize(vm, [] { fishjam::FJAudioSinkInstaller::registerNatives(); });
}
