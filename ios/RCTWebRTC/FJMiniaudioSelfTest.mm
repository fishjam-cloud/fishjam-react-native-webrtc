// =============================================================================
// PHASE-1 TEMPORARY SELF-TEST — DELETE IN PHASE 3.
//
// This file is an isolated, throwaway proof that the conversion-only miniaudio
// build (Phase 1) actually compiles, links and converts. It exists ONLY to make
// the Phase-1 review criterion ("compiles + links + converts 48k -> 16k")
// observable at runtime. It is gated behind `#if DEBUG` and wired to run once
// automatically via `+load`. It has no production responsibilities and MUST be
// removed wholesale in Phase 3 (when the real native sink lands). Removing this
// single file fully reverts the self-test.
//
// It deliberately `#include`s "miniaudio.h" WITHOUT defining MA_IMPLEMENTATION,
// so it is a *consumer* translation unit and proves it links against the single
// implementation TU (vendor/miniaudio.c).
// =============================================================================

#if DEBUG

#import <Foundation/Foundation.h>

#include "miniaudio.h"

@interface FJMiniaudioSelfTest : NSObject
@end

@implementation FJMiniaudioSelfTest

+ (void)load {
    // Conversion-only contract: int16 stereo @ 48000 -> int16 mono @ 16000.
    // (s16 output keeps the test independent of the f32 default; the resampler
    //  path is identical regardless of output format.)
    const ma_uint32 inRate = 48000;
    const ma_uint32 outRate = 16000;
    const ma_uint32 inChannels = 2;
    const ma_uint32 outChannels = 1;

    // Field paths/signature verified against vendored miniaudio v0.11.25:
    //   ma_data_converter_config_init(formatIn, formatOut,
    //                                 channelsIn, channelsOut,
    //                                 sampleRateIn, sampleRateOut)
    //   config.resampling.algorithm        (ma_resample_algorithm)
    //   config.resampling.linear.lpfOrder  (ma_uint32)
    ma_data_converter_config config = ma_data_converter_config_init(
        ma_format_s16, ma_format_s16,
        inChannels, outChannels,
        inRate, outRate);
    config.resampling.algorithm = ma_resample_algorithm_linear;
    config.resampling.linear.lpfOrder = 1;

    ma_data_converter converter;
    ma_result initResult =
        ma_data_converter_init(&config, NULL, &converter);
    if (initResult != MA_SUCCESS) {
        NSLog(@"[FJMiniaudioSelfTest] FAIL: ma_data_converter_init returned %d",
              (int)initResult);
        return;
    }

    // 10 ms of input at 48 kHz = 480 frames. A simple int16 sine, interleaved
    // stereo, so the buffer is non-trivial (not pure silence).
    const ma_uint64 inFrameCount = 480;
    int16_t input[inFrameCount * 2 /* stereo */];
    for (ma_uint64 i = 0; i < inFrameCount; i++) {
        double t = (double)i / (double)inRate;
        int16_t sample = (int16_t)(10000.0 * sin(2.0 * M_PI * 440.0 * t));
        input[i * 2 + 0] = sample;  // L
        input[i * 2 + 1] = sample;  // R
    }

    // Expected output ~ inFrameCount * (outRate / inRate) = 480 / 3 = 160.
    ma_uint64 expectedOut = 0;
    ma_data_converter_get_expected_output_frame_count(&converter, inFrameCount,
                                                      &expectedOut);

    // Generously size the output (mono int16).
    ma_uint64 outCap = expectedOut + 64;
    int16_t *output = (int16_t *)malloc((size_t)(outCap * outChannels * sizeof(int16_t)));

    ma_uint64 inProcessed = inFrameCount;
    ma_uint64 outProcessed = outCap;
    ma_result procResult = ma_data_converter_process_pcm_frames(
        &converter, input, &inProcessed, output, &outProcessed);

    BOOL ok = (procResult == MA_SUCCESS);
    // 48k -> 16k is a 3:1 decimation: out frames should be ~ in/3.
    double ratio = inFrameCount > 0 ? (double)outProcessed / (double)inFrameCount : 0.0;
    BOOL ratioOk = (ratio > 0.28 && ratio < 0.40);  // ~0.333, allow filter latency slack

    if (ok && ratioOk) {
        NSLog(@"[FJMiniaudioSelfTest] PASS: 48k stereo -> 16k mono | "
              @"in=%llu frames, expected~%llu, out=%llu frames, ratio=%.3f (~1/3)",
              inFrameCount, expectedOut, outProcessed, ratio);
    } else {
        NSLog(@"[FJMiniaudioSelfTest] FAIL: procResult=%d in=%llu expected~%llu "
              @"out=%llu ratio=%.3f",
              (int)procResult, inFrameCount, expectedOut, outProcessed, ratio);
    }

    free(output);
    ma_data_converter_uninit(&converter, NULL);
}

@end

#endif  // DEBUG
