import { endCallKitSession, hasActiveCallKitSession, startCallKitSession } from '../CallKit';

const { __mockReactNative, Platform } = require('react-native');

describe('CallKit', () => {
    beforeEach(() => {
        Platform.OS = 'ios';
        __mockReactNative.WebRTCModule.startCallKitSession.mockReset();
        __mockReactNative.WebRTCModule.endCallKitSession.mockReset();
        __mockReactNative.WebRTCModule.hasActiveCallKitSession = false;
    });

    it('starts and ends call kit session on iOS', async () => {
        await startCallKitSession({ displayName: 'Fishjam', isVideo: true });
        await endCallKitSession();

        expect(
            __mockReactNative.WebRTCModule.startCallKitSession,
        ).toHaveBeenCalledWith('Fishjam', true);
        expect(__mockReactNative.WebRTCModule.endCallKitSession).toHaveBeenCalled();
    });

    it('returns callkit active status on iOS', () => {
        __mockReactNative.WebRTCModule.hasActiveCallKitSession = true;

        expect(hasActiveCallKitSession()).toBe(true);
    });

    it('does not call native module on non iOS', async () => {
        Platform.OS = 'android';

        await startCallKitSession({ displayName: 'Fishjam', isVideo: false });
        await endCallKitSession();

        expect(__mockReactNative.WebRTCModule.startCallKitSession).not.toHaveBeenCalled();
        expect(__mockReactNative.WebRTCModule.endCallKitSession).not.toHaveBeenCalled();
        expect(hasActiveCallKitSession()).toBe(false);
    });
});
