/**
 * Custom video track.
 *
 * Lets you feed your own GPU- or CPU-rendered frames into a WebRTC video track.
 * You create a track backed by a small pool of native surfaces, render into one
 * of those surfaces (for example with react-native-webgpu), then hand the frame
 * back so it is encoded and sent on the track's {@link MediaStream}.
 *
 * The typical loop is:
 *
 * ```ts
 * const { stream, buffers } = await createCustomVideoTrack({
 *   width: 720,
 *   height: 1280,
 *   poolSize: 3,
 * });
 *
 * // Import each pooled surface into your GPU device once, up front.
 * const textures = buffers.map((buffer) =>
 *   device.importSharedTextureMemory({ handle: buffer.surfaceHandle }),
 * );
 *
 * // Per frame: pick the next pool slot, render into it, then push it.
 * const buffer = buffers[frameCount % buffers.length];
 * renderInto(textures[buffer.index]);
 * pushCustomVideoFrame({
 *   trackId: stream.getVideoTracks()[0].id,
 *   bufferIndex: buffer.index,
 *   timestampNs: performance.now() * 1e6,
 * });
 * ```
 *
 * New Architecture only. {@link pushCustomVideoFrame} routes through a JSI
 * binding, and {@link createCustomVideoTrack} rejects with a clear error on the
 * old architecture.
 *
 * @module createCustomVideoTrack
 */
import { NativeModules } from 'react-native';

import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';
import type { MediaStreamTrackInfo } from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

// Installed natively once the JSI binding is in place (see installCustomVideoJSI).
declare const global: {
    __fishjamWebrtcPushCustomVideoFrame?: (frame: CustomVideoFramePush) => void;
};

// The old architecture has no JSI-capable invoker, so the install may never
// resolve — cap the wait and reject rather than hang.
const INSTALL_TIMEOUT_MS = 10_000;

let installPromise: Promise<void> | null = null;

function normalizeInstallError(cause: unknown): Error {
    if (
        cause instanceof Error &&
        (cause as { code?: string }).code !== 'E_NO_JSI'
    ) {
        return cause;
    }
    return new Error('Custom video tracks require the New Architecture.');
}

