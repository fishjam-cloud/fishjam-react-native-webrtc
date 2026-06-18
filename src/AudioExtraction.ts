/**
 * Remote audio extraction.
 *
 * Extracts a remote participant's audio from a WebRTC track, converts it to the
 * sample rate, channel layout, and format you ask for, and delivers it to your
 * code in steady batches. Use it to run audio processing on a remote peer's
 * voice — speech-to-text, voice-activity detection, recording, or level metering.
 *
 * ```ts
 * // Start, asking for the audio format you want and receiving the batches.
 * await startAudioExtraction(
 *   remoteTrack,
 *   { sampleRate: 16000, channels: 1, format: 'f32' },
 *   ({ data }) => {
 *     const samples = new Float32Array(data); // matches the requested 'f32'
 *     // …hand `samples` to your processor…
 *   },
 * );
 *
 * // Stop when finished.
 * stopAudioExtraction(remoteTrack);
 * ```
 *
 * Currently available on iOS with the New Architecture enabled.
 *
 * @module AudioExtraction
 */
import { NativeModules } from 'react-native';

import type MediaStreamTrack from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

// The project's tsconfig sets `types: []`, so RN/Node globals aren't declared.
// Mirror the `declare const global` convention used in index.ts, typed for the
// JSI binding installed natively (see installAudioSinkJSI).
declare const global: {
    __fishjamWebrtcSetAudioSink?: (cb: (d: AudioTrackData) => void) => void;
};

/**
 * The audio format you want {@link startAudioExtraction} to deliver. The track
 * audio is converted to match these settings. Sample rate, channels, and format
 * are required.
 */
export type AudioExtractionOptions = {
    /**
     * Output sample rate in Hz (for example `16000`). Pass `0` to keep the
     * track's original rate.
     */
    sampleRate: number;
    /** Output channels: `1` for mono, `2` for stereo. */
    channels: number;
    /**
     * Sample format of each batch:
     * - `'f32'` — 32-bit float in `[-1, 1]`; read with `new Float32Array(data)`.
     * - `'s16'` — 16-bit signed integer; read with `new Int16Array(data)`.
     */
    format: 'f32' | 's16';
    /**
     * Resampling quality when converting between sample rates: `'linear'`
     * (default) is faster, `'high'` gives better audio quality at higher CPU
     * cost. Has no effect when the output rate matches the source.
     */
    resampleQuality?: 'linear' | 'high';
    /**
     * Length of audio in each delivered batch, in milliseconds (default `100`).
     * Larger values give fewer, larger batches with more latency; smaller
     * values give more frequent, smaller batches.
     */
    batchDurationMs?: number;
};

/**
 * A single batch of audio, passed to the callback you give
 * {@link startAudioExtraction}.
 */
export type AudioTrackData = {
    /** Id of the peer connection the track belongs to. */
    pcId: number;
    /** Id of the source audio track (the one you passed to start). */
    trackId: string;
    /** Sample rate of this batch in Hz. */
    sampleRate: number;
    /** Channel count. Samples are interleaved when there is more than one. */
    channels: number;
    /** Sample format of `data`, matching the `format` you requested. */
    format: 'f32' | 's16';
    /**
     * The audio samples for this batch. Wrap it to read them:
     * `new Float32Array(data)` for `'f32'`, `new Int16Array(data)` for `'s16'`.
     */
    data: ArrayBuffer;
};

// On the old architecture the native install may never call back (no
// JSI-capable CallInvoker); bound the wait so we reject clearly instead of
// hanging. Generous to survive a busy JS thread (e.g. model loading).
const INSTALL_TIMEOUT_MS = 10000;

let installPromise: Promise<void> | null = null;
let sinkRegistered = false;
const listeners = new Map<string, (d: AudioTrackData) => void>();

function peerConnectionId(track: MediaStreamTrack): number {
    // Remote tracks carry the pcId; local tracks use -1 (see MediaStreamTrack).
    return track.remote ? (track as unknown as { _peerConnectionId: number })._peerConnectionId : -1;
}

function toNewArchError(e: unknown): Error {
    if (e instanceof Error && (e as { code?: string }).code !== 'E_NO_JSI') {
        return e;
    }
    return new Error('Audio extraction requires the New Architecture.');
}

/** Memoized JSI install handshake; re-runnable after a JS reload. */
function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timer!: ReturnType<typeof setTimeout>;
    const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(
            () => reject(new Error('Audio extraction install timed out; the New Architecture is required.')),
            INSTALL_TIMEOUT_MS,
        );
    });
    const install: Promise<void> = WebRTCModule.installAudioSinkJSI().then(() => {
        if (typeof global.__fishjamWebrtcSetAudioSink !== 'function') {
            throw new Error('Audio extraction unavailable: JSI binding not installed.');
        }
        sinkRegistered = false;
    });
    const p: Promise<void> = Promise.race([install, timeout])
        .finally(() => clearTimeout(timer))
        .catch((e: unknown) => {
            installPromise = null;
            throw toNewArchError(e);
        });
    installPromise = p;
    return p;
}

/** Register the single native callback that dispatches to the per-track handler. */
function registerSink(): void {
    if (sinkRegistered) {
        return;
    }
    global.__fishjamWebrtcSetAudioSink!((d: AudioTrackData) => {
        listeners.get(d.trackId)?.(d);
    });
    sinkRegistered = true;
}

/**
 * Start extracting audio from a remote participant's track.
 *
 * Converted audio is delivered to `onData` in batches (one call per batch) until
 * you call {@link stopAudioExtraction} for the same track.
 *
 * @param track   The remote audio {@link MediaStreamTrack} to extract from.
 * @param options The audio format to receive; see {@link AudioExtractionOptions}.
 * @param onData  Receives each {@link AudioTrackData} batch.
 * @returns Resolves once extraction has started.
 * @throws Rejects if audio extraction isn't supported on this platform
 *   (currently it requires iOS with the New Architecture).
 *
 * @example
 * await startAudioExtraction(
 *   remoteTrack,
 *   { sampleRate: 16000, channels: 1, format: 'f32' },
 *   ({ data }) => processor.feed(new Float32Array(data)),
 * );
 */
export async function startAudioExtraction(
    track: MediaStreamTrack,
    options: AudioExtractionOptions,
    onData: (data: AudioTrackData) => void,
): Promise<void> {
    await ensureInstalled();
    registerSink();
    listeners.set(track.id, onData);
    WebRTCModule.startAudioExtraction(peerConnectionId(track), track.id, options);
}

/**
 * Stop extracting audio from `track` and stop delivering its batches.
 *
 * @param track The track you passed to {@link startAudioExtraction}.
 */
export function stopAudioExtraction(track: MediaStreamTrack): void {
    WebRTCModule.stopAudioExtraction(peerConnectionId(track), track.id);
    listeners.delete(track.id);
}
