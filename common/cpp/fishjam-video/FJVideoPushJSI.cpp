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

                std::string trackId = frame.getProperty(rt, "trackId").asString(rt).utf8(rt);
                int bufferIndex = (int)frame.getProperty(rt, "bufferIndex").asNumber();
                uint64_t timestampNs = (uint64_t)frame.getProperty(rt, "timestampNs").asNumber();

                // rotation is optional; default to 0 when absent or not a number.
                int rotation = 0;
                jsi::Value rotationValue = frame.getProperty(rt, "rotation");
                if (rotationValue.isNumber()) {
                    rotation = (int)rotationValue.asNumber();
                }

                // fence is optional; absent/null means no fence -> immediate
                // delivery, signalled by passing 0/0 to the delivery callback.
                uint64_t fenceHandle = 0;
                uint64_t fenceSignaledValue = 0;
                jsi::Value fenceValue = frame.getProperty(rt, "fence");
                if (fenceValue.isObject()) {
                    jsi::Object fenceObject = fenceValue.getObject(rt);
                    fenceHandle = fenceObject.getProperty(rt, "handle").asBigInt(rt).getUint64(rt);
                    fenceSignaledValue =
                        fenceObject.getProperty(rt, "signaledValue").asBigInt(rt).getUint64(rt);
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
