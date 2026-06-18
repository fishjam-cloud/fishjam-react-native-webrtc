#import "FJAudioSinkJSI.h"

namespace jsi = facebook::jsi;

void FJAudioSink::install(std::function<void()> onInstalled) {
    installed_.store(false);
    std::weak_ptr<FJAudioSink> weak = shared_from_this();
    jsInvoker_->invokeAsync([weak, onInstalled](jsi::Runtime &rt) {
        auto self = weak.lock();
        if (!self) {
            return;
        }
        auto fn = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__fishjamWebrtcSetAudioSink"), 1,
            [weak](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                auto self = weak.lock();
                if (self && count > 0 && args[0].isObject() && args[0].getObject(rt).isFunction(rt)) {
                    self->callback_ =
                        std::make_shared<jsi::Function>(args[0].getObject(rt).asFunction(rt));
                } else if (self) {
                    self->callback_.reset();
                }
                return jsi::Value::undefined();
            });
        rt.global().setProperty(rt, "__fishjamWebrtcSetAudioSink", fn);
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
    std::string tid = trackId.UTF8String;
    std::string fmt = format;
    std::weak_ptr<FJAudioSink> weak = shared_from_this();
    jsInvoker_->invokeAsync([weak, pcId, tid, fmt, sampleRate, channels,
                             bytes = std::move(bytes)](jsi::Runtime &rt) mutable {
        auto self = weak.lock();
        if (!self || !self->callback_) {
            return;
        }
        jsi::Object o(rt);
        o.setProperty(rt, "pcId", pcId);
        o.setProperty(rt, "trackId", jsi::String::createFromUtf8(rt, tid));
        o.setProperty(rt, "sampleRate", sampleRate);
        o.setProperty(rt, "channels", channels);
        o.setProperty(rt, "format", jsi::String::createFromUtf8(rt, fmt));  // "f32" | "s16"
        o.setProperty(rt, "data",
                      jsi::ArrayBuffer(rt, std::make_shared<PcmBuffer>(std::move(bytes))));
        try {
            self->callback_->call(rt, o);
        } catch (const jsi::JSError &) {
            // drop batch
        }
    });
}
