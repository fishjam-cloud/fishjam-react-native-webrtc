#import <Foundation/Foundation.h>

#import <WebRTC/RTCExternalAudioSource.h>

#import "CaptureController.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Lifecycle holder for one custom audio track.
 *
 * The audio data path does not go through this controller: JS pushes samples
 * into the track's FJAudioFrameScheduler (via the JSI sink), whose feeder
 * thread pushes 10 ms frames straight into the RTCExternalAudioSource. This
 * controller exists so the track-release path has something to tear down —
 * `releaseCaptureResources` runs the teardown block exactly once, which
 * unregisters the scheduler (joining its feeder thread) so no further frames
 * reach the source.
 *
 * startCapture/stopCapture are inherited no-ops on purpose: a disabled audio
 * track is muted by WebRTC itself (the sender zeroes its input), which matches
 * microphone-track semantics, so pausing the feeder is neither needed nor
 * desirable.
 */
@interface CustomAudioSourceController : CaptureController

- (instancetype)initWithAudioSource:(RTCExternalAudioSource *)audioSource teardownBlock:(void (^)(void))teardownBlock;

/** True teardown; idempotent. Also invoked from dealloc as a safety net. */
- (void)releaseCaptureResources;

@property(nonatomic, readonly) RTCExternalAudioSource *audioSource;
@property(nonatomic, readonly) BOOL isTornDown;

@end

NS_ASSUME_NONNULL_END
