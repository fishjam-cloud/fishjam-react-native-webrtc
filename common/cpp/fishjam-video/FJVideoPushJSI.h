// JSI channel for pushing custom video frames from JS to native. Installs a
// global `__fishjamWebrtcPushVideoFrame(frame)` that JS calls per frame; each
// push is forwarded to a registered delivery callback that the platform layer
// sets. Pure C++20.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

// Owns the JS-facing push function and forwards each frame to the platform's
// registered delivery callback. The jsi::Runtime is only touched on the JS
// thread; the platform layer wires up frame delivery via setDeliver.
class FJVideoPush : public std::enable_shared_from_this<FJVideoPush> {
   public:
    // Called for every frame pushed from JS. Carries the resolved fence handle
    // and signaled value (both `0` when no fence was supplied).
    using DeliverFn = std::function<void(const std::string &trackId,
                                         int bufferIndex,
                                         uint64_t timestampNs,
                                         int rotation,
                                         uint64_t fenceHandle,
                                         uint64_t fenceSignaledValue)>;

    explicit FJVideoPush(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
        : jsInvoker_(std::move(jsInvoker)) {}

    // Installs the global push function; invokes onInstalled on the JS thread
    // once ready.
    void install(std::function<void()> onInstalled);

    bool isInstalled() const { return installed_.load(); }

    // Registers the platform delivery callback that each pushed frame is
    // forwarded to. Set it before frames start arriving.
    void setDeliver(DeliverFn deliver);

   private:
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
    DeliverFn deliver_;
    std::atomic<bool> installed_{false};
};
