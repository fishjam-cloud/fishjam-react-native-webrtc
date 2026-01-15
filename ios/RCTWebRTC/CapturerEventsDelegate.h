#import <WebRTC/RTCVideoCapturer.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CapturerEventsDelegate

/** Called when the capturer is ended and in an irrecoverable state. */
- (void)capturerDidEnd:(RTCVideoCapturer *)capturer;

/** Called when the capturer is ready to capture frames. */
- (void)capturerReady:(RTCVideoCapturer *)capturer;


@end

NS_ASSUME_NONNULL_END
