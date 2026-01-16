#import "WebRTCModule+CallKit.h"

#import <objc/runtime.h>

#import <React/RCTBridgeModule.h>

#import "CallKitManager.h"

static void *CallKitManagerKey = &CallKitManagerKey;

@implementation WebRTCModule (CallKit)

- (CallKitManager *)callKitManager {
    CallKitManager *manager = objc_getAssociatedObject(self, CallKitManagerKey);
    if (manager != nil) {
        return manager;
    }

    manager = [[CallKitManager alloc] init];
    __weak typeof(self) weakSelf = self;
    manager.onCallStarted = ^{
        [weakSelf sendEventWithName:kEventCallKitActionPerformed body:@{@"started" : [NSNull null]}];
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

RCT_EXPORT_METHOD(startCallKitSession
                  : (NSString *)displayName
                  isVideo
                  : (BOOL)isVideo
                  resolver
                  : (RCTPromiseResolveBlock)resolve
                  rejecter
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

RCT_EXPORT_METHOD(endCallKitSession
                  : (RCTPromiseResolveBlock)resolve
                  rejecter
                  : (RCTPromiseRejectBlock)reject) {
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
