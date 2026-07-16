// JSI channel for pushing custom audio samples from JS to native.
//
// Installs `__fishjamWebrtcGetCustomAudioSink(trackId)` on the JS runtime, which
// returns a per-track `CustomAudioSink` host object with a `push(samples)`
// method. Because react-native-worklets serializes host objects *by reference*,
// the sink can be captured into a worklet and its `push` dispatches
// synchronously on the worklet thread to the same native instance — no hop.
//
// Unlike the video push channel (which routes each frame to a platform delivery
// callback), the audio channel owns the per-track pacing: each registered track
// has an FJAudioFrameScheduler that absorbs arbitrary-size pushes and feeds the
// platform emit callback exactly one 10 ms int16 frame at a time, in real time.
//
// Pure C++20; the jsi::Runtime is only touched on the JS/worklet thread.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

#include "FJAudioFrameScheduler.h"

class FJAudioPush;

// Per-track push handle handed to JS on `track.sink`. Holds only the bound
// `trackId` and a weak reference to the owning FJAudioPush; every `push`
// enqueues into that track's scheduler. Shared by reference into worklet
// runtimes, so `push` runs synchronously wherever it is called.
class CustomAudioSink : public facebook::jsi::HostObject {
   public:
    CustomAudioSink(std::weak_ptr<FJAudioPush> owner, std::string trackId)
        : owner_(std::move(owner)), trackId_(std::move(trackId)) {}

    facebook::jsi::Value get(facebook::jsi::Runtime &rt, const facebook::jsi::PropNameID &name) override;

   private:
    std::weak_ptr<FJAudioPush> owner_;
    std::string trackId_;
};

// Owns the JS-facing push channel and the per-track pacing schedulers. The
// platform layer registers a track (with its emit callback into the WebRTC
// external audio source) when the track is created, and unregisters it when the
// track is released.
class FJAudioPush : public std::enable_shared_from_this<FJAudioPush> {
   public:
    explicit FJAudioPush(std::shared_ptr<facebook::react::CallInvoker> jsInvoker) : jsInvoker_(std::move(jsInvoker)) {}

    // Installs the `__fishjamWebrtcGetCustomAudioSink` global; invokes
    // onInstalled on the JS thread once ready. Re-runnable after a JS reload.
    void install(std::function<void()> onInstalled);

    bool isInstalled() const { return installed_.load(); }

    // Creates and starts the pacing scheduler for `trackId`. `emit` is called
    // from the scheduler's feeder thread with one 10 ms int16 frame per call.
    void registerTrack(const std::string &trackId,
                       int sampleRateHz,
                       int channelCount,
                       int maxBufferedDurationMs,
                       FJAudioFrameScheduler::EmitFn emit);

    // Stops the feeder thread and removes the scheduler. Safe to call for an
    // unknown trackId. Pushes racing an unregister are dropped.
    void unregisterTrack(const std::string &trackId);

    // Parses a JS samples value (Float32Array | Int16Array | ArrayBuffer of
    // int16) and enqueues it into `trackId`'s scheduler. Runs on whatever thread
    // pushed (JS or worklet). Malformed input is dropped (never throws back into
    // JS on the hot path).
    void deliverSamples(facebook::jsi::Runtime &rt, const std::string &trackId, const facebook::jsi::Value &samples);

   private:
    // Returns a fresh sink host object bound to `trackId` (see the video twin
    // for why sinks are not cached natively).
    facebook::jsi::Value getSink(facebook::jsi::Runtime &rt, const std::string &trackId);

    std::shared_ptr<FJAudioFrameScheduler> schedulerForTrack(const std::string &trackId);

    std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
    std::mutex schedulersMutex_;
    std::unordered_map<std::string, std::shared_ptr<FJAudioFrameScheduler>> schedulers_;
    std::atomic<bool> installed_{false};
};
