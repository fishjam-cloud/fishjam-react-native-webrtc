/**
 * Custom audio track.
 *
 * Feed your own PCM into a WebRTC audio track. Create the track with
 * {@link createCustomAudioTrack}, publish the returned {@link MediaStream}, and
 * hand samples over with {@link pushAudioSamples} whenever your source produces
 * them — any chunk size, `Float32Array` (values in `[-1, 1]`) or `Int16Array`.
 *
 * The native layer re-paces your pushes into the continuous real-time frame
 * stream the encoder expects, inserting silence whenever the buffer runs dry —
 * the track behaves like a live microphone, so pauses in pushing are fine and
 * the stream never ends. Sending this track does not involve the device
 * microphone in any way: it neither triggers the recording permission nor mixes
 * microphone audio in.
 *
 * ```ts
 * const { stream, track } = await createCustomAudioTrack({ sampleRateHz: 48000 });
 * // e.g. from react-native-audio-api's AudioRecorder:
 * recorder.onAudioReady({ sampleRate: 48000, bufferLength: 4800, channelCount: 1 },
 *     ({ buffer }) => pushAudioSamples(track, buffer.getChannelData(0)));
 * ```
 *
 * New Architecture only: {@link createCustomAudioTrack} rejects with a clear
 * error on the old architecture, where the per-push JSI channel is unavailable.
 *
 * @module createCustomAudioTrack
 */
import { NativeModules } from 'react-native';

import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';
import type { MediaStreamTrackInfo } from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

// Installed natively once the JSI binding is in place (see installCustomAudioJSI).
// Returns the per-track host object used for hop-free pushes.
declare const global: {
    __fishjamWebrtcGetCustomAudioSink?: (trackId: string) => CustomAudioSink;
};

// The old architecture has no JSI-capable invoker, so the install may never
// resolve — cap the wait and reject rather than hang.
const INSTALL_TIMEOUT_MS = 10_000;

let installPromise: Promise<void> | null = null;

function normalizeInstallError(cause: unknown): Error {
    if (cause instanceof Error) {
        return (cause as { code?: string }).code === 'E_NO_JSI'
            ? new Error('Custom audio tracks require the New Architecture.')
            : cause;
    }
    return new Error(`Custom audio track install failed: ${String(cause)}`);
}

function invalidInitError(message: string): Error {
    const error = new Error(message) as Error & { code: string };
    error.code = 'E_INVALID_CUSTOM_AUDIO_TRACK_INIT';
    return error;
}

