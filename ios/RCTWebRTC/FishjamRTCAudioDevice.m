#import "FishjamRTCAudioDevice.h"

#if TARGET_OS_IOS

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface FishjamRTCAudioDevice ()

@property(nonatomic, strong) AUAudioUnit *audioUnit;
@property(nonatomic, weak) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, assign) BOOL shouldPlay;
@property(nonatomic, assign) BOOL shouldRecord;
@property(nonatomic, assign) BOOL interrupted;

@end

@implementation FishjamRTCAudioDevice

- (AVAudioSession *)audioSession {
    return [AVAudioSession sharedInstance];
}

#pragma mark - RTCAudioDevice

- (double)deviceInputSampleRate {
    return self.audioSession.sampleRate;
}

- (double)deviceOutputSampleRate {
    return self.audioSession.sampleRate;
}

- (NSTimeInterval)inputIOBufferDuration {
    return self.audioSession.IOBufferDuration;
}

- (NSTimeInterval)outputIOBufferDuration {
    return self.audioSession.IOBufferDuration;
}

- (NSInteger)inputNumberOfChannels {
    return MIN(2, self.audioSession.inputNumberOfChannels);
}

- (NSInteger)outputNumberOfChannels {
    return MIN(2, self.audioSession.outputNumberOfChannels);
}

- (NSTimeInterval)inputLatency {
    return self.audioSession.inputLatency;
}

- (NSTimeInterval)outputLatency {
    return self.audioSession.outputLatency;
}

- (BOOL)isInitialized {
    return self.delegate != nil && self.audioUnit != nil;
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    if (self.delegate != nil) {
        return NO;
    }

    AudioComponentDescription desc = {.componentType = kAudioUnitType_Output,
                                      .componentSubType = kAudioUnitSubType_VoiceProcessingIO,
                                      .componentManufacturer = kAudioUnitManufacturer_Apple,
                                      .componentFlags = 0,
                                      .componentFlagsMask = 0};

    NSError *error = nil;
    AUAudioUnit *audioUnit = [[AUAudioUnit alloc] initWithComponentDescription:desc error:&error];
    if (error || !audioUnit) {
        NSLog(@"[FishjamRTCAudioDevice] Failed to create audio unit: %@", error);
        return NO;
    }

    audioUnit.inputEnabled = NO;
    audioUnit.outputEnabled = NO;
    audioUnit.maximumFramesToRender = 1024;

    self.audioUnit = audioUnit;
    self.delegate = delegate;

    [self subscribeToNotifications];

    return YES;
}

- (BOOL)terminateDevice {
    [self unsubscribeFromNotifications];

    self.shouldPlay = NO;
    self.shouldRecord = NO;
    [self updateAudioUnit];

    self.audioUnit = nil;
    self.delegate = nil;

    return YES;
}

- (BOOL)isPlayoutInitialized {
    return self.isInitialized;
}

- (BOOL)initializePlayout {
    return self.isPlayoutInitialized;
}

- (BOOL)isPlaying {
    return self.shouldPlay;
}

- (BOOL)startPlayout {
    self.shouldPlay = YES;
    [self updateAudioUnit];
    return YES;
}

- (BOOL)stopPlayout {
    self.shouldPlay = NO;
    [self updateAudioUnit];
    return YES;
}

- (BOOL)isRecordingInitialized {
    return self.isInitialized;
}

- (BOOL)initializeRecording {
    return self.isRecordingInitialized;
}

- (BOOL)isRecording {
    return self.shouldRecord;
}

- (BOOL)startRecording {
    self.shouldRecord = YES;
    [self updateAudioUnit];
    return YES;
}

- (BOOL)stopRecording {
    self.shouldRecord = NO;
    [self updateAudioUnit];
    return YES;
}

#pragma mark - Audio Unit Management

- (void)configureAudioSession {
    NSError *error = nil;
    AVAudioSession *session = self.audioSession;

    if (self.shouldRecord) {
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionDefaultToSpeaker
                       error:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to set PlayAndRecord category: %@", error);
        }
        [session setMode:AVAudioSessionModeVoiceChat error:&error];
    } else {
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to set Playback category: %@", error);
        }
        [session setMode:AVAudioSessionModeDefault error:&error];
    }

    [session setActive:YES error:&error];
    if (error) {
        NSLog(@"[FishjamRTCAudioDevice] Failed to activate audio session: %@", error);
    }
}

