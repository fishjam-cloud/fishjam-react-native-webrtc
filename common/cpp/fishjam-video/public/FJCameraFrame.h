// Public contract between this library's camera frame processor and a consumer
// built in another one (the worklets package, for instance).
//
// Header-only and pure-virtual on purpose: a consumer only needs to include
// this file, never to link against the library, and nothing here relies on
// RTTI working across dynamic-library boundaries.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <utility>

#include <jsi/jsi.h>

namespace fishjam::video {

enum class FJCameraPixelFormat : int32_t {
    Unknown = 0,
    // kCVPixelFormatType_420YpCbCr8BiPlanar* on iOS.
    NV12 = 1,
    BGRA8 = 2,
    RGBA8 = 3,
};

// One camera frame handed to a consumer. Owns its native buffer: dropping the
// last reference returns the buffer to the camera and reopens the admission
// gate, so a consumer must let go of a frame as soon as it is done with it.
class FJCameraFrame {
   public:
    using Release = std::function<void()>;

    FJCameraFrame(uint64_t nativeBuffer,
                  int32_t width,
                  int32_t height,
                  int32_t rotationDegrees,
                  bool isFrontCamera,
                  int64_t timestampNanoseconds,
                  FJCameraPixelFormat pixelFormat,
                  Release release)
        : nativeBuffer(nativeBuffer),
          width(width),
          height(height),
          rotationDegrees(rotationDegrees),
          isFrontCamera(isFrontCamera),
          timestampNanoseconds(timestampNanoseconds),
          pixelFormat(pixelFormat),
          release_(std::move(release)) {}

    ~FJCameraFrame() {
        if (release_) {
            release_();
        }
    }

    FJCameraFrame(const FJCameraFrame &) = delete;
    FJCameraFrame &operator=(const FJCameraFrame &) = delete;

    // A CVPixelBufferRef on iOS, an AHardwareBuffer* on Android, retained for the
    // frame's lifetime.
    const uint64_t nativeBuffer;
    // Dimensions of the buffer as stored, before `rotationDegrees` is applied.
    const int32_t width;
    const int32_t height;
    // Clockwise rotation that brings the buffer upright: 0, 90, 180 or 270.
    const int32_t rotationDegrees;
    const bool isFrontCamera;
    // Capture time on the platform's monotonic clock.
    const int64_t timestampNanoseconds;
    const FJCameraPixelFormat pixelFormat;

   private:
    Release release_;
};

class FJCameraFrameConsumer {
   public:
    virtual ~FJCameraFrameConsumer() = default;
    // Called on the camera's capture thread for every admitted frame. Must return
    // promptly; the frame stays valid until the consumer drops its reference.
    virtual void onFrame(std::shared_ptr<FJCameraFrame> frame) = 0;
};

// How a consumer crosses JSI into `CameraFrameProcessor.attach`: as a host
// object deriving from this class whose `get` answers `true` for
// `__fishjamCameraFrameConsumer`. Host objects are what react-native-worklets
// passes between runtimes by reference, and the tag is what makes a static cast
// to this type safe without RTTI.
class FJCameraFrameConsumerHostObject : public facebook::jsi::HostObject {
   public:
    virtual std::shared_ptr<FJCameraFrameConsumer> consumer() = 0;
};

inline constexpr const char *kFJCameraFrameConsumerTag = "__fishjamCameraFrameConsumer";

}  // namespace fishjam::video
