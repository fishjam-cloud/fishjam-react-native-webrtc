#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <WebRTC/RTCAudioRenderer.h>
#import <WebRTC/RTCAudioTrack.h>

#if __has_include(<React/RCTCallInvoker.h>)
#import <React/RCTCallInvoker.h>
#define FJ_HAS_CALL_INVOKER 1
#endif

#import "FJAudioSinkJSI.h"
#import "WebRTCModule.h"
#import "WebRTCModule+RTCMediaStream.h"

#include <vector>

#include "miniaudio.h"

#pragma mark - FJAudioSinkBox

// ObjC holder for the C++ shared_ptr<FJAudioSink>, stored on the module as an
// associated object (category has no ivars). Keeps the C++ type out of headers.
// Declared before the renderer because FJAudioSinkRenderer::flush dereferences it.
@interface FJAudioSinkBox : NSObject {
   @public
    std::shared_ptr<FJAudioSink> sink;
}
@end

@implementation FJAudioSinkBox
@end

#pragma mark - PCM batching renderer

// Batches input int16 PCM from a remote audio track (via the WebRTC SDK
// RTCAudioRenderer), converts each batch (sample-format + channel mix +
// anti-aliased resample) with a persistent miniaudio ma_data_converter, and
// delivers the converted PCM to JS over the JSI channel (FJAudioSink::deliver).
@interface FJAudioSinkRenderer : NSObject <RTC_OBJC_TYPE (RTCAudioRenderer)>
- (instancetype)initWithModule:(WebRTCModule *)module
                          pcId:(NSNumber *)pcId
                       trackId:(NSString *)trackId
                       outRate:(int)outRate
                   outChannels:(int)outChannels
                     outFormat:(ma_format)outFormat
                      lpfOrder:(int)lpfOrder
                       batchMs:(double)batchMs;
// Releases the converter (safe to call multiple times).
- (void)teardown;
@end

@implementation FJAudioSinkRenderer {
    __weak WebRTCModule *_module;
    NSNumber *_pcId;
    NSString *_trackId;
    NSMutableData *_buffer;  // accumulates input int16

    // Output config (from startAudioExtraction options).
    int _outRate;
    int _outChannels;
    int _lpfOrder;
    ma_format _outFormat;
    double _batchMs;

    // Converter state. Persists across flushes so the resampler keeps its
    // filter state (no boundary clicks). Re-inits if the input rate/channels
    // ever change.
    ma_data_converter _conv;
    BOOL _convReady;
    int _inRate;
    int _inChannels;
}

- (instancetype)initWithModule:(WebRTCModule *)module
                          pcId:(NSNumber *)pcId
                       trackId:(NSString *)trackId
                       outRate:(int)outRate
                   outChannels:(int)outChannels
                     outFormat:(ma_format)outFormat
                      lpfOrder:(int)lpfOrder
                       batchMs:(double)batchMs {
    if (self = [super init]) {
        _module = module;
        _pcId = pcId;
        _trackId = trackId;
        _buffer = [NSMutableData data];
        _outRate = outRate;
        _outChannels = outChannels;
        _outFormat = outFormat;
        _lpfOrder = lpfOrder;
        _batchMs = batchMs;
        _convReady = NO;
        _inRate = 0;
        _inChannels = 0;
    }
    return self;
}

- (void)renderPCMBuffer:(const void *)audioData
          bitsPerSample:(int)bitsPerSample
             sampleRate:(int)sampleRate
       numberOfChannels:(size_t)numberOfChannels
         numberOfFrames:(size_t)numberOfFrames {
    if (bitsPerSample != 16 || audioData == NULL || numberOfChannels == 0) {
        return;
    }
    [self ensureConverterForRate:sampleRate channels:(int)numberOfChannels];
    [_buffer appendBytes:audioData length:numberOfFrames * numberOfChannels * sizeof(int16_t)];

    NSUInteger flushBytes =
        (NSUInteger)(_inRate * _batchMs / 1000.0) * _inChannels * sizeof(int16_t);
    if (flushBytes > 0 && _buffer.length >= flushBytes) {
        [self flush];
    }
}

- (void)ensureConverterForRate:(int)sr channels:(int)ch {
    if (_convReady && sr == _inRate && ch == _inChannels) {
        return;
    }
    if (_convReady) {
        ma_data_converter_uninit(&_conv, NULL);
        _convReady = NO;
    }
    _inRate = sr;
    _inChannels = ch;
    int outRate = _outRate > 0 ? _outRate : sr;  // sampleRate:0 => keep input rate
    ma_data_converter_config c = ma_data_converter_config_init(
        ma_format_s16, _outFormat, (ma_uint32)ch, (ma_uint32)_outChannels, (ma_uint32)sr,
        (ma_uint32)outRate);
    c.resampling.algorithm = ma_resample_algorithm_linear;
    c.resampling.linear.lpfOrder = (ma_uint32)_lpfOrder;
    _convReady = (ma_data_converter_init(&c, NULL, &_conv) == MA_SUCCESS);
    _outRate = outRate;
}

