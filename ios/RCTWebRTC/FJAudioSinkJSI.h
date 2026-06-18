// JSI install channel for native -> JS audio delivery.
//
// Stands up a global JS function `__fishjamWebrtcSetAudioSink` through which JS
// registers a callback, then marshals PCM metadata + a zero-copy jsi::ArrayBuffer
// to that callback via the CallInvoker. This is an ObjC++ unit (references NSString)
// and must be compiled as C++20.
#pragma once

#ifdef __cplusplus

#import <Foundation/Foundation.h>

#include <atomic>
#include <functional>
#include <memory>
#include <vector>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

// Backs a JS ArrayBuffer with an owned byte vector (moved in — no copy).
class PcmBuffer : public facebook::jsi::MutableBuffer {
   public:
    explicit PcmBuffer(std::vector<uint8_t> b) : b_(std::move(b)) {}
    size_t size() const override { return b_.size(); }
    uint8_t *data() override { return b_.data(); }

   private:
    std::vector<uint8_t> b_;
};

// Owns the CallInvoker + the JS callback (JS-thread-only). The jsi::Runtime is
// never cached — it is obtained only inside invokeAsync. Lambdas capture a
// weak_ptr<FJAudioSink> to avoid a retain cycle with the runtime global.
class FJAudioSink : public std::enable_shared_from_this<FJAudioSink> {
   public:
    explicit FJAudioSink(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
        : jsInvoker_(std::move(jsInvoker)) {}

    // Installs the `__fishjamWebrtcSetAudioSink` global; calls onInstalled on the JS thread.
    void install(std::function<void()> onInstalled);

    bool isInstalled() const { return installed_.load(); }

    // Marshals one (already-converted) PCM batch to the registered JS callback.
    // `bytes` is moved straight into the ArrayBuffer — no copy here.
    void deliver(int pcId,
                 NSString *trackId,
                 int sampleRate,
                 int channels,
                 const char *format,
                 std::vector<uint8_t> bytes);

   private:
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
    std::shared_ptr<facebook::jsi::Function> callback_;  // JS-thread-only
    std::atomic<bool> installed_{false};
};

#endif  // __cplusplus
