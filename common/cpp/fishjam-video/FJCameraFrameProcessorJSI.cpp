#include "FJCameraFrameProcessorJSI.h"

#include <utility>

namespace jsi = facebook::jsi;
using fishjam::video::FJCameraFrameConsumer;
using fishjam::video::FJCameraFrameConsumerHostObject;
using fishjam::video::kFJCameraFrameConsumerTag;

namespace {

const char *messageForCode(const std::string &code) {
    if (code == "E_NOT_A_CAMERA_TRACK") {
        return "The track is not a local camera track.";
    }
    if (code == "E_VIDEO_EFFECTS_ACTIVE") {
        return "Native video effects are active on this track; clear them before attaching a frame processor.";
    }
    if (code == "E_ATTACH_FAILED") {
        return "Attaching the camera frame processor failed natively.";
    }
    if (code == "E_MODULE_GONE") {
        return "The WebRTC module is gone.";
    }
    return "Attaching the camera frame processor failed.";
}

// Throws a JS Error carrying `code`, so JS can branch on it the way it does on
// native module rejections.
[[noreturn]] void throwCodedError(jsi::Runtime &rt, const std::string &code, const std::string &message) {
    jsi::Function errorConstructor = rt.global().getPropertyAsFunction(rt, "Error");
    jsi::Object error = errorConstructor.callAsConstructor(rt, jsi::String::createFromUtf8(rt, message)).getObject(rt);
    error.setProperty(rt, "code", jsi::String::createFromUtf8(rt, code));
    throw jsi::JSError(rt, jsi::Value(rt, error));
}

std::shared_ptr<FJCameraFrameConsumer> consumerFromArgument(jsi::Runtime &rt, const jsi::Value &argument) {
    if (!argument.isObject()) {
        return nullptr;
    }
    jsi::Object object = argument.getObject(rt);
    if (!object.isHostObject(rt)) {
        return nullptr;
    }
    jsi::Value tag = object.getProperty(rt, kFJCameraFrameConsumerTag);
    if (!tag.isBool() || !tag.getBool()) {
        return nullptr;
    }
    // The tag guarantees the host object's concrete type; see FJCameraFrame.h.
    auto host = std::static_pointer_cast<FJCameraFrameConsumerHostObject>(object.getHostObject(rt));
    return host ? host->consumer() : nullptr;
}

jsi::Object statisticsToObject(jsi::Runtime &rt, const FJCameraFrameProcessorCore::Statistics &statistics) {
    jsi::Object object(rt);
    object.setProperty(rt, "offered", static_cast<double>(statistics.offered));
    object.setProperty(rt, "accepted", static_cast<double>(statistics.accepted));
    object.setProperty(rt, "droppedBusy", static_cast<double>(statistics.droppedBusy));
    object.setProperty(rt, "droppedDetached", static_cast<double>(statistics.droppedDetached));
    object.setProperty(rt, "completed", static_cast<double>(statistics.completed));
    object.setProperty(rt, "droppedUndeliverable", static_cast<double>(statistics.droppedUndeliverable));
    return object;
}

}  // namespace

