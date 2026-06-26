#include "FJVideoPushJSI.h"

namespace jsi = facebook::jsi;

void FJVideoPush::install(std::function<void()> onInstalled) {
    // Reset for re-install on JS reload: the same FJVideoPush instance may be
    // reused across reloads (iOS associated object), so the flag must be cleared.
    installed_.store(false);
    std::weak_ptr<FJVideoPush> weakSelf = shared_from_this();
    jsInvoker_->invokeAsync([weakSelf, onInstalled](jsi::Runtime &rt) {
        auto self = weakSelf.lock();
        if (!self) {
            return;
        }
        auto pusher = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__fishjamWebrtcPushCustomVideoFrame"), 1,
            [weakSelf](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                auto self = weakSelf.lock();
                if (!self) {
                    return jsi::Value::undefined();
                }
                if (count == 0 || !args[0].isObject()) {
                    return jsi::Value::undefined();
                }
                jsi::Object frame = args[0].getObject(rt);

                // Per-frame hot path: validate every field and silently drop a
                // malformed frame rather than throwing a jsi::JSError back into JS.
                jsi::Value trackIdValue = frame.getProperty(rt, "trackId");
                jsi::Value bufferIndexValue = frame.getProperty(rt, "bufferIndex");
                jsi::Value timestampValue = frame.getProperty(rt, "timestampNs");
                if (!trackIdValue.isString() || !bufferIndexValue.isNumber() ||
                    !timestampValue.isNumber()) {
                    return jsi::Value::undefined();
                }

                std::string trackId = trackIdValue.asString(rt).utf8(rt);
                int bufferIndex = static_cast<int>(bufferIndexValue.asNumber());
                uint64_t timestampNs = static_cast<uint64_t>(timestampValue.asNumber());

                // rotation is optional; accept only the four valid quarter turns,
                // defaulting to 0 for absent / non-numeric / out-of-domain values.
                int rotation = 0;
                jsi::Value rotationValue = frame.getProperty(rt, "rotation");
                if (rotationValue.isNumber()) {
                    int requested = static_cast<int>(rotationValue.asNumber());
                    if (requested == 90 || requested == 180 || requested == 270) {
                        rotation = requested;
                    }
                }

                // fence is optional; absent/null/malformed means no fence -> 0/0
                // (immediate delivery). Only read handle/value when both are bigints.
                uint64_t fenceHandle = 0;
                uint64_t fenceSignaledValue = 0;
                jsi::Value fenceValue = frame.getProperty(rt, "fence");
                if (fenceValue.isObject()) {
                    jsi::Object fenceObject = fenceValue.getObject(rt);
                    jsi::Value handleValue = fenceObject.getProperty(rt, "handle");
                    jsi::Value signaledValue = fenceObject.getProperty(rt, "signaledValue");
                    if (handleValue.isBigInt() && signaledValue.isBigInt()) {
                        fenceHandle = handleValue.asBigInt(rt).getUint64(rt);
                        fenceSignaledValue = signaledValue.asBigInt(rt).getUint64(rt);
                    }
                }

                if (self->deliver_) {
                    self->deliver_(trackId, bufferIndex, timestampNs, rotation, fenceHandle,
                                   fenceSignaledValue);
                }
                return jsi::Value::undefined();
            });
        rt.global().setProperty(rt, "__fishjamWebrtcPushCustomVideoFrame", pusher);
        self->installed_.store(true);
        if (onInstalled) {
            onInstalled();
        }
    });
}

void FJVideoPush::setDeliver(DeliverFn deliver) {
    deliver_ = std::move(deliver);
}
