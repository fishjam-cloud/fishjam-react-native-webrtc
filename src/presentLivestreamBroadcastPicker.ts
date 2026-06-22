import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

/**
 * Presents the iOS system `RPSystemBroadcastPickerView` for the standalone
 * livestream screen-share extension (Info.plist key `RTCLivestreamExtension`).
 *
 * Unlike {@link presentBroadcastPicker} (the in-call extension), the livestream
 * extension owns the whole WebRTC pipeline in-process, so the stream keeps
 * running while the host app is backgrounded. Call
 * {@link writeLivestreamCredentials} first so the extension can read the WHIP
 * url and token when the broadcast starts.
 *
 * iOS only. Resolves once the tap is dispatched, NOT once the user confirms.
 *
 * No-op on non-iOS platforms.
 */
export default function presentLivestreamBroadcastPicker(): Promise<void> {
    if (Platform.OS !== 'ios') {
        return Promise.resolve();
    }
    return WebRTCModule.presentLivestreamBroadcastPicker();
}
