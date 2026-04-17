#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "FishjamRTCAudioDevice.h"
#import "H264BackgroundSafeEncoderFactory.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "WebRTCModule.h"
#import "WebRTCModuleOptions.h"
#import "videoEffects/H264DebugFrameCounter.h"

// Temporary instrumentation for RCA of "H264 encoder stuck after background".
// Enabled in DEBUG builds; override by defining DEBUG_H264_LIFECYCLE=0 in build settings.
#ifndef DEBUG_H264_LIFECYCLE
#if DEBUG
#define DEBUG_H264_LIFECYCLE 1
#else
#define DEBUG_H264_LIFECYCLE 0
#endif
#endif

@interface WebRTCModule ()
#if DEBUG_H264_LIFECYCLE && !TARGET_OS_OSX
- (void)h264Debug_registerLifecycleObservers;
- (void)h264Debug_logNotification:(NSNotification *)notification;
#endif
@end

@implementation WebRTCModule

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (void)dealloc {
    [self removeAudioRouteObserver];

#if DEBUG_H264_LIFECYCLE && !TARGET_OS_OSX
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidEnterBackgroundNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
#endif

    [_localTracks removeAllObjects];
    _localTracks = nil;
    [_localStreams removeAllObjects];
    _localStreams = nil;

    for (NSNumber *peerConnectionId in _peerConnections) {
        RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
        peerConnection.delegate = nil;
        [peerConnection close];
    }
    [_peerConnections removeAllObjects];

    _peerConnectionFactory = nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        WebRTCModuleOptions *options = [WebRTCModuleOptions sharedInstance];
        id<RTCAudioDevice> audioDevice = options.audioDevice;
        id<RTCVideoDecoderFactory> decoderFactory = options.videoDecoderFactory;
        id<RTCVideoEncoderFactory> encoderFactory = options.videoEncoderFactory;
        NSDictionary *fieldTrials = options.fieldTrials;
        RTCLoggingSeverity loggingSeverity = options.loggingSeverity;

        // Initialize field trials.
        if (fieldTrials == nil) {
            // Fix for dual-sim connectivity:
            // https://bugs.chromium.org/p/webrtc/issues/detail?id=10966
            fieldTrials = @{kRTCFieldTrialUseNWPathMonitor : kRTCFieldTrialEnabledValue};
        }
        RTCInitFieldTrialDictionary(fieldTrials);

        // Initialize logging.
#if DEBUG_H264_LIFECYCLE
        // When the caller left logging at the default (None), force verbose so libwebrtc's
        // RTCVideoEncoderH264 surfaces VTCompressionSession create/destroy and background logs.
        if (loggingSeverity == RTCLoggingSeverityNone) {
            loggingSeverity = RTCLoggingSeverityVerbose;
            RCTLogInfo(@"[H264-DEBUG] Forcing RTCLoggingSeverityVerbose for RCA instrumentation");
        }
#endif
        RTCSetMinDebugLogLevel(loggingSeverity);

        if (encoderFactory == nil) {
            encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        }
        if (decoderFactory == nil) {
            decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        }

#if !TARGET_OS_OSX
        // Wrap the encoder factory so H264 encoders survive app background→foreground
        // transitions. See `H264BackgroundSafeEncoder.h` for the full rationale.
        encoderFactory = [[H264BackgroundSafeEncoderFactory alloc] initWithInnerFactory:encoderFactory];
#endif

        _encoderFactory = encoderFactory;
        _decoderFactory = decoderFactory;

        RCTLogInfo(@"Using video encoder factory: %@", NSStringFromClass([encoderFactory class]));
        RCTLogInfo(@"Using video decoder factory: %@", NSStringFromClass([decoderFactory class]));

        if (audioDevice == nil) {
#if TARGET_OS_IOS
            audioDevice = [[FishjamRTCAudioDevice alloc] init];
#endif
        }

        _peerConnectionFactory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                           decoderFactory:decoderFactory
                                                                              audioDevice:audioDevice];

        _peerConnections = [NSMutableDictionary new];
        _localStreams = [NSMutableDictionary new];
        _localTracks = [NSMutableDictionary new];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _workerQueue = dispatch_queue_create("WebRTCModule.queue", attributes);

#if DEBUG_H264_LIFECYCLE
        [H264DebugFrameCounter registerIfNeeded];
#endif
#if DEBUG_H264_LIFECYCLE && !TARGET_OS_OSX
        [self h264Debug_registerLifecycleObservers];
#endif
    }

    return self;
}

#if DEBUG_H264_LIFECYCLE && !TARGET_OS_OSX
- (void)h264Debug_registerLifecycleObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray<NSNotificationName> *names = @[
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationWillEnterForegroundNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationWillResignActiveNotification,
    ];
    for (NSNotificationName name in names) {
        [nc addObserver:self selector:@selector(h264Debug_logNotification:) name:name object:nil];
    }
    RCTLogInfo(@"[H264-DEBUG] Registered app lifecycle observers");
}

- (void)h264Debug_logNotification:(NSNotification *)notification {
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    NSString *stateStr = @"unknown";
    switch (state) {
        case UIApplicationStateActive:
            stateStr = @"Active";
            break;
        case UIApplicationStateInactive:
            stateStr = @"Inactive";
            break;
        case UIApplicationStateBackground:
            stateStr = @"Background";
            break;
    }
    RCTLogInfo(@"[H264-DEBUG] %@ t=%.3f appState=%@ pcs=%lu",
               notification.name,
               CACurrentMediaTime(),
               stateStr,
               (unsigned long)_peerConnections.count);
}
#endif

- (RTCMediaStream *)streamForReactTag:(NSString *)reactTag {
    RTCMediaStream *stream = _localStreams[reactTag];
    if (!stream) {
        for (NSNumber *peerConnectionId in _peerConnections) {
            RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
            stream = peerConnection.remoteStreams[reactTag];
            if (stream) {
                break;
            }
        }
    }
    return stream;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue {
    return _workerQueue;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        kEventPeerConnectionSignalingStateChanged,
        kEventPeerConnectionStateChanged,
        kEventPeerConnectionOnRenegotiationNeeded,
        kEventPeerConnectionIceConnectionChanged,
        kEventPeerConnectionIceGatheringChanged,
        kEventPeerConnectionGotICECandidate,
        kEventPeerConnectionDidOpenDataChannel,
        kEventDataChannelDidChangeBufferedAmount,
        kEventDataChannelStateChanged,
        kEventDataChannelReceiveMessage,
        kEventMediaStreamTrackMuteChanged,
        kEventMediaStreamTrackEnded,
        kEventPeerConnectionOnRemoveTrack,
        kEventPeerConnectionOnTrack,
        kEventCallKitActionPerformed,
        kEventAudioOutputChanged
    ];
}

@end
