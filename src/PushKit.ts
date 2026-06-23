import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export function getVoipToken(): string | null {
    if (Platform.OS !== 'ios') {
        return null;
    }
    const token = WebRTCModule.getVoipToken()
    return typeof token === 'string' ? token : null;
}