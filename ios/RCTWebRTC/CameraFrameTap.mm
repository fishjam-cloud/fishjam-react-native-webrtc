#if !TARGET_OS_TV && !TARGET_OS_OSX

#import "CameraFrameTap.h"

#import <CoreVideo/CoreVideo.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import "VideoCaptureController.h"

#include <mutex>

using fishjam::video::FJCameraFrame;
using fishjam::video::FJCameraFrameConsumer;
using fishjam::video::FJCameraPixelFormat;

static int32_t FJRotationDegrees(RTCVideoRotation rotation) {
    switch (rotation) {
        case RTCVideoRotation_90:
            return 90;
        case RTCVideoRotation_180:
            return 180;
        case RTCVideoRotation_270:
            return 270;
        case RTCVideoRotation_0:
        default:
            return 0;
    }
}

static FJCameraPixelFormat FJPixelFormatOf(CVPixelBufferRef pixelBuffer) {
    OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        return FJCameraPixelFormat::NV12;
    }
    if (type == kCVPixelFormatType_32BGRA) {
        return FJCameraPixelFormat::BGRA8;
    }
    if (type == kCVPixelFormatType_32RGBA) {
        return FJCameraPixelFormat::RGBA8;
    }
    return FJCameraPixelFormat::Unknown;
}

@interface CameraFrameTap () {
    std::shared_ptr<FJCameraFrameProcessorCore> _core;
    std::shared_ptr<FJCameraFrameConsumer> _consumer;
    std::mutex _consumerMutex;
}

@property(nonatomic, strong) RTCVideoSource *videoSource;
@property(nonatomic, weak) VideoCaptureController *captureController;

@end

@implementation CameraFrameTap

- (instancetype)initWithVideoSource:(RTCVideoSource *)videoSource
                  captureController:(VideoCaptureController *)captureController {
    self = [super init];
    if (self) {
        _videoSource = videoSource;
        _captureController = captureController;
        _core = std::make_shared<FJCameraFrameProcessorCore>();
    }
    return self;
}

- (void)attachConsumer:(std::shared_ptr<FJCameraFrameConsumer>)consumer {
    std::lock_guard<std::mutex> lock(_consumerMutex);
    _consumer = std::move(consumer);
    _core->attach();
}

- (void)detachConsumer {
    std::lock_guard<std::mutex> lock(_consumerMutex);
    _core->detach();
    _consumer = nullptr;
}

- (FJCameraFrameProcessorCore::Statistics)statistics {
    return _core->statistics();
}

#pragma mark - RTCVideoCapturerDelegate

- (void)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame {
    // The camera track first: it keeps flowing whatever the processor does.
    [self.videoSource capturer:capturer didCaptureVideoFrame:frame];

    std::shared_ptr<FJCameraFrameConsumer> consumer;
    {
        std::lock_guard<std::mutex> lock(_consumerMutex);
        consumer = _consumer;
    }
    if (!consumer) {
        return;
    }

    FJCameraFrameProcessorCore::Offer offer = _core->offer();
    if (offer.result != FJCameraFrameProcessorCore::OfferResult::Accepted) {
        return;
    }

    id<RTCVideoFrameBuffer> buffer = frame.buffer;
    if (![buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        // Only the camera capturer's native buffers can be shared with a GPU.
        _core->completed(offer.token);
        return;
    }
    CVPixelBufferRef pixelBuffer = ((RTCCVPixelBuffer *)buffer).pixelBuffer;
    CVPixelBufferRetain(pixelBuffer);

    // The frame's destructor is the single release path: it hands the buffer back
    // and reopens the gate, however the consumer let go of the frame.
    std::shared_ptr<FJCameraFrameProcessorCore> core = _core;
    uint64_t token = offer.token;
    auto cameraFrame = std::make_shared<FJCameraFrame>(
        (uint64_t)(uintptr_t)pixelBuffer, frame.width, frame.height, FJRotationDegrees(frame.rotation),
        self.captureController.usingFrontCamera, frame.timeStampNs, FJPixelFormatOf(pixelBuffer),
        /* acquireFenceFileDescriptor */ -1, [core, token, pixelBuffer]() {
            CVPixelBufferRelease(pixelBuffer);
            core->completed(token);
        });
    consumer->onFrame(std::move(cameraFrame));
}

@end

#endif
