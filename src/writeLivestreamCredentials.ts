import { NativeModules, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export interface LivestreamCredentials {
    /** Full WHIP ingestion URL the extension should POST the SDP offer to. */
    whipUrl: string;
    /** Streamer token used to authenticate with Fishjam WHIP (Bearer). */
    token: string;
}

/**
 * Writes the WHIP credentials into the shared App Group UserDefaults so the
 * livestream broadcast extension can read them when the broadcast starts.
 *
 * Must be called before {@link presentLivestreamBroadcastPicker}. Requires the
 * App Group to be configured via the config plugin
 * (`ios.enableLivestreamScreensharing`).
 *
 * iOS only. No-op on non-iOS platforms.
 */
export default function writeLivestreamCredentials(
    credentials: LivestreamCredentials,
): Promise<void> {
    if (Platform.OS !== 'ios') {
        return Promise.resolve();
    }
    return WebRTCModule.writeLivestreamCredentials(credentials);
}
