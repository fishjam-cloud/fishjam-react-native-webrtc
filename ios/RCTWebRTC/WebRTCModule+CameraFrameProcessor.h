#import "WebRTCModule.h"

@interface WebRTCModule (CameraFrameProcessor)

// Hands every tapped capturer back to its track's source. Called when the module
// goes away (a JS reload), because RTCVideoCapturer.delegate is weak and a
// released tap would otherwise leave the camera track silent.
- (void)fj_detachAllCameraFrameTaps;

@end