jsi::Value CameraFrameProcessorHandle::get(jsi::Runtime &rt, const jsi::PropNameID &name) {
    std::string property = name.utf8(rt);
    if (property == "trackId") {
        return jsi::String::createFromUtf8(rt, trackId_);
    }

    // Captured by value so each function stays self-contained on whichever
    // runtime picked it up.
    std::weak_ptr<FJCameraFrameProcessorChannel> owner = owner_;
    std::string trackId = trackId_;

    if (property == "attach") {
        return jsi::Function::createFromHostFunction(
            rt, name, 1,
            [owner, trackId](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                auto channel = owner.lock();
                if (!channel) {
                    throwCodedError(rt, "E_CHANNEL_GONE", "The camera frame processor channel is no longer available.");
                }
                std::shared_ptr<FJCameraFrameConsumer> consumer = count > 0 ? consumerFromArgument(rt, args[0]) : nullptr;
                if (!consumer) {
                    throwCodedError(rt, "E_INVALID_CONSUMER",
                                    "attach() expects a camera frame consumer created by "
                                    "@fishjam-cloud/react-native-webrtc-worklets.");
                }
                auto handlers = channel->handlers();
                if (!handlers->attach) {
                    throwCodedError(rt, "E_UNSUPPORTED_PLATFORM",
                                    "Camera frame processing is not available on this platform.");
                }
                std::string code = handlers->attach(trackId, std::move(consumer));
                if (!code.empty()) {
                    throwCodedError(rt, code, messageForCode(code));
                }
                return jsi::Value::undefined();
            });
    }
    if (property == "detach") {
        return jsi::Function::createFromHostFunction(
            rt, name, 0, [owner, trackId](jsi::Runtime &, const jsi::Value &, const jsi::Value *, size_t) -> jsi::Value {
                auto channel = owner.lock();
                if (channel) {
                    auto handlers = channel->handlers();
                    if (handlers->detach) {
                        handlers->detach(trackId);
                    }
                }
                return jsi::Value::undefined();
            });
    }
    if (property == "statistics") {
        return jsi::Function::createFromHostFunction(
            rt, name, 0, [owner, trackId](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *, size_t) -> jsi::Value {
                auto channel = owner.lock();
                FJCameraFrameProcessorCore::Statistics statistics;
                if (channel) {
                    auto handlers = channel->handlers();
                    if (handlers->statistics) {
                        handlers->statistics(trackId, statistics);
                    }
                }
                return statisticsToObject(rt, statistics);
            });
    }
    return jsi::Value::undefined();
}

std::vector<jsi::PropNameID> CameraFrameProcessorHandle::getPropertyNames(jsi::Runtime &rt) {
    return jsi::PropNameID::names(rt, "trackId", "attach", "detach", "statistics");
}

void FJCameraFrameProcessorChannel::install(std::function<void()> onInstalled) {
    std::weak_ptr<FJCameraFrameProcessorChannel> weakSelf = weak_from_this();
    jsInvoker_->invokeAsync([weakSelf, onInstalled = std::move(onInstalled)](jsi::Runtime &rt) {
        auto self = weakSelf.lock();
        if (!self) {
            return;
        }
        // Always (re)define the global: a JS reload replaces the runtime while
        // this channel survives on Android, so the new runtime needs it again.
        jsi::PropNameID globalName = jsi::PropNameID::forAscii(rt, "__fishjamWebrtcGetCameraFrameProcessor");
        rt.global().setProperty(
            rt, globalName,
            jsi::Function::createFromHostFunction(
                rt, globalName, 1,
                [weakSelf](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                    auto self = weakSelf.lock();
                    if (!self || count == 0 || !args[0].isString()) {
                        return jsi::Value::undefined();
                    }
                    return self->getProcessor(rt, args[0].getString(rt).utf8(rt));
                }));
        self->installed_.store(true);
        if (onInstalled) {
            onInstalled();
        }
    });
}

void FJCameraFrameProcessorChannel::setHandlers(Handlers handlers) {
    auto replacement = std::make_shared<const Handlers>(std::move(handlers));
    std::lock_guard<std::mutex> lock(handlersMutex_);
    handlers_ = std::move(replacement);
}

std::shared_ptr<const FJCameraFrameProcessorChannel::Handlers> FJCameraFrameProcessorChannel::handlers() const {
    std::lock_guard<std::mutex> lock(handlersMutex_);
    return handlers_;
}

jsi::Value FJCameraFrameProcessorChannel::getProcessor(jsi::Runtime &rt, const std::string &trackId) {
    auto handle = std::make_shared<CameraFrameProcessorHandle>(weak_from_this(), trackId);
    return jsi::Object::createFromHostObject(rt, handle);
}