- (void)flush {
    WebRTCModule *m = _module;
    FJAudioSinkBox *box = m ? [m fj_audioSinkBox] : nil;
    if (!box || !box->sink->isInstalled() || !_convReady) {
        _buffer.length = 0;
        return;
    }
    size_t outBps = (_outFormat == ma_format_f32) ? sizeof(float) : sizeof(int16_t);
    const uint8_t *inBytes = (const uint8_t *)_buffer.bytes;
    ma_uint64 inFramesRemaining = _buffer.length / (_inChannels * sizeof(int16_t));

    std::vector<uint8_t> out;
    // Usually a single process call drains all input (we size the output from
    // get_expected_output_frame_count). Loop defensively until input is consumed.
    while (inFramesRemaining > 0) {
        ma_uint64 expectedOut = 0;
        ma_data_converter_get_expected_output_frame_count(&_conv, inFramesRemaining, &expectedOut);
        if (expectedOut == 0) {
            // No output expected for the remaining input this pass; stop to avoid spinning.
            break;
        }
        size_t base = out.size();
        out.resize(base + (size_t)(expectedOut * _outChannels * outBps));

        ma_uint64 inC = inFramesRemaining;
        ma_uint64 outC = expectedOut;
        ma_result r = ma_data_converter_process_pcm_frames(&_conv, inBytes, &inC, out.data() + base,
                                                           &outC);
        if (r != MA_SUCCESS) {
            break;
        }
        // Trim to the frames actually produced this pass.
        out.resize(base + (size_t)(outC * _outChannels * outBps));

        if (inC == 0) {
            // Made no progress consuming input; bail to avoid an infinite loop.
            break;
        }
        inBytes += inC * _inChannels * sizeof(int16_t);
        inFramesRemaining -= inC;
    }

    _buffer.length = 0;
    if (out.empty()) {
        return;
    }
    box->sink->deliver(_pcId.intValue, _trackId, _outRate, _outChannels,
                       _outFormat == ma_format_f32 ? "f32" : "s16", std::move(out));
}

- (void)teardown {
    if (_convReady) {
        ma_data_converter_uninit(&_conv, NULL);
        _convReady = NO;
    }
}

- (void)dealloc {
    [self teardown];
}

@end

#pragma mark - WebRTCModule (AudioSink)

@implementation WebRTCModule (AudioSink)

