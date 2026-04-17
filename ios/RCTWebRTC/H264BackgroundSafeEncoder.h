#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Wraps a single `id<RTCVideoEncoder>` returned by an inner factory.
 *
 * Background:
 * On iOS, libwebrtc's `RTCVideoEncoderH264` tears down its `VTCompressionSession`
 * when the app enters the background and tries to recreate it on the first frame
 * after foreground. On some iOS versions `VTCompressionSessionCreate` fails during
 * the transition (or the encoder instance ends up in a wedged state), and
 * `framesEncoded` stays frozen indefinitely even though new capture frames keep
 * arriving. `RtpSender.setTrack:` does NOT recreate the encoder instance
 * (it only swaps the `VideoSourceInterface`), so the stuck encoder is never
 * replaced.
 *
 * Fix:
 * Wrap every H264 encoder produced by the configured `RTCVideoEncoderFactory`.
 * On `UIApplicationDidBecomeActiveNotification`, mark the wrapper as needing a
 * reset. On the next `encode:` call (which runs on libwebrtc's encoder thread
 * and therefore has a capture frame ready), release the inner encoder, ask the
 * inner factory for a fresh encoder instance, replay the cached settings and
 * callback, and forward the current frame. The fresh encoder has a fresh
 * `_isBackgrounded=NO` state and creates a fresh `VTCompressionSession` at a
 * point in time where VideoToolbox is known to accept encoder creation.
 *
 * Non-H264 encoders are never wrapped; the factory delegates to the inner
 * factory directly for them.
 */
@interface H264BackgroundSafeEncoder : NSObject<RTCVideoEncoder>

- (instancetype)initWithInnerFactory:(id<RTCVideoEncoderFactory>)innerFactory
                           codecInfo:(RTCVideoCodecInfo *)codecInfo NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
