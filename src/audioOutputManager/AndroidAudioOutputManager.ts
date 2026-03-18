import { NativeModules } from 'react-native';

import { addListener, removeListener } from '../EventEmitter';

import { ensurePlatform } from './common';

export enum AudioOutputDeviceType {
    builtInEarpiece = 'builtInEarpiece',
    builtInSpeaker = 'builtInSpeaker',
    wiredHeadset = 'wiredHeadset',
    wiredHeadphones = 'wiredHeadphones',
    bluetoothSCO = 'bluetoothSCO',
    bluetoothA2DP = 'bluetoothA2DP',
    HDMI = 'HDMI',
    usbDevice = 'usbDevice',
    usbHeadset = 'usbHeadset',
    usbAccessory = 'usbAccessory',
    hearingAid = 'hearingAid',
    bleHeadset = 'bleHeadset',
    bleSpeaker = 'bleSpeaker',
    bleBroadcast = 'bleBroadcast',
    unknown = 'unknown',
}

export type AndroidAudioDevice = {
    type: AudioOutputDeviceType;
    name: string;
    id: number;
};

export type AndroidAudioOutputChangedInfo = {
    currentAudioOutput: AndroidAudioDevice | null;
    availableAudioOutputs: AndroidAudioDevice[];
};

const { WebRTCModule } = NativeModules;

export const androidAudioOutputManager = {
    selectAudioOutput(deviceId: number): Promise<void> {
        ensurePlatform('android', 'selectAudioOutput');
        return WebRTCModule.selectAudioOutput(String(deviceId));
    },

    getAvailableAudioOutputs(): Promise<AndroidAudioDevice[]> {
        ensurePlatform('android', 'getAvailableAudioOutputs');
        return WebRTCModule.getAvailableAudioOutputs();
    },

    getCurrentAudioOutput(): Promise<AndroidAudioDevice | null> {
        ensurePlatform('android', 'getCurrentAudioOutput');
        return WebRTCModule.getCurrentAudioOutput();
    },

    onAudioOutputChanged(
        handler: (info: AndroidAudioOutputChangedInfo) => void,
    ): () => void {
        ensurePlatform('android', 'onAudioOutputChanged');
        const listener = {};
        addListener(
            listener,
            'audioOutputChanged',
            handler as (event: unknown) => void,
        );
        return () => removeListener(listener);
    },
};
