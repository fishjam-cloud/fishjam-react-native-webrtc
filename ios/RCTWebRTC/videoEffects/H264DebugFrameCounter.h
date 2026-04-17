#import <Foundation/Foundation.h>

#import "VideoFrameProcessor.h"

// Temporary instrumentation for RCA of "H264 encoder stuck after background".
// Counts frames that flow through the capture pipeline (i.e. reach libwebrtc's
// video source) and periodically logs the rate. Useful to distinguish a
// capturer-side stall from an encoder-side stall after foregrounding.
//
// Activation from JS:
//   mediaStreamTrackSetVideoEffects(trackId, ["h264DebugFrameCounter"])
//
// Deactivation (restore default passthrough):
//   mediaStreamTrackSetVideoEffects(trackId, [])

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kH264DebugFrameCounterName;

@interface H264DebugFrameCounter : NSObject<VideoFrameProcessorDelegate>

+ (void)registerIfNeeded;

@end

NS_ASSUME_NONNULL_END
