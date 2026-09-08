#if !TARGET_OS_TV && !TARGET_OS_OSX

#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import <WebRTC/RTCVideoSource.h>

#ifdef __cplusplus
#include <memory>

#include "FJCameraFrame.h"
#include "FJCameraFrameProcessorCore.h"
#endif

@class VideoCaptureController;

NS_ASSUME_NONNULL_BEGIN

// Sits between a camera capturer and its RTCVideoSource. Every frame goes to the
// source unchanged, so the camera track behaves exactly as before; frames the
// admission core accepts are additionally handed to the attached consumer.
//
// RTCVideoCapturer.delegate is weak: whoever installs a tap must keep it alive
// and must hand the capturer back to the track's source before letting go.
@interface CameraFrameTap : NSObject<RTCVideoCapturerDelegate>

@property(nonatomic, readonly, strong) RTCVideoSource *videoSource;

- (instancetype)initWithVideoSource:(RTCVideoSource *)videoSource
                  captureController:(VideoCaptureController *)captureController;

#ifdef __cplusplus
- (void)attachConsumer:(std::shared_ptr<fishjam::video::FJCameraFrameConsumer>)consumer;
- (FJCameraFrameProcessorCore::Statistics)statistics;
#endif
- (void)detachConsumer;

@end

NS_ASSUME_NONNULL_END

#endif
