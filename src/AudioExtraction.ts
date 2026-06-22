/**
 * Remote audio extraction.
 *
 * Extracts a remote participant's audio from a WebRTC track, converts it to the
 * sample rate, channels, and format you ask for, and delivers it in batches —
 * for speech-to-text, voice-activity detection, recording, or metering.
 *
 * ```ts
 * await startAudioExtraction(
 *   track,
 *   { sampleRate: 16000, channels: 1, format: 'f32' },
 *   ({ data }) => processor.feed(new Float32Array(data)),
 * );
 * stopAudioExtraction(track);
 * ```
 *
 * New Architecture only (iOS and Android).
 *
 * @module AudioExtraction
 */
import { NativeModules } from 'react-native';

import type MediaStreamTrack from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

// Installed natively once the JSI binding is in place (see installAudioSinkJSI).
declare const global: {
    __fishjamWebrtcSetAudioSink?: (
        handler: (batch: AudioTrackData) => void,
    ) => void;
};

/** Output format for {@link startAudioExtraction}; the track audio is converted to match. */
export type AudioExtractionOptions = {
    /** Output sample rate in Hz (e.g. `16000`); `0` keeps the source rate. */
    sampleRate: number;
    /** Output channels: `1` for mono, `2` for stereo. */
    channels: number;
    /** Sample format: `'f32'` (Float32, `[-1, 1]`) or `'s16'` (Int16, little-endian). */
    format: 'f32' | 's16';
    /** Resampling quality: `'linear'` (default, faster) or `'high'` (better, more CPU). */
    resampleQuality?: 'linear' | 'high';
    /** Audio per delivered batch, in milliseconds (default `100`). */
    batchDurationMs?: number;
};

/** One batch of converted audio, passed to the {@link startAudioExtraction} callback. */
export type AudioTrackData = {
    pcId: number;
    trackId: string;
    sampleRate: number;
    channels: number;
    format: 'f32' | 's16';
    /** Read with `new Float32Array(data)` for `'f32'`, `new Int16Array(data)` for `'s16'`. */
    data: ArrayBuffer;
};

// The old architecture has no JSI-capable invoker, so the install may never
// resolve — cap the wait and reject rather than hang.
const INSTALL_TIMEOUT_MS = 10_000;

const handlers = new Map<string, (batch: AudioTrackData) => void>();
let installPromise: Promise<void> | null = null;
let dispatcherRegistered = false;

function peerConnectionId(track: MediaStreamTrack): number {
    // Remote tracks carry the pcId; local tracks use -1.
    return track.remote
        ? (track as unknown as { _peerConnectionId: number })._peerConnectionId
        : -1;
}

function unsupportedError(cause: unknown): Error {
    if (
        cause instanceof Error &&
        (cause as { code?: string }).code !== 'E_NO_JSI'
    ) {
        return cause;
    }
    return new Error('Audio extraction requires the New Architecture.');
}

// Install the native JSI binding once. Re-runnable after a JS reload.
function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timeoutId!: ReturnType<typeof setTimeout>;
    const timeout = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(
            () => reject(new Error('Audio extraction install timed out.')),
            INSTALL_TIMEOUT_MS,
        );
    });
    const install = WebRTCModule.installAudioSinkJSI().then(() => {
        if (typeof global.__fishjamWebrtcSetAudioSink !== 'function') {
            throw new Error('Audio extraction binding was not installed.');
        }
        dispatcherRegistered = false;
    });
    installPromise = Promise.race([install, timeout])
        .finally(() => clearTimeout(timeoutId))
        .catch((cause: unknown) => {
            installPromise = null;
            throw unsupportedError(cause);
        });
    return installPromise;
}

// Point the single native callback at our per-track handler map (once).
function registerDispatcher(): void {
    if (dispatcherRegistered) {
        return;
    }
    global.__fishjamWebrtcSetAudioSink!((batch) =>
        handlers.get(batch.trackId)?.(batch),
    );
    dispatcherRegistered = true;
}

/**
 * Start extracting audio from a remote track. `onData` is called once per batch
 * until {@link stopAudioExtraction} is called for the same track.
 *
 * @throws If extraction is unsupported on this platform (New Architecture only).
 */
export async function startAudioExtraction(
    track: MediaStreamTrack,
    options: AudioExtractionOptions,
    onData: (batch: AudioTrackData) => void,
): Promise<void> {
    await ensureInstalled();
    registerDispatcher();
    handlers.set(track.id, onData);
    WebRTCModule.startAudioExtraction(
        peerConnectionId(track),
        track.id,
        options,
    );
}

/** Stop extracting audio from `track` and stop delivering its batches. */
export function stopAudioExtraction(track: MediaStreamTrack): void {
    WebRTCModule.stopAudioExtraction(peerConnectionId(track), track.id);
    handlers.delete(track.id);
}
