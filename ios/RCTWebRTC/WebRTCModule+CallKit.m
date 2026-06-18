#import "WebRTCModule+CallKit.h"

#import <objc/runtime.h>

#import <React/RCTBridgeModule.h>

#import "CallKitManager.h"

#import "FishjamVoIPPush.h"

static void *CallKitManagerKey = &CallKitManagerKey;

@implementation WebRTCModule (CallKit)

- (CallKitManager *)callKitManager {
    CallKitManager *manager = objc_getAssociatedObject(self, CallKitManagerKey);
    if (manager != nil) {
        return manager;
    }

    manager = [CallKitManager shared];
    __weak typeof(self) weakSelf = self;
    manager.onCallStarted = ^{
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"started" : [NSNull null]}];
    };
    manager.onCallAnswered = ^{
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"answer" : [NSNull null]}];
    };
    manager.onCallEnded = ^{
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"ended" : [NSNull null]}];
    };
    manager.onCallFailed = ^(NSString *reason) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"failed" : reason ?: @""}];
    };
    manager.onCallMuted = ^(BOOL isMuted) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"muted" : @(isMuted)}];
    };
    manager.onCallHeld = ^(BOOL isOnHold) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"held" : @(isOnHold)}];
    };

    objc_setAssociatedObject(self, CallKitManagerKey, manager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return manager;
}

-(void) startObserving {
    [super startObserving];
    // we have to create callkitmanager singleton to be able to receive callbacks when call is answered/ended
    [self callKitManager];
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    __weak typeof(self) weakSelf = self;
    push.onTokenUpdated = ^(NSString *token) {a
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"registered": token}];
    };
    
    push.onIncomingPush = ^(NSDictionary *payload) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"incoming": payload ?: @{}}];
    };
    
    NSString *token = [FishjamVoIPPush shared].token;
    if (token.length > 0) {
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"registered": token}];
    }
}

- (void)stopObserving {
    FishjamVoIPPush *push = [FishjamVoIPPush shared];
    push.onTokenUpdated = nil;
    push.onIncomingPush = nil;
    [super stopObserving];
}

RCT_EXPORT_METHOD(startCallKitSession
                  : (NSString *)displayName isVideo
                  : (BOOL)isVideo resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    if (displayName == nil || displayName.length == 0) {
        reject(@"E_CALLKIT_INVALID_DISPLAY_NAME", @"displayName is required", nil);
        return;
    }

    @try {
        [[self callKitManager] startCallWithDisplayName:displayName isVideo:isVideo];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_START_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(endCallKitSession : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    @try {
        [[self callKitManager] endCall];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_END_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(hasActiveCallKitSession) {
    return @([self callKitManager].hasActiveCall);
}

@end
