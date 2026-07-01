#if !TARGET_OS_TV && !TARGET_OS_OSX

#import <Metal/Metal.h>

#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "CustomVideoCaptureController.h"

static NSTimeInterval const kCustomVideoDrainTimeoutSeconds = 2.0;

@implementation CustomVideoCaptureController {
    RTCVideoSource *_videoSource;

    NSInteger _width;
    NSInteger _height;

    // Pool and its pre-allocated, index-stable buffers. The buffers are
    // retained for the whole lifetime of the controller because JS imports each
    // IOSurface exactly once and addresses them by index forever after.
    CVPixelBufferPoolRef _pixelBufferPool;
    NSArray *_pixelBuffers;  // boxed CVPixelBufferRef (NSValue pointerValue)

    // Single listener + dedicated serial queue for all fence callbacks.
    MTLSharedEventListener *_sharedEventListener API_AVAILABLE(ios(13.0));
    dispatch_queue_t _fenceCallbackQueue;

    // Lifecycle / drain bookkeeping. A single NSCondition, _drainCondition, is the
    // one mutual-exclusion lock guarding _accepting, _inFlightCount, _generation
    // and _tornDown. stopCapture pauses by bumping _generation; completion blocks
    // from an older generation then drop their frames instead of delivering stale
    // buffers after a pause/resume or final release.
    NSCondition *_drainCondition;
    BOOL _accepting;
    NSInteger _inFlightCount;
    NSInteger _generation;
    // Set only by releaseCaptureResources immediately before releaseBuffers. Any
    // notify/no-fence completion that runs after this is set must not deliver,
    // because the CVPixelBuffers it would ship have been released.
    BOOL _tornDown;
}

- (nullable instancetype)initWithVideoSource:(RTCVideoSource *)videoSource
                                       width:(NSInteger)width
                                      height:(NSInteger)height
                                    poolSize:(NSInteger)poolSize
                                       error:(NSError **)outError {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (width <= 0 || height <= 0 || poolSize <= 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"react-native-webrtc"
                                            code:0
                                        userInfo:@{
                                            NSLocalizedDescriptionKey :
                                                @"width, height and poolSize must all be positive"
                                        }];
        }
        return nil;
    }

    _videoSource = videoSource;
    _width = width;
    _height = height;

    _drainCondition = [[NSCondition alloc] init];
    _accepting = NO;
    _inFlightCount = 0;
    _generation = 0;
    _tornDown = NO;

    _fenceCallbackQueue =
        dispatch_queue_create("com.fishjam.webrtc.customVideoTrack.fence", DISPATCH_QUEUE_SERIAL);
    if (@available(iOS 13.0, *)) {
        _sharedEventListener = [[MTLSharedEventListener alloc] initWithDispatchQueue:_fenceCallbackQueue];
    }

    if (![self buildPoolWithSize:poolSize error:outError]) {
        return nil;
    }

    return self;
}

#pragma mark - Pool construction

- (BOOL)buildPoolWithSize:(NSInteger)poolSize error:(NSError **)outError {
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(_width),
        (id)kCVPixelBufferHeightKey : @(_height),
        // IOSurface-backed so the buffer can be imported into the GPU
        // (react-native-webgpu importSharedTextureMemory) and Metal-compatible
        // so the GPU can render into it.
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };

    // Cap the pool so CVPixelBufferPoolCreatePixelBuffer never recycles a buffer
    // while WebRTC still holds it: we allocate exactly poolSize buffers up front
    // and keep them all, so the pool's min-buffer-count == our pool size.
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey : @(poolSize),
    };

    CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                  (__bridge CFDictionaryRef)poolAttributes,
                                                  (__bridge CFDictionaryRef)pixelBufferAttributes,
                                                  &_pixelBufferPool);
    if (poolStatus != kCVReturnSuccess || _pixelBufferPool == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"react-native-webrtc"
                                            code:poolStatus
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : [NSString
                                                stringWithFormat:@"CVPixelBufferPoolCreate failed: %d", poolStatus]
                                        }];
        }
        return NO;
    }

    NSMutableArray *buffers = [NSMutableArray arrayWithCapacity:poolSize];
    for (NSInteger index = 0; index < poolSize; index++) {
        CVPixelBufferRef buffer = NULL;
        CVReturn bufferStatus =
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &buffer);
        if (bufferStatus != kCVReturnSuccess || buffer == NULL) {
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"react-native-webrtc"
                               code:bufferStatus
                           userInfo:@{
                               NSLocalizedDescriptionKey : [NSString
                                   stringWithFormat:@"CVPixelBufferPoolCreatePixelBuffer failed at index %ld: %d",
                                                    (long)index,
                                                    bufferStatus]
                           }];
            }
            // Release whatever we already allocated before bailing out.
            for (NSValue *boxed in buffers) {
                CVPixelBufferRelease((CVPixelBufferRef)boxed.pointerValue);
            }
            return NO;
        }
        // The NSArray keeps the +1 from CVPixelBufferPoolCreatePixelBuffer; we
        // balance it in dealloc / stopCapture.
        [buffers addObject:[NSValue valueWithPointer:buffer]];
    }

    _pixelBuffers = [buffers copy];

    // Build the JS-facing descriptors once, now that the surfaces are stable.
    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray arrayWithCapacity:poolSize];
    for (NSInteger index = 0; index < poolSize; index++) {
        CVPixelBufferRef buffer = (CVPixelBufferRef)[_pixelBuffers[index] pointerValue];
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
        // Emit the handle exactly the way react-native-webgpu interprets it on
        // import: the raw (uintptr_t)IOSurfaceRef, as a decimal string (a 64-bit
        // pointer would lose precision through a JS double).
        uintptr_t handle = (uintptr_t)surface;
        [descriptors addObject:@{
            @"index" : @(index),
            @"surfaceHandle" : [NSString stringWithFormat:@"%lu", (unsigned long)handle],
            @"width" : @(_width),
            @"height" : @(_height),
        }];
    }
    _bufferDescriptors = [descriptors copy];

    return YES;
}

