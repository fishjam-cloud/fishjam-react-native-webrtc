#import <Foundation/Foundation.h>

@interface VoIPManager : NSObject
@property(copy, readonly, nullable) NSString *token;
@property(copy, readonly, nullable) NSDictionary *pendingIncomingCall;
@property(copy, readonly, nullable) NSDictionary *pendingCallIntent;
@property(copy) void (^onTokenUpdated)(NSString *token);
@property(copy) void (^onIncomingPush)(NSDictionary *payload);
@property(copy) void (^onCallIntent)(NSDictionary *intent);
@property(copy) void (^onWaitingCallDeclined)(NSDictionary *payload);
+ (instancetype)shared;
+ (void)registerForVoIPPushes;
+ (BOOL)handleContinueUserActivity:(NSUserActivity *)userActivity NS_SWIFT_NAME(handleContinueUserActivity(_:));
- (void)clearPendingIncomingCall;
- (void)clearPendingCallIntent;
- (void)bufferPendingSecondIncomingCall:(NSDictionary *)payload;
- (void)revealPendingSecondIncomingCall;
- (void)discardPendingSecondIncomingCall;
@end
