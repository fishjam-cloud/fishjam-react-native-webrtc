#import "H264BackgroundSafeEncoder.h"

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTLog.h>
#import <stdatomic.h>

@interface H264BackgroundSafeEncoder () {
    id<RTCVideoEncoderFactory> _innerFactory;
    RTCVideoCodecInfo *_codecInfo;

    // Inner encoder. Created eagerly in `-initWithInnerFactory:...` and replaced
    // on-demand when the app comes back to the foreground. All accesses happen
    // on libwebrtc's encoder thread (which is the only thread that calls the
    // `RTCVideoEncoder` protocol methods), except for the flag flip in the
    // foreground observer.
    id<RTCVideoEncoder> _inner;

    // Cached init parameters so we can re-init a freshly created inner encoder.
    RTCVideoEncoderCallback _cachedCallback;
    RTCVideoEncoderSettings *_cachedSettings;
    int _cachedNumberOfCores;
    uint32_t _cachedBitrateKbit;
    uint32_t _cachedFramerate;

    atomic_bool _needsReset;
    atomic_bool _startEncodeCalled;
}
@end

@implementation H264BackgroundSafeEncoder

- (instancetype)initWithInnerFactory:(id<RTCVideoEncoderFactory>)innerFactory codecInfo:(RTCVideoCodecInfo *)codecInfo {
    self = [super init];
    if (self) {
        _innerFactory = innerFactory;
        _codecInfo = codecInfo;
        _inner = [innerFactory createEncoder:codecInfo];
        atomic_init(&_needsReset, false);
        atomic_init(&_startEncodeCalled, false);
        [self registerForegroundObserver];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)registerForegroundObserver {
#if !TARGET_OS_OSX
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
#endif
}

#if !TARGET_OS_OSX
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (!atomic_load(&_startEncodeCalled)) {
        return;
    }
    atomic_store(&_needsReset, true);
}
#endif

#pragma mark - RTCVideoEncoder

- (void)setCallback:(RTCVideoEncoderCallback)callback {
    _cachedCallback = [callback copy];
    [_inner setCallback:callback];
}

- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings numberOfCores:(int)numberOfCores {
    _cachedSettings = settings;
    _cachedNumberOfCores = numberOfCores;
    atomic_store(&_startEncodeCalled, true);
    return [_inner startEncodeWithSettings:settings numberOfCores:numberOfCores];
}

- (NSInteger)releaseEncoder {
    NSInteger rc = [_inner releaseEncoder];
    atomic_store(&_startEncodeCalled, false);
    atomic_store(&_needsReset, false);
    return rc;
}

- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(nullable id<RTCCodecSpecificInfo>)info
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
    if (atomic_exchange(&_needsReset, false)) {
        [self swapInnerEncoder];
    }
    return [_inner encode:frame codecSpecificInfo:info frameTypes:frameTypes];
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
    _cachedBitrateKbit = bitrateKbit;
    _cachedFramerate = framerate;
    return [_inner setBitrate:bitrateKbit framerate:framerate];
}

- (NSString *)implementationName {
    return [_inner implementationName];
}

- (RTCVideoEncoderQpThresholds *)scalingSettings {
    return [_inner scalingSettings];
}

- (NSInteger)resolutionAlignment {
    if ([_inner respondsToSelector:@selector(resolutionAlignment)]) {
        return [_inner resolutionAlignment];
    }
    return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
    if ([_inner respondsToSelector:@selector(applyAlignmentToAllSimulcastLayers)]) {
        return [_inner applyAlignmentToAllSimulcastLayers];
    }
    return NO;
}

- (BOOL)supportsNativeHandle {
    if ([_inner respondsToSelector:@selector(supportsNativeHandle)]) {
        return [(id)_inner supportsNativeHandle];
    }
    return YES;
}

#pragma mark - Forwarding (future-proof any optional methods we don't know about)

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) {
        return YES;
    }
    return [_inner respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([_inner respondsToSelector:aSelector]) {
        return _inner;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (sig) {
        return sig;
    }
    return [(NSObject *)_inner methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([_inner respondsToSelector:anInvocation.selector]) {
        [anInvocation invokeWithTarget:_inner];
        return;
    }
    [super forwardInvocation:anInvocation];
}

#pragma mark - Reset

- (void)swapInnerEncoder {
    if (_cachedSettings == nil || _cachedCallback == nil) {
        return;
    }

    id<RTCVideoEncoder> oldInner = _inner;
    id<RTCVideoEncoder> newInner = [_innerFactory createEncoder:_codecInfo];
    if (newInner == nil) {
        RCTLogWarn(@"[H264BackgroundSafeEncoder] Inner factory returned nil, keeping old encoder");
        return;
    }

    [oldInner releaseEncoder];

    [newInner setCallback:_cachedCallback];
    NSInteger rc = [newInner startEncodeWithSettings:_cachedSettings numberOfCores:_cachedNumberOfCores];
    if (rc != 0) {
        RCTLogWarn(@"[H264BackgroundSafeEncoder] startEncodeWithSettings on fresh encoder failed: %ld", (long)rc);
        // Keep the fresh encoder anyway; next frame may recover.
    }
    if (_cachedBitrateKbit > 0 || _cachedFramerate > 0) {
        [newInner setBitrate:_cachedBitrateKbit framerate:_cachedFramerate];
    }

    _inner = newInner;
    RCTLogInfo(@"[H264BackgroundSafeEncoder] Swapped inner H264 encoder after foreground");
}

@end
