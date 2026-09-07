#import "WebRTCModule+CameraFrameProcessor.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#if !TARGET_OS_TV && !TARGET_OS_OSX
#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCVideoSource.h>
#import <WebRTC/RTCVideoTrack.h>

#if __has_include(<React/RCTCallInvokerModule.h>)
#import <React/RCTCallInvoker.h>
#define FJ_HAS_CALL_INVOKER 1
#endif

#import "CameraFrameTap.h"
#import "FJCameraFrameProcessorJSI.h"
#import "RTCMediaStreamTrack+React.h"
#import "VideoCaptureController.h"
#import "WebRTCModule+RTCMediaStream.h"

#include <memory>
#include <string>

using fishjam::video::FJCameraFrameConsumer;

// ObjC holder for the C++ channel, stored on the module as an associated object.
@interface FJCameraFrameProcessorBox : NSObject {
   @public
    std::shared_ptr<FJCameraFrameProcessorChannel> channel;
}
@end

@implementation FJCameraFrameProcessorBox
@end
#endif

@implementation WebRTCModule (CameraFrameProcessor)

#if !TARGET_OS_TV && !TARGET_OS_OSX

// Lazily builds the channel from the JS CallInvoker. Returns nil on the old
// architecture, where there is no JSI to install into.
- (FJCameraFrameProcessorBox *)fj_cameraFrameProcessorBox {
#if FJ_HAS_CALL_INVOKER
    static const void *key = &key;
    FJCameraFrameProcessorBox *box = objc_getAssociatedObject(self, key);
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
    box = [FJCameraFrameProcessorBox new];
    box->channel = std::make_shared<FJCameraFrameProcessorChannel>(jsInvoker);
    objc_setAssociatedObject(self, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
#else
    return nil;
#endif
}

// trackId -> tap. Strong values: the tap is the capturer's (weak) delegate, so
// this dictionary is what keeps it alive. Accessed on the worker queue only.
- (NSMutableDictionary<NSString *, CameraFrameTap *> *)fj_cameraFrameTaps {
    static const void *key = &key;
    @synchronized(self) {
        NSMutableDictionary *taps = objc_getAssociatedObject(self, key);
        if (taps == nil) {
            taps = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, key, taps, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return taps;
    }
}

- (VideoCaptureController *)fj_cameraCaptureControllerForTrack:(RTCMediaStreamTrack *)track {
    if (![track isKindOfClass:[RTCVideoTrack class]]) {
        return nil;
    }
    CaptureController *controller = track.captureController;
    if (![controller isKindOfClass:[VideoCaptureController class]]) {
        return nil;
    }
    return (VideoCaptureController *)controller;
}

// Runs on the JS thread inside `attach()`; hops to the worker queue, which owns
// localTracks and the capture controllers.
- (NSString *)fj_attachConsumer:(std::shared_ptr<FJCameraFrameConsumer>)consumer toTrackId:(NSString *)trackId {
    __block NSString *errorCode = @"";
    dispatch_sync(self.workerQueue, ^{
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        VideoCaptureController *captureController = [self fj_cameraCaptureControllerForTrack:track];
        if (captureController == nil) {
            errorCode = @"E_NOT_A_CAMERA_TRACK";
            return;
        }
        if (self.videoEffectProcessor != nil) {
            // Both want to be the capturer's delegate; composing them is not defined.
            errorCode = @"E_VIDEO_EFFECTS_ACTIVE";
            return;
        }
        NSMutableDictionary<NSString *, CameraFrameTap *> *taps = [self fj_cameraFrameTaps];
        CameraFrameTap *tap = taps[trackId];
        if (tap == nil) {
            tap = [[CameraFrameTap alloc] initWithVideoSource:((RTCVideoTrack *)track).source
                                            captureController:captureController];
            taps[trackId] = tap;
        }
        captureController.capturer.delegate = tap;
        [tap attachConsumer:consumer];
    });
    return errorCode;
}

- (void)fj_detachTrackId:(NSString *)trackId {
    dispatch_sync(self.workerQueue, ^{
        NSMutableDictionary<NSString *, CameraFrameTap *> *taps = [self fj_cameraFrameTaps];
        CameraFrameTap *tap = taps[trackId];
        if (tap == nil) {
            return;
        }
        [taps removeObjectForKey:trackId];
        [tap detachConsumer];
        // Hand the capturer back to the track's own source, never to a cached delegate.
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        VideoCaptureController *captureController = [self fj_cameraCaptureControllerForTrack:track];
        if (captureController != nil) {
            captureController.capturer.delegate = ((RTCVideoTrack *)track).source;
        }
    });
}

- (BOOL)fj_statisticsForTrackId:(NSString *)trackId into:(FJCameraFrameProcessorCore::Statistics &)statistics {
    __block BOOL found = NO;
    __block FJCameraFrameProcessorCore::Statistics snapshot;
    dispatch_sync(self.workerQueue, ^{
        CameraFrameTap *tap = [self fj_cameraFrameTaps][trackId];
        if (tap != nil) {
            snapshot = [tap statistics];
            found = YES;
        }
    });
    if (found) {
        statistics = snapshot;
    }
    return found;
}

#endif

- (void)fj_detachAllCameraFrameTaps {
#if !TARGET_OS_TV && !TARGET_OS_OSX
    NSMutableDictionary<NSString *, CameraFrameTap *> *taps = [self fj_cameraFrameTaps];
    for (NSString *trackId in [taps allKeys]) {
        CameraFrameTap *tap = taps[trackId];
        [tap detachConsumer];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        VideoCaptureController *captureController = [self fj_cameraCaptureControllerForTrack:track];
        if (captureController != nil) {
            captureController.capturer.delegate = tap.videoSource;
        }
    }
    [taps removeAllObjects];
#endif
}

RCT_REMAP_METHOD(installCameraFrameProcessorJSI,
                 installCameraFrameProcessorJSIWithResolver : (RCTPromiseResolveBlock)resolve
                 rejecter : (RCTPromiseRejectBlock)reject) {
#if TARGET_OS_TV || TARGET_OS_OSX
    reject(@"E_UNSUPPORTED_PLATFORM", @"Camera frame processing is only supported on iOS and Android.", nil);
    return;
#else
    FJCameraFrameProcessorBox *box = [self fj_cameraFrameProcessorBox];
    if (box == nil) {
        reject(@"E_NO_JSI", @"Camera frame processing requires the New Architecture.", nil);
        return;
    }
    __weak WebRTCModule *weakSelf = self;
    FJCameraFrameProcessorChannel::Handlers handlers;
    handlers.attach = [weakSelf](const std::string &trackId, std::shared_ptr<FJCameraFrameConsumer> consumer) {
        WebRTCModule *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return std::string("E_MODULE_GONE");
        }
        NSString *code = [strongSelf fj_attachConsumer:std::move(consumer)
                                             toTrackId:[NSString stringWithUTF8String:trackId.c_str()]];
        return std::string([code UTF8String]);
    };
    handlers.detach = [weakSelf](const std::string &trackId) {
        WebRTCModule *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf fj_detachTrackId:[NSString stringWithUTF8String:trackId.c_str()]];
        }
    };
    handlers.statistics = [weakSelf](const std::string &trackId, FJCameraFrameProcessorCore::Statistics &out) {
        WebRTCModule *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return false;
        }
        return (bool)[strongSelf fj_statisticsForTrackId:[NSString stringWithUTF8String:trackId.c_str()] into:out];
    };
    box->channel->setHandlers(std::move(handlers));
    if (box->channel->isInstalled()) {
        resolve(nil);
        return;
    }
    box->channel->install([resolve]() { resolve(nil); });
#endif
}

@end
