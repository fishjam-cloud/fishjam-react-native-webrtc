#include "FJAudioFrameScheduler.h"

#include <algorithm>
#include <chrono>
#include <cmath>

namespace {
constexpr int kEmitsPerSecond = 100;  // one frame every 10 ms
constexpr auto kEmitInterval = std::chrono::milliseconds(10);

int16_t floatSampleToInt16(float sample) {
    float clamped = std::clamp(sample, -1.0f, 1.0f);
    return static_cast<int16_t>(std::lrintf(clamped * 32767.0f));
}
}  // namespace

FJAudioFrameScheduler::FJAudioFrameScheduler(int sampleRateHz,
                                             int channelCount,
                                             int maxBufferedDurationMs,
                                             EmitFn emit)
    : sampleRateHz_(sampleRateHz),
      channelCount_(channelCount),
      samplesPerEmit_(static_cast<size_t>(sampleRateHz / kEmitsPerSecond) * static_cast<size_t>(channelCount)),
      maxBufferedSamples_(static_cast<size_t>(sampleRateHz) * static_cast<size_t>(channelCount) *
                          static_cast<size_t>(maxBufferedDurationMs) / 1000),
      emit_(std::move(emit)) {}

FJAudioFrameScheduler::~FJAudioFrameScheduler() {
    stop();
}

void FJAudioFrameScheduler::start() {
    if (running_.exchange(true)) {
        return;
    }
    emitScratch_.assign(samplesPerEmit_, 0);
    feeder_ = std::thread([this] { feederLoop(); });
}

void FJAudioFrameScheduler::stop() {
    if (!running_.exchange(false)) {
        return;
    }
    if (feeder_.joinable()) {
        feeder_.join();
    }
}

void FJAudioFrameScheduler::enqueueInt16(const int16_t *interleavedSamples, size_t sampleCount) {
    if (interleavedSamples == nullptr || sampleCount == 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(fifoMutex_);
    fifo_.insert(fifo_.end(), interleavedSamples, interleavedSamples + sampleCount);
    dropOldestBeyondCapacityLocked();
}

void FJAudioFrameScheduler::enqueueFloat32(const float *samples, size_t sampleCount) {
    if (samples == nullptr || sampleCount == 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(fifoMutex_);
    for (size_t i = 0; i < sampleCount; i++) {
        fifo_.push_back(floatSampleToInt16(samples[i]));
    }
    dropOldestBeyondCapacityLocked();
}

void FJAudioFrameScheduler::dropOldestBeyondCapacityLocked() {
    if (fifo_.size() <= maxBufferedSamples_) {
        return;
    }
    // Drop whole emit frames so the stream stays frame-aligned after overflow.
    size_t excess = fifo_.size() - maxBufferedSamples_;
    size_t framesToDrop = (excess + samplesPerEmit_ - 1) / samplesPerEmit_;
    size_t samplesToDrop = std::min(fifo_.size(), framesToDrop * samplesPerEmit_);
    fifo_.erase(fifo_.begin(), fifo_.begin() + static_cast<ptrdiff_t>(samplesToDrop));
}

void FJAudioFrameScheduler::feederLoop() {
    auto nextDeadline = std::chrono::steady_clock::now() + kEmitInterval;
    while (running_.load()) {
        {
            std::lock_guard<std::mutex> lock(fifoMutex_);
            if (fifo_.size() >= samplesPerEmit_) {
                std::copy(fifo_.begin(), fifo_.begin() + static_cast<ptrdiff_t>(samplesPerEmit_),
                          emitScratch_.begin());
                fifo_.erase(fifo_.begin(), fifo_.begin() + static_cast<ptrdiff_t>(samplesPerEmit_));
            } else {
                // Less than a whole frame buffered: emit silence and leave the
                // partial data for the next tick, keeping the stream continuous.
                std::fill(emitScratch_.begin(), emitScratch_.end(), 0);
            }
        }
        emit_(emitScratch_.data(), samplesPerEmit_ / static_cast<size_t>(channelCount_));

        std::this_thread::sleep_until(nextDeadline);
        nextDeadline += kEmitInterval;
        // If emission fell far behind (system sleep, debugger pause), resync
        // instead of bursting a backlog of frames at the encoder.
        auto now = std::chrono::steady_clock::now();
        if (nextDeadline + kEmitInterval < now) {
            nextDeadline = now + kEmitInterval;
        }
    }
}
