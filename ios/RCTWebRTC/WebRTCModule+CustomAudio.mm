#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCExternalAudioSource.h>

#if __has_include(<React/RCTCallInvokerModule.h>)
#import <React/RCTCallInvoker.h>
#define FJ_HAS_CALL_INVOKER 1
#endif

#import "CustomAudioSourceController.h"
#import "FJAudioPushJSI.h"
#import "RTCMediaStreamTrack+React.h"
#import "WebRTCModule.h"

#include <memory>
#include <string>

#pragma mark - FJAudioPushBox

// ObjC holder for the C++ shared_ptr<FJAudioPush>, stored on the module as an
// associated object.
@interface FJAudioPushBox : NSObject {
   @public
    std::shared_ptr<FJAudioPush> push;
}
@end

@implementation FJAudioPushBox
@end

#pragma mark - WebRTCModule (CustomAudio)

@implementation WebRTCModule (CustomAudio)

// Lazily builds the push channel from the JS CallInvoker. Returns nil when
// there is no CallInvoker (i.e. the old architecture), which makes custom
// audio tracks unsupported.
- (FJAudioPushBox *)fj_audioPushBox {
#if FJ_HAS_CALL_INVOKER
    static const void *key = &key;
    FJAudioPushBox *box = objc_getAssociatedObject(self, key);
    if (box != nil) {
        return box;
    }
    RCTCallInvoker *invoker = self.callInvoker;
    if (invoker == nil) {
        return nil;  // old architecture: no CallInvoker, push unsupported
    }
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker = [invoker callInvoker];
    if (!jsInvoker) {
        return nil;
    }
    box = [FJAudioPushBox new];
    box->push = std::make_shared<FJAudioPush>(jsInvoker);
    objc_setAssociatedObject(self, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
#else
    return nil;
#endif
}

RCT_REMAP_METHOD(installCustomAudioJSI,
                 installCustomAudioJSIWithResolver : (RCTPromiseResolveBlock)resolve
                 rejecter : (RCTPromiseRejectBlock)reject) {
#if TARGET_OS_TV || TARGET_OS_OSX
    reject(@"E_UNSUPPORTED_PLATFORM", @"Custom audio tracks are only supported on iOS and Android.", nil);
    return;
#else
    FJAudioPushBox *box = [self fj_audioPushBox];
    if (box == nil) {
        reject(@"E_NO_JSI", @"Custom audio sample push requires the New Architecture.", nil);
        return;
    }
    // Unlike custom video there is no deliver callback to wire up: pushes are
    // routed inside FJAudioPush to the per-track pacing scheduler, whose emit
    // callback is bound at createCustomAudioTrack time.
    box->push->install([resolve]() { resolve(@YES); });
#endif
}

RCT_EXPORT_METHOD(createCustomAudioTrack
                  : (NSDictionary *)init resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
#if TARGET_OS_TV || TARGET_OS_OSX
    reject(@"E_UNSUPPORTED_PLATFORM", @"Custom audio tracks are only supported on iOS and Android.", nil);
    return;
#else
    FJAudioPushBox *box = [self fj_audioPushBox];
    if (box == nil) {
        reject(@"E_NO_JSI", @"Custom audio sample push requires the New Architecture.", nil);
        return;
    }

    NSInteger sampleRateHz = [init[@"sampleRateHz"] integerValue];
    NSInteger channelCount = [init[@"channelCount"] integerValue];
    NSInteger maxBufferedDurationMs = [init[@"maxBufferedDurationMs"] integerValue];
    if (sampleRateHz <= 0 || sampleRateHz % 100 != 0 || (channelCount != 1 && channelCount != 2) ||
        maxBufferedDurationMs <= 0) {
        reject(@"E_INVALID_CUSTOM_AUDIO_TRACK_INIT",
               @"sampleRateHz must be a positive multiple of 100, channelCount 1 or 2, and "
               @"maxBufferedDurationMs a positive integer.",
               nil);
        return;
    }

    RTCExternalAudioSource *audioSource =
        [self.peerConnectionFactory externalAudioSourceWithSampleRateHz:(int)sampleRateHz
                                                           channelCount:channelCount];
    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCAudioTrack *audioTrack = [self.peerConnectionFactory audioTrackWithSource:audioSource trackId:trackUUID];

    // The scheduler's feeder thread pushes each 10 ms frame straight into the
    // external audio source; the emit lambda retains the source for as long as
    // the scheduler lives (until unregisterTrack).
    std::string trackIdForPush = std::string([trackUUID UTF8String]);
    box->push->registerTrack(trackIdForPush,
                             (int)sampleRateHz,
                             (int)channelCount,
                             (int)maxBufferedDurationMs,
                             [audioSource](const int16_t *interleavedSamples, size_t numberOfFrames) {
                                 [audioSource pushAudioFrameWithSamples:interleavedSamples
                                                         numberOfFrames:numberOfFrames];
                             });

    // Teardown (idempotent, run by the track-release path or controller
    // dealloc): unregister joins the feeder thread, so no frame is in flight in
    // the source once this returns. __weak self avoids a retain cycle through
    // the associated-object box.
    __weak WebRTCModule *weakSelf = self;
    CustomAudioSourceController *controller = [[CustomAudioSourceController alloc]
        initWithAudioSource:audioSource
              teardownBlock:^{
                  WebRTCModule *strongSelf = weakSelf;
                  if (strongSelf == nil) {
                      return;
                  }
                  FJAudioPushBox *strongBox = [strongSelf fj_audioPushBox];
                  if (strongBox != nil) {
                      strongBox->push->unregisterTrack(trackIdForPush);
                  }
              }];
    audioTrack.captureController = controller;

    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    [mediaStream addAudioTrack:audioTrack];

    self.localTracks[trackUUID] = audioTrack;
    self.localStreams[mediaStreamId] = mediaStream;

    resolve(@{
        @"streamId" : mediaStreamId,
        @"track" : @{
            @"id" : trackUUID,
            @"kind" : audioTrack.kind,
            @"readyState" : @"live",
            @"remote" : @(NO),
            @"enabled" : @(audioTrack.isEnabled),
            @"settings" : [controller getSettings],
        },
    });
#endif
}

@end
