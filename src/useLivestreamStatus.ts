import { useEffect, useRef, useState } from 'react';
import { AppState, NativeModules, Platform } from 'react-native';

import { addListener, removeListener } from './EventEmitter';

const { WebRTCModule } = NativeModules;

/**
 * Lifecycle of a background screen-share livestream, reported by the broadcast extension:
 * - `idle`       no broadcast has run yet (or status was never set)
 * - `starting`   the extension launched and is setting up the WebRTC pipeline
 * - `connecting` the WHIP offer has been sent, negotiating
 * - `streaming`  the peer connection is connected and media is flowing
 * - `failed`     the broadcast ended because of an error (see `error`)
 * - `stopped`    the broadcast finished normally
 * - `unsupported` livestream screen-share is not available on this platform (non-iOS)
 */
export type LivestreamStatus =
    | 'idle'
    | 'starting'
    | 'connecting'
    | 'streaming'
    | 'failed'
    | 'stopped'
    | 'unsupported';

export interface LivestreamStatusInfo {
    status: LivestreamStatus;
    /** Failure reason when `status === 'failed'`, otherwise `null`. */
    error: string | null;
}

/**
 * Subscribes to status updates from the livestream broadcast extension (iOS only).
 *
 * The extension runs in a separate process and signals the host app via a Darwin
 * notification; the status payload is read from the shared App Group. Because a
 * backgrounded app cannot receive Darwin notifications live, the status is also
 * re-read whenever the app returns to the foreground.
 *
 * On non-iOS platforms this always returns `{ status: 'unsupported', error: null }`.
 */
export function useLivestreamStatus(): LivestreamStatusInfo {
    const [status, setStatus] = useState<LivestreamStatus>(
        Platform.OS === 'ios' ? 'idle' : 'unsupported',
    );
    const [error, setError] = useState<string | null>(null);
    const listener = useRef({});

    useEffect(() => {
        if (Platform.OS !== 'ios') {
            return;
        }

        const apply = (info: LivestreamStatusInfo) => {
            setStatus(info.status);
            setError(info.error ?? null);
        };

        WebRTCModule.startLivestreamStatusObserver()
            .then(apply)
            .catch(() => {});

        addListener(
            listener.current,
            'livestreamStatusChanged',
            (event: unknown) => {
                apply(event as LivestreamStatusInfo);
            },
        );

        const appStateSub = AppState.addEventListener('change', (state) => {
            if (state === 'active') {
                WebRTCModule.getLivestreamStatus()
                    .then(apply)
                    .catch(() => {});
            }
        });

        return () => {
            removeListener(listener.current);
            appStateSub.remove();
        };
    }, []);

    return { status, error };
}