- (void)updateAudioUnit {
    AUAudioUnit *au = self.audioUnit;
    if (!au) {
        return;
    }

    id<RTCAudioDeviceDelegate> delegate = self.delegate;

    if (!delegate || (!self.shouldPlay && !self.shouldRecord) || self.interrupted) {
        [self stopAndDeallocateAudioUnit:au delegate:delegate];
        return;
    }

    [self configureAudioSession];

    if (au.inputEnabled != self.shouldRecord) {
        [self stopAndDeallocateAudioUnit:au delegate:delegate];
        au.inputEnabled = self.shouldRecord;
    }

    if (au.outputEnabled != self.shouldPlay) {
        [self stopAndDeallocateAudioUnit:au delegate:delegate];
        au.outputEnabled = self.shouldPlay;
    }

    double sampleRate = self.audioSession.sampleRate;

    if (self.shouldRecord) {
        AVAudioFormat *recordFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatInt16
                      sampleRate:sampleRate
                        channels:(AVAudioChannelCount)MIN(2, self.audioSession.inputNumberOfChannels)
                     interleaved:YES];
        NSError *error = nil;
        [au.outputBusses[1] setFormat:recordFormat error:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to set record format: %@", error);
            return;
        }

        RTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData = delegate.deliverRecordedData;
        AURenderBlock renderBlock = au.renderBlock;

        RTCAudioDeviceRenderRecordedDataBlock customRenderBlock =
            ^OSStatus(AudioUnitRenderActionFlags *_Nonnull actionFlags,
                      const AudioTimeStamp *_Nonnull timestamp,
                      NSInteger inputBusNumber,
                      UInt32 frameCount,
                      AudioBufferList *_Nonnull abl,
                      void *_Nullable renderContext) {
                return renderBlock(actionFlags, timestamp, frameCount, (AUAudioFrameCount)inputBusNumber, abl, nil);
            };

        au.inputHandler = ^(AudioUnitRenderActionFlags *_Nonnull actionFlags,
                            const AudioTimeStamp *_Nonnull timestamp,
                            AUAudioFrameCount frameCount,
                            NSInteger inputBusNumber) {
            OSStatus status =
                deliverRecordedData(actionFlags, timestamp, inputBusNumber, frameCount, nil, nil, customRenderBlock);
            if (status != noErr) {
                NSLog(@"[FishjamRTCAudioDevice] Failed to deliver recorded data: %d", (int)status);
            }
        };
    }

    if (self.shouldPlay) {
        AVAudioFormat *playFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatInt16
                      sampleRate:sampleRate
                        channels:(AVAudioChannelCount)MIN(2, self.audioSession.outputNumberOfChannels)
                     interleaved:YES];
        NSError *error = nil;
        [au.inputBusses[0] setFormat:playFormat error:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to set play format: %@", error);
            return;
        }

        if (au.outputProvider == nil) {
            RTCAudioDeviceGetPlayoutDataBlock getPlayoutData = delegate.getPlayoutData;
            au.outputProvider = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *_Nonnull actionFlags,
                                                   const AudioTimeStamp *_Nonnull timestamp,
                                                   AUAudioFrameCount frameCount,
                                                   NSInteger inputBusNumber,
                                                   AudioBufferList *_Nonnull inputData) {
                return getPlayoutData(actionFlags, timestamp, inputBusNumber, frameCount, inputData);
            };
        }
    }

    NSError *error = nil;
    if (!au.renderResourcesAllocated) {
        [au allocateRenderResourcesAndReturnError:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to allocate render resources: %@", error);
            return;
        }
    }

    if (!au.isRunning) {
        [au startHardwareAndReturnError:&error];
        if (error) {
            NSLog(@"[FishjamRTCAudioDevice] Failed to start hardware: %@", error);
            return;
        }
    }
}

- (void)stopAndDeallocateAudioUnit:(AUAudioUnit *)au delegate:(id<RTCAudioDeviceDelegate>)delegate {
    if (au.isRunning) {
        [au stopHardware];
        if (delegate) {
            [delegate notifyAudioInputInterrupted];
            [delegate notifyAudioOutputInterrupted];
        }
    }
    if (au.renderResourcesAllocated) {
        [au deallocateRenderResources];
    }
}

#pragma mark - Audio Session Notifications

- (void)subscribeToNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleRouteChange:)
                   name:AVAudioSessionRouteChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleMediaServerReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:nil];
}

- (void)unsubscribeFromNotifications {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleInterruption:(NSNotification *)notification {
    NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.interrupted = YES;
    } else {
        self.interrupted = NO;
    }
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate) {
        [delegate dispatchAsync:^{
            [self updateAudioUnit];
        }];
    }
}

- (void)handleRouteChange:(NSNotification *)notification {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate) {
        [delegate dispatchAsync:^{
            [self updateAudioUnit];
        }];
    }
}

- (void)handleMediaServerReset:(NSNotification *)notification {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate) {
        [delegate dispatchAsync:^{
            [self updateAudioUnit];
        }];
    }
}

@end

#else  // !TARGET_OS_IOS

@implementation FishjamRTCAudioDevice

- (double)deviceInputSampleRate {
    return 0;
}
- (double)deviceOutputSampleRate {
    return 0;
}
- (NSTimeInterval)inputIOBufferDuration {
    return 0;
}
- (NSTimeInterval)outputIOBufferDuration {
    return 0;
}
- (NSInteger)inputNumberOfChannels {
    return 0;
}
- (NSInteger)outputNumberOfChannels {
    return 0;
}
- (NSTimeInterval)inputLatency {
    return 0;
}
- (NSTimeInterval)outputLatency {
    return 0;
}
- (BOOL)isInitialized {
    return NO;
}
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    return NO;
}
- (BOOL)terminateDevice {
    return NO;
}
- (BOOL)isPlayoutInitialized {
    return NO;
}
- (BOOL)initializePlayout {
    return NO;
}
- (BOOL)isPlaying {
    return NO;
}
- (BOOL)startPlayout {
    return NO;
}
- (BOOL)stopPlayout {
    return NO;
}
- (BOOL)isRecordingInitialized {
    return NO;
}
- (BOOL)initializeRecording {
    return NO;
}
- (BOOL)isRecording {
    return NO;
}
- (BOOL)startRecording {
    return NO;
}
- (BOOL)stopRecording {
    return NO;
}

@end

#endif
