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
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onVoIPTokenUpdated:) name:kFishjamVoIPTokenUpdatedNotification object:nil];
    [nc addObserver:self selector:@selector(onVoIPIncomingPush:) name:kFishjamVoIPIncomingPushNotification object:nil];
    
    NSString *token = [FishjamVoIPPush shared].token;
    if (token.length > 0) {
        [self sendEventWithName:kEventCallKitActionPerformed body:@{@"registered": token}];
    }
}

- (void)stopObserving {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kFishjamVoIPTokenUpdatedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kFishjamVoIPIncomingPushNotification object:nil];
    [super stopObserving];
}

- (void)onVoIPTokenUpdated:(NSNotification *)note {
    NSString *token = note.userInfo[@"token"];
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"registered" : token ?: @""}];
}

- (void)onVoIPIncomingPush:(NSNotification *)note {
    NSDictionary *payload = note.userInfo[@"payload"];
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"incoming" : payload ?: @{}}];
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

RCT_EXPORT_METHOD(reportIncomingCall
                  : (NSString *)displayName isVideo
                  : (BOOL)isVideo resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    if (displayName == nil || displayName.length == 0) {
        reject(@"E_CALLKIT_INVALID_DISPLAY_NAME", @"displayName is required", nil);
        return;
    }
    
    @try {
        [[self callKitManager] reportIncomingCallWithDisplayName:displayName isVideo:isVideo];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_REPORT_INCOMING_FAILED", exception.reason, nil);
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
