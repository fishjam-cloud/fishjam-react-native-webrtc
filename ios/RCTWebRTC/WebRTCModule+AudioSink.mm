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

#pragma mark - PCM batching renderer

// Batches ~100 ms of int16 PCM from a remote audio track (via the WebRTC SDK
// RTCAudioRenderer) and forwards it to JS as a base64 `audioTrackData` event.
@interface FJAudioSinkRenderer : NSObject <RTC_OBJC_TYPE (RTCAudioRenderer)>
- (instancetype)initWithModule:(WebRTCModule *)module
                          pcId:(NSNumber *)pcId
                       trackId:(NSString *)trackId;
@end

@implementation FJAudioSinkRenderer {
    __weak WebRTCModule *_module;
    NSNumber *_pcId;
    NSString *_trackId;
    NSMutableData *_buffer;
}

- (instancetype)initWithModule:(WebRTCModule *)module
                          pcId:(NSNumber *)pcId
                       trackId:(NSString *)trackId {
    if (self = [super init]) {
        _module = module;
        _pcId = pcId;
        _trackId = trackId;
        _buffer = [NSMutableData data];
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
    [_buffer appendBytes:audioData length:numberOfFrames * numberOfChannels * sizeof(int16_t)];

    // Flush ~100 ms of audio: (sampleRate / 10) frames * channels * 2 bytes.
    NSUInteger bytesPerFlush = (NSUInteger)(sampleRate / 10) * numberOfChannels * sizeof(int16_t);
    if (_buffer.length < bytesPerFlush) {
        return;
    }

    WebRTCModule *module = _module;
    if (module == nil) {
        _buffer.length = 0;
        return;
    }
    NSString *base64 = [_buffer base64EncodedStringWithOptions:0];
    _buffer.length = 0;
    [module sendEventWithName:kEventAudioTrackData
                         body:@{
                           @"pcId" : _pcId,
                           @"trackId" : _trackId,
                           @"sampleRate" : @(sampleRate),
                           @"channels" : @(numberOfChannels),
                           @"data" : base64,
                         }];
}

@end

#pragma mark - FJAudioSinkBox

// ObjC holder for the C++ shared_ptr<FJAudioSink>, stored on the module as an
// associated object (category has no ivars). Keeps the C++ type out of headers.
@interface FJAudioSinkBox : NSObject {
   @public
    std::shared_ptr<FJAudioSink> sink;
}
@end

@implementation FJAudioSinkBox
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

// ===== PHASE-2 TEMPORARY — DELETE IN PHASE 3 =====
// Proves the JSI channel end-to-end: a dummy deliver should reach the registered
// JS callback with an ArrayBuffer of byteLength 16. Debug-only.
#if DEBUG
RCT_EXPORT_METHOD(fjDebugTestDeliver) {
    FJAudioSinkBox *box = [self fj_audioSinkBox];
    if (!box || !box->sink->isInstalled()) {
        return;
    }
    std::vector<uint8_t> bytes(16, 0xAB);  // 16 dummy bytes
    box->sink->deliver(-1, @"debug-track", 16000, 1, "s16", std::move(bytes));
}
#endif
// ===== END PHASE-2 TEMPORARY =====

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
                  : (nonnull NSString *)trackId) {
    RTCMediaStreamTrack *track = [self trackForId:trackId pcId:pcId];
    if (![track isKindOfClass:[RTC_OBJC_TYPE(RTCAudioTrack) class]]) {
        return;
    }
    NSMutableDictionary *renderers = [self audioRenderers];
    if (renderers[trackId] != nil) {
        return;
    }
    FJAudioSinkRenderer *renderer = [[FJAudioSinkRenderer alloc] initWithModule:self pcId:pcId trackId:trackId];
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
}

@end
