#import <Foundation/Foundation.h>

extern NSString *const kFishjamVoIPTokenUpdatedNotification;
extern NSString *const kFishjamVoIPIncomingPushNotification;

@interface FishjamVoIPPush : NSObject
@property (nonatomic, copy, readonly, nullable) NSString *token;
+ (instancetype)shared;
+ (void)registerForVoIPPushes;
@end
