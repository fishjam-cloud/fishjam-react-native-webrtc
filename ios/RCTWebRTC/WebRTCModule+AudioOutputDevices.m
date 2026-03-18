#if !TARGET_OS_OSX

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVRoutePickerView.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <React/RCTBridgeModule.h>

#import "WebRTCModule.h"

static void *AudioRouteObserverKey = &AudioRouteObserverKey;

@implementation WebRTCModule (AudioOutputDevices)

- (void)removeAudioRouteObserver {
    id observer = objc_getAssociatedObject(self, AudioRouteObserverKey);
    if (observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        objc_setAssociatedObject(self, AudioRouteObserverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)ensureAudioRouteObserver {
    if (objc_getAssociatedObject(self, AudioRouteObserverKey))
        return;

    __weak typeof(self) weakSelf = self;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                                    object:nil
                                                                     queue:[NSOperationQueue mainQueue]
                                                                usingBlock:^(NSNotification *notification) {
                                                                    [weakSelf handleAudioRouteChange:notification];
                                                                }];

    objc_setAssociatedObject(self, AudioRouteObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    NSInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    AVAudioSessionRouteDescription *previousRoute = notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];

    [self sendEventWithName:kEventAudioOutputChanged
                       body:@{
                           @"reason" : @(reason),
                           @"currentRoute" : [self routeToDict:currentRoute],
                           @"previousRoute" : [self routeToDict:previousRoute]
                       }];
}

- (NSDictionary *)routeToDict:(AVAudioSessionRouteDescription *)route {
    NSMutableArray *inputs = [NSMutableArray new];
    for (AVAudioSessionPortDescription *port in route.inputs) {
        [inputs addObject:@{@"type" : [self portTypeToString:port.portType], @"name" : port.portName}];
    }

    NSMutableArray *outputs = [NSMutableArray new];
    for (AVAudioSessionPortDescription *port in route.outputs) {
        [outputs addObject:@{@"type" : [self portTypeToString:port.portType], @"name" : port.portName}];
    }

    return @{@"inputs" : inputs, @"outputs" : outputs};
}

- (NSString *)portTypeToString:(AVAudioSessionPort)portType {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            AVAudioSessionPortBuiltInMic : @"builtInMic",
            AVAudioSessionPortHeadsetMic : @"headsetMic",
            AVAudioSessionPortLineIn : @"lineIn",
            AVAudioSessionPortLineOut : @"lineOut",
            AVAudioSessionPortHeadphones : @"headphones",
            AVAudioSessionPortBluetoothA2DP : @"bluetoothA2DP",
            AVAudioSessionPortBuiltInReceiver : @"builtInReceiver",
            AVAudioSessionPortBuiltInSpeaker : @"builtInSpeaker",
            AVAudioSessionPortHDMI : @"HDMI",
            AVAudioSessionPortAirPlay : @"airPlay",
            AVAudioSessionPortBluetoothLE : @"bluetoothLE",
            AVAudioSessionPortBluetoothHFP : @"bluetoothHFP",
            AVAudioSessionPortUSBAudio : @"usbAudio",
            AVAudioSessionPortCarAudio : @"carAudio",
        };
    });
    return map[portType] ?: portType;
}

RCT_EXPORT_METHOD(overrideAudioOutput
                  : (NSString *)output resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    [self ensureAudioRouteObserver];
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    if ([output isEqualToString:@"speaker"]) {
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
    } else if ([output isEqualToString:@"none"]) {
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
    } else {
        reject(@"E_AUDIO_OUTPUT_INVALID",
               [NSString stringWithFormat:@"Invalid output '%@', expected 'speaker' or 'none'", output],
               nil);
        return;
    }

    if (error) {
        reject(@"E_AUDIO_OUTPUT_OVERRIDE", error.localizedDescription, error);
    } else {
        resolve(nil);
    }
}

RCT_EXPORT_METHOD(showAudioRoutePicker) {
    [self ensureAudioRouteObserver];

    dispatch_async(dispatch_get_main_queue(), ^{
        AVRoutePickerView *routePickerView = [[AVRoutePickerView alloc] initWithFrame:CGRectZero];

        UIWindow *keyWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
            }
        }

        if (keyWindow) {
            [keyWindow addSubview:routePickerView];
        }

        for (UIView *subview in routePickerView.subviews) {
            if ([subview isKindOfClass:[UIButton class]]) {
                [(UIButton *)subview sendActionsForControlEvents:UIControlEventTouchUpInside];
                break;
            }
        }

        [routePickerView removeFromSuperview];
    });
}

RCT_EXPORT_METHOD(getCurrentAudioOutput : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [self ensureAudioRouteObserver];
    AVAudioSessionRouteDescription *route = [[AVAudioSession sharedInstance] currentRoute];
    resolve([self routeToDict:route]);
}

@end

#endif
