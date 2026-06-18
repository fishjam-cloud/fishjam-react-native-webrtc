#import "WebRTCModule+PushKit.h"

#import "FishjamVoIPPush.h"

@implementation WebRTCModule (PushKit)

- (void)startObservingPushKit {
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    __weak typeof(self) weakSelf = self;

    push.onTokenUpdated = ^(NSString *token) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"registered" : token ?: @""}];
    };

    push.onIncomingPush = ^(NSDictionary *payload) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"incoming" : payload ?: @{}}];
    };

    NSString *token = push.token;
    if (token.length > 0) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"registered" : token}];
    }
}

- (void)stopObservingPushKit {
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    push.onTokenUpdated = nil;
    push.onIncomingPush = nil;
}

@end
