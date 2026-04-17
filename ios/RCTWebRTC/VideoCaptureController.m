#if !TARGET_OS_TV

#import "VideoCaptureController.h"

#import <React/RCTLog.h>

// Temporary instrumentation for RCA of "H264 encoder stuck after background".
// Enabled in DEBUG builds; override by defining DEBUG_H264_LIFECYCLE=0 in build settings.
#ifndef DEBUG_H264_LIFECYCLE
#if DEBUG
#define DEBUG_H264_LIFECYCLE 1
#else
#define DEBUG_H264_LIFECYCLE 0
#endif
#endif

@interface VideoCaptureController ()

@property(nonatomic, strong) RTCCameraVideoCapturer *capturer;
@property(nonatomic, strong) AVCaptureDeviceFormat *selectedFormat;
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL usingFrontCamera;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) int frameRate;

#if DEBUG_H264_LIFECYCLE
@property(nonatomic, weak) AVCaptureSession *h264DebugObservedSession;
#endif

@end

@implementation VideoCaptureController

- (instancetype)initWithCapturer:(RTCCameraVideoCapturer *)capturer andConstraints:(NSDictionary *)constraints {
    self = [super init];
    if (self) {
        self.capturer = capturer;
        self.running = NO;
        [self applyConstraints:constraints error:nil];

#if DEBUG_H264_LIFECYCLE
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(h264Debug_appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(h264Debug_appWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
#if DEBUG_H264_LIFECYCLE
    [self h264Debug_unregisterSessionObservers];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];
#endif
    self.device = NULL;
}

- (void)startCapture {
    if (self.deviceId) {
        self.device = [AVCaptureDevice deviceWithUniqueID:self.deviceId];
    }
    if (!self.device) {
        AVCaptureDevicePosition position =
            self.usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        self.device = [self findDeviceForPosition:position];
        self.deviceId = self.device.uniqueID;
    }

    if (!self.device) {
        RCTLogWarn(@"[VideoCaptureController] No capture devices found!");

        return;
    }

    AVCaptureDeviceFormat *format = [self selectFormatForDevice:self.device
                                                withTargetWidth:self.width
                                               withTargetHeight:self.height];
    if (!format) {
        RCTLogWarn(@"[VideoCaptureController] No valid formats for device %@", self.device);

        return;
    }

    self.selectedFormat = format;

    AVCaptureSession *session = self.capturer.captureSession;
    if (@available(iOS 16.0, *)) {
        BOOL enable = self.enableMultitaskingCameraAccess;
        BOOL shouldChange = session.multitaskingCameraAccessEnabled != enable;
        BOOL canChange = !enable || (enable && session.isMultitaskingCameraAccessSupported);

        if (shouldChange && canChange) {
            [session beginConfiguration];
            [session setMultitaskingCameraAccessEnabled:enable];
            [session commitConfiguration];
        }
    }

    RCTLog(@"[VideoCaptureController] Capture will start");

    // Starting the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer startCaptureWithDevice:self.device
                                   format:format
                                      fps:self.frameRate
                        completionHandler:^(NSError *err) {
                            if (err) {
                                RCTLogError(@"[VideoCaptureController] Error starting capture: %@", err);
                            } else {
                                RCTLog(@"[VideoCaptureController] Capture started");
                                weakSelf.running = YES;
#if DEBUG_H264_LIFECYCLE
                                [weakSelf h264Debug_registerSessionObservers];
#endif
                            }
                            dispatch_semaphore_signal(semaphore);
                        }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)stopCapture {
    if (!self.running)
        return;

    RCTLog(@"[VideoCaptureController] Capture will stop");
#if DEBUG_H264_LIFECYCLE
    [self h264Debug_unregisterSessionObservers];
#endif
    // Stopping the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer stopCaptureWithCompletionHandler:^{
        RCTLog(@"[VideoCaptureController] Capture stopped");
        weakSelf.running = NO;
        weakSelf.device = nil;

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)applyConstraints:(NSDictionary *)constraints error:(NSError **)outError {
    // Clear device to prepare for starting camera with new constraints.
    self.device = nil;

    BOOL hasChanged = NO;

    NSString *deviceId = constraints[@"deviceId"];
    int width = [constraints[@"width"] intValue];
    int height = [constraints[@"height"] intValue];
    int frameRate = [constraints[@"frameRate"] intValue];

    if (self.width != width) {
        hasChanged = YES;
        self.width = width;
    }

    if (self.height != height) {
        hasChanged = YES;
        self.height = height;
    }

    if (self.frameRate != frameRate) {
        hasChanged = YES;
        self.frameRate = frameRate;
    }

    id facingMode = constraints[@"facingMode"];

    if (!facingMode && !deviceId) {
        // Default to front camera.
        facingMode = @"user";
    }

    if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
        AVCaptureDevicePosition position;
        if ([facingMode isEqualToString:@"environment"]) {
            position = AVCaptureDevicePositionBack;
        } else if ([facingMode isEqualToString:@"user"]) {
            position = AVCaptureDevicePositionFront;
        } else {
            // If the specified facingMode value is not supported, fall back
            // to the front camera.
            position = AVCaptureDevicePositionFront;
        }

        BOOL usingFrontCamera = position == AVCaptureDevicePositionFront;
        if (self.usingFrontCamera != usingFrontCamera) {
            hasChanged = YES;
            self.usingFrontCamera = usingFrontCamera;
        }
    }

    if (!deviceId) {
        AVCaptureDevicePosition position =
            self.usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        deviceId = [self findDeviceForPosition:position].uniqueID;
    }

    if (self.deviceId != deviceId && ![self.deviceId isEqualToString:deviceId]) {
        hasChanged = YES;
        self.deviceId = deviceId;
    }

    if (self.running && hasChanged) {
        [self startCapture];
    }
}

- (NSDictionary *)getSettings {
    AVCaptureDeviceFormat *format = self.selectedFormat;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    NSMutableDictionary *settings = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"groupId" : @"",
        @"height" : @(dimensions.height),
        @"width" : @(dimensions.width),
        @"frameRate" : @(30),
        @"facingMode" : self.usingFrontCamera ? @"user" : @"environment"
    }];

    if (self.deviceId) {
        settings[@"deviceId"] = self.deviceId;
    }
    return settings;
}
#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (@available(iOS 11.1, *)) {
        if ([object isKindOfClass:[AVCaptureDevice class]] && [keyPath isEqualToString:@"systemPressureState"]) {
            AVCaptureDevice *device = (AVCaptureDevice *)object;
            AVCaptureSystemPressureLevel pressureLevel =
                ((AVCaptureSystemPressureState *)change[NSKeyValueChangeNewKey]).level;
            if (pressureLevel == AVCaptureSystemPressureLevelSerious ||
                pressureLevel == AVCaptureSystemPressureLevelCritical) {
                RCTLogWarn(
                    @"[VideoCaptureController] Reached elevated system pressure level: %@. Throttling frame rate.",
                    pressureLevel);
                [self throttleFrameRateForDevice:device];
            } else if (pressureLevel == AVCaptureSystemPressureLevelNominal) {
                RCTLogWarn(@"[VideoCaptureController] Restored normal system pressure level. Resetting frame rate to "
                           @"default.");
                [self resetFrameRateForDevice:device];
            }
        }
    }
}

