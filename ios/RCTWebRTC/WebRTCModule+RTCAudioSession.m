#import <objc/runtime.h>

#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTLog.h>

#import <WebRTC/RTCAudioSession.h>

#import "WebRTCModule.h"

@implementation WebRTCModule (RTCAudioSession)

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioSessionDidActivate) {
    [[RTCAudioSession sharedInstance] audioSessionDidActivate:[AVAudioSession sharedInstance]];
    return nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(audioSessionDidDeactivate) {
    [[RTCAudioSession sharedInstance] audioSessionDidDeactivate:[AVAudioSession sharedInstance]];
    return nil;
}

#if DEBUG && !TARGET_OS_OSX

#pragma mark - TEMP audio-session contention diagnostics (remove after investigation)

// Registered as an RTCAudioSessionDelegate from WebRTCModule -init. Logs the full sequence of
// audio-session events so we can see, on a physical device, who steals the session and exactly
// where WebRTC's recovery (setActive) fails. Filter device logs by the [AudioDbg] tag.

static NSString *RTCAudioDbgSnapshot(void) {
    RTCAudioSession *s = [RTCAudioSession sharedInstance];
    return [NSString stringWithFormat:@"cat=%@ opts=%lu mode=%@ active=%d secSilenced=%d",
                                      s.category,
                                      (unsigned long)s.categoryOptions,
                                      s.mode,
                                      s.isActive,
                                      s.secondaryAudioShouldBeSilencedHint];
}

- (void)audioSessionDidBeginInterruption:(RTCAudioSession *)session {
    RCTLogInfo(@"[AudioDbg] BEGIN_INTERRUPT %@", RTCAudioDbgSnapshot());
}

- (void)audioSessionDidEndInterruption:(RTCAudioSession *)session shouldResumeSession:(BOOL)shouldResume {
    RCTLogInfo(@"[AudioDbg] END_INTERRUPT shouldResume=%d %@", shouldResume, RTCAudioDbgSnapshot());
}

- (void)audioSession:(RTCAudioSession *)session failedToSetActive:(BOOL)active error:(NSError *)error {
    // THE money line: the error code when recovery loses the race for the session.
    // e.g. 560557684 ('!int') = CannotInterruptOthers, 561015905 ('!pri') = InsufficientPriority.
    RCTLogInfo(@"[AudioDbg] FAILED_SET_ACTIVE active=%d err=%ld domain=%@ %@",
               active,
               (long)error.code,
               error.domain,
               RTCAudioDbgSnapshot());
}

- (void)audioSession:(RTCAudioSession *)session didSetActive:(BOOL)active {
    RCTLogInfo(@"[AudioDbg] DID_SET_ACTIVE active=%d %@", active, RTCAudioDbgSnapshot());
}

- (void)audioSession:(RTCAudioSession *)session willSetActive:(BOOL)active {
    RCTLogInfo(@"[AudioDbg] WILL_SET_ACTIVE active=%d", active);
}

- (void)audioSessionDidChangeRoute:(RTCAudioSession *)session
                            reason:(AVAudioSessionRouteChangeReason)reason
                     previousRoute:(AVAudioSessionRouteDescription *)previousRoute {
    RCTLogInfo(@"[AudioDbg] ROUTE_CHANGE reason=%lu %@", (unsigned long)reason, RTCAudioDbgSnapshot());
}

- (void)audioSessionMediaServerTerminated:(RTCAudioSession *)session {
    RCTLogInfo(@"[AudioDbg] MEDIA_SERVER_TERMINATED");
}

- (void)audioSessionMediaServerReset:(RTCAudioSession *)session {
    RCTLogInfo(@"[AudioDbg] MEDIA_SERVER_RESET %@", RTCAudioDbgSnapshot());
}

- (void)audioSession:(RTCAudioSession *)session didChangeCanPlayOrRecord:(BOOL)canPlayOrRecord {
    RCTLogInfo(@"[AudioDbg] CAN_PLAY_OR_RECORD=%d", canPlayOrRecord);
}

- (void)audioSessionDidStartPlayOrRecord:(RTCAudioSession *)session {
    RCTLogInfo(@"[AudioDbg] DID_START_PLAY_OR_RECORD %@", RTCAudioDbgSnapshot());
}

- (void)audioSessionDidStopPlayOrRecord:(RTCAudioSession *)session {
    RCTLogInfo(@"[AudioDbg] DID_STOP_PLAY_OR_RECORD");
}

#endif

@end
