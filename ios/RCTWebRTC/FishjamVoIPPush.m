#import "FishjamVoIPPush.h"
#import <PushKit/PushKit.h>
#import "CallKitManager.h"

@interface FishjamVoIPPush () <PKPushRegistryDelegate>
@property(nonatomic, strong) PKPushRegistry *registry;
@property(nonatomic, copy, readwrite, nullable) NSString *token;
@end

@implementation FishjamVoIPPush

+ (instancetype)shared {
    static FishjamVoIPPush *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FishjamVoIPPush alloc] init];
    });
    
    return sharedInstance;
}

+ (void)registerForVoIPPushes {
    [[self shared] registerForVoIPPushes];
}

- (void)registerForVoIPPushes {
    if (self.registry != nil) {
        return;
    }
    
    self.registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.registry.delegate = self;
    self.registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)pushCredentials forType:(PKPushType)type {
    const unsigned char *bytes = pushCredentials.token.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:pushCredentials.token.length * 2];
    for (NSUInteger i = 0; i < pushCredentials.token.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    NSString *tokenString = [hex copy];
    if ([tokenString isEqualToString:self.token]) {
        return;
    }
    self.token = tokenString;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kFishjamVoIPTokenUpdatedNotification object:nil userInfo:@{@"token": tokenString}];
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    self.token = nil;
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
    NSDictionary *dict = payload.dictionaryPayload;
    NSString *displayName = dict[@"displayName"] ?: dict[@"username"];
    BOOL isVideo = [dict[@"isVideo"] boolValue];
    
    if (displayName == nil || displayName.length == 0) {
        displayName = @"Incoming call";
    }

    [[CallKitManager shared] reportIncomingCallWithDisplayName:displayName isVideo:isVideo];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kFishjamVoIPIncomingPushNotification object:nil userInfo:@{@"payload": dict ?: @{}}];
    
    completion();
}

@end
