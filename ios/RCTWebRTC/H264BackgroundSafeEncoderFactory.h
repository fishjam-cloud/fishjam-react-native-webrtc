#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * `RTCVideoEncoderFactory` that wraps another factory and returns a
 * `H264BackgroundSafeEncoder` for any H264 codec. Non-H264 codecs are
 * delegated to the inner factory unchanged.
 *
 * This only affects iOS. On other platforms (macOS, tvOS, simulator builds
 * without VideoToolbox lifecycle issues) the wrapper still applies but is
 * effectively a no-op because the DidBecomeActive reset is only scheduled
 * when the host app actually cycles through background/foreground.
 */
@interface H264BackgroundSafeEncoderFactory : NSObject<RTCVideoEncoderFactory>

- (instancetype)initWithInnerFactory:(id<RTCVideoEncoderFactory>)innerFactory NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