#pragma mark - CaptureController overrides

- (void)startCapture {
    [_drainCondition lock];
    if (!_tornDown) {
        _generation++;
        _accepting = YES;
    }
    [_drainCondition unlock];
}

- (void)stopCapture {
    [_drainCondition lock];
    if (_tornDown) {
        [_drainCondition unlock];
        return;
    }

    // Pause only: mediaStreamTrackSetEnabled(false) calls stopCapture(), and a
    // later startCapture() must resume using the same IOSurface pool.
    _accepting = NO;
    _generation++;

    // Bound the drain so a never-signaled MTLSharedEvent cannot block the RN
    // method queue forever. Late completions from older generations drop.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kCustomVideoDrainTimeoutSeconds];
    while (_inFlightCount > 0) {
        if (![_drainCondition waitUntilDate:deadline]) {
            break;
        }
    }
    [_drainCondition unlock];
}

- (NSDictionary *)getSettings {
    return @{
        @"deviceId" : self.deviceId ?: @"custom-video",
        @"groupId" : @"",
        @"width" : @(_width),
        @"height" : @(_height),
    };
}

#pragma mark - Frame push

- (void)pushFrameForBufferIndex:(NSInteger)bufferIndex
                    fenceHandle:(uint64_t)fenceHandle
             fenceSignaledValue:(uint64_t)fenceSignaledValue
                    timestampNs:(int64_t)timestampNs
                       rotation:(RTCVideoRotation)rotation {
    CVPixelBufferRef buffer = NULL;
    NSInteger frameGeneration = 0;

    [_drainCondition lock];
    if (bufferIndex < 0 || bufferIndex >= (NSInteger)_pixelBuffers.count) {
        [_drainCondition unlock];
        NSLog(@"[CustomVideoCaptureController] pushFrame: bufferIndex %ld out of range", (long)bufferIndex);
        return;
    }
    if (!_accepting || _tornDown) {
        [_drainCondition unlock];
        return;
    }
    frameGeneration = _generation;
    buffer = (CVPixelBufferRef)[_pixelBuffers[bufferIndex] pointerValue];
    _inFlightCount++;
    [_drainCondition unlock];

    // Decide whether we have a usable fence to wait on. A handle of 0 means JS
    // supplied no fence (the JSI core passes 0/0 in that case); pre-iOS-13 has no
    // MTLSharedEvent. In those cases we deliver without waiting on the GPU.
    BOOL hasFence = (fenceHandle != 0);
    if (@available(iOS 13.0, *)) {
        // MTLSharedEvent available.
    } else {
        hasFence = NO;
    }

    if (!hasFence) {
        // No-fence delivery must NOT run on the calling (JS) thread: hop onto the
        // fence callback queue so JS is never blocked by source-side work, and so
        // this path shares the serialisation and torn-down guard of the fenced one.
        // The in-flight slot was reserved above; it is released inside.
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(_fenceCallbackQueue, ^{
            __typeof__(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf completeInFlightDeliveringBuffer:buffer
                                             generation:frameGeneration
                                             timestampNs:timestampNs
                                                rotation:rotation];
        });
        return;
    }

    if (@available(iOS 13.0, *)) {
        // The fence handle is the exported id<MTLSharedEvent> object pointer
        // reinterpreted as uint64_t (confirmed in react-native-webgpu
        // GPUSharedFence.cpp — reinterpret_cast<uint64_t> of the id<MTLSharedEvent>
        // held by SharedFenceMTLSharedEventExportInfo). The cast is __bridge (no
        // ARC ownership transfer); on its own that reference is non-owning, so if
        // JS drops the originating fence before the GPU signals, the event could
        // deallocate and we'd miss the callback / message a freed object.
        id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)(void *)(uintptr_t)fenceHandle;
        if (event == nil) {
            // Reserved a slot but have nothing to wait on; complete off-thread.
            __weak __typeof__(self) weakSelf = self;
            dispatch_async(_fenceCallbackQueue, ^{
                __typeof__(self) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                [strongSelf completeInFlightDeliveringBuffer:buffer
                                                 generation:frameGeneration
                                                 timestampNs:timestampNs
                                                    rotation:rotation];
            });
            return;
        }

        // Take an owning reference for the armed listener's lifetime so the event
        // cannot deallocate out from under the notify block. Balanced by exactly
        // one CFRelease inside the block, on every path out of it.
        CFRetain((__bridge CFTypeRef)event);

        __weak __typeof__(self) weakSelf = self;
        [event notifyListener:_sharedEventListener
                      atValue:fenceSignaledValue
                        block:^(id<MTLSharedEvent> _Nonnull notifyingEvent, uint64_t signaledValue) {
                            __typeof__(self) strongSelf = weakSelf;
                            if (strongSelf != nil) {
                                [strongSelf completeInFlightDeliveringBuffer:buffer
                                                                generation:frameGeneration
                                                                timestampNs:timestampNs
                                                                   rotation:rotation];
                            }
                            CFRelease((__bridge CFTypeRef)event);
                        }];
    }
}