// Install the native JSI binding once. Re-runnable after a JS reload.
function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timeoutId!: ReturnType<typeof setTimeout>;
    const timeout = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(
            () => reject(new Error('Custom audio track install timed out.')),
            INSTALL_TIMEOUT_MS,
        );
    });
    const install = WebRTCModule.installCustomAudioJSI().then(() => {
        if (typeof global.__fishjamWebrtcGetCustomAudioSink !== 'function') {
            throw new Error('Custom audio track binding was not installed.');
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

type BridgeCustomAudioTrack = {
    streamId: string;
    track: MediaStreamTrackInfo;
};

/**
 * Settings for {@link createCustomAudioTrack}, fixed for the track's lifetime.
 */
export interface CustomAudioTrackInit {
    /**
     * Sample rate of the PCM you will push, in hertz. Must be a positive
     * multiple of `100` (the pacing works in 10 ms frames). Any rate is
     * resampled to the codec rate downstream, so push whatever your source
     * produces natively. Defaults to `48000`.
     */
    sampleRateHz?: number;
    /**
     * `1` for mono or `2` for interleaved stereo. Defaults to `1`.
     */
    channelCount?: 1 | 2;
    /**
     * How much pushed-but-not-yet-sent audio to hold, in milliseconds, before
     * the oldest is dropped. The buffer drains in real time, so this is the
     * furthest you can push ahead — for example a long text-to-speech
     * utterance handed over in one call. Defaults to `60000` (one minute).
     */
    maxBufferedDurationMs?: number;
}

/**
 * The native per-track push channel handed back on a track handle's `sink`.
 *
 * Backed by a JSI host object, so it is shared *by reference* into a worklet —
 * calling `push` there dispatches synchronously on the worklet thread with no
 * hop. You normally don't call this directly; use {@link pushAudioSamples}.
 *
 * Push from the *same* worklet runtime the sink was captured into: `push` binds
 * lazily to whichever runtime first resolves it. `push` is stable per runtime,
 * so a hot loop may hoist it once (`const push = track.sink.push`) and reuse it.
 */
export interface CustomAudioSink {
    push(samples: Float32Array | Int16Array): void;
}

/**
 * Handle for a custom audio track. Plain and worklet-serializable — store it
 * (not the {@link MediaStream}) in the ref/shared value your audio-producing
 * code reads, and pass it to {@link pushAudioSamples}.
 */
export interface CustomAudioTrack {
    /** Id of the underlying audio track. */
    readonly trackId: string;
    /** The sample rate this track was created with. */
    readonly sampleRateHz: number;
    /** The channel count this track was created with. */
    readonly channelCount: 1 | 2;
    /** Native push channel; use {@link pushAudioSamples} rather than calling it directly. */
    readonly sink: CustomAudioSink;
}

/** Result of {@link createCustomAudioTrack}: the stream to publish + the push handle. */
export interface CustomAudioTrackResult {
    /**
     * A {@link MediaStream} containing the single custom audio track. Use it as
     * any other stream — publish it (for example via `useCustomSource`). Keep it
     * on the JS thread; it is not worklet-serializable.
     */
    stream: MediaStream;
    /** The worklet-serializable push handle. Pass to {@link pushAudioSamples}. */
    track: CustomAudioTrack;
}

/**
 * Create a custom audio track.
 *
 * Returns the {@link MediaStream} to publish plus a worklet-serializable
 * {@link CustomAudioTrack} handle for pushing samples. Stop the track like any
 * other (`stream.getTracks().forEach((track) => track.stop())`); pushes after
 * stopping are dropped.
 *
 * New Architecture only: rejects with a clear error on the old architecture.
 */
export async function createCustomAudioTrack(
    init?: CustomAudioTrackInit,
): Promise<CustomAudioTrackResult> {
    const sampleRateHz = init?.sampleRateHz ?? 48000;
    const channelCount = init?.channelCount ?? 1;
    const maxBufferedDurationMs = init?.maxBufferedDurationMs ?? 60_000;

    if (
        !Number.isInteger(sampleRateHz) ||
        sampleRateHz <= 0 ||
        sampleRateHz % 100 !== 0
    ) {
        throw invalidInitError(
            'createCustomAudioTrack: sampleRateHz must be a positive multiple of 100.',
        );
    }
    if (channelCount !== 1 && channelCount !== 2) {
        throw invalidInitError(
            'createCustomAudioTrack: channelCount must be 1 or 2.',
        );
    }
    if (!Number.isInteger(maxBufferedDurationMs) || maxBufferedDurationMs <= 0) {
        throw invalidInitError(
            'createCustomAudioTrack: maxBufferedDurationMs must be a positive integer.',
        );
    }

    await ensureInstalled();

    let data: BridgeCustomAudioTrack;
    try {
        data = await WebRTCModule.createCustomAudioTrack({
            sampleRateHz,
            channelCount,
            maxBufferedDurationMs,
        });
    } catch (error) {
        throw new MediaStreamError(error);
    }

    const { streamId, track } = data;
    const stream = new MediaStream({
        streamId,
        streamReactTag: streamId,
        tracks: [track],
    });

    const sink = global.__fishjamWebrtcGetCustomAudioSink!(track.id);
    const handle: CustomAudioTrack = {
        trackId: track.id,
        sampleRateHz,
        channelCount,
        sink,
    };

    return { stream, track: handle };
}

/**
 * Hand PCM to a custom audio track.
 *
 * Call whenever your source produces audio, with any chunk size — the native
 * layer re-frames and paces it. `Float32Array` samples are expected in
 * `[-1, 1]` (values outside are clamped); `Int16Array` is taken as-is. Stereo
 * tracks take interleaved samples. Worklet-safe: it dispatches synchronously to
 * native on whatever thread you call it from. The samples are copied before the
 * call returns, so the array may be reused immediately.
 */
export function pushAudioSamples(
    track: CustomAudioTrack,
    samples: Float32Array | Int16Array,
): void {
    'worklet';
    track.sink.push(samples);
}
