#import "H264DebugFrameCounter.h"

#import <React/RCTLog.h>
#import <stdatomic.h>

#import "ProcessorProvider.h"

NSString *const kH264DebugFrameCounterName = @"h264DebugFrameCounter";

@interface H264DebugFrameCounter () {
    atomic_ullong _frameCount;
    atomic_ullong _lastLoggedCount;
    atomic_int_fast64_t _lastLoggedNanos;
}
@end

@implementation H264DebugFrameCounter

+ (void)registerIfNeeded {
    if ([ProcessorProvider getProcessor:kH264DebugFrameCounterName] != nil) {
        return;
    }
    [ProcessorProvider addProcessor:[[H264DebugFrameCounter alloc] init]
                            forName:kH264DebugFrameCounterName];
    RCTLogInfo(@"[H264-DEBUG] Registered frame counter processor as \"%@\"", kH264DebugFrameCounterName);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_frameCount, 0);
        atomic_init(&_lastLoggedCount, 0);
        atomic_init(&_lastLoggedNanos, (int_fast64_t)(CACurrentMediaTime() * 1e9));
    }
    return self;
}

- (RTCVideoFrame *)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame {
    unsigned long long total = atomic_fetch_add(&_frameCount, 1) + 1;

    int_fast64_t nowNanos = (int_fast64_t)(CACurrentMediaTime() * 1e9);
    int_fast64_t lastNanos = atomic_load(&_lastLoggedNanos);
    int_fast64_t elapsedNanos = nowNanos - lastNanos;
    // Log roughly once per second without introducing a timer.
    if (elapsedNanos >= (int_fast64_t)1e9) {
        if (atomic_compare_exchange_strong(&_lastLoggedNanos, &lastNanos, nowNanos)) {
            unsigned long long previous = atomic_exchange(&_lastLoggedCount, total);
            unsigned long long delta = total - previous;
            double seconds = (double)elapsedNanos / 1e9;
            double fps = seconds > 0 ? (double)delta / seconds : 0.0;
            RCTLogInfo(@"[H264-DEBUG] frames t=%.3f total=%llu last=%llu window=%.2fs fps=%.2f",
                       (double)nowNanos / 1e9,
                       total,
                       delta,
                       seconds,
                       fps);
        }
    }

    return frame;
}

@end