- (void)deliverBuffer:(CVPixelBufferRef)buffer timestampNs:(int64_t)timestampNs rotation:(RTCVideoRotation)rotation {
    if (buffer == NULL) {
        return;
    }
    // Ship the BGRA RTCCVPixelBuffer directly (no I420 conversion): I420 is only
    // needed for the local Metal preview of screen sharing, not for sending.
    RTCCVPixelBuffer *rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:buffer];
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                        rotation:rotation
                                                     timeStampNs:timestampNs];
    // The RTCVideoSource is an RTCVideoCapturerDelegate; deliver straight to it.
    // No RTCVideoCapturer subclass needed.
    [_videoSource capturer:nil didCaptureVideoFrame:frame];
}

// Single completion path for an in-flight frame, shared by the fenced and
// no-fence routes. We decide-and-retain under _drainCondition, then deliver
// OUTSIDE the lock — never holding it across the WebRTC delivery call (which can
// apply back-pressure and would otherwise stall pushFrame on the JS thread).
// A completion delivers only if its generation is still current and capture is
// still accepting. Pause/resume/release all bump the generation, so stale
// completions only decrement the in-flight count. Retaining the CVPixelBuffer
// under the lock keeps it alive through delivery.
- (void)completeInFlightDeliveringBuffer:(CVPixelBufferRef)buffer
                              generation:(NSInteger)frameGeneration
                             timestampNs:(int64_t)timestampNs
                                rotation:(RTCVideoRotation)rotation {
    CVPixelBufferRef bufferToDeliver = NULL;
    [_drainCondition lock];
    if (!_tornDown && _accepting && _generation == frameGeneration && buffer != NULL) {
        bufferToDeliver = buffer;
        CVPixelBufferRetain(bufferToDeliver);
    }
    [_drainCondition unlock];

    if (bufferToDeliver != NULL) {
        [self deliverBuffer:bufferToDeliver timestampNs:timestampNs rotation:rotation];
        CVPixelBufferRelease(bufferToDeliver);
    }

    [_drainCondition lock];
    if (_inFlightCount > 0) {
        _inFlightCount--;
    }
    if (_inFlightCount <= 0) {
        [_drainCondition broadcast];
    }
    [_drainCondition unlock];
}

#pragma mark - Teardown

- (void)releaseCaptureResources {
    [_drainCondition lock];
    if (_tornDown) {
        [_drainCondition unlock];
        return;
    }

    _accepting = NO;
    _generation++;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kCustomVideoDrainTimeoutSeconds];
    while (_inFlightCount > 0) {
        if (![_drainCondition waitUntilDate:deadline]) {
            break;
        }
    }

    _tornDown = YES;
    [_drainCondition unlock];

    [self releaseBuffers];
}

// Safe to run while fence listeners are still armed or a delivery is in progress:
// releaseCaptureResources sets _tornDown under _drainCondition before calling
// this, so a completion starting afterwards observes _tornDown and skips
// delivery. An armed notify block still fires and balances its CFRetain.
- (void)releaseBuffers {
    if (_pixelBuffers) {
        for (NSValue *boxed in _pixelBuffers) {
            CVPixelBufferRef buffer = (CVPixelBufferRef)boxed.pointerValue;
            if (buffer) {
                CVPixelBufferRelease(buffer);
            }
        }
        _pixelBuffers = nil;
    }
    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    _bufferDescriptors = nil;
}

- (void)dealloc {
    [self releaseCaptureResources];
}

@end

#endif