// Install the native JSI binding once. Re-runnable after a JS reload.
function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timeoutId!: ReturnType<typeof setTimeout>;
    const timeout = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(
            () =>
                reject(new Error('Custom video track install timed out.')),
            INSTALL_TIMEOUT_MS,
        );
    });
    const install = WebRTCModule.installCustomVideoJSI().then(() => {
        if (typeof global.__fishjamWebrtcPushCustomVideoFrame !== 'function') {
            throw new Error('Custom video track binding was not installed.');
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

// Shape of one pooled surface as it arrives over the React Native bridge, where
// the 64-bit surface handle is carried as a decimal string to avoid losing
// precision through a JS number.
type BridgeCustomVideoBuffer = {
    index: number;
    surfaceHandle: string;
    width: number;
    height: number;
};

// Shape resolved by the native createCustomVideoTrack method over the bridge.
// Distinct from the public CustomVideoTrack: the bridge hands back the raw
// stream/track ids and string handles, which the wrapper converts into a
// MediaStream and bigint-handle buffers.
type BridgeCustomVideoTrack = {
    streamId: string;
    track: MediaStreamTrackInfo;
    buffers: BridgeCustomVideoBuffer[];
};

/**
 * Settings for {@link createCustomVideoTrack}, describing the pool of native
 * surfaces the track will render into.
 */
export interface CustomVideoTrackInit {
    /**
     * Width of every pooled surface, in pixels. All frames you push must be
     * rendered at this size; it also becomes the encoded width of the track.
     */
    width: number;
    /**
     * Height of every pooled surface, in pixels. All frames you push must be
     * rendered at this size; it also becomes the encoded height of the track.
     */
    height: number;
    /**
     * Number of in-flight surfaces to allocate (must be at least `1`, typically
     * `2`–`3`).
     *
     * Why more than one: a frame you push may still be in use — being encoded
     * and delivered — when you want to start drawing the next one. Redrawing a
     * surface that is still being read would tear or corrupt that frame. With a
     * pool you render into a different slot each time, cycling round-robin over
     * the {@link CustomVideoTrack.buffers}, so the producer never overwrites a
     * buffer still being consumed. Size the pool to the number of frames you
     * expect to have in flight at once.
     */
    poolSize: number;
}

/**
 * One surface in the track's pool. Returned (once, up front) from
 * {@link createCustomVideoTrack}; you render into these and reference them by
 * {@link CustomVideoBuffer.index} when pushing a frame.
 */
export interface CustomVideoBuffer {
    /**
     * Stable index of this surface within the pool (`0` to `poolSize - 1`).
     * Pass it back as {@link CustomVideoFramePush.bufferIndex} to identify the
     * surface you rendered into for a given frame. The index never changes for
     * the lifetime of the track.
     */
    index: number;
    /**
     * The 64-bit native surface handle (an `IOSurface` on iOS, an
     * `AHardwareBuffer` on Android), as a `bigint`.
     *
     * Import it into your GPU as a texture you can render into — using whatever
     * library or native code you like (for example react-native-webgpu:
     * `device.importSharedTextureMemory({ handle: surfaceHandle })`). Import each
     * surface once, up front, and reuse the imported texture for every frame you
     * draw into that slot.
     */
    surfaceHandle: bigint;
    /** Width of this surface in pixels; matches {@link CustomVideoTrackInit.width}. */
    width: number;
    /** Height of this surface in pixels; matches {@link CustomVideoTrackInit.height}. */
    height: number;
}

/**
 * The result of {@link createCustomVideoTrack}: a media stream carrying the new
 * video track, plus the pool of surfaces to render into.
 */
export interface CustomVideoTrack {
    /**
     * A {@link MediaStream} containing the single custom video track. Use it as
     * you would any other stream — add it to an `RTCPeerConnection`, take its
     * track id from `stream.getVideoTracks()[0].id` to pass as
     * {@link CustomVideoFramePush.trackId}, render it locally, and so on.
     */
    stream: MediaStream;
    /**
     * The pool of surfaces to render into, one entry per `poolSize`. Indexed by
     * {@link CustomVideoBuffer.index}; iterate it once to import every surface
     * into your GPU device.
     */
    buffers: CustomVideoBuffer[];
}

/**
 * An optional GPU completion fence that tells the encoder when your rendering
 * into a surface has actually finished on the GPU, so it waits for the draw
 * before reading the frame.
 *
 * This is a standard platform GPU-synchronization primitive — it is not tied to
 * any particular GPU library. You can produce it from raw Metal/Vulkan/GL code
 * or from any library that can surface one. For example, with react-native-webgpu
 * the two values come from an `endAccess` result: `handle` from
 * `fences[0].fence.export().handle` and `signaledValue` from
 * `fences[0].signaledValue` (both already bigints — pass them through unchanged).
 */
export interface CustomVideoFrameFence {
    /**
     * The native GPU fence object, as a bigint:
     * - **iOS** — an `MTLSharedEvent` handle.
     * - **Android** — a `sync` file descriptor.
     */
    handle: bigint;
    /**
     * The value the fence is signaled to once this frame's GPU work completes.
     *
     * Used on iOS, where the encoder waits until the `MTLSharedEvent` reaches
     * this value. Ignored on Android, where a `sync` fd carries no value (pass
     * `0n`).
     */
    signaledValue: bigint;
}

/**
 * One frame handed back to the track for encoding, identifying which pooled
 * surface you rendered into and when it should be presented.
 */
export interface CustomVideoFramePush {
    /**
     * Id of the custom video track to deliver this frame to. Take it from the
     * stream returned by {@link createCustomVideoTrack}, via
     * `stream.getVideoTracks()[0].id`.
     */
    trackId: string;
    /**
     * The {@link CustomVideoBuffer.index} of the pooled surface you rendered
     * into for this frame.
     */
    bufferIndex: number;
    /**
     * Monotonic presentation timestamp for this frame, in nanoseconds. Must
     * increase from frame to frame; used to pace and time the encoded video.
     */
    timestampNs: number;
    /**
     * Clockwise rotation to apply at delivery, in degrees. One of `0`, `90`,
     * `180`, `270`. Optional; defaults to `0` (no rotation).
     */
    rotation?: 0 | 90 | 180 | 270;
    /**
     * Optional GPU completion fence (see {@link CustomVideoFrameFence}). Provide
     * it when the frame's GPU work may not be finished yet, so the encoder waits
     * for your draw to complete before reading the surface.
     *
     * Omit it to deliver the frame immediately — for CPU-filled frames or any
     * frame whose rendering has already finished.
     */
    fence?: CustomVideoFrameFence;
}

/**
 * Create a custom video track backed by a pool of native surfaces you render
 * into yourself.
 *
 * Call this once, import every surface in {@link CustomVideoTrack.buffers} into
 * your GPU device, then drive the track by rendering into a surface and calling
 * {@link pushCustomVideoFrame} per frame.
 *
 * New Architecture only: rejects with a clear error on the old architecture.
 *
 * @param init Pool dimensions and size; see {@link CustomVideoTrackInit}.
 * @returns A promise resolving to the {@link CustomVideoTrack} (stream + pool).
 */
export async function createCustomVideoTrack(
    init: CustomVideoTrackInit,
): Promise<CustomVideoTrack> {
    await ensureInstalled();

    let data: BridgeCustomVideoTrack;
    try {
        data = await WebRTCModule.createCustomVideoTrack(init);
    } catch (error) {
        throw new MediaStreamError(error);
    }

    const { streamId, track, buffers } = data;

    const stream = new MediaStream({
        streamId: streamId,
        streamReactTag: streamId,
        tracks: [track],
    });

    // The bridge carries each surface handle as a decimal string; expose it as a
    // bigint, the public type the GPU import path consumes.
    const pool: CustomVideoBuffer[] = buffers.map((buffer) => ({
        index: buffer.index,
        surfaceHandle: BigInt(buffer.surfaceHandle),
        width: buffer.width,
        height: buffer.height,
    }));

    return { stream, buffers: pool };
}

/**
 * Hand a rendered frame back to its custom video track for encoding and
 * delivery.
 *
 * Call it once per frame, after rendering into the pooled surface named by
 * {@link CustomVideoFramePush.bufferIndex}. Provide a
 * {@link CustomVideoFramePush.fence} when the GPU work may still be in flight,
 * or omit it to deliver immediately.
 *
 * New Architecture only: this routes through a JSI binding and has no effect on
 * the old architecture (where {@link createCustomVideoTrack} has already
 * rejected).
 *
 * @param frame The frame to deliver; see {@link CustomVideoFramePush}.
 */
export function pushCustomVideoFrame(frame: CustomVideoFramePush): void {
    if (typeof global.__fishjamWebrtcPushCustomVideoFrame !== 'function') {
        throw new Error(
            'Custom video frame binding is not installed; call ' +
                'createCustomVideoTrack first (New Architecture only).',
        );
    }
    global.__fishjamWebrtcPushCustomVideoFrame(frame);
}
