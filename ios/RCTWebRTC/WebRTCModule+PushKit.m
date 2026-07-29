#import "WebRTCModule+PushKit.h"

#import "VoIPManager.h"

@implementation WebRTCModule (PushKit)

- (void)startObservingPushKit {
    VoIPManager *push = [VoIPManager shared];
    __weak typeof(self) weakSelf = self;

    push.onTokenUpdated = ^(NSString *token) {
        [weakSelf sendEventWithName:kEventVoIPPush body:@{@"registered" : token ?: @""}];
    };

    push.onIncomingPush = ^(NSDictionary *payload) {
        [weakSelf sendEventWithName:kEventVoIPPush body:@{@"incoming" : payload ?: @{}}];
    };
    push.onWaitingCallDeclined = ^(NSDictionary *payload) {
        [weakSelf sendEventWithName:kEventVoIPPush body:@{@"waitingDeclined" : payload ?: @{}}];
    };
    push.onCallIntent = ^(NSDictionary *intent) {
        [weakSelf sendEventWithName:kEventVoIPPush body:@{@"callIntent" : intent ?: @{}}];
    };
}

- (void)stopObservingPushKit {
    VoIPManager *push = [VoIPManager shared];
    push.onTokenUpdated = nil;
    push.onIncomingPush = nil;
    push.onWaitingCallDeclined = nil;
    push.onCallIntent = nil;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getVoIPToken) {
    return [VoIPManager shared].token ?: [NSNull null];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getPendingIncomingCall) {
    return [VoIPManager shared].pendingIncomingCall ?: [NSNull null];
}

RCT_EXPORT_METHOD(clearPendingIncomingCall) {
    [[VoIPManager shared] clearPendingIncomingCall];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getPendingCallIntent) {
    return [VoIPManager shared].pendingCallIntent ?: [NSNull null];
}

RCT_EXPORT_METHOD(clearPendingCallIntent) {
    [[VoIPManager shared] clearPendingCallIntent];
}

@end
