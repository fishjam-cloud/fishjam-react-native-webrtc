#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <WebRTC/RTCAudioRenderer.h>
#import <WebRTC/RTCAudioTrack.h>

#if __has_include(<React/RCTCallInvokerModule.h>)
#import <React/RCTCallInvoker.h>
#define FJ_HAS_CALL_INVOKER 1
#endif

#import "FJAudioSinkJSI.h"
#import "WebRTCModule+RTCMediaStream.h"
#import "WebRTCModule.h"

#include <mutex>
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
@interface FJAudioSinkRenderer : NSObject<RTC_OBJC_TYPE (RTCAudioRenderer)>
- (instancetype)initWithSink:(std::shared_ptr<FJAudioSink>)sink
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
    std::shared_ptr<FJAudioSink> _sink;
    std::mutex _mutex;  // guards _converter, _converterReady, _inputBuffer
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

- (instancetype)initWithSink:(std::shared_ptr<FJAudioSink>)sink
                        pcId:(NSNumber *)pcId
                     trackId:(NSString *)trackId
                     outRate:(int)outRate
                 outChannels:(int)outChannels
                   outFormat:(ma_format)outFormat
                    lpfOrder:(int)lpfOrder
                     batchMs:(double)batchMs {
    if (self = [super init]) {
        _sink = std::move(sink);
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
    std::lock_guard<std::mutex> lock(_mutex);
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

    ma_data_converter_config config = ma_data_converter_config_init(ma_format_s16,
                                                                    _outFormat,
                                                                    (ma_uint32)channels,
                                                                    (ma_uint32)_outChannels,
                                                                    (ma_uint32)sampleRate,
                                                                    (ma_uint32)outRate);
    config.resampling.algorithm = ma_resample_algorithm_linear;
    config.resampling.linear.lpfOrder = (ma_uint32)_lpfOrder;

    _converterReady = (ma_data_converter_init(&config, NULL, &_converter) == MA_SUCCESS);
    _outRate = outRate;
}

- (void)flush {
    if (!_sink || !_sink->isInstalled() || !_converterReady) {
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
        if (ma_data_converter_process_pcm_frames(
                &_converter, readPtr, &framesIn, output.data() + writeOffset, &framesOut) != MA_SUCCESS) {
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
    _sink->deliver(_pcId.intValue,
                   _trackId.UTF8String,
                   _outRate,
                   _outChannels,
                   _outFormat == ma_format_f32 ? "f32" : "s16",
                   std::move(output));
}

- (void)teardown {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_converterReady) {
        ma_data_converter_uninit(&_converter, NULL);
        _converterReady = NO;
    }
}

- (void)dealloc {
    [self teardown];
}

@end

static const void *kLocalAudioEngineKey = &kLocalAudioEngineKey;

// pcId the JS side uses to mean "the local mic track", not a remote pc track.
static const int kFJLocalTrackPcId = -1;

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

RCT_REMAP_METHOD(installAudioSinkJSI, installAudioSinkJSIWithResolver
                 : (RCTPromiseResolveBlock)resolve rejecter
                 : (RCTPromiseRejectBlock)reject) {
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

// trackId -> attached renderer (remote tracks only).
- (NSMutableDictionary<NSString *, FJAudioSinkRenderer *> *)audioRenderers {
    static const void *key = &key;
    NSMutableDictionary *renderers = objc_getAssociatedObject(self, key);
    if (renderers == nil) {
        renderers = [NSMutableDictionary new];
        objc_setAssociatedObject(self, key, renderers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return renderers;
}

// trackId -> attached renderer (local tracks, pcId == -1).
- (NSMutableDictionary<NSString *, FJAudioSinkRenderer *> *)fj_localRenderers {
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
    FJAudioSinkBox *box = [self fj_audioSinkBox];
    if (box == nil) {
        return;
    }

    FJAudioSinkRenderer *renderer = [self fj_makeRendererWithBox:box pcId:pcId trackId:trackId options:options];

    if ([pcId intValue] == kFJLocalTrackPcId) {
        [self fj_startLocalExtractionForTrackId:trackId renderer:renderer];
    } else {
        [self fj_startRemoteExtractionForTrackId:trackId pcId:pcId renderer:renderer];
    }
}

RCT_EXPORT_METHOD(stopAudioExtraction : (nonnull NSNumber *)pcId trackId : (nonnull NSString *)trackId) {
    if ([pcId intValue] == kFJLocalTrackPcId) {
        [self fj_stopLocalExtractionForTrackId:trackId];
    } else {
        [self fj_stopRemoteExtractionForTrackId:trackId pcId:pcId];
    }
}

// Builds a renderer from the JS options (defaults match Android), source-agnostic.
- (FJAudioSinkRenderer *)fj_makeRendererWithBox:(FJAudioSinkBox *)box
                                           pcId:(NSNumber *)pcId
                                        trackId:(NSString *)trackId
                                        options:(NSDictionary *)options {
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
    return [[FJAudioSinkRenderer alloc] initWithSink:box->sink
                                                pcId:pcId
                                             trackId:trackId
                                             outRate:outRate
                                         outChannels:outChannels
                                           outFormat:outFormat
                                            lpfOrder:lpfOrder
                                             batchMs:batchMs];
}

#pragma mark - Remote track extraction (RTCAudioRenderer)

// Remote: fed by WebRTC's RTCAudioRenderer. All access is on the React method
// queue, so audioRenderers needs no locking (unlike the local path).
- (void)fj_startRemoteExtractionForTrackId:(NSString *)trackId
                                      pcId:(NSNumber *)pcId
                                  renderer:(FJAudioSinkRenderer *)renderer {
    RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
    if (![track isKindOfClass:[RTC_OBJC_TYPE(RTCAudioTrack) class]]) {
        return;
    }
    NSMutableDictionary *renderers = [self audioRenderers];
    if (renderers[trackId] != nil) {
        return;
    }
    [(RTC_OBJC_TYPE(RTCAudioTrack) *)track addRenderer:renderer];
    renderers[trackId] = renderer;
}

- (void)fj_stopRemoteExtractionForTrackId:(NSString *)trackId pcId:(NSNumber *)pcId {
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

#pragma mark - Local track extraction (AVAudioEngine input tap)

// Local: fed by the AVAudioEngine tap on an audio thread, so fj_localRenderers
// is guarded by @synchronized(self).
- (void)fj_startLocalExtractionForTrackId:(NSString *)trackId renderer:(FJAudioSinkRenderer *)renderer {
    @synchronized(self) {
        NSMutableDictionary *localRenderers = [self fj_localRenderers];
        if (localRenderers[trackId] != nil) {
            return;
        }
        localRenderers[trackId] = renderer;
    }
    [self fj_startLocalAudioEngineIfNeeded];
}

- (void)fj_stopLocalExtractionForTrackId:(NSString *)trackId {
    FJAudioSinkRenderer *renderer;
    @synchronized(self) {
        NSMutableDictionary *localRenderers = [self fj_localRenderers];
        renderer = localRenderers[trackId];
        if (renderer == nil) {
            return;
        }
        [localRenderers removeObjectForKey:trackId];
    }
    [renderer teardown];
    [self fj_stopLocalAudioEngineIfNoMoreRenderers];
}

#pragma mark - Local audio engine lifecycle

// One shared input tap feeds every local renderer: started on the first local
// track, torn down with the last.
- (void)fj_startLocalAudioEngineIfNeeded {
    if (objc_getAssociatedObject(self, kLocalAudioEngineKey) != nil) {
        return;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = engine.inputNode;
    AVAudioFormat *format = [inputNode outputFormatForBus:0];

    __weak __typeof__(self) weakSelf = self;
    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:format
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                             [weakSelf fj_deliverLocalAudioBuffer:buffer];
                         }];

    NSError *error = nil;
    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        NSLog(@"[FJAudioSink] Failed to start local audio engine: %@", error);
        [inputNode removeTapOnBus:0];
        return;
    }

    objc_setAssociatedObject(self, kLocalAudioEngineKey, engine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)fj_deliverLocalAudioBuffer:(AVAudioPCMBuffer *)buffer {
    if (buffer.frameLength == 0 || buffer.format.channelCount == 0 || buffer.floatChannelData == nil) {
        return;
    }

    NSArray<FJAudioSinkRenderer *> *snapshot;
    @synchronized(self) {
        snapshot = [[self fj_localRenderers] allValues];
    }
    if (snapshot.count == 0) {
        return;
    }

    AVAudioChannelCount channels = buffer.format.channelCount;
    double sampleRate = buffer.format.sampleRate;
    AVAudioFrameCount frameCount = buffer.frameLength;
    NSUInteger totalSamples = (NSUInteger)(frameCount * channels);

    // Convert non-interleaved float32 → interleaved int16
    NSMutableData *int16Data = [NSMutableData dataWithLength:totalSamples * sizeof(int16_t)];
    int16_t *dst = (int16_t *)int16Data.mutableBytes;
    float *const *src = buffer.floatChannelData;
    for (AVAudioFrameCount f = 0; f < frameCount; f++) {
        for (AVAudioChannelCount ch = 0; ch < channels; ch++) {
            float s = src[ch][f];
            if (s > 1.0f)
                s = 1.0f;
            else if (s < -1.0f)
                s = -1.0f;
            dst[f * channels + ch] = (int16_t)(s * 32767.0f);
        }
    }

    for (FJAudioSinkRenderer *renderer in snapshot) {
        [renderer renderPCMBuffer:int16Data.bytes
                    bitsPerSample:16
                       sampleRate:(int)sampleRate
                 numberOfChannels:(size_t)channels
                   numberOfFrames:(size_t)frameCount];
    }
}

- (void)fj_stopLocalAudioEngineIfNoMoreRenderers {
    @synchronized(self) {
        if ([self fj_localRenderers].count > 0)
            return;
    }

    AVAudioEngine *engine = objc_getAssociatedObject(self, kLocalAudioEngineKey);
    if (engine == nil) {
        return;
    }
    [engine.inputNode removeTapOnBus:0];
    [engine stop];
    objc_setAssociatedObject(self, kLocalAudioEngineKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
