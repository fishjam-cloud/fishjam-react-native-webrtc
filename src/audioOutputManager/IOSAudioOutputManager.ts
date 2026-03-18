import { NativeModules } from 'react-native';

import { addListener, removeListener } from '../EventEmitter';

import { ensurePlatform } from './common';

export enum AVAudioSessionPort {
    builtInMic = 'builtInMic',
    headsetMic = 'headsetMic',
    lineIn = 'lineIn',
    lineOut = 'lineOut',
    headphones = 'headphones',
    bluetoothA2DP = 'bluetoothA2DP',
    builtInReceiver = 'builtInReceiver',
    builtInSpeaker = 'builtInSpeaker',
    HDMI = 'HDMI',
    airPlay = 'airPlay',
    bluetoothLE = 'bluetoothLE',
    bluetoothHFP = 'bluetoothHFP',
    usbAudio = 'usbAudio',
    carAudio = 'carAudio',
}

export type AudioPort = { type: AVAudioSessionPort; name: string };

export type AudioOutputRoute = { inputs: AudioPort[]; outputs: AudioPort[] };

export enum RouteChangeReason {
    unknown = 0,
    newDeviceAvailable = 1,
    oldDeviceUnavailable = 2,
    categoryChange = 3,
    override = 4,
    wakeFromSleep = 5,
    noSuitableRouteForCategory = 6,
    routeConfigurationChange = 7,
}

export type IOSAudioOutputChangedInfo = {
    reason: RouteChangeReason;
    currentRoute: AudioOutputRoute;
    previousRoute: AudioOutputRoute;
};

const { WebRTCModule } = NativeModules;

export const iosAudioOutputManager = {
    overrideAudioOutput(output: 'speaker' | 'none'): Promise<void> {
        ensurePlatform('ios', 'overrideAudioOutput');
        return WebRTCModule.overrideAudioOutput(output);
    },

    showAudioRoutePicker(): void {
        ensurePlatform('ios', 'showAudioRoutePicker');
        WebRTCModule.showAudioRoutePicker();
    },

    getCurrentAudioOutput(): Promise<AudioOutputRoute> {
        ensurePlatform('ios', 'getCurrentAudioOutput');
        return WebRTCModule.getCurrentAudioOutput();
    },

    onAudioOutputChanged(
        handler: (info: IOSAudioOutputChangedInfo) => void,
    ): () => void {
        ensurePlatform('ios', 'onAudioOutputChanged');
        const listener = {};
        addListener(
            listener,
            'audioOutputChanged',
            handler as (event: unknown) => void,
        );
        return () => removeListener(listener);
    },
};
