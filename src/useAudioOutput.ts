import { useEffect, useRef, useState } from 'react';
import { NativeModules } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import {
    AudioOutputManager,
    type AudioDevice,
    type AudioOutputChangedInfo,
} from './audioOutputManager';

const { WebRTCModule } = NativeModules;

export type UseAudioOutputResult = {
    /** Active output device, or `null` if not yet known. */
    currentAudioOutput: AudioDevice | null;
    /** All output devices currently reachable. */
    availableAudioOutputs: AudioDevice[];
    /** iOS-only controls. Throws on other platforms. */
    ios: typeof AudioOutputManager.ios;
    /** Android-only controls. Throws on other platforms. */
    android: typeof AudioOutputManager.android;
};

/**
 * Audio output state for the current session.
 *
 * Use `.ios` / `.android` for platform-specific actions.
 */
export function useAudioOutput(): UseAudioOutputResult {
    const [currentAudioOutput, setCurrentAudioOutput] =
        useState<AudioDevice | null>(null);
    const [availableAudioOutputs, setAvailableAudioOutputs] = useState<
        AudioDevice[]
    >([]);
    const listener = useRef({});

    useEffect(() => {
        WebRTCModule.getCurrentAudioOutput().then(
            (device: AudioDevice | null) => setCurrentAudioOutput(device),
        );
        WebRTCModule.getAvailableAudioOutputs().then((devices: AudioDevice[]) =>
            setAvailableAudioOutputs(devices),
        );

        addListener(
            listener.current,
            'audioOutputChanged',
            (event: unknown) => {
                const info = event as AudioOutputChangedInfo;
                setCurrentAudioOutput(info.currentAudioOutput);
                setAvailableAudioOutputs(info.availableAudioOutputs);
            },
        );

        return () => removeListener(listener.current);
    }, []);

    return {
        currentAudioOutput,
        availableAudioOutputs,
        ios: AudioOutputManager.ios,
        android: AudioOutputManager.android,
    };
}
