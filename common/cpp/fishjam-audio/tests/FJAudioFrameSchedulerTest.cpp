// Host-side unit tests for FJAudioFrameScheduler (run via `npm run test:cpp`).
//
// Plain assert-style harness on purpose: the scheduler is dependency-free C++,
// and a gtest dependency would be the only reason this repo needs a C++ test
// framework. Timing-sensitive checks use generous margins so they stay stable
// on loaded CI machines; data-path checks (framing, truncation, conversion,
// overflow) pre-fill the FIFO before start() and are fully deterministic.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

#include "FJAudioFrameScheduler.h"

namespace {

int failures = 0;

#define CHECK(cond)                                                                    \
    do {                                                                               \
        if (!(cond)) {                                                                 \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);       \
            failures++;                                                                \
        }                                                                              \
    } while (0)

#define CHECK_EQ(a, b)                                                                 \
    do {                                                                               \
        auto va = (a);                                                                 \
        auto vb = (b);                                                                 \
        if (!(va == vb)) {                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s == %s (%lld vs %lld)\n", __FILE__,    \
                         __LINE__, #a, #b, (long long)va, (long long)vb);              \
            failures++;                                                                \
        }                                                                              \
    } while (0)

// Collects every emitted frame. Reads must happen after stop() (the join is the
// synchronization point); the mutex additionally covers mid-run reads.
struct FrameRecorder {
    std::mutex mutex;
    std::vector<std::vector<int16_t>> frames;

    FJAudioFrameScheduler::EmitFn emitFn(int channelCount) {
        return [this, channelCount](const int16_t *samples, size_t numberOfFrames) {
            std::lock_guard<std::mutex> lock(mutex);
            frames.emplace_back(samples, samples + numberOfFrames * static_cast<size_t>(channelCount));
        };
    }

    size_t frameCount() {
        std::lock_guard<std::mutex> lock(mutex);
        return frames.size();
    }
};

bool isSilence(const std::vector<int16_t> &frame) {
    return std::all_of(frame.begin(), frame.end(), [](int16_t s) { return s == 0; });
}

void sleepMs(int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// A scheduler with nothing pushed emits continuous, correctly-sized silence.
void testUnderrunEmitsSilence() {
    FrameRecorder recorder;
    FJAudioFrameScheduler scheduler(48000, 1, 1000, recorder.emitFn(1));
    scheduler.start();
    sleepMs(100);
    scheduler.stop();

    CHECK(recorder.frames.size() >= 2);
    for (const auto &frame : recorder.frames) {
        CHECK_EQ(frame.size(), static_cast<size_t>(480));
        CHECK(isSilence(frame));
    }
}

// Pre-filled FIFO drains in order, whole frames first, then silence resumes.
void testDataThenSilence() {
    FrameRecorder recorder;
    FJAudioFrameScheduler scheduler(48000, 1, 1000, recorder.emitFn(1));
    std::vector<int16_t> pcm(480 * 3, 1000);
    scheduler.enqueueInt16(pcm.data(), pcm.size());
    scheduler.start();
    sleepMs(100);
    scheduler.stop();

    CHECK(recorder.frames.size() >= 4);
    for (size_t i = 0; i < recorder.frames.size(); i++) {
        if (i < 3) {
            CHECK(!isSilence(recorder.frames[i]));
            CHECK(std::all_of(recorder.frames[i].begin(), recorder.frames[i].end(),
                              [](int16_t s) { return s == 1000; }));
        } else {
            CHECK(isSilence(recorder.frames[i]));
        }
    }
}

// Odd-size pushes to a stereo track are truncated to whole frames, so channels
// never swap — including across multiple odd pushes.
void testStereoOddPushKeepsAlignment() {
    FrameRecorder recorder;
    FJAudioFrameScheduler scheduler(48000, 2, 1000, recorder.emitFn(2));

    // One 10 ms stereo frame is 960 samples; push 961 (odd) twice. The trailing
    // sample of each push must be dropped, leaving exactly two aligned frames.
    std::vector<int16_t> pcm(961);
    for (size_t i = 0; i < pcm.size(); i++) {
        pcm[i] = (i % 2 == 0) ? 111 : 222;  // L=111, R=222
    }
    scheduler.enqueueInt16(pcm.data(), pcm.size());
    scheduler.enqueueInt16(pcm.data(), pcm.size());

    scheduler.start();
    sleepMs(60);
    scheduler.stop();

    size_t dataFrames = 0;
    for (const auto &frame : recorder.frames) {
        if (isSilence(frame)) {
            continue;
        }
        dataFrames++;
        CHECK_EQ(frame.size(), static_cast<size_t>(960));
        for (size_t i = 0; i < frame.size(); i++) {
            CHECK_EQ(frame[i], (i % 2 == 0) ? 111 : 222);
        }
    }
    CHECK_EQ(dataFrames, static_cast<size_t>(2));
}

// Float32 samples are converted with clamping to [-1, 1].
void testFloat32ConversionAndClamp() {
    FrameRecorder recorder;
    FJAudioFrameScheduler scheduler(48000, 1, 1000, recorder.emitFn(1));

    std::vector<float> pcm(480);
    for (size_t i = 0; i < pcm.size(); i += 4) {
        pcm[i] = 0.5f;
        pcm[i + 1] = -0.5f;
        pcm[i + 2] = 2.0f;   // clamps to 1.0
        pcm[i + 3] = -2.0f;  // clamps to -1.0
    }
    scheduler.enqueueFloat32(pcm.data(), pcm.size());
    scheduler.start();
    sleepMs(40);
    scheduler.stop();

    CHECK(!recorder.frames.empty());
    const auto &frame = recorder.frames.front();
    CHECK(!isSilence(frame));
    for (size_t i = 0; i + 3 < frame.size(); i += 4) {
        CHECK(std::abs(frame[i] - 16384) <= 1);
        CHECK(std::abs(frame[i + 1] + 16384) <= 1);
        CHECK_EQ(frame[i + 2], 32767);
        CHECK_EQ(frame[i + 3], -32767);
    }
}

// Overflow drops the OLDEST whole frames; what survives stays frame-aligned.
void testOverflowDropsOldestWholeFrames() {
    FrameRecorder recorder;
    // 20 ms capacity at 48 kHz mono = 960 samples = 2 frames.
    FJAudioFrameScheduler scheduler(48000, 1, 20, recorder.emitFn(1));

    // Push 5 frames, each filled with its index; only frames 3 and 4 fit.
    std::vector<int16_t> pcm(480 * 5);
    for (size_t i = 0; i < pcm.size(); i++) {
        pcm[i] = static_cast<int16_t>(i / 480);
    }
    scheduler.enqueueInt16(pcm.data(), pcm.size());
    scheduler.start();
    sleepMs(60);
    scheduler.stop();

    std::vector<int16_t> dataFrameValues;
    for (const auto &frame : recorder.frames) {
        if (isSilence(frame)) {
            continue;
        }
        CHECK(std::all_of(frame.begin(), frame.end(),
                          [&](int16_t s) { return s == frame.front(); }));
        dataFrameValues.push_back(frame.front());
    }
    CHECK_EQ(dataFrameValues.size(), static_cast<size_t>(2));
    if (dataFrameValues.size() == 2) {
        CHECK_EQ(dataFrameValues[0], 3);
        CHECK_EQ(dataFrameValues[1], 4);
    }
}

// A capacity below one 10 ms frame is clamped up to a whole frame, so pushed
// audio still comes out instead of being trimmed into permanent silence.
void testTinyCapacityStillEmitsData() {
    FrameRecorder recorder;
    // 5 ms capacity at 48 kHz mono would be 240 samples — half an emit frame.
    FJAudioFrameScheduler scheduler(48000, 1, 5, recorder.emitFn(1));
    std::vector<int16_t> pcm(480 * 3, 1000);
    scheduler.enqueueInt16(pcm.data(), pcm.size());
    scheduler.start();
    sleepMs(60);
    scheduler.stop();

    size_t dataFrames = 0;
    for (const auto &frame : recorder.frames) {
        if (!isSilence(frame)) {
            dataFrames++;
        }
    }
    CHECK(dataFrames >= 1);
}

// A throwing emit callback drops that frame; it must not unwind out of the
// feeder thread (process abort) and later frames must keep arriving.
void testEmitThrowKeepsFeederAlive() {
    std::mutex mutex;
    size_t calls = 0;
    size_t callsAfterThrows = 0;
    FJAudioFrameScheduler scheduler(48000, 1, 1000, [&](const int16_t *, size_t) {
        std::lock_guard<std::mutex> lock(mutex);
        calls++;
        if (calls <= 2) {
            throw std::runtime_error("emit failed");
        }
        callsAfterThrows++;
    });
    scheduler.start();
    sleepMs(100);
    scheduler.stop();

    // Surviving to here is the real assertion; the count confirms liveness.
    CHECK(callsAfterThrows >= 1);
}

// stop() joins the feeder: no emit ever lands after it returns. Double-stop and
// destructor-after-stop are safe.
void testStopIsFinalAndIdempotent() {
    FrameRecorder recorder;
    auto *scheduler = new FJAudioFrameScheduler(48000, 1, 1000, recorder.emitFn(1));
    scheduler->start();
    sleepMs(30);
    scheduler->stop();
    size_t countAfterStop = recorder.frameCount();
    sleepMs(50);
    CHECK_EQ(recorder.frameCount(), countAfterStop);
    scheduler->stop();  // second stop is a no-op
    delete scheduler;   // dtor calls stop() again
    CHECK_EQ(recorder.frameCount(), countAfterStop);
}

// Pacing sanity: ~10 ms cadence, with wide margins for loaded CI machines.
void testPacingIsRoughlyRealTime() {
    FrameRecorder recorder;
    FJAudioFrameScheduler scheduler(48000, 1, 1000, recorder.emitFn(1));
    scheduler.start();
    sleepMs(200);
    scheduler.stop();

    // Nominal 20 frames in 200 ms; accept 10..40 (never bursting, never stalled).
    size_t count = recorder.frameCount();
    CHECK(count >= 10);
    CHECK(count <= 40);
}

}  // namespace

int main() {
    testUnderrunEmitsSilence();
    testDataThenSilence();
    testStereoOddPushKeepsAlignment();
    testFloat32ConversionAndClamp();
    testOverflowDropsOldestWholeFrames();
    testTinyCapacityStillEmitsData();
    testEmitThrowKeepsFeederAlive();
    testStopIsFinalAndIdempotent();
    testPacingIsRoughlyRealTime();

    if (failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("FJAudioFrameScheduler: all tests passed\n");
    return 0;
}
