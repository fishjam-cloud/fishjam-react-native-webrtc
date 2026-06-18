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
    NSLog(@"[FishjamVoIPPush] Inicjalizacja PKPushRegistry dla VoIP...");
    [[self shared] registerForVoIPPushes];
}

- (void)registerForVoIPPushes {
    if (self.registry != nil) {
        return;
    }
    
    // TODO: apple recommends serial queue for this param, will have to investigate
    self.registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.registry.delegate = self;
    self.registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)pushCredentials forType:(PKPushType)type {
    NSLog(@"[FishjamVoIPPush] Otrzymano/Zaktualizowano VoIP Push Credentials.");
    
    const unsigned char *bytes = pushCredentials.token.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:pushCredentials.token.length * 2];
    for (NSUInteger i = 0; i < pushCredentials.token.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    NSString *tokenString = [hex copy];
    
    NSLog(@"[FishjamVoIPPush] Wygenerowany Token: %@", tokenString);
    if ([tokenString isEqualToString:self.token]) {
        return;
    }
    self.token = tokenString;
    
    if (self.onTokenUpdated) {
        self.onTokenUpdated(tokenString);
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    self.token = nil;
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
    NSDictionary *dict = payload.dictionaryPayload;
    NSLog(@"[FishjamVoIPPush] OTRZYMANO PUSH! Pełny payload: %@", dict);
    NSString *displayName = dict[@"displayName"] ?: dict[@"username"];
    BOOL isVideo = [dict[@"isVideo"] boolValue];
    
    if (displayName == nil || displayName.length == 0) {
        displayName = @"Incoming call";
    }

    [[CallKitManager shared] reportIncomingCallWithDisplayName:displayName isVideo:isVideo];
    
    if (self.onIncomingPush) {
        self.onIncomingPush(dict ?: @{});
    }
    
    completion();
}

@end