- (void)registerSystemPressureStateObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device addObserver:self forKeyPath:@"systemPressureState" options:NSKeyValueObservingOptionNew context:nil];
    }
}

- (void)removeObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device removeObserver:self forKeyPath:@"systemPressureState"];
    }
}

#pragma mark Private

- (void)setDevice:(AVCaptureDevice *)device {
    if (_device) {
        [self removeObserverForDevice:_device];
    }
    if (device) {
        [self registerSystemPressureStateObserverForDevice:device];
    }

    _device = device;
}

- (AVCaptureDevice *)findDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray<AVCaptureDevice *> *captureDevices = [RTCCameraVideoCapturer captureDevices];
    for (AVCaptureDevice *device in captureDevices) {
        if (device.position == position) {
            return device;
        }
    }

    return [captureDevices firstObject];
}

- (AVCaptureDeviceFormat *)selectFormatForDevice:(AVCaptureDevice *)device
                                 withTargetWidth:(int)targetWidth
                                withTargetHeight:(int)targetHeight {
    NSArray<AVCaptureDeviceFormat *> *formats = [RTCCameraVideoCapturer supportedFormatsForDevice:device];
    AVCaptureDeviceFormat *selectedFormat = nil;
    int currentDiff = INT_MAX;

    for (AVCaptureDeviceFormat *format in formats) {
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        int diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height);
        if (diff < currentDiff) {
            selectedFormat = format;
            currentDiff = diff;
        } else if (diff == currentDiff && pixelFormat == [_capturer preferredOutputPixelFormat]) {
            selectedFormat = format;
        }
    }

    return selectedFormat;
}

- (void)throttleFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = CMTimeMake(1, 20);
    device.activeVideoMaxFrameDuration = CMTimeMake(1, 15);

    [device unlockForConfiguration];
}

- (void)resetFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = kCMTimeInvalid;
    device.activeVideoMaxFrameDuration = kCMTimeInvalid;

    [device unlockForConfiguration];
}

- (BOOL)isMultitaskingCameraAccessSupported {
    if (@available(iOS 16.0, *)) {
        return self.capturer.captureSession.isMultitaskingCameraAccessSupported;
    }
    return NO;
}

- (BOOL)setMultitaskingCameraAccessEnabled:(BOOL)enabled {
    self.enableMultitaskingCameraAccess = enabled;
    if (@available(iOS 16.0, *)) {
        AVCaptureSession *session = self.capturer.captureSession;
        if (!session.isMultitaskingCameraAccessSupported) {
            return NO;
        }
        if (session.isMultitaskingCameraAccessEnabled == enabled) {
            return YES;
        }
        [session beginConfiguration];
        [session setMultitaskingCameraAccessEnabled:enabled];
        [session commitConfiguration];
        return YES;
    }
    return NO;
}

