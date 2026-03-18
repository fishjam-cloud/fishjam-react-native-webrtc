import { NativeModules } from 'react-native';

import { addListener, removeListener } from '../EventEmitter';

import { ensurePlatform } from './common';

export enum AudioOutputDeviceType {
    EARPIECE = 'EARPIECE',
    SPEAKERPHONE = 'SPEAKERPHONE',
    WIRED_HEADSET = 'WIRED_HEADSET',
    BLUETOOTH = 'BLUETOOTH',
}

export type AndroidAudioOutputChangedInfo = {
    currentAudioOutput: AudioOutputDeviceType | null;
    availableAudioOutputs: AudioOutputDeviceType[];
};

const { WebRTCModule } = NativeModules;

export const androidAudioOutputManager = {
    selectAudioOutput(device: AudioOutputDeviceType): Promise<void> {
        ensurePlatform('android', 'selectAudioOutput');
        return WebRTCModule.selectAudioOutput(device);
    },

    getAvailableAudioOutputs(): Promise<AudioOutputDeviceType[]> {
        ensurePlatform('android', 'getAvailableAudioOutputs');
        return WebRTCModule.getAvailableAudioOutputs();
    },

    getCurrentAudioOutput(): Promise<AudioOutputDeviceType | null> {
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
