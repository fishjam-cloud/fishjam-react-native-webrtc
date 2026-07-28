"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.AudioOutputManager = exports.AudioDeviceType = void 0;
const react_native_1 = require("react-native");
const EventEmitter_1 = require("../EventEmitter");
/** Normalized audio device categories across iOS and Android. */
var AudioDeviceType;
(function (AudioDeviceType) {
    AudioDeviceType["earpiece"] = "earpiece";
    AudioDeviceType["speaker"] = "speaker";
    AudioDeviceType["bluetooth"] = "bluetooth";
    AudioDeviceType["wiredHeadset"] = "wiredHeadset";
    AudioDeviceType["usb"] = "usb";
    AudioDeviceType["hdmi"] = "hdmi";
    AudioDeviceType["airplay"] = "airplay";
    AudioDeviceType["carAudio"] = "carAudio";
    AudioDeviceType["hearingAid"] = "hearingAid";
    AudioDeviceType["lineOut"] = "lineOut";
    AudioDeviceType["unknown"] = "unknown";
})(AudioDeviceType || (exports.AudioDeviceType = AudioDeviceType = {}));
const { WebRTCModule } = react_native_1.NativeModules;
function ensurePlatform(expected, methodName) {
    if (react_native_1.Platform.OS !== expected) {
        throw new Error(`AudioOutputManager.${expected}.${methodName} is not available on ${react_native_1.Platform.OS}`);
    }
}
/** Imperative API for querying and controlling audio output routing. */
exports.AudioOutputManager = {
    /** Returns all audio output devices currently reachable by the system. */
    getAvailableAudioOutputs() {
        return WebRTCModule.getAvailableAudioOutputs();
    },
    /** Returns the device audio is currently routed to, or `null` if unknown. */
    getCurrentAudioOutput() {
        return WebRTCModule.getCurrentAudioOutput();
    },
    /** Subscribes to audio output changes. Returns an unsubscribe function. */
    onAudioOutputChanged(handler) {
        const listener = {};
        (0, EventEmitter_1.addListener)(listener, 'audioOutputChanged', handler);
        return () => (0, EventEmitter_1.removeListener)(listener);
    },
    ios: {
        /** Presents the native iOS audio route picker (AVRoutePickerView). */
        showAudioRoutePicker() {
            ensurePlatform('ios', 'showAudioRoutePicker');
            WebRTCModule.showAudioRoutePicker();
        },
        /**
         * Forces audio output to the built-in speaker or resets to the default route.
         *
         * @param output `'speaker'` to route to the built-in speaker, `'none'` to restore the default route.
         */
        overrideAudioOutput(output) {
            ensurePlatform('ios', 'overrideAudioOutput');
            return WebRTCModule.overrideAudioOutput(output);
        },
    },
    android: {
        /**
         * Routes audio to a specific device.
         *
         * The returned promise resolves only once the device is confirmed active.
         * It rejects with one of the following error codes:
         *
         * - `E_AUDIO_OUTPUT_SELECT` — invalid device ID, device unavailable, or the
         *   underlying `AudioManager` call failed.
         * - `E_AUDIO_OUTPUT_SUPERSEDED` — a newer `selectAudioOutput` call was made
         *   before this one completed. Callers may safely ignore this code.
         * - `E_AUDIO_OUTPUT_TIMEOUT` — the system did not confirm the route change
         *   within the platform timeout.
         * - `E_AUDIO_OUTPUT_CANCELLED` — the audio output observer was stopped
         *   (e.g. module teardown) before the route change completed.
         *
         * @param deviceId The {@link AudioDevice.id} of the target device.
         */
        selectAudioOutput(deviceId) {
            ensurePlatform('android', 'selectAudioOutput');
            return WebRTCModule.selectAudioOutput(deviceId);
        },
    },
};
