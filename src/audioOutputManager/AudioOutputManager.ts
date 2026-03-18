import { NativeModules, Platform } from 'react-native';

import { addListener, removeListener } from '../EventEmitter';

export enum AudioDeviceType {
    earpiece = 'earpiece',
    speaker = 'speaker',
    bluetooth = 'bluetooth',
    wiredHeadset = 'wiredHeadset',
    usb = 'usb',
    hdmi = 'hdmi',
    airplay = 'airplay',
    carAudio = 'carAudio',
    hearingAid = 'hearingAid',
    lineOut = 'lineOut',
    unknown = 'unknown',
}

export type AudioDevice = {
    type: AudioDeviceType;
    nativeType: string;
    name: string;
    id: string;
};

export type AudioOutputChangedInfo = {
    currentAudioOutput: AudioDevice | null;
    availableAudioOutputs: AudioDevice[];
};

const { WebRTCModule } = NativeModules;

function ensurePlatform(expected: string, methodName: string): void {
    if (Platform.OS !== expected) {
        throw new Error(
            `AudioOutputManager.${expected}.${methodName} is not available on ${Platform.OS}`,
        );
    }
}

export const AudioOutputManager = {
    getAvailableAudioOutputs(): Promise<AudioDevice[]> {
        return WebRTCModule.getAvailableAudioOutputs();
    },

    getCurrentAudioOutput(): Promise<AudioDevice | null> {
        return WebRTCModule.getCurrentAudioOutput();
    },

    onAudioOutputChanged(
        handler: (info: AudioOutputChangedInfo) => void,
    ): () => void {
        const listener = {};
        addListener(
            listener,
            'audioOutputChanged',
            handler as (event: unknown) => void,
        );
        return () => removeListener(listener);
    },

    ios: {
        showAudioRoutePicker(): void {
            ensurePlatform('ios', 'showAudioRoutePicker');
            WebRTCModule.showAudioRoutePicker();
        },

        overrideAudioOutput(output: 'speaker' | 'none'): Promise<void> {
            ensurePlatform('ios', 'overrideAudioOutput');
            return WebRTCModule.overrideAudioOutput(output);
        },
    },

    android: {
        selectAudioOutput(deviceId: string): Promise<void> {
            ensurePlatform('android', 'selectAudioOutput');
            return WebRTCModule.selectAudioOutput(deviceId);
        },
    },
};
