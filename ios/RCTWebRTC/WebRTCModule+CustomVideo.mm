#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <WebRTC/RTCVideoTrack.h>

#if __has_include(<React/RCTCallInvokerModule.h>)
#import <React/RCTCallInvoker.h>
#define FJ_HAS_CALL_INVOKER 1
#endif

#import "CustomVideoCaptureController.h"
#import "FJVideoPushJSI.h"
#import "RTCMediaStreamTrack+React.h"
#import "WebRTCModule.h"

#include <memory>
#include <string>

#pragma mark - FJVideoPushBox

// ObjC holder for the C++ shared_ptr<FJVideoPush>, stored on the module as an
// associated object (mirrors FJAudioSinkBox in WebRTCModule+AudioSink.mm).
@interface FJVideoPushBox : NSObject {
   @public
    std::shared_ptr<FJVideoPush> push;
}
@end

@implementation FJVideoPushBox
@end

#pragma mark - WebRTCModule (CustomVideo)

@implementation WebRTCModule (CustomVideo)

// Lazily builds the push channel from the JS CallInvoker. Returns nil when there
// is no CallInvoker (i.e. the old architecture), which makes per-frame push
// unsupported.
- (FJVideoPushBox *)fj_videoPushBox {
#if FJ_HAS_CALL_INVOKER
    static const void *key = &key;
    FJVideoPushBox *box = objc_getAssociatedObject(self, key);
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
    box = [FJVideoPushBox new];
    box->push = std::make_shared<FJVideoPush>(jsInvoker);
    objc_setAssociatedObject(self, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
#else
    return nil;
#endif
}

// Looks up the custom-video capture controller registered for trackId. Returns
// nil when the track is unknown or is not a custom video track. Mirrors the
// lookup the old bridge pushCustomVideoFrame method used.
- (CustomVideoCaptureController *)customVideoCaptureControllerForTrackId:(NSString *)trackId {
    RTCMediaStreamTrack *track = self.localTracks[trackId];
    if (track == nil || ![track isKindOfClass:[RTCVideoTrack class]]) {
        return nil;
    }
    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    if (![videoTrack.captureController isKindOfClass:[CustomVideoCaptureController class]]) {
        return nil;
    }
    return (CustomVideoCaptureController *)videoTrack.captureController;
}

RCT_REMAP_METHOD(installCustomVideoJSI,
                 installCustomVideoJSIWithResolver : (RCTPromiseResolveBlock)resolve
                 rejecter : (RCTPromiseRejectBlock)reject) {
    FJVideoPushBox *box = [self fj_videoPushBox];
    if (box == nil) {
        reject(@"E_NO_JSI", @"Custom video frame push requires the New Architecture.", nil);
        return;
    }
    if (box->push->isInstalled()) {
        resolve(@YES);
        return;
    }

    // The deliver callback runs on the JS thread (synchronously inside the JS
    // push function). Look up the controller for the frame's trackId and forward
    // the resolved uint64 fence. __weak self avoids a retain cycle through the
    // associated-object box (self -> box -> push -> deliver_ -> self).
    __weak WebRTCModule *weakSelf = self;
    box->push->setDeliver([weakSelf](const std::string &trackId, int bufferIndex, uint64_t timestampNs,
                                     int rotation, uint64_t fenceHandle, uint64_t fenceSignaledValue) {
        WebRTCModule *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSString *trackIdString = [NSString stringWithUTF8String:trackId.c_str()];
        CustomVideoCaptureController *captureController =
            [strongSelf customVideoCaptureControllerForTrackId:trackIdString];
        if (captureController == nil) {
            return;
        }
        [captureController pushFrameForBufferIndex:bufferIndex
                                       fenceHandle:fenceHandle
                                fenceSignaledValue:fenceSignaledValue
                                       timestampNs:(int64_t)timestampNs
                                          rotation:(RTCVideoRotation)rotation];
    });

    box->push->install([resolve]() { resolve(@YES); });
}

@end
