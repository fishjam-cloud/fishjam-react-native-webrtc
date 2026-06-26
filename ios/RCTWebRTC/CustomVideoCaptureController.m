#if !TARGET_OS_TV

#import <Metal/Metal.h>

#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "CustomVideoCaptureController.h"

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
    // one mutual-exclusion lock guarding _accepting, _inFlightCount and _tornDown,
    // and it also provides the wait/signal channel stopCapture uses to drain the
    // in-flight notify blocks before the pool is torn down. Keeping all three
    // fields under the same lock is what makes the accepting-check + in-flight
    // increment atomic against teardown (no use-after-free).
    NSCondition *_drainCondition;
    BOOL _accepting;
    NSInteger _inFlightCount;
    // Set (under _drainCondition) by stopCapture immediately before releaseBuffers.
    // Any notify/no-fence completion that runs after this is set must NOT deliver,
    // because the CVPixelBuffers it would ship have already been freed.
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
    _accepting = YES;
    [_drainCondition unlock];
}

- (void)stopCapture {
    [_drainCondition lock];
    // Stop accepting new pushes first so _inFlightCount can only decrease.
    _accepting = NO;

    // Wait for any armed fence-notify blocks to run and deliver their frame; they
    // decrement _inFlightCount and signal the condition when done. The wait is
    // BOUNDED: _inFlightCount only drops inside an MTLSharedEvent notify block, so
    // a fence that the GPU never signals would otherwise deadlock teardown forever.
    // After the deadline we abandon any stragglers and tear down anyway.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (_inFlightCount > 0) {
        if (![_drainCondition waitUntilDate:deadline]) {
            break;  // deadline elapsed — proceed even though stragglers remain
        }
    }

    // Mark torn down under the same lock that the completion path checks, so any
    // straggler notify block either already finished delivering (it held this lock)
    // or will observe _tornDown and bail without touching the buffers we free below.
    _tornDown = YES;
    [_drainCondition unlock];

    [self releaseBuffers];
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
    if (bufferIndex < 0 || bufferIndex >= (NSInteger)_pixelBuffers.count) {
        NSLog(@"[CustomVideoCaptureController] pushFrame: bufferIndex %ld out of range", (long)bufferIndex);
        return;
    }

    // Atomically check we are still accepting AND reserve the in-flight slot under
    // the single lock. This is the point stopCapture synchronises against: doing
    // the check and the increment as one critical section means a push can never
    // pass the accepting check, get preempted while stopCapture drains (sees count
    // 0) and frees the buffers, then resume and deliver a freed buffer (UAF).
    [_drainCondition lock];
    if (!_accepting) {
        [_drainCondition unlock];
        return;
    }
    _inFlightCount++;
    [_drainCondition unlock];

    CVPixelBufferRef buffer = (CVPixelBufferRef)[_pixelBuffers[bufferIndex] pointerValue];

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
// Retaining the CVPixelBuffer under the lock keeps it alive through delivery even
// if stopCapture's releaseBuffers (which only runs after _tornDown is set under
// this same lock) drops the pool's reference concurrently — so there is no
// use-after-free. A completion that starts after teardown observes _tornDown and
// skips delivery. The in-flight slot reserved in pushFrame is released here,
// signalling stopCapture once the count reaches zero.
- (void)completeInFlightDeliveringBuffer:(CVPixelBufferRef)buffer
                             timestampNs:(int64_t)timestampNs
                                rotation:(RTCVideoRotation)rotation {
    CVPixelBufferRef bufferToDeliver = NULL;
    [_drainCondition lock];
    if (!_tornDown && buffer != NULL) {
        bufferToDeliver = buffer;
        CVPixelBufferRetain(bufferToDeliver);
    }
    _inFlightCount--;
    if (_inFlightCount <= 0) {
        [_drainCondition broadcast];
    }
    [_drainCondition unlock];

    if (bufferToDeliver != NULL) {
        [self deliverBuffer:bufferToDeliver timestampNs:timestampNs rotation:rotation];
        CVPixelBufferRelease(bufferToDeliver);
    }
}

#pragma mark - Teardown

// Safe to run while fence listeners are still armed or a delivery is in progress:
// stopCapture sets _tornDown under _drainCondition before calling this, so a
// completion starting afterwards observes _tornDown and skips delivery, and a
// completion already in flight has retained its CVPixelBuffer under the lock — so
// the CVPixelBufferRelease here only drops the pool's reference, never the last
// one. An armed notify block still fires and balances its CFRetain.
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
    // stopCapture normally releases the buffers; releaseBuffers is idempotent so
    // this is a safety net for paths that dealloc without an explicit stop.
    [self releaseBuffers];
}

@end

#endif
