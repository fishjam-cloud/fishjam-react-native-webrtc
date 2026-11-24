#import "WebRTCModule+CallKit.h"

#import <React/RCTBridgeModule.h>

#import "CallKitManager.h"
#import "WebRTCModule+PushKit.h"

@interface WebRTCModule (CallKitEventSink)<CallKitEventSink>
@end

@implementation WebRTCModule (CallKit)

// Sets this module as the receiver of call events without creating the CallKit manager. The manager
// is created when a call starts or a VoIP push arrives.
- (void)startObserving {
    [super startObserving];
    [CallKitManager setEventSink:self];
    [self startObservingPushKit];
}

- (void)stopObserving {
    [self stopObservingPushKit];
    [CallKitManager removeEventSink:self];
    [super stopObserving];
}

#pragma mark - CallKitEventSink

- (void)callKitCallStarted {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"started" : [NSNull null]}];
}

- (void)callKitCallAnswered:(NSString *)requestId {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"answer" : requestId}];
}

- (void)callKitCallEnded:(NSString *)reason {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"ended" : reason ?: @"local"}];
}

- (void)callKitCallFailed:(NSString *)reason {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"failed" : reason ?: @""}];
}

- (void)callKitCallMuted:(BOOL)muted {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"muted" : @(muted)}];
}

- (void)callKitCallHeld:(BOOL)onHold {
    [self sendEventWithName:kEventCallKitActionPerformed body:@{@"held" : @(onHold)}];
}

RCT_EXPORT_METHOD(startCallKitSession
                  : (NSString *)displayName handle
                  : (NSString *)handle isVideo
                  : (BOOL)isVideo isDialing
                  : (BOOL)isDialing resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    if (displayName == nil || displayName.length == 0) {
        reject(@"E_CALLKIT_INVALID_DISPLAY_NAME", @"displayName is required", nil);
        return;
    }

    NSString *callHandle = handle.length > 0 ? handle : displayName;

    @try {
        [[CallKitManager shared] startCallWithDisplayName:displayName
                                                   handle:callHandle
                                                  isVideo:isVideo
                                                isDialing:isDialing];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_START_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(endCallKitSession
                  : (NSString *)reason resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        [[CallKitManager sharedIfExists] endCallWithReason:reason];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_END_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(fulfillIncomingCallConnected
                  : (NSString *)requestId resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        resolve(@([[CallKitManager sharedIfExists] fulfillIncomingCallConnected:requestId]));
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_FULFILL_ANSWER_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(failIncomingCallConnected
                  : (NSString *)requestId resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        [[CallKitManager sharedIfExists] failIncomingCallConnected:requestId];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_FAIL_ANSWER_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(reportOutgoingCallConnected
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        [[CallKitManager sharedIfExists] reportOutgoingCallConnected];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_REPORT_OUTGOING_CONNECTED_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(setCallKitCallHeld
                  : (BOOL)onHold resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        [[CallKitManager sharedIfExists] setCallHeld:onHold];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_SET_HELD_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(setCallKitMuted
                  : (BOOL)muted resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    @try {
        [[CallKitManager sharedIfExists] setMuted:muted];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_CALLKIT_SET_MUTED_FAILED", exception.reason, nil);
    }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getPendingAnswerRequestId) {
    return [CallKitManager sharedIfExists].pendingAnswerRequestId ?: [NSNull null];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(hasActiveCallKitSession) {
    return @([CallKitManager sharedIfExists].hasActiveCall);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(isCallAnswered) {
    return @([CallKitManager sharedIfExists].isCallAnswered);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(isCallKitCallHeld) {
    return @([CallKitManager sharedIfExists].isCallOnHold);
}

@end
