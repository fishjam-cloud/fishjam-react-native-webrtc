import { Platform } from 'react-native';

export function ensurePlatform(expected: string, methodName: string): void {
    if (Platform.OS !== expected) {
        throw new Error(
            `audioOutputManager.${expected}.${methodName} is not available on ${Platform.OS}`,
        );
    }
}
