import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export function getVoipToken(): string | null {
    if (Platform.OS !== 'ios') {
        return null;
    }
    const token = WebRTCModule.getVoipToken();
    return typeof token === 'string' ? token : null;
}

export function getPendingIncomingCall(): Record<string, unknown> | null {
    if (Platform.OS !== 'ios') {
        return null;
    }
    const call = WebRTCModule.getPendingIncomingCall();
    return call && typeof call === 'object'
        ? (call as Record<string, unknown>)
        : null;
}

export function clearPendingIncomingCall(): void {
    if (Platform.OS !== 'ios') {
        return;
    }
    WebRTCModule.clearPendingIncomingCall();
}
