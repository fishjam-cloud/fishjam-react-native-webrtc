#import "WebRTCModule.h"

@interface WebRTCModule (CameraFrameProcessor)

// YES while a camera frame processor is attached to the track. Worker queue only.
- (BOOL)fj_hasCameraFrameTapForTrackId:(NSString *)trackId;

// Detaches the track's tap, if any, and hands the capturer back to the track's
// source. Must run on the worker queue (every RCT_EXPORT_METHOD already does).
- (void)fj_detachTrackIdOnWorkerQueue:(NSString *)trackId;

// Hands every tapped capturer back to its track's source. Called when the module
// goes away (a JS reload), because RTCVideoCapturer.delegate is weak and a
// released tap would otherwise leave the camera track silent.
- (void)fj_detachAllCameraFrameTaps;

@end
