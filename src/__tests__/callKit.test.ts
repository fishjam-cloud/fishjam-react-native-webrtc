import { NativeModules, Platform } from 'react-native';

import {
    endCallKitSession,
    hasActiveCallKitSession,
    startCallKitSession,
} from '../CallKit';

const WebRTCModule = NativeModules.WebRTCModule as {
    startCallKitSession: jest.Mock;
    endCallKitSession: jest.Mock;
    hasActiveCallKitSession: boolean;
};

describe('CallKit', () => {
    beforeEach(() => {
        Platform.OS = 'ios';
        WebRTCModule.startCallKitSession.mockReset();
        WebRTCModule.endCallKitSession.mockReset();
        WebRTCModule.hasActiveCallKitSession = false;
    });

    it('starts and ends call kit session on iOS', async () => {
        await startCallKitSession({ displayName: 'Fishjam', isVideo: true });
        await endCallKitSession();

        expect(WebRTCModule.startCallKitSession).toHaveBeenCalledWith(
            'Fishjam',
            true,
        );
        expect(WebRTCModule.endCallKitSession).toHaveBeenCalled();
    });

    it('returns callkit active status on iOS', () => {
        WebRTCModule.hasActiveCallKitSession = true;

        expect(hasActiveCallKitSession()).toBe(true);
    });

    it('does not call native module on non iOS', async () => {
        Platform.OS = 'android';

        await startCallKitSession({ displayName: 'Fishjam', isVideo: false });
        await endCallKitSession();

        expect(WebRTCModule.startCallKitSession).not.toHaveBeenCalled();
        expect(WebRTCModule.endCallKitSession).not.toHaveBeenCalled();
        expect(hasActiveCallKitSession()).toBe(false);
    });
});
