#import "FJAudioSinkJSI.h"

namespace jsi = facebook::jsi;

void FJAudioSink::install(std::function<void()> onInstalled) {
    installed_.store(false);
    std::weak_ptr<FJAudioSink> weakSelf = shared_from_this();
    jsInvoker_->invokeAsync([weakSelf, onInstalled](jsi::Runtime &rt) {
        auto self = weakSelf.lock();
        if (!self) {
            return;
        }
        auto setter = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__fishjamWebrtcSetAudioSink"), 1,
            [weakSelf](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                auto self = weakSelf.lock();
                if (!self) {
                    return jsi::Value::undefined();
                }
                if (count > 0 && args[0].isObject() && args[0].getObject(rt).isFunction(rt)) {
                    self->callback_ = std::make_shared<jsi::Function>(args[0].getObject(rt).asFunction(rt));
                } else {
                    self->callback_.reset();
                }
                return jsi::Value::undefined();
            });
        rt.global().setProperty(rt, "__fishjamWebrtcSetAudioSink", setter);
        self->installed_.store(true);
        if (onInstalled) {
            onInstalled();
        }
    });
}

void FJAudioSink::deliver(int pcId,
                          NSString *trackId,
                          int sampleRate,
                          int channels,
                          const char *format,
                          std::vector<uint8_t> bytes) {
    std::string trackIdUtf8 = trackId.UTF8String;
    std::string formatUtf8 = format;
    std::weak_ptr<FJAudioSink> weakSelf = shared_from_this();
    jsInvoker_->invokeAsync([weakSelf, pcId, trackIdUtf8, formatUtf8, sampleRate, channels,
                             bytes = std::move(bytes)](jsi::Runtime &rt) mutable {
        auto self = weakSelf.lock();
        if (!self || !self->callback_) {
            return;
        }
        jsi::Object batch(rt);
        batch.setProperty(rt, "pcId", pcId);
        batch.setProperty(rt, "trackId", jsi::String::createFromUtf8(rt, trackIdUtf8));
        batch.setProperty(rt, "sampleRate", sampleRate);
        batch.setProperty(rt, "channels", channels);
        batch.setProperty(rt, "format", jsi::String::createFromUtf8(rt, formatUtf8));
        batch.setProperty(rt, "data", jsi::ArrayBuffer(rt, std::make_shared<PcmBuffer>(std::move(bytes))));
        try {
            self->callback_->call(rt, batch);
        } catch (const jsi::JSError &) {
            // Drop this batch if the JS handler throws.
        }
    });
}
