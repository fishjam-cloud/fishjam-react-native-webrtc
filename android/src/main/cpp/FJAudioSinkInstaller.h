// fbjni HybridClass backing com.oney.WebRTCModule.FJAudioSinkInstaller.
//
// Installs the JS global `__fishjamWebrtcSetAudioSink` on the JS thread (via the
// CallInvoker), then notifies the Java peer so the install Promise resolves only
// once the global actually exists.
#pragma once

#include <ReactCommon/CallInvokerHolder.h>
#include <fbjni/ByteBuffer.h>
#include <fbjni/fbjni.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "FJAudioSinkJSI.h"
#include "miniaudio.h"

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

    // --- Audio extraction (mirrors the iOS FJAudioSinkRenderer) ---

    // Creates/replaces the requested output config for a track. The miniaudio
    // converter itself is created lazily on the first onAudioData call, once the
    // input rate/channels are known (like iOS -ensureConverterForRate:channels:).
    // Called on the native-modules thread.
    void configureTrack(jint pcId,
                        facebook::jni::alias_ref<jstring> trackId,
                        jint outRate,
                        jint outChannels,
                        jboolean formatF32,
                        jint lpfOrder,
                        jdouble batchMs);

    // Accumulates one int16 PCM chunk for a track, converts and delivers a batch
    // to JS once enough is buffered. Called on a WebRTC audio thread; the direct
    // ByteBuffer is only valid for the duration of this call, so its bytes are
    // copied before returning.
    void onAudioData(facebook::jni::alias_ref<jstring> trackId,
                     facebook::jni::alias_ref<facebook::jni::JByteBuffer> audioData,
                     jint sampleRate,
                     jint channels,
                     jint frames);

    // Tears down and removes a track's converter. Called on the native-modules
    // thread.
    void removeTrack(facebook::jni::alias_ref<jstring> trackId);

   private:
    friend HybridBase;

    // Per-track conversion state. Ports the iOS FJAudioSinkRenderer ivars: the
    // converter persists across flushes (keeping its resampler filter state) and
    // is re-initialised only when the input rate or channel count changes.
    struct TrackConverter {
        int pcId = 0;

        // Requested output config (from startAudioExtraction options).
        int requestedOutRate = 16000;  // user-supplied; 0 = follow input rate
        int outRate = 16000;           // resolved: equals requestedOutRate, or actual input rate when 0
        int outChannels = 1;
        int lpfOrder = 1;
        ma_format outFormat = ma_format_f32;
        double batchMs = 100.0;

        // Lazily inited; re-inited on input rate/channel change.
        ma_data_converter converter{};
        bool ready = false;
        int inRate = 0;
        int inChannels = 0;

        std::vector<uint8_t> inputBuffer;
    };

    // Lazily inits/re-inits the track's converter for the given input format.
    // Caller must hold tracksMutex_.
    void ensureConverter(TrackConverter &state, int sampleRate, int channels);

    // Drains state.inputBuffer through the converter and delivers it to JS, then
    // clears the buffer. Caller must hold tracksMutex_.
    void flush(const std::string &trackId, TrackConverter &state);

    facebook::jni::global_ref<javaobject> javaPart_;
    std::shared_ptr<FJAudioSink> sink_;

    // Guards tracks_ and each entry's converter: onAudioData runs on a WebRTC
    // audio thread, configureTrack/removeTrack on the native-modules thread.
    std::mutex tracksMutex_;
    std::unordered_map<std::string, TrackConverter> tracks_;

    FJAudioSinkInstaller(facebook::jni::alias_ref<jhybridobject> javaThis, std::shared_ptr<FJAudioSink> sink);
};

}  // namespace fishjam
