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

    // Lifecycle / drain bookkeeping. _stateLock guards _accepting and
    // _inFlightCount; _drainCondition lets stopCapture wait for the in-flight
    // notify blocks to finish before the pool is torn down.
    NSLock *_stateLock;
    NSCondition *_drainCondition;
    BOOL _accepting;
    NSInteger _inFlightCount;
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

    _stateLock = [[NSLock alloc] init];
    _drainCondition = [[NSCondition alloc] init];
    _accepting = NO;
    _inFlightCount = 0;

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
    [_stateLock lock];
    _accepting = YES;
    [_stateLock unlock];
}

- (void)stopCapture {
    // Stop accepting new pushes first so _inFlightCount can only decrease.
    [_stateLock lock];
    _accepting = NO;
    [_stateLock unlock];

    // Wait for any armed fence-notify blocks to run and deliver their frame.
    // They decrement _inFlightCount and signal the condition when done.
    [_drainCondition lock];
    while (_inFlightCount > 0) {
        [_drainCondition wait];
    }
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

    // Reserve an in-flight slot only if we are still accepting. This is the
    // point that stopCapture synchronises against: once _accepting is NO, no new
    // slot is reserved, so the drain loop is guaranteed to converge.
    [_stateLock lock];
    if (!_accepting) {
        [_stateLock unlock];
        return;
    }
    [_stateLock unlock];

    [_drainCondition lock];
    _inFlightCount++;
    [_drainCondition unlock];

    CVPixelBufferRef buffer = (CVPixelBufferRef)[_pixelBuffers[bufferIndex] pointerValue];

    // No fence: a handle of 0 means JS supplied no fence (the JSI core passes
    // 0/0 in that case). Deliver immediately, accepting that the GPU render may
    // not be complete.
    if (fenceHandle == 0) {
        [self deliverBuffer:buffer timestampNs:timestampNs rotation:rotation];
        [self finishInFlight];
        return;
    }

    if (@available(iOS 13.0, *)) {
        // The fence handle is the exported id<MTLSharedEvent> object pointer
        // reinterpreted as uint64_t (confirmed in react-native-webgpu
        // GPUSharedFence.cpp — reinterpret_cast<uint64_t> of the id<MTLSharedEvent>
        // held by SharedFenceMTLSharedEventExportInfo). It is a BORROWED,
        // non-owning reference: neither export nor import retains it, so we use
        // __bridge (no ARC ownership transfer) and rely on JS keeping the
        // originating fence alive for the duration of this callback.
        id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)(void *)(uintptr_t)fenceHandle;
        if (event == nil) {
            [self deliverBuffer:buffer timestampNs:timestampNs rotation:rotation];
            [self finishInFlight];
            return;
        }

        __weak __typeof__(self) weakSelf = self;
        [event notifyListener:_sharedEventListener
                      atValue:fenceSignaledValue
                        block:^(id<MTLSharedEvent> _Nonnull notifyingEvent, uint64_t signaledValue) {
                            __typeof__(self) strongSelf = weakSelf;
                            if (strongSelf == nil) {
                                return;
                            }
                            [strongSelf deliverBuffer:buffer timestampNs:timestampNs rotation:rotation];
                            [strongSelf finishInFlight];
                        }];
    } else {
        // MTLSharedEvent requires iOS 13; fall back to immediate delivery.
        [self deliverBuffer:buffer timestampNs:timestampNs rotation:rotation];
        [self finishInFlight];
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

- (void)finishInFlight {
    [_drainCondition lock];
    _inFlightCount--;
    if (_inFlightCount <= 0) {
        [_drainCondition broadcast];
    }
    [_drainCondition unlock];
}

#pragma mark - Teardown

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
