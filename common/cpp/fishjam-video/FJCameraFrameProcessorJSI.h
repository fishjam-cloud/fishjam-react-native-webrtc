// JSI channel for attaching a camera frame consumer to a local camera track.
//
// Installs `__fishjamWebrtcGetCameraFrameProcessor(trackId)` on the JS runtime.
// It returns a per-track `CameraFrameProcessor` host object with
// `attach(consumer)`, `detach()` and `statistics()`. The platform layer decides
// what a camera track is and installs the tap; this class only carries the
// calls across JSI.
//
// Pure C++20 plus JSI; the jsi::Runtime is only touched on the JS thread.
#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

#include "FJCameraFrame.h"
#include "FJCameraFrameProcessorCore.h"

class FJCameraFrameProcessorChannel;

// Per-track handle handed to JS. Holds only the track id and a weak reference
// to the channel; every call forwards to the channel's platform handlers.
class CameraFrameProcessorHandle : public facebook::jsi::HostObject {
   public:
    CameraFrameProcessorHandle(std::weak_ptr<FJCameraFrameProcessorChannel> owner, std::string trackId)
        : owner_(std::move(owner)), trackId_(std::move(trackId)) {}

    facebook::jsi::Value get(facebook::jsi::Runtime &rt, const facebook::jsi::PropNameID &name) override;
    std::vector<facebook::jsi::PropNameID> getPropertyNames(facebook::jsi::Runtime &rt) override;

   private:
    std::weak_ptr<FJCameraFrameProcessorChannel> owner_;
    std::string trackId_;
};

class FJCameraFrameProcessorChannel : public std::enable_shared_from_this<FJCameraFrameProcessorChannel> {
   public:
    // Platform hooks, all invoked on the JS thread from the host object's methods.
    struct Handlers {
        // Installs the tap on `trackId` and hands it `consumer`. Returns an empty
        // string on success, otherwise an error code (E_NOT_A_CAMERA_TRACK,
        // E_VIDEO_EFFECTS_ACTIVE, E_ATTACH_FAILED, E_MODULE_GONE) that the
        // channel throws to JS.
        std::function<std::string(const std::string &trackId,
                                  std::shared_ptr<fishjam::video::FJCameraFrameConsumer> consumer)>
            attach;
        std::function<void(const std::string &trackId)> detach;
        // Fills `out` for a track with a tap; false when the track has none.
        std::function<bool(const std::string &trackId, FJCameraFrameProcessorCore::Statistics &out)> statistics;
    };

    explicit FJCameraFrameProcessorChannel(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
        : jsInvoker_(std::move(jsInvoker)) {}

    // Installs the global on the JS thread; `onInstalled` runs there once it exists.
    void install(std::function<void()> onInstalled);
    bool isInstalled() const { return installed_.load(); }

    void setHandlers(Handlers handlers);
    // Never null; an empty Handlers until setHandlers() runs.
    std::shared_ptr<const Handlers> handlers() const;

   private:
    friend class CameraFrameProcessorHandle;
    facebook::jsi::Value getProcessor(facebook::jsi::Runtime &rt, const std::string &trackId);

    std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
    mutable std::mutex handlersMutex_;
    std::shared_ptr<const Handlers> handlers_ = std::make_shared<const Handlers>();
    std::atomic<bool> installed_{false};
};
