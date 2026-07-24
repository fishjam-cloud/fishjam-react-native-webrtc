#include "FJAudioPushJSI.h"

namespace jsi = facebook::jsi;

jsi::Value CustomAudioSink::get(jsi::Runtime &rt, const jsi::PropNameID &name) {
    if (name.utf8(rt) != "push") {
        return jsi::Value::undefined();
    }
    // Capture the bound trackId + owner by value so the returned push function
    // is self-contained and safe to call on whatever runtime `get` ran on
    // (worklet or main JS). `get` is invoked lazily by the runtime that captured
    // the sink.
    std::weak_ptr<FJAudioPush> owner = owner_;
    std::string trackId = trackId_;
    return jsi::Function::createFromHostFunction(
        rt,
        jsi::PropNameID::forAscii(rt, "push"),
        1,
        [owner, trackId](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
            auto push = owner.lock();
            if (!push || count == 0) {
                return jsi::Value::undefined();
            }
            push->deliverSamples(rt, trackId, args[0]);
            return jsi::Value::undefined();
        });
}

std::shared_ptr<FJAudioFrameScheduler> FJAudioPush::schedulerForTrack(const std::string &trackId) {
    std::lock_guard<std::mutex> lock(schedulersMutex_);
    auto it = schedulers_.find(trackId);
    return it == schedulers_.end() ? nullptr : it->second;
}

void FJAudioPush::deliverSamples(jsi::Runtime &rt, const std::string &trackId, const jsi::Value &samples) {
    // Per-push hot path: validate and silently drop malformed input rather than
    // throwing a jsi::JSError back into JS.
    auto scheduler = schedulerForTrack(trackId);
    if (!scheduler || !samples.isObject()) {
        return;
    }
    jsi::Object object = samples.getObject(rt);

    // Raw ArrayBuffer: interpreted as interleaved int16.
    if (object.isArrayBuffer(rt)) {
        jsi::ArrayBuffer arrayBuffer = object.getArrayBuffer(rt);
        scheduler->enqueueInt16(reinterpret_cast<const int16_t *>(arrayBuffer.data(rt)), arrayBuffer.size(rt) / 2);
        return;
    }

    // TypedArray (Float32Array | Int16Array): read the view's window into its
    // backing ArrayBuffer.
    jsi::Value bufferValue = object.getProperty(rt, "buffer");
    jsi::Value byteOffsetValue = object.getProperty(rt, "byteOffset");
    jsi::Value byteLengthValue = object.getProperty(rt, "byteLength");
    if (!bufferValue.isObject() || !byteOffsetValue.isNumber() || !byteLengthValue.isNumber()) {
        return;
    }
    jsi::Object bufferObject = bufferValue.getObject(rt);
    if (!bufferObject.isArrayBuffer(rt)) {
        return;
    }
    jsi::ArrayBuffer arrayBuffer = bufferObject.getArrayBuffer(rt);
    size_t byteOffset = static_cast<size_t>(byteOffsetValue.asNumber());
    size_t byteLength = static_cast<size_t>(byteLengthValue.asNumber());
    if (byteOffset + byteLength > arrayBuffer.size(rt)) {
        return;
    }
    const uint8_t *viewData = arrayBuffer.data(rt) + byteOffset;

    jsi::Function float32ArrayConstructor = rt.global().getPropertyAsFunction(rt, "Float32Array");
    if (object.instanceOf(rt, float32ArrayConstructor)) {
        scheduler->enqueueFloat32(reinterpret_cast<const float *>(viewData), byteLength / 4);
        return;
    }
    jsi::Function int16ArrayConstructor = rt.global().getPropertyAsFunction(rt, "Int16Array");
    if (object.instanceOf(rt, int16ArrayConstructor)) {
        scheduler->enqueueInt16(reinterpret_cast<const int16_t *>(viewData), byteLength / 2);
        return;
    }
    // Any other view type is unsupported: drop.
}

void FJAudioPush::registerTrack(const std::string &trackId,
                                int sampleRateHz,
                                int channelCount,
                                int maxBufferedDurationMs,
                                FJAudioFrameScheduler::EmitFn emit) {
    auto scheduler =
        std::make_shared<FJAudioFrameScheduler>(sampleRateHz, channelCount, maxBufferedDurationMs, std::move(emit));
    scheduler->start();
    std::shared_ptr<FJAudioFrameScheduler> replaced;
    {
        std::lock_guard<std::mutex> lock(schedulersMutex_);
        auto it = schedulers_.find(trackId);
        if (it != schedulers_.end()) {
            replaced = std::move(it->second);
            it->second = std::move(scheduler);
        } else {
            schedulers_.emplace(trackId, std::move(scheduler));
        }
    }
    // Stop a replaced scheduler outside the lock (stop joins its feeder thread).
    if (replaced) {
        replaced->stop();
    }
}

void FJAudioPush::unregisterTrack(const std::string &trackId) {
    std::shared_ptr<FJAudioFrameScheduler> removed;
    {
        std::lock_guard<std::mutex> lock(schedulersMutex_);
        auto it = schedulers_.find(trackId);
        if (it == schedulers_.end()) {
            return;
        }
        removed = std::move(it->second);
        schedulers_.erase(it);
    }
    removed->stop();
}

jsi::Value FJAudioPush::getSink(jsi::Runtime &rt, const std::string &trackId) {
    // Fresh sink per request: JS fetches a track's sink once and holds it, so
    // the runtime owns the host object's lifetime (see the video twin).
    auto sink = std::make_shared<CustomAudioSink>(weak_from_this(), trackId);
    return jsi::Object::createFromHostObject(rt, sink);
}

void FJAudioPush::install(std::function<void()> onInstalled) {
    // Reset for re-install on JS reload: the same FJAudioPush instance may be
    // reused across reloads, so the flag must be cleared.
    installed_.store(false);
    std::weak_ptr<FJAudioPush> weakSelf = shared_from_this();
    jsInvoker_->invokeAsync([weakSelf, onInstalled](jsi::Runtime &rt) {
        auto self = weakSelf.lock();
        if (!self) {
            return;
        }

        // Per-track sink accessor: returns a CustomAudioSink host object bound
        // to the given trackId. Shared by reference into worklets for hop-free
        // push.
        auto getSink = jsi::Function::createFromHostFunction(
            rt,
            jsi::PropNameID::forAscii(rt, "__fishjamWebrtcGetCustomAudioSink"),
            1,
            [weakSelf](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                auto self = weakSelf.lock();
                if (!self || count == 0 || !args[0].isString()) {
                    return jsi::Value::undefined();
                }
                return self->getSink(rt, args[0].asString(rt).utf8(rt));
            });
        rt.global().setProperty(rt, "__fishjamWebrtcGetCustomAudioSink", getSink);

        self->installed_.store(true);
        if (onInstalled) {
            onInstalled();
        }
    });
}
