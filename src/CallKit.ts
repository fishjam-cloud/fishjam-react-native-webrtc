import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export type CallKitConfig = {
    displayName: string;
    isVideo: boolean;
};

export type CallKitAction = {
    started?: undefined;
    ended?: undefined;
    failed?: string;
    muted?: boolean;
    held?: boolean;
};

export async function startCallKitSession(config: CallKitConfig): Promise<void> {
    if (Platform.OS !== 'ios') {
        return;
    }
    await WebRTCModule.startCallKitSession(config.displayName, config.isVideo);
}

export async function endCallKitSession(): Promise<void> {
    if (Platform.OS !== 'ios') {
        return;
    }
    await WebRTCModule.endCallKitSession();
}

export function hasActiveCallKitSession(): boolean {
    if (Platform.OS !== 'ios') {
        return false;
    }
    return WebRTCModule.hasActiveCallKitSession;
}