- (BOOL)isMultitaskingCameraAccessEnabled {
    if (@available(iOS 16.0, *)) {
        return self.capturer.captureSession.isMultitaskingCameraAccessEnabled;
    }
    return NO;
}

#if DEBUG_H264_LIFECYCLE

#pragma mark - H264 background RCA probes

- (void)h264Debug_registerSessionObservers {
    AVCaptureSession *session = self.capturer.captureSession;
    if (session == nil || session == self.h264DebugObservedSession) {
        return;
    }
    [self h264Debug_unregisterSessionObservers];
    self.h264DebugObservedSession = session;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(h264Debug_sessionWasInterrupted:)
               name:AVCaptureSessionWasInterruptedNotification
             object:session];
    [nc addObserver:self
           selector:@selector(h264Debug_sessionInterruptionEnded:)
               name:AVCaptureSessionInterruptionEndedNotification
             object:session];
    [nc addObserver:self
           selector:@selector(h264Debug_sessionRuntimeError:)
               name:AVCaptureSessionRuntimeErrorNotification
             object:session];
    [nc addObserver:self
           selector:@selector(h264Debug_sessionDidStartRunning:)
               name:AVCaptureSessionDidStartRunningNotification
             object:session];
    [nc addObserver:self
           selector:@selector(h264Debug_sessionDidStopRunning:)
               name:AVCaptureSessionDidStopRunningNotification
             object:session];
    RCTLogInfo(@"[H264-DEBUG] Registered AVCaptureSession observers (session=%p)", session);
}

- (void)h264Debug_unregisterSessionObservers {
    AVCaptureSession *session = self.h264DebugObservedSession;
    if (session == nil) {
        return;
    }
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:AVCaptureSessionWasInterruptedNotification object:session];
    [nc removeObserver:self name:AVCaptureSessionInterruptionEndedNotification object:session];
    [nc removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:session];
    [nc removeObserver:self name:AVCaptureSessionDidStartRunningNotification object:session];
    [nc removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:session];
    self.h264DebugObservedSession = nil;
}

- (NSString *)h264Debug_interruptionReasonString:(AVCaptureSessionInterruptionReason)reason {
    switch (reason) {
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
            return @"VideoDeviceNotAvailableInBackground";
        case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
            return @"AudioDeviceInUseByAnotherClient";
        case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
            return @"VideoDeviceInUseByAnotherClient";
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
            return @"VideoDeviceNotAvailableWithMultipleForegroundApps";
        case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableDueToSystemPressure:
            return @"VideoDeviceNotAvailableDueToSystemPressure";
        default:
            return [NSString stringWithFormat:@"Unknown(%ld)", (long)reason];
    }
}

- (void)h264Debug_sessionWasInterrupted:(NSNotification *)notification {
    NSNumber *reasonValue = notification.userInfo[AVCaptureSessionInterruptionReasonKey];
    AVCaptureSessionInterruptionReason reason =
        reasonValue ? (AVCaptureSessionInterruptionReason)reasonValue.integerValue : 0;
    RCTLogInfo(@"[H264-DEBUG] AVCaptureSessionWasInterrupted t=%.3f reason=%@",
               CACurrentMediaTime(),
               [self h264Debug_interruptionReasonString:reason]);
}

- (void)h264Debug_sessionInterruptionEnded:(NSNotification *)notification {
    RCTLogInfo(@"[H264-DEBUG] AVCaptureSessionInterruptionEnded t=%.3f isRunning=%d",
               CACurrentMediaTime(),
               self.capturer.captureSession.isRunning);
}

- (void)h264Debug_sessionRuntimeError:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    RCTLogWarn(@"[H264-DEBUG] AVCaptureSessionRuntimeError t=%.3f error=%@",
               CACurrentMediaTime(),
               error);
}

- (void)h264Debug_sessionDidStartRunning:(NSNotification *)notification {
    RCTLogInfo(@"[H264-DEBUG] AVCaptureSessionDidStartRunning t=%.3f", CACurrentMediaTime());
}

- (void)h264Debug_sessionDidStopRunning:(NSNotification *)notification {
    RCTLogInfo(@"[H264-DEBUG] AVCaptureSessionDidStopRunning t=%.3f", CACurrentMediaTime());
}

- (void)h264Debug_appWillEnterForeground:(NSNotification *)notification {
    AVCaptureSession *session = self.capturer.captureSession;
    RCTLogInfo(@"[H264-DEBUG] WillEnterForeground capture state t=%.3f isRunning=%d isInterrupted=%d running=%d",
               CACurrentMediaTime(),
               session.isRunning,
               session.isInterrupted,
               self.running);
}

- (void)h264Debug_appDidBecomeActive:(NSNotification *)notification {
    AVCaptureSession *session = self.capturer.captureSession;
    RCTLogInfo(@"[H264-DEBUG] DidBecomeActive capture state t=%.3f isRunning=%d isInterrupted=%d running=%d",
               CACurrentMediaTime(),
               session.isRunning,
               session.isInterrupted,
               self.running);
}

#endif  // DEBUG_H264_LIFECYCLE

@end

#endif