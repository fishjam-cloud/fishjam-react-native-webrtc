package com.oney.WebRTCModule;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothHeadset;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
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

import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class AudioOutputManager {
    private final ReactApplicationContext reactContext;
    private final AudioManager audioManager;
    private final WebRTCModule webRTCModule;
    private AudioDeviceCallback audioDeviceCallback;
    private BroadcastReceiver headsetReceiver;
    private boolean isObserving = false;

    public AudioOutputManager(WebRTCModule module, ReactApplicationContext context) {
        this.webRTCModule = module;
        this.reactContext = context;
        this.audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    private static String audioDeviceInfoTypeToString(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE: return "EARPIECE";
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:  return "SPEAKERPHONE";
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES: return "WIRED_HEADSET";
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:   return "BLUETOOTH";
            default: return null;
        }
    }

    public void getAvailableAudioOutputs(Promise promise) {
        WritableArray result = Arguments.createArray();
        Set<String> seen = new HashSet<>();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            List<AudioDeviceInfo> devices = audioManager.getAvailableCommunicationDevices();
            for (AudioDeviceInfo device : devices) {
                String type = audioDeviceInfoTypeToString(device.getType());
                if (type != null && seen.add(type)) {
                    result.pushString(type);
                }
            }
        } else {
            result.pushString("EARPIECE");
            result.pushString("SPEAKERPHONE");

            if (audioManager.isWiredHeadsetOn()) {
                result.pushString("WIRED_HEADSET");
            }

            BluetoothAdapter btAdapter = BluetoothAdapter.getDefaultAdapter();
            if (btAdapter != null && btAdapter.isEnabled()
                    && btAdapter.getProfileConnectionState(BluetoothProfile.HEADSET)
                        == BluetoothProfile.STATE_CONNECTED) {
                result.pushString("BLUETOOTH");
            }
        }

        promise.resolve(result);
    }

    public void getCurrentAudioOutput(Promise promise) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AudioDeviceInfo device = audioManager.getCommunicationDevice();
            if (device != null) {
                String type = audioDeviceInfoTypeToString(device.getType());
                promise.resolve(type);
            } else {
                promise.resolve(null);
            }
        } else {
            if (audioManager.isBluetoothScoOn()) {
                promise.resolve("BLUETOOTH");
            } else if (audioManager.isSpeakerphoneOn()) {
                promise.resolve("SPEAKERPHONE");
            } else if (audioManager.isWiredHeadsetOn()) {
                promise.resolve("WIRED_HEADSET");
            } else {
                promise.resolve("EARPIECE");
            }
        }
    }

    public void selectAudioOutput(String deviceType, Promise promise) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                selectAudioOutputApi31(deviceType);
            } else {
                selectAudioOutputLegacy(deviceType);
            }
            promise.resolve(null);
        } catch (Exception e) {
            promise.reject("E_AUDIO_OUTPUT_SELECT", e.getMessage(), e);
        }
    }

    private void selectAudioOutputApi31(String deviceType) {
        if ("EARPIECE".equals(deviceType)) {
            audioManager.clearCommunicationDevice();
            return;
        }

        List<AudioDeviceInfo> devices = audioManager.getAvailableCommunicationDevices();
        for (AudioDeviceInfo device : devices) {
            String type = audioDeviceInfoTypeToString(device.getType());
            if (deviceType.equals(type)) {
                boolean success = audioManager.setCommunicationDevice(device);
                if (!success) {
                    throw new RuntimeException("setCommunicationDevice failed for " + deviceType);
                }
                return;
            }
        }
        throw new RuntimeException("Audio output not available: " + deviceType);
    }

    private void selectAudioOutputLegacy(String deviceType) {
        audioManager.setSpeakerphoneOn(false);
        audioManager.setBluetoothScoOn(false);
        try { audioManager.stopBluetoothSco(); } catch (Exception ignored) {}

        switch (deviceType) {
            case "SPEAKERPHONE":
                audioManager.setSpeakerphoneOn(true);
                break;
            case "BLUETOOTH":
                audioManager.startBluetoothSco();
                audioManager.setBluetoothScoOn(true);
                break;
            case "EARPIECE":
            case "WIRED_HEADSET":
                break;
            default:
                throw new RuntimeException("Unknown audio output type: " + deviceType);
        }
    }

    public void startObserving() {
        if (isObserving) return;
        isObserving = true;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
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
        } else {
            headsetReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    emitOutputChangedEvent();
                }
            };
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_HEADSET_PLUG);
            filter.addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED);
            reactContext.registerReceiver(headsetReceiver, filter);
        }
    }

    public void stopObserving() {
        if (!isObserving) return;
        isObserving = false;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && audioDeviceCallback != null) {
            audioManager.unregisterAudioDeviceCallback(audioDeviceCallback);
            audioDeviceCallback = null;
        }
        if (headsetReceiver != null) {
            reactContext.unregisterReceiver(headsetReceiver);
            headsetReceiver = null;
        }
    }

    private void emitOutputChangedEvent() {
        WritableMap params = Arguments.createMap();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AudioDeviceInfo device = audioManager.getCommunicationDevice();
            params.putString("currentAudioOutput",
                device != null ? audioDeviceInfoTypeToString(device.getType()) : null);
        } else {
            if (audioManager.isBluetoothScoOn()) params.putString("currentAudioOutput", "BLUETOOTH");
            else if (audioManager.isSpeakerphoneOn()) params.putString("currentAudioOutput", "SPEAKERPHONE");
            else if (audioManager.isWiredHeadsetOn()) params.putString("currentAudioOutput", "WIRED_HEADSET");
            else params.putString("currentAudioOutput", "EARPIECE");
        }

        WritableArray available = Arguments.createArray();
        Set<String> seen = new HashSet<>();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            for (AudioDeviceInfo d : audioManager.getAvailableCommunicationDevices()) {
                String type = audioDeviceInfoTypeToString(d.getType());
                if (type != null && seen.add(type)) available.pushString(type);
            }
        } else {
            available.pushString("EARPIECE");
            available.pushString("SPEAKERPHONE");
            if (audioManager.isWiredHeadsetOn()) available.pushString("WIRED_HEADSET");
            BluetoothAdapter bt = BluetoothAdapter.getDefaultAdapter();
            if (bt != null && bt.isEnabled()
                    && bt.getProfileConnectionState(BluetoothProfile.HEADSET) == BluetoothProfile.STATE_CONNECTED) {
                available.pushString("BLUETOOTH");
            }
        }
        params.putArray("availableAudioOutputs", available);

        webRTCModule.sendEvent("audioOutputChanged", params);
    }
}
