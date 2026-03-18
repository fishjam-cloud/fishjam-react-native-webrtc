package com.oney.WebRTCModule;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;

import java.util.List;

public class AudioOutputManager {
    private final ReactApplicationContext reactContext;
    private final AudioManager audioManager;
    private final WebRTCModule webRTCModule;
    private AudioDeviceCallback audioDeviceCallback;
    private AudioManager.OnCommunicationDeviceChangedListener communicationDeviceChangedListener;
    private boolean isObserving = false;

    public AudioOutputManager(WebRTCModule module, ReactApplicationContext context) {
        this.webRTCModule = module;
        this.reactContext = context;
        this.audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    private static String audioDeviceInfoTypeToString(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return "builtInEarpiece";
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return "builtInSpeaker";
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
                return "wiredHeadset";
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
                return "wiredHeadphones";
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
                return "bluetoothSCO";
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
                return "bluetoothA2DP";
            case AudioDeviceInfo.TYPE_HDMI:
                return "HDMI";
            case AudioDeviceInfo.TYPE_USB_DEVICE:
                return "usbDevice";
            case AudioDeviceInfo.TYPE_USB_HEADSET:
                return "usbHeadset";
            case AudioDeviceInfo.TYPE_USB_ACCESSORY:
                return "usbAccessory";
            case AudioDeviceInfo.TYPE_HEARING_AID:
                return "hearingAid";
            default:
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (type == AudioDeviceInfo.TYPE_BLE_HEADSET) return "bleHeadset";
                    if (type == AudioDeviceInfo.TYPE_BLE_SPEAKER) return "bleSpeaker";
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    if (type == AudioDeviceInfo.TYPE_BLE_BROADCAST) return "bleBroadcast";
                }
                return "unknown";
        }
    }

    private static WritableMap serializeAudioDevice(AudioDeviceInfo device) {
        WritableMap map = Arguments.createMap();
        map.putString("type", audioDeviceInfoTypeToString(device.getType()));
        map.putString("name", device.getProductName().toString());
        map.putInt("id", device.getId());
        return map;
    }

    public void getAvailableAudioOutputs(Promise promise) {
        WritableArray result = Arguments.createArray();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            List<AudioDeviceInfo> devices = audioManager.getAvailableCommunicationDevices();
            for (AudioDeviceInfo device : devices) {
                result.pushMap(serializeAudioDevice(device));
            }
        } else {
            AudioDeviceInfo[] devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            for (AudioDeviceInfo device : devices) {
                int type = device.getType();
                if (type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                        || type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                        || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                        || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        || type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                        || type == AudioDeviceInfo.TYPE_HDMI
                        || type == AudioDeviceInfo.TYPE_USB_DEVICE
                        || type == AudioDeviceInfo.TYPE_USB_HEADSET
                        || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                        || type == AudioDeviceInfo.TYPE_HEARING_AID) {
                    result.pushMap(serializeAudioDevice(device));
                }
            }
        }

        promise.resolve(result);
    }

    public void getCurrentAudioOutput(Promise promise) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AudioDeviceInfo device = audioManager.getCommunicationDevice();
            if (device != null) {
                promise.resolve(serializeAudioDevice(device));
            } else {
                promise.resolve(null);
            }
        } else {
            AudioDeviceInfo matched = findCurrentOutputLegacy();
            if (matched != null) {
                promise.resolve(serializeAudioDevice(matched));
            } else {
                promise.resolve(null);
            }
        }
    }

    private AudioDeviceInfo findCurrentOutputLegacy() {
        AudioDeviceInfo[] devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);

        if (audioManager.isBluetoothScoOn()) {
            for (AudioDeviceInfo d : devices) {
                if (d.getType() == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) return d;
            }
        }
        if (audioManager.isSpeakerphoneOn()) {
            for (AudioDeviceInfo d : devices) {
                if (d.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) return d;
            }
        }
        if (audioManager.isWiredHeadsetOn()) {
            for (AudioDeviceInfo d : devices) {
                if (d.getType() == AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || d.getType() == AudioDeviceInfo.TYPE_WIRED_HEADPHONES) return d;
            }
        }
        for (AudioDeviceInfo d : devices) {
            if (d.getType() == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) return d;
        }
        return null;
    }

    public void selectAudioOutput(String deviceIdStr, Promise promise) {
        try {
            int deviceId = Integer.parseInt(deviceIdStr);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                selectAudioOutputApi31(deviceId);
            } else {
                selectAudioOutputLegacy(deviceId);
                emitOutputChangedEvent();
            }
            promise.resolve(null);
        } catch (NumberFormatException e) {
            promise.reject("E_AUDIO_OUTPUT_SELECT", "Invalid device ID: " + deviceIdStr, e);
        } catch (Exception e) {
            promise.reject("E_AUDIO_OUTPUT_SELECT", e.getMessage(), e);
        }
    }

    private void selectAudioOutputApi31(int deviceId) {
        List<AudioDeviceInfo> devices = audioManager.getAvailableCommunicationDevices();
        for (AudioDeviceInfo device : devices) {
            if (device.getId() == deviceId) {
                if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) {
                    audioManager.clearCommunicationDevice();
                    return;
                }
                boolean success = audioManager.setCommunicationDevice(device);
                if (!success) {
                    throw new RuntimeException("setCommunicationDevice failed for device ID " + deviceId);
                }
                return;
            }
        }
        throw new RuntimeException("Audio output not available for device ID: " + deviceId);
    }

    private void selectAudioOutputLegacy(int deviceId) {
        AudioDeviceInfo[] devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        AudioDeviceInfo target = null;
        for (AudioDeviceInfo d : devices) {
            if (d.getId() == deviceId) {
                target = d;
                break;
            }
        }
        if (target == null) {
            throw new RuntimeException("Audio output not available for device ID: " + deviceId);
        }

        audioManager.setSpeakerphoneOn(false);
        audioManager.setBluetoothScoOn(false);
        try {
            audioManager.stopBluetoothSco();
        } catch (Exception ignored) {
        }

        switch (target.getType()) {
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                audioManager.setSpeakerphoneOn(true);
                break;
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
                audioManager.startBluetoothSco();
                audioManager.setBluetoothScoOn(true);
                break;
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
                break;
            default:
                throw new RuntimeException(
                        "Cannot select audio output type on this API level: "
                                + audioDeviceInfoTypeToString(target.getType()));
        }
    }

    public void startObserving() {
        if (isObserving) return;
        isObserving = true;

        audioDeviceCallback = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
                emitOutputChangedEvent();
            }
            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
                emitOutputChangedEvent();
            }
        };
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, new Handler(Looper.getMainLooper()));

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            communicationDeviceChangedListener = device -> emitOutputChangedEvent();
            audioManager.addOnCommunicationDeviceChangedListener(
                    reactContext.getMainExecutor(), communicationDeviceChangedListener);
        }
    }

    public void stopObserving() {
        if (!isObserving) return;
        isObserving = false;

        if (audioDeviceCallback != null) {
            audioManager.unregisterAudioDeviceCallback(audioDeviceCallback);
            audioDeviceCallback = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && communicationDeviceChangedListener != null) {
            audioManager.removeOnCommunicationDeviceChangedListener(communicationDeviceChangedListener);
            communicationDeviceChangedListener = null;
        }
    }

    private void emitOutputChangedEvent() {
        WritableMap params = Arguments.createMap();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AudioDeviceInfo device = audioManager.getCommunicationDevice();
            if (device != null) {
                params.putMap("currentAudioOutput", serializeAudioDevice(device));
            } else {
                params.putNull("currentAudioOutput");
            }
        } else {
            AudioDeviceInfo current = findCurrentOutputLegacy();
            if (current != null) {
                params.putMap("currentAudioOutput", serializeAudioDevice(current));
            } else {
                params.putNull("currentAudioOutput");
            }
        }

        WritableArray available = Arguments.createArray();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            for (AudioDeviceInfo d : audioManager.getAvailableCommunicationDevices()) {
                available.pushMap(serializeAudioDevice(d));
            }
        } else {
            AudioDeviceInfo[] devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            for (AudioDeviceInfo d : devices) {
                int type = d.getType();
                if (type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                        || type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                        || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                        || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        || type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                        || type == AudioDeviceInfo.TYPE_HDMI
                        || type == AudioDeviceInfo.TYPE_USB_DEVICE
                        || type == AudioDeviceInfo.TYPE_USB_HEADSET
                        || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                        || type == AudioDeviceInfo.TYPE_HEARING_AID) {
                    available.pushMap(serializeAudioDevice(d));
                }
            }
        }
        params.putArray("availableAudioOutputs", available);

        webRTCModule.sendEvent("audioOutputChanged", params);
    }
}
