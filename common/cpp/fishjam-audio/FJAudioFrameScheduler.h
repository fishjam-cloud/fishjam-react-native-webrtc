// Real-time pacing engine for one custom audio track.
//
// JS pushes arbitrary-size PCM whenever it has it; the underlying WebRTC
// external audio source expects exactly one 10 ms int16 frame per call, in real
// time. This scheduler sits between the two: an int16 FIFO absorbs the pushes,
// and a dedicated feeder thread emits fixed 10 ms frames on an absolute-deadline
// clock, substituting silence whenever the FIFO holds less than a whole frame —
// so the track behaves like a continuous live microphone.
//
// Pure C++20, no JSI and no platform types; the platform layer injects the
// per-frame emit callback.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

class FJAudioFrameScheduler {
   public:
    // Called once per 10 ms frame from the feeder thread with exactly
    // `sampleRateHz / 100` frames of interleaved int16 samples.
    using EmitFn = std::function<void(const int16_t *interleavedSamples, size_t numberOfFrames)>;

    FJAudioFrameScheduler(int sampleRateHz, int channelCount, int maxBufferedDurationMs, EmitFn emit);
    ~FJAudioFrameScheduler();

    FJAudioFrameScheduler(const FJAudioFrameScheduler &) = delete;
    FJAudioFrameScheduler &operator=(const FJAudioFrameScheduler &) = delete;

    void start();
    // Stops and joins the feeder thread. Safe to call twice; called by the dtor.
    void stop();

    // Append interleaved int16 samples (sampleCount = frames * channels). May be
    // called from any thread; the FIFO mutex is the only lock taken.
    void enqueueInt16(const int16_t *interleavedSamples, size_t sampleCount);
    // Append Float32 samples in [-1, 1]; converted (with clamping) to int16.
    void enqueueFloat32(const float *samples, size_t sampleCount);

    int sampleRateHz() const { return sampleRateHz_; }
    int channelCount() const { return channelCount_; }

   private:
    void feederLoop();
    void dropOldestBeyondCapacityLocked();

    const int sampleRateHz_;
    const int channelCount_;
    // One 10 ms frame, in samples (frames * channels).
    const size_t samplesPerEmit_;
    const size_t maxBufferedSamples_;
    const EmitFn emit_;

    std::mutex fifoMutex_;
    std::deque<int16_t> fifo_;

    std::atomic<bool> running_{false};
    std::thread feeder_;
    // Scratch for the frame handed to emit_; owned by the feeder thread.
    std::vector<int16_t> emitScratch_;
};
