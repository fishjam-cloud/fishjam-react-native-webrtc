#import <CallKit/CallKit.h>
#import <Foundation/Foundation.h>

typedef void (^CallKitVoidCallback)(void);
typedef void (^CallKitStringCallback)(NSString *);
typedef void (^CallKitBoolCallback)(BOOL);

/**
 * Where an incoming call landed relative to whatever call already exists:
 * - Current: there was no call yet, so it is reported as the one call the app tracks.
 * - Waiting: another call is already answered/connected, so this one rings as the second
 *   CallKit call; JS is not told unless it is answered.
 * - Rejected: no slot left (still ringing or waiting already taken) — transient CallKit
 *   report for PushKit, then ended; JS signals rejection to the caller.
 */
typedef NS_ENUM(NSInteger, IncomingCallSlot) {
    IncomingCallSlotCurrent,
    IncomingCallSlotWaiting,
    IncomingCallSlotRejected,
};

@interface CallKitManager : NSObject<CXProviderDelegate>

@property(copy) CallKitVoidCallback onCallStarted;
@property(copy) CallKitStringCallback onCallAnswered;
@property(copy) CallKitStringCallback onCallEnded;
@property(copy) CallKitStringCallback onCallFailed;
@property(copy) CallKitBoolCallback onCallMuted;
@property(copy) CallKitBoolCallback onCallHeld;
@property(readonly) BOOL hasActiveCall;
@property(readonly) BOOL isCallAnswered;
@property(readonly) BOOL isOutgoingCall;
@property(readonly) BOOL isCallOnHold;
@property(readonly, nullable) NSString *pendingAnswerRequestId;

+ (instancetype)shared;

- (void)startCallWithDisplayName:(NSString *)displayName handle:(NSString *)handle isVideo:(BOOL)isVideo;
- (IncomingCallSlot)reportIncomingCallWithDisplayName:(NSString *)displayName
                                               handle:(NSString *)handle
                                              isVideo:(BOOL)isVideo;
- (void)endCallWithReason:(NSString *_Nullable)reason;
- (BOOL)fulfillIncomingCallConnected:(NSString *)requestId;
- (void)failIncomingCallConnected:(NSString *)requestId;
- (void)reportOutgoingCallConnected;
- (void)setCallHeld:(BOOL)onHold;
- (void)setMuted:(BOOL)muted;

@end
