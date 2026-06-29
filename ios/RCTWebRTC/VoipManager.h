#import <Foundation/Foundation.h>

@interface VoipManager : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *token;
@property(nonatomic, copy, readonly, nullable) NSDictionary *pendingIncomingCall;
@property(nonatomic, copy) void (^onTokenUpdated)(NSString *token);
@property(nonatomic, copy) void (^onIncomingPush)(NSDictionary *payload);
+ (instancetype)shared;
+ (void)registerForVoIPPushes;
- (void)clearPendingIncomingCall;
@end
