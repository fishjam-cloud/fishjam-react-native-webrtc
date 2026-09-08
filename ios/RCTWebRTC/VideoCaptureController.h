#if !TARGET_OS_TV

#import <Foundation/Foundation.h>
#import <WebRTC/RTCCameraVideoCapturer.h>

#import "CaptureController.h"

@interface VideoCaptureController : CaptureController
@property(nonatomic, readonly, strong) RTCCameraVideoCapturer *capturer;
@property(nonatomic, readonly, strong) AVCaptureDeviceFormat *selectedFormat;
@property(nonatomic, readonly, assign) int frameRate;
@property(nonatomic, assign) BOOL enableMultitaskingCameraAccess;
// Whether the active device faces the user. Read per frame by the camera frame tap.
@property(nonatomic, readonly, assign) BOOL usingFrontCamera;

- (instancetype)initWithCapturer:(RTCCameraVideoCapturer *)capturer andConstraints:(NSDictionary *)constraints;
- (void)startCapture;
- (void)stopCapture;
- (void)switchCamera;
- (void)applyConstraints:(NSDictionary *)constraints error:(NSError **)outError;
- (BOOL)isMultitaskingCameraAccessSupported;
- (BOOL)setMultitaskingCameraAccessEnabled:(BOOL)enabled;
- (BOOL)isMultitaskingCameraAccessEnabled;

@end
#endif
