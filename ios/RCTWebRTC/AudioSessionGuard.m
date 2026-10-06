#import "AudioSessionGuard.h"

#import <WebRTC/RTCAudioSession.h>
#import <objc/runtime.h>

static __thread BOOL webRTCIsSettingActive = NO;

#pragma mark - C functions

static BOOL shouldAllowSetActive(BOOL active) {
    if (active || webRTCIsSettingActive || ![RTCAudioSession sharedInstance].isActive) {
        return YES;
    }
    NSLog(@"[AudioSessionGuard] Ignoring an AVAudioSession deactivation while a call uses the audio session");
    return NO;
}

static void swapMethods(SEL original, SEL replacement) {
    Class sessionClass = [AVAudioSession class];
    method_exchangeImplementations(class_getInstanceMethod(sessionClass, original),
                                   class_getInstanceMethod(sessionClass, replacement));
}

#pragma mark - AVAudioSession (AudioSessionGuard)

@implementation AVAudioSession (AudioSessionGuard)
- (BOOL)fishjam_setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)error {
    if (shouldAllowSetActive(active)) {
        return [self fishjam_setActive:active withOptions:options error:error];
    }
    return YES;
}

- (BOOL)fishjam_setActive:(BOOL)active error:(NSError **)error {
    if (shouldAllowSetActive(active)) {
        return [self fishjam_setActive:active error:error];
    }
    return YES;
}
@end

#pragma mark - AudioSessionGuard

@interface AudioSessionGuard ()<RTCAudioSessionDelegate>
@end

@implementation AudioSessionGuard

+ (void)activate {
    // RTCAudioSession keeps delegates weakly, so having it defined as static makes sure it won't be garbage collected
    static AudioSessionGuard *guard;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        guard = [[AudioSessionGuard alloc] init];
        [[RTCAudioSession sharedInstance] addDelegate:guard];

        swapMethods(@selector(setActive:withOptions:error:), @selector(fishjam_setActive:withOptions:error:));
        swapMethods(@selector(setActive:error:), @selector(fishjam_setActive:error:));
    });
}

#pragma mark - RTCAudioSessionDelegate

- (void)audioSession:(RTCAudioSession *)audioSession willSetActive:(BOOL)active {
    webRTCIsSettingActive = YES;
}

- (void)audioSession:(RTCAudioSession *)audioSession didSetActive:(BOOL)active {
    webRTCIsSettingActive = NO;
}

- (void)audioSession:(RTCAudioSession *)audioSession failedToSetActive:(BOOL)active error:(NSError *)error {
    webRTCIsSettingActive = NO;
}

@end
