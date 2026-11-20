#import <CallKit/CallKit.h>
#import <Foundation/Foundation.h>

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

@protocol CallKitEventSink<NSObject>
- (void)callKitCallStarted;
- (void)callKitCallAnswered:(NSString *)requestId;
- (void)callKitCallEnded:(nullable NSString *)reason;
- (void)callKitCallFailed:(nullable NSString *)reason;
- (void)callKitCallMuted:(BOOL)muted;
- (void)callKitCallHeld:(BOOL)onHold;
@end

@interface CallKitManager : NSObject<CXProviderDelegate>

@property(readonly) BOOL hasActiveCall;
@property(readonly) BOOL isCallAnswered;
@property(readonly) BOOL isDialing;
@property(readonly) BOOL isCallOnHold;
@property(readonly, nullable) NSString *pendingAnswerRequestId;

/**
 * Returns the manager, creating it (and with it the app's CXProvider) on first use. Created lazily,
 * only when a call is started or a VoIP push arrives: a CXProvider registers the app with CallKit,
 * which would interfere with apps that use their own provider.
 */
+ (instancetype)shared;
/** Returns the manager only if it was already created, without creating a CXProvider. */
+ (nullable instancetype)sharedIfExists;

/**
 * The sink receives call events no matter who created the manager (a JS call or an incoming
 * VoIP push). It is held weakly.
 */
+ (void)setEventSink:(id<CallKitEventSink>)sink;
/** Clears the sink only if it is still `sink`, so an old module cannot clear its replacement's. */
+ (void)removeEventSink:(id<CallKitEventSink>)sink;

- (void)startCallWithDisplayName:(NSString *)displayName
                          handle:(NSString *)handle
                         isVideo:(BOOL)isVideo
                       isDialing:(BOOL)isDialing;
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
