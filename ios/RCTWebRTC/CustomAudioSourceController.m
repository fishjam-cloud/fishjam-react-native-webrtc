#import "CustomAudioSourceController.h"

@implementation CustomAudioSourceController {
    void (^_teardownBlock)(void);
}

- (instancetype)initWithAudioSource:(RTCExternalAudioSource *)audioSource
                      teardownBlock:(void (^)(void))teardownBlock {
    self = [super init];
    if (self) {
        _audioSource = audioSource;
        _teardownBlock = [teardownBlock copy];
        _isTornDown = NO;
    }
    return self;
}

- (void)dealloc {
    [self releaseCaptureResources];
}

- (void)releaseCaptureResources {
    void (^teardownBlock)(void) = nil;
    @synchronized(self) {
        if (_isTornDown) {
            return;
        }
        _isTornDown = YES;
        teardownBlock = _teardownBlock;
        _teardownBlock = nil;
    }
    if (teardownBlock) {
        teardownBlock();
    }
}

- (NSDictionary *)getSettings {
    return @{
        @"deviceId" : @"custom-audio",
        @"groupId" : @"",
    };
}

@end
