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

- (NSString *)portTypeToNativeString:(AVAudioSessionPort)portType {
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

- (NSString *)portTypeToNormalizedType:(AVAudioSessionPort)portType {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            AVAudioSessionPortBuiltInReceiver : @"earpiece",
            AVAudioSessionPortBuiltInSpeaker : @"speaker",
            AVAudioSessionPortBluetoothHFP : @"bluetooth",
            AVAudioSessionPortBluetoothA2DP : @"bluetooth",
            AVAudioSessionPortBluetoothLE : @"bluetooth",
            AVAudioSessionPortHeadphones : @"wiredHeadset",
            AVAudioSessionPortHeadsetMic : @"wiredHeadset",
            AVAudioSessionPortUSBAudio : @"usb",
            AVAudioSessionPortHDMI : @"hdmi",
            AVAudioSessionPortAirPlay : @"airplay",
            AVAudioSessionPortCarAudio : @"carAudio",
            AVAudioSessionPortLineOut : @"lineOut",
        };
    });
    return map[portType] ?: @"unknown";
}

- (NSString *)deviceIdForPort:(AVAudioSessionPortDescription *)port {
    if ([port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        return @"speaker";
    }
    if ([port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return @"receiver";
    }
    return port.UID;
}

- (NSDictionary *)serializePort:(AVAudioSessionPortDescription *)port {
    return @{
        @"type" : [self portTypeToNormalizedType:port.portType],
        @"nativeType" : [self portTypeToNativeString:port.portType],
        @"name" : port.portName,
        @"id" : [self deviceIdForPort:port],
    };
}

- (NSDictionary *)serializeBuiltInSpeaker {
    return @{
        @"type" : @"speaker",
        @"nativeType" : @"builtInSpeaker",
        @"name" : @"Speaker",
        @"id" : @"speaker",
    };
}

- (NSDictionary *)serializeBuiltInReceiver {
    return @{
        @"type" : @"earpiece",
        @"nativeType" : @"builtInReceiver",
        @"name" : @"iPhone",
        @"id" : @"receiver",
    };
}

- (NSArray *)buildAvailableDevices {
    NSMutableArray *devices = [NSMutableArray new];
    AVAudioSession *session = [AVAudioSession sharedInstance];

    [devices addObject:[self serializeBuiltInSpeaker]];
    [devices addObject:[self serializeBuiltInReceiver]];

    for (AVAudioSessionPortDescription *port in session.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            continue;
        }
        [devices addObject:[self serializePort:port]];
    }

    return devices;
}

- (NSDictionary *)buildCurrentDevice {
    AVAudioSessionRouteDescription *route = [[AVAudioSession sharedInstance] currentRoute];
    AVAudioSessionPortDescription *output = route.outputs.firstObject;
    if (!output) {
        return (id)[NSNull null];
    }
    return [self serializePort:output];
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    [self sendEventWithName:kEventAudioOutputChanged
                       body:@{
                           @"currentAudioOutput" : [self buildCurrentDevice],
                           @"availableAudioOutputs" : [self buildAvailableDevices],
                       }];
}

RCT_EXPORT_METHOD(getAvailableAudioOutputs : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [self ensureAudioRouteObserver];
    resolve([self buildAvailableDevices]);
}

RCT_EXPORT_METHOD(getCurrentAudioOutput : (RCTPromiseResolveBlock)resolve rejecter : (RCTPromiseRejectBlock)reject) {
    [self ensureAudioRouteObserver];
    NSDictionary *device = [self buildCurrentDevice];
    resolve([device isEqual:[NSNull null]] ? nil : device);
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

@end

#endif
