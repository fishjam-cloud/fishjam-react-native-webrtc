// JSI channel for delivering converted PCM from native to JS. Installs a global
// `__fishjamWebrtcSetAudioSink(handler)` that JS uses to register its callback;
// batches are then delivered to that handler via the CallInvoker. Pure C++20.
#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

// Backs a JS ArrayBuffer with an owned byte vector (moved in, no copy).
class PcmBuffer : public facebook::jsi::MutableBuffer {
   public:
    explicit PcmBuffer(std::vector<uint8_t> bytes) : bytes_(std::move(bytes)) {}
    size_t size() const override { return bytes_.size(); }
    uint8_t *data() override { return bytes_.data(); }

   private:
    std::vector<uint8_t> bytes_;
};

// Owns the JS callback and delivers batches to it on the JS thread. The
// jsi::Runtime is only ever touched inside invokeAsync; the lambdas hold a
// weak_ptr to avoid a retain cycle through the runtime global.
class FJAudioSink : public std::enable_shared_from_this<FJAudioSink> {
   public:
    explicit FJAudioSink(std::shared_ptr<facebook::react::CallInvoker> jsInvoker) : jsInvoker_(std::move(jsInvoker)) {}

    // Installs the global; invokes onInstalled on the JS thread once ready.
    void install(std::function<void()> onInstalled);

    bool isInstalled() const { return installed_.load(); }

    // Delivers one already-converted PCM batch to the JS callback. `bytes` is
    // moved straight into the ArrayBuffer.
    void deliver(int pcId,
                 const std::string &trackId,
                 int sampleRate,
                 int channels,
                 std::string_view format,
                 std::vector<uint8_t> bytes);

   private:
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
    std::shared_ptr<facebook::jsi::Function> callback_;
    std::atomic<bool> installed_{false};
};
