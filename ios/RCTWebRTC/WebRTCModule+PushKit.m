#import "WebRTCModule+PushKit.h"

#import "FishjamVoIPPush.h"

@implementation WebRTCModule (PushKit)

- (void)startObservingPushKit {
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    __weak typeof(self) weakSelf = self;

    push.onTokenUpdated = ^(NSString *token) {
        [weakSelf sendEventWithName:kEventVoipPush body:@{@"registered" : token ?: @""}];
    };

    push.onIncomingPush = ^(NSDictionary *payload) {
        [weakSelf sendEventWithName:kEventVoipPush body:@{@"incoming" : payload ?: @{}}];
    };

    NSString *token = push.token;
    if (token.length > 0) {
        [weakSelf sendEventWithName:kEventVoipPush body:@{@"registered" : token}];
    }
}

- (void)stopObservingPushKit {
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    push.onTokenUpdated = nil;
    push.onIncomingPush = nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getVoipToken) {
    return [FishjamVoIPPush shared].token ?: [NSNull null];
}

@end