// Lazily creates the FJAudioSinkBox + FJAudioSink from the JS CallInvoker.
// Returns nil when no CallInvoker is available (old arch / no New Architecture).
- (FJAudioSinkBox *)fj_audioSinkBox {
#if FJ_HAS_CALL_INVOKER
    static const void *kAudioSinkBoxKey = &kAudioSinkBoxKey;
    FJAudioSinkBox *box = objc_getAssociatedObject(self, kAudioSinkBoxKey);
    if (box != nil) {
        return box;
    }
    RCTCallInvoker *invoker = self.callInvoker;
    if (invoker == nil) {
        return nil;
    }
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker = [invoker callInvoker];
    if (!jsInvoker) {
        return nil;
    }
    box = [FJAudioSinkBox new];
    box->sink = std::make_shared<FJAudioSink>(jsInvoker);
    objc_setAssociatedObject(self, kAudioSinkBoxKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
#else
    return nil;
#endif
}

RCT_REMAP_METHOD(installAudioSinkJSI,
                 installAudioSinkJSIWithResolver : (RCTPromiseResolveBlock)resolve
                 rejecter : (RCTPromiseRejectBlock)reject) {
    FJAudioSinkBox *box = [self fj_audioSinkBox];
    if (box == nil) {
        reject(@"E_NO_JSI", @"Audio extraction requires the New Architecture.", nil);
        return;
    }
    if (box->sink->isInstalled()) {
        resolve(@YES);
        return;
    }
    box->sink->install([resolve]() { resolve(@YES); });
}

// ===== PHASE-3 TEMPORARY — DELETE IN PHASE 5 =====
// Feeds a synthetic 48 kHz stereo int16 buffer through a real FJAudioSinkRenderer
// (converter+batch+deliver) so JS can verify the conversion path end-to-end.
#if DEBUG
RCT_EXPORT_METHOD(fjDebugFeedSynthetic) {
    FJAudioSinkBox *box = [self fj_audioSinkBox];
    if (!box || !box->sink->isInstalled()) {
        return;
    }
    // Default options: 16 kHz mono f32, linear (lpfOrder 1), 100 ms batches.
    FJAudioSinkRenderer *renderer = [[FJAudioSinkRenderer alloc] initWithModule:self
                                                                          pcId:@(-1)
                                                                       trackId:@"debug-track"
                                                                       outRate:16000
                                                                   outChannels:1
                                                                     outFormat:ma_format_f32
                                                                      lpfOrder:1
                                                                       batchMs:100.0];
    // Synthesize ~250 ms of 48 kHz stereo s16 sine so the 100 ms flush fires (≥2x).
    const int inRate = 48000;
    const int inChannels = 2;
    const int totalFrames = 12000;  // 48000 * 0.25
    std::vector<int16_t> samples((size_t)totalFrames * inChannels);
    const double freq = 440.0;
    for (int i = 0; i < totalFrames; i++) {
        double t = (double)i / inRate;
        int16_t s = (int16_t)(0.5 * 32767.0 * sin(2.0 * M_PI * freq * t));
        samples[(size_t)i * inChannels + 0] = s;
        samples[(size_t)i * inChannels + 1] = s;
    }
    // Feed in chunks so renderPCMBuffer accumulates and flushes at the threshold.
    const int chunkFrames = 480;  // 10 ms @ 48 kHz
    for (int off = 0; off < totalFrames; off += chunkFrames) {
        int n = MIN(chunkFrames, totalFrames - off);
        [renderer renderPCMBuffer:&samples[(size_t)off * inChannels]
                    bitsPerSample:16
                       sampleRate:inRate
                 numberOfChannels:inChannels
                   numberOfFrames:n];
    }
    [renderer teardown];
}
#endif
// ===== END PHASE-3 TEMPORARY =====

// trackId -> attached FJAudioSinkRenderer (associated object; category has no ivars).
- (NSMutableDictionary<NSString *, FJAudioSinkRenderer *> *)audioRenderers {
    static const void *kAudioRenderersKey = &kAudioRenderersKey;
    NSMutableDictionary *renderers = objc_getAssociatedObject(self, kAudioRenderersKey);
    if (renderers == nil) {
        renderers = [NSMutableDictionary new];
        objc_setAssociatedObject(self, kAudioRenderersKey, renderers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return renderers;
}

RCT_EXPORT_METHOD(startAudioExtraction
                  : (nonnull NSNumber *)pcId trackId
                  : (nonnull NSString *)trackId options
                  : (NSDictionary *)options) {
    RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
    if (![track isKindOfClass:[RTC_OBJC_TYPE(RTCAudioTrack) class]]) {
        return;
    }
    NSMutableDictionary *renderers = [self audioRenderers];
    if (renderers[trackId] != nil) {
        return;
    }

    // Parse options with defaults (options may be nil).
    int outRate = 16000;       // 0 => keep input rate
    int outChannels = 1;
    ma_format outFormat = ma_format_f32;
    int lpfOrder = 1;          // "linear"
    double batchMs = 100.0;
    if ([options isKindOfClass:[NSDictionary class]]) {
        if (options[@"sampleRate"] != nil) {
            outRate = [options[@"sampleRate"] intValue];
        }
        if (options[@"channels"] != nil) {
            outChannels = [options[@"channels"] intValue];
        }
        if ([options[@"format"] isKindOfClass:[NSString class]]) {
            outFormat = [options[@"format"] isEqualToString:@"s16"] ? ma_format_s16 : ma_format_f32;
        }
        if ([options[@"resampleQuality"] isKindOfClass:[NSString class]]) {
            lpfOrder = [options[@"resampleQuality"] isEqualToString:@"high"] ? MA_MAX_FILTER_ORDER : 1;
        }
        if (options[@"batchDurationMs"] != nil) {
            batchMs = [options[@"batchDurationMs"] doubleValue];
        }
    }
    if (outChannels < 1) {
        outChannels = 1;
    }
    if (batchMs <= 0) {
        batchMs = 100.0;
    }

    FJAudioSinkRenderer *renderer = [[FJAudioSinkRenderer alloc] initWithModule:self
                                                                          pcId:pcId
                                                                       trackId:trackId
                                                                       outRate:outRate
                                                                   outChannels:outChannels
                                                                     outFormat:outFormat
                                                                      lpfOrder:lpfOrder
                                                                       batchMs:batchMs];
    [(RTC_OBJC_TYPE(RTCAudioTrack) *)track addRenderer:renderer];
    renderers[trackId] = renderer;
}

RCT_EXPORT_METHOD(stopAudioExtraction
                  : (nonnull NSNumber *)pcId trackId
                  : (nonnull NSString *)trackId) {
    NSMutableDictionary *renderers = [self audioRenderers];
    FJAudioSinkRenderer *renderer = renderers[trackId];
    if (renderer == nil) {
        return;
    }
    [renderers removeObjectForKey:trackId];
    RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
    if ([track isKindOfClass:[RTC_OBJC_TYPE(RTCAudioTrack) class]]) {
        [(RTC_OBJC_TYPE(RTCAudioTrack) *)track removeRenderer:renderer];
    }
    // Release the converter promptly (dealloc would also do it, but be explicit).
    [renderer teardown];
}

@end
