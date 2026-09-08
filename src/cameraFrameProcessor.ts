/**
 * Camera frame processor.
 *
 * Gives a consumer running on another JS runtime (a worklet runtime) access to
 * the frames a local camera track captures, without changing what the track
 * itself delivers. Frames are admitted one at a time: while a consumer holds a
 * frame, newer ones are dropped on the capture thread, never queued.
 *
 * ```ts
 * const processor = await getCameraFrameProcessor(cameraTrack);
 * processor.attach(consumer); // from @fishjam-cloud/react-native-webrtc-worklets
 * // ...
 * processor.detach();
 * ```
 */
import { NativeModules } from 'react-native';

import Logger from './Logger';
import type MediaStreamTrack from './MediaStreamTrack';

const log = new Logger('cameraFrameProcessor');
const { WebRTCModule } = NativeModules;

/** Counters kept by the admission gate; every value is a frame count. */
export interface CameraFrameProcessorStatistics {
    readonly offered: number;
    readonly accepted: number;
    readonly droppedBusy: number;
    readonly droppedDetached: number;
    readonly completed: number;
}

/**
 * A native consumer of camera frames. Created by a companion package
 * (`@fishjam-cloud/react-native-webrtc-worklets`); opaque here.
 */
export interface CameraFrameConsumer {
    readonly __fishjamCameraFrameConsumer: true;
}

/** Per-track handle returned by {@link getCameraFrameProcessor}. */
export interface CameraFrameProcessor {
    readonly trackId: string;
    /**
     * Starts handing admitted frames to `consumer`. Throws with `code`
     * `E_NOT_A_CAMERA_TRACK` when the track is not a local camera track, or
     * `E_VIDEO_EFFECTS_ACTIVE` when native video effects hold the capturer.
     */
    attach(consumer: CameraFrameConsumer): void;
    /** Stops delivery and hands the capturer back to the track. Safe to repeat. */
    detach(): void;
    statistics(): CameraFrameProcessorStatistics;
}

// Installed natively once the JSI binding is in place (see installCameraFrameProcessorJSI).
declare const global: {
    __fishjamWebrtcGetCameraFrameProcessor?: (
        trackId: string,
    ) => CameraFrameProcessor;
};

// The old architecture has no JSI-capable invoker, so the install may never
// resolve — cap the wait and reject rather than hang.
const INSTALL_TIMEOUT_MS = 10_000;

let installPromise: Promise<void> | null = null;

function normalizeInstallError(cause: unknown): Error {
    if (cause instanceof Error) {
        return (cause as { code?: string }).code === 'E_NO_JSI'
            ? new Error(
                  'Camera frame processing requires the New Architecture.',
              )
            : cause;
    }
    return new Error(`Camera frame processor install failed: ${String(cause)}`);
}

function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timeoutId!: ReturnType<typeof setTimeout>;
    let timedOut = false;
    const timeout = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(() => {
            timedOut = true;
            reject(new Error('Camera frame processor install timed out.'));
        }, INSTALL_TIMEOUT_MS);
    });
    const install = WebRTCModule.installCameraFrameProcessorJSI().then(() => {
        if (
            typeof global.__fishjamWebrtcGetCameraFrameProcessor !== 'function'
        ) {
            throw new Error(
                'Camera frame processor binding was not installed.',
            );
        }
    });
    // A rejection after the timeout has no consumer left; log it instead of
    // letting it surface as an unhandled rejection.
    install.catch((cause: unknown) => {
        if (timedOut) {
            log.error(
                'installCameraFrameProcessorJSI failed after the install timeout',
                cause instanceof Error ? cause : new Error(String(cause)),
            );
        }
    });
    installPromise = Promise.race([install, timeout])
        .finally(() => clearTimeout(timeoutId))
        .catch((cause: unknown) => {
            installPromise = null;
            throw normalizeInstallError(cause);
        });
    return installPromise;
}

/**
 * Returns the frame processor for a local camera track. Whether the track
 * really is a camera track is checked natively when a consumer is attached.
 */
export async function getCameraFrameProcessor(
    track: MediaStreamTrack,
): Promise<CameraFrameProcessor> {
    if (track.kind !== 'video') {
        throw new Error('A camera frame processor needs a video track.');
    }
    await ensureInstalled();
    return global.__fishjamWebrtcGetCameraFrameProcessor!(track.id);
}
