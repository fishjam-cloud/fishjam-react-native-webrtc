#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <WebRTC/RTCAudioRenderer.h>
#import <WebRTC/RTCAudioTrack.h>

#if __has_include(<React/RCTCallInvokerModule.h>)
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
// associated object. Defined first because the renderer's -flush dereferences it.
@interface FJAudioSinkBox : NSObject {
   @public
    std::shared_ptr<FJAudioSink> sink;
}
@end

@implementation FJAudioSinkBox
@end

#pragma mark - FJAudioSinkRenderer

// Accumulates int16 PCM from a remote track, converts each batch to the
// requested format/rate/channels with a persistent miniaudio converter, and
// delivers the result to JS via FJAudioSink.
@interface FJAudioSinkRenderer : NSObject <RTC_OBJC_TYPE (RTCAudioRenderer)>
- (instancetype)initWithModule:(WebRTCModule *)module
                          pcId:(NSNumber *)pcId
                       trackId:(NSString *)trackId
                       outRate:(int)outRate
                   outChannels:(int)outChannels
                     outFormat:(ma_format)outFormat
                      lpfOrder:(int)lpfOrder
                       batchMs:(double)batchMs;
- (void)teardown;
@end

@implementation FJAudioSinkRenderer {
    __weak WebRTCModule *_module;
    NSNumber *_pcId;
    NSString *_trackId;
    NSMutableData *_inputBuffer;

    // Requested output config (from startAudioExtraction options).
    int _requestedOutRate;  // user-supplied; 0 = follow input rate
    int _outRate;           // resolved: equals _requestedOutRate, or the actual input rate when 0
    int _outChannels;
    int _lpfOrder;
    ma_format _outFormat;
    double _batchMs;

    // Persists across flushes so the resampler keeps its filter state.
    // Re-initialised if the input rate or channel count changes.
    ma_data_converter _converter;
    BOOL _converterReady;
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
        _inputBuffer = [NSMutableData data];
        _requestedOutRate = outRate;
        _outRate = outRate;
        _outChannels = outChannels;
        _outFormat = outFormat;
        _lpfOrder = lpfOrder;
        _batchMs = batchMs;
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
    [_inputBuffer appendBytes:audioData length:numberOfFrames * numberOfChannels * sizeof(int16_t)];

    NSUInteger bytesPerBatch = (NSUInteger)(_inRate * _batchMs / 1000.0) * _inChannels * sizeof(int16_t);
    if (bytesPerBatch > 0 && _inputBuffer.length >= bytesPerBatch) {
        [self flush];
    }
}

- (void)ensureConverterForRate:(int)sampleRate channels:(int)channels {
    if (_converterReady && sampleRate == _inRate && channels == _inChannels) {
        return;
    }
    if (_converterReady) {
        ma_data_converter_uninit(&_converter, NULL);
        _converterReady = NO;
    }
    _inRate = sampleRate;
    _inChannels = channels;
    int outRate = _requestedOutRate > 0 ? _requestedOutRate : sampleRate;  // outRate 0 => keep input rate

    ma_data_converter_config config = ma_data_converter_config_init(
        ma_format_s16, _outFormat, (ma_uint32)channels, (ma_uint32)_outChannels,
        (ma_uint32)sampleRate, (ma_uint32)outRate);
    config.resampling.algorithm = ma_resample_algorithm_linear;
    config.resampling.linear.lpfOrder = (ma_uint32)_lpfOrder;

    _converterReady = (ma_data_converter_init(&config, NULL, &_converter) == MA_SUCCESS);
    _outRate = outRate;
}

- (void)flush {
    WebRTCModule *module = _module;
    FJAudioSinkBox *box = module ? [module fj_audioSinkBox] : nil;
    if (!box || !box->sink->isInstalled() || !_converterReady) {
        _inputBuffer.length = 0;
        return;
    }

    size_t outBytesPerSample = (_outFormat == ma_format_f32) ? sizeof(float) : sizeof(int16_t);
    const uint8_t *readPtr = (const uint8_t *)_inputBuffer.bytes;
    ma_uint64 framesRemaining = _inputBuffer.length / (_inChannels * sizeof(int16_t));

    // One process call usually drains everything (the output is sized from the
    // expected frame count); loop defensively in case it doesn't.
    std::vector<uint8_t> output;
    while (framesRemaining > 0) {
        ma_uint64 expectedFrames = 0;
        ma_data_converter_get_expected_output_frame_count(&_converter, framesRemaining, &expectedFrames);
        if (expectedFrames == 0) {
            break;
        }
        size_t writeOffset = output.size();
        output.resize(writeOffset + (size_t)(expectedFrames * _outChannels * outBytesPerSample));

        ma_uint64 framesIn = framesRemaining;
        ma_uint64 framesOut = expectedFrames;
        if (ma_data_converter_process_pcm_frames(&_converter, readPtr, &framesIn,
                                                 output.data() + writeOffset, &framesOut) != MA_SUCCESS) {
            break;
        }
        output.resize(writeOffset + (size_t)(framesOut * _outChannels * outBytesPerSample));

        if (framesIn == 0) {
            break;  // made no progress; avoid spinning
        }
        readPtr += framesIn * _inChannels * sizeof(int16_t);
        framesRemaining -= framesIn;
    }

    _inputBuffer.length = 0;
    if (output.empty()) {
        return;
    }
    box->sink->deliver(_pcId.intValue, _trackId.UTF8String, _outRate, _outChannels,
                       _outFormat == ma_format_f32 ? "f32" : "s16", std::move(output));
}

- (void)teardown {
    if (_converterReady) {
        ma_data_converter_uninit(&_converter, NULL);
        _converterReady = NO;
    }
}

- (void)dealloc {
    [self teardown];
}

@end

#pragma mark - WebRTCModule (AudioSink)

@implementation WebRTCModule (AudioSink)

// Lazily builds the sink from the JS CallInvoker. Returns nil when there is no
// CallInvoker (i.e. the old architecture), which makes extraction unsupported.
- (FJAudioSinkBox *)fj_audioSinkBox {
#if FJ_HAS_CALL_INVOKER
    static const void *key = &key;
    FJAudioSinkBox *box = objc_getAssociatedObject(self, key);
    if (box != nil) {
        return box;
    }
    RCTCallInvoker *invoker = self.callInvoker;
    if (invoker == nil) {
        return nil;  // old architecture: no CallInvoker, extraction unsupported
    }
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker = [invoker callInvoker];
    if (!jsInvoker) {
        return nil;
    }
    box = [FJAudioSinkBox new];
    box->sink = std::make_shared<FJAudioSink>(jsInvoker);
    objc_setAssociatedObject(self, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// trackId -> attached renderer.
- (NSMutableDictionary<NSString *, FJAudioSinkRenderer *> *)audioRenderers {
    static const void *key = &key;
    NSMutableDictionary *renderers = objc_getAssociatedObject(self, key);
    if (renderers == nil) {
        renderers = [NSMutableDictionary new];
        objc_setAssociatedObject(self, key, renderers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    int outRate = options[@"sampleRate"] ? [options[@"sampleRate"] intValue] : 16000;
    int outChannels = options[@"channels"] ? [options[@"channels"] intValue] : 1;
    ma_format outFormat = [options[@"format"] isEqualToString:@"s16"] ? ma_format_s16 : ma_format_f32;
    int lpfOrder = [options[@"resampleQuality"] isEqualToString:@"high"] ? MA_MAX_FILTER_ORDER : 1;
    double batchMs = options[@"batchDurationMs"] ? [options[@"batchDurationMs"] doubleValue] : 100.0;
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
    [renderer teardown];
}

@end
