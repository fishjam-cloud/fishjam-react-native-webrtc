#import "VoipManager.h"
#import <PushKit/PushKit.h>
#import "CallKitManager.h"

@interface VoipManager ()<PKPushRegistryDelegate>
@property(nonatomic, strong) PKPushRegistry *registry;
@property(nonatomic, strong) dispatch_queue_t registryQueue;
@property(copy, readwrite, nullable) NSString *token;
@end

@implementation VoipManager

+ (instancetype)shared {
    static VoipManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[VoipManager alloc] init];
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

    self.registryQueue = dispatch_queue_create("io.fishjam.voippush", DISPATCH_QUEUE_SERIAL);
    self.registry = [[PKPushRegistry alloc] initWithQueue:self.registryQueue];
    self.registry.delegate = self;
    self.registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry
    didUpdatePushCredentials:(PKPushCredentials *)pushCredentials
                     forType:(PKPushType)type {
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

    if (self.onTokenUpdated) {
        self.onTokenUpdated(tokenString);
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    self.token = nil;
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
                              forType:(PKPushType)type
                withCompletionHandler:(void (^)(void))completion {
    NSMutableDictionary *dict = [payload.dictionaryPayload mutableCopy];
    NSString *displayName = dict[@"displayName"];
    BOOL isVideo = [dict[@"isVideo"] boolValue];
    dict[@"isVideo"] = @(isVideo);

    if (displayName == nil || displayName.length == 0) {
        displayName = @"Incoming call";
        dict[@"displayName"] = displayName;
    }

    [[CallKitManager shared] reportIncomingCallWithDisplayName:displayName isVideo:isVideo];

    if (self.onIncomingPush) {
        self.onIncomingPush(dict ?: @{});
    }

    completion();
}

@end
