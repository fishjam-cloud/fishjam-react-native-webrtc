#import <Foundation/Foundation.h>

@interface VoipManager : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *token;
@property(nonatomic, copy) void (^onTokenUpdated)(NSString *token);
@property(nonatomic, copy) void (^onIncomingPush)(NSDictionary *payload);
+ (instancetype)shared;
+ (void)registerForVoIPPushes;
@end
