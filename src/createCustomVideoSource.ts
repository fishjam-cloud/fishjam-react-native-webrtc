/**
 * Custom video source.
 *
 * Feed your own frames into a WebRTC video track. There are two modes, and you
 * pick by *how you produce frames*:
 *
 * - **Render-target** — *you render the frames yourself* (for example with
 *   react-native-webgpu). Allocate a pool of native render targets with
 *   {@link createCustomVideoRenderTargetPool}, render into them, create a source over
 *   the pool with {@link createRenderTargetSource}, and hand each frame back with
 *   {@link renderFrame} (by render-target index, with an optional GPU fence).
 *
 * - **Forwarding** — *the frames are already produced natively* (a camera,
 *   VisionCamera, a native ML pipeline, a compositor) and you only want to forward
 *   the finished buffer. Create a source with {@link createForwardingSource} and
 *   forward each buffer pointer with {@link forwardFrame}.
 *
 * ```ts
 * // Render-target — render in JS:
 * const pool = await createCustomVideoRenderTargetPool({ width, height, poolSize: 3 });
 * const { stream, sink } = await createRenderTargetSource({ pool });
 * // ...render into pool.renderTargets[i]...
 * renderFrame(sink, { renderTargetIndex, timestampNs, fence });
 *
 * // Forwarding — hand over a finished native buffer:
 * const { stream, sink } = await createForwardingSource();
 * forwardFrame(sink, { nativeBuffer }); // bigint CVPixelBufferRef / AHardwareBuffer*
 * ```
 *
 * New Architecture only: the source factories reject with a clear error on the old
 * architecture, where the per-frame JSI channel is unavailable.
 *
 * Render-target mode needs GPU-shareable native surfaces and should be exercised on
 * a physical device — the iOS Simulator's GPU stack does not reliably back the
 * shared `IOSurface` import path.
 *
 * @module createCustomVideoSource
 */
import { NativeModules } from 'react-native';

import MediaStream from './MediaStream';
import MediaStreamError from './MediaStreamError';
import type { MediaStreamTrackInfo } from './MediaStreamTrack';

const { WebRTCModule } = NativeModules;

// Installed natively once the JSI binding is in place (see installCustomVideoJSI).
// Returns the per-track push channel used for hop-free pushes.
declare const global: {
    __fishjamWebrtcGetCustomVideoPushChannel?: (trackId: string) => CustomVideoPushChannel;
};

// The old architecture has no JSI-capable invoker, so the install may never
// resolve — cap the wait and reject rather than hang.
const INSTALL_TIMEOUT_MS = 10_000;

let installPromise: Promise<void> | null = null;

function normalizeInstallError(cause: unknown): Error {
    if (cause instanceof Error) {
        return (cause as { code?: string }).code === 'E_NO_JSI'
            ? new Error('Custom video sources require the New Architecture.')
            : cause;
    }
    return new Error(`Custom video source install failed: ${String(cause)}`);
}

function invalidInitError(message: string): Error {
    const error = new Error(message) as Error & { code: string };
    error.code = 'E_INVALID_CUSTOM_VIDEO_RENDER_TARGET_POOL_INIT';
    return error;
}

function validatePoolInit(init: CustomVideoRenderTargetPoolInit): void {
    if (
        !Number.isInteger(init?.width) ||
        !Number.isInteger(init?.height) ||
        !Number.isInteger(init?.poolSize) ||
        init.width <= 0 ||
        init.height <= 0 ||
        init.poolSize <= 0
    ) {
        throw invalidInitError(
            'Custom video render target pool width, height, and poolSize must be positive integers.',
        );
    }
}

// Install the native JSI binding once. Re-runnable after a JS reload.
function ensureInstalled(): Promise<void> {
    if (installPromise) {
        return installPromise;
    }
    let timeoutId!: ReturnType<typeof setTimeout>;
    const timeout = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(
            () => reject(new Error('Custom video source install timed out.')),
            INSTALL_TIMEOUT_MS,
        );
    });
    const install = WebRTCModule.installCustomVideoJSI().then(() => {
        if (typeof global.__fishjamWebrtcGetCustomVideoPushChannel !== 'function') {
            throw new Error('Custom video source binding was not installed.');
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

// Shape of one pooled render target as it arrives over the React Native bridge,
// where the 64-bit surface handle is carried as a decimal string to avoid losing
// precision through a JS number. The bridge field names are the native contract.
type BridgeRenderTarget = {
    index: number;
    surfaceHandle: string;
    width: number;
    height: number;
};

type BridgeRenderTargetPool = {
    poolId: string;
    renderTargets: BridgeRenderTarget[];
};

type BridgeCustomVideoTrack = {
    streamId: string;
    track: MediaStreamTrackInfo;
};

/**
 * Settings for {@link createCustomVideoRenderTargetPool}, describing the pool of
 * native surfaces you will render into.
 */
export interface CustomVideoRenderTargetPoolInit {
    /**
     * Width of every render target, in pixels. Becomes the encoded width of any
     * render-target source fed from this pool.
     */
    width: number;
    /**
     * Height of every render target, in pixels. Becomes the encoded height of any
     * render-target source fed from this pool.
     */
    height: number;
    /**
     * Number of in-flight render targets to allocate (at least `1`, typically
     * `2`–`3`).
     *
     * A frame you submit may still be in use — being encoded and delivered — when
     * you want to start drawing the next one. Redrawing a surface that is still
     * being read would tear that frame. With a pool you render into a different
     * target each time, cycling round-robin over {@link CustomVideoRenderTargetPool.renderTargets},
     * so the producer never overwrites a surface still being consumed.
     */
    poolSize: number;
}

/**
 * One surface in a {@link CustomVideoRenderTargetPool}. Import it into your GPU once,
 * up front, and reference it by {@link CustomVideoRenderTarget.index} when submitting
 * a frame.
 */
export interface CustomVideoRenderTarget {
    /**
     * Stable index of this render target within the pool (`0` to `poolSize - 1`).
     * Pass it back as `renderFrame(sink, { renderTargetIndex })`. Never changes for
     * the pool's lifetime.
     */
    index: number;
    /**
     * The 64-bit native surface handle (an `IOSurface` on iOS, an `AHardwareBuffer`
     * on Android), as a `bigint`. Import it into your GPU as a render target (for
     * example react-native-webgpu:
     * `device.importSharedTextureMemory({ handle: surfaceHandle })`). Import each
     * target once and reuse it for every frame you draw into that slot.
     *
     * **Render into the platform's native surface format**, or the frame comes out
     * garbled (red/blue swapped) or is rejected at import:
     * - **iOS** — `BGRA8` (`bgra8unorm`; the surface is `kCVPixelFormatType_32BGRA`).
     * - **Android** — `RGBA8` (`rgba8unorm`).
     */
    surfaceHandle: bigint;
    /** Width of this render target in pixels; matches {@link CustomVideoRenderTargetPoolInit.width}. */
    width: number;
    /** Height of this render target in pixels; matches {@link CustomVideoRenderTargetPoolInit.height}. */
    height: number;
}

/**
 * A pool of native surfaces you render into, owned independently of any source.
 * Returned by {@link createCustomVideoRenderTargetPool}; attach it to a render-target
 * source via {@link createRenderTargetSource}, and free it yourself with
 * {@link CustomVideoRenderTargetPool.dispose} once the source has stopped.
 */
export interface CustomVideoRenderTargetPool {
    /** Opaque id identifying this pool to the native layer. */
    poolId: string;
    /** The render targets, one entry per `poolSize`; import each into your GPU once. */
    renderTargets: CustomVideoRenderTarget[];
    /**
     * Free the pool's native surfaces. Call it after the source bound to this pool
     * has stopped. Stopping the source does *not* free the pool — you own it.
     * Rejects while the bound source is still live; safe to retry after stopping it.
     * After a successful dispose, further calls are no-ops.
     */
    dispose(): Promise<void>;
}

/**
 * An optional GPU completion fence that tells the encoder when your rendering into
 * a surface has finished on the GPU, so it waits for the draw before reading the
 * frame. A standard platform GPU-sync primitive — not tied to any GPU library.
 */
export interface CustomVideoFrameFence {
    /**
     * The native GPU fence object, as a bigint:
     * - **iOS** — an `MTLSharedEvent` handle.
     * - **Android** — a `sync` file descriptor.
     */
    handle: bigint;
    /**
     * The value the fence is signaled to once this frame's GPU work completes. Used
     * on iOS (the encoder waits until the `MTLSharedEvent` reaches it); ignored on
     * Android, where a `sync` fd carries no value (pass `0n`).
     */
    signaledValue: bigint;
}

/**
 * The native per-track push channel carried on a sink's `pushChannel`.
 *
 * Backed by a JSI host object, so it is shared *by reference* into a frame-processor
 * worklet — calling `push` there dispatches synchronously on the worklet thread with
 * no hop. You normally don't call this directly; use {@link renderFrame} /
 * {@link forwardFrame}. It is exposed so it can be captured into a worklet setup
 * where the wrappers aren't processed.
 *
 * Push from the *same* worklet runtime the channel was captured into: `push` binds
 * lazily to whichever runtime first resolves it, so importing one channel into two
 * runtimes and pushing from both is unsupported. `push` is stable per runtime, so a
 * hot loop may hoist it once (`const push = sink.pushChannel.push`) and reuse it.
 */
export interface CustomVideoPushChannel {
    push(frame: object): void;
}

/**
 * Handle for a **render-target** custom video source (you render frames in JS).
 * Plain and worklet-serializable — store it (not the {@link MediaStream}) in the
 * ref/shared value your render/worklet loop reads, and pass it to {@link renderFrame}.
 */
export interface RenderSink {
    readonly kind: 'render';
    /** Id of the underlying video track. */
    trackId: string;
    /** Native push channel; use {@link renderFrame} rather than calling it directly. */
    readonly pushChannel: CustomVideoPushChannel;
}

/**
 * Handle for a **forwarding** custom video source (frames produced natively). Plain
 * and worklet-serializable — store it (not the {@link MediaStream}) in the ref/shared
 * value your frame processor reads, and pass it to {@link forwardFrame}.
 */
export interface ForwardSink {
    readonly kind: 'forward';
    /** Id of the underlying video track. */
    trackId: string;
    /** Native push channel; use {@link forwardFrame} rather than calling it directly. */
    readonly pushChannel: CustomVideoPushChannel;
}

/** Result of a custom video source factory: the stream to publish + the frame sink. */
export interface CustomVideoSourceResult<Sink extends RenderSink | ForwardSink> {
    /**
     * A {@link MediaStream} containing the single custom video track. Use it as any
     * other stream — publish it (for example via `useCustomSource`), render it
     * locally, and so on. Keep it on the JS thread; it is not worklet-serializable.
     */
    stream: MediaStream;
    /** The worklet-serializable frame sink. Pass to {@link renderFrame} / {@link forwardFrame}. */
    sink: Sink;
}

/** Frame arguments for {@link renderFrame} (render-target mode). */
export interface RenderFrameArgs {
    /** {@link CustomVideoRenderTarget.index} of the render target you rendered into. */
    renderTargetIndex: number;
    /** Monotonic presentation timestamp, in nanoseconds. Must increase per frame. */
    timestampNs: number;
    /** Clockwise rotation at delivery, in degrees. Defaults to `0`. */
    rotation?: 0 | 90 | 180 | 270;
    /**
     * Optional GPU completion fence: provide it when the frame's GPU work may not
     * be finished, so the encoder waits for your draw. Omit for CPU-filled or
     * already-finished frames.
     */
    fence?: CustomVideoFrameFence;
}

/** Frame arguments for {@link forwardFrame} (forwarding mode). */
export interface ForwardFrameArgs {
    /**
     * Pointer to the native buffer to forward, as a `bigint` — a retainable,
     * IOSurface-backed `CVPixelBufferRef` (iOS) or `AHardwareBuffer*` (Android). The
     * SDK retains it for the duration of encoding, so you may release/dispose your
     * own reference immediately after this call returns.
     */
    nativeBuffer: bigint;
    /**
     * Optional monotonic presentation timestamp, in nanoseconds. A raw buffer
     * pointer carries no timestamp, so when omitted the native layer stamps the
     * frame with a monotonic clock at delivery. Pass the source's real capture
     * timestamp only when you need tight A/V sync with a separate audio track.
     */
    timestampNs?: number;
    /** Clockwise rotation at delivery, in degrees. Defaults to `0`. */
    rotation?: 0 | 90 | 180 | 270;
}

/**
 * Allocate a pool of native surfaces to render into (render-target mode).
 *
 * Call once, import every surface in {@link CustomVideoRenderTargetPool.renderTargets}
 * into your GPU, then attach the pool to a source with {@link createRenderTargetSource}.
 * You own the pool: free it with {@link CustomVideoRenderTargetPool.dispose} after the
 * source stops.
 *
 * @param init Pool dimensions and size; see {@link CustomVideoRenderTargetPoolInit}.
 */
export async function createCustomVideoRenderTargetPool(
    init: CustomVideoRenderTargetPoolInit,
): Promise<CustomVideoRenderTargetPool> {
    validatePoolInit(init);

    let data: BridgeRenderTargetPool;
    try {
        data = await WebRTCModule.createCustomVideoRenderTargetPool(init);
    } catch (error) {
        throw new MediaStreamError(error);
    }

    // The bridge carries each surface handle as a decimal string; expose it as a
    // bigint, the public type the GPU import path consumes.
    const renderTargets: CustomVideoRenderTarget[] = data.renderTargets.map((renderTarget) => ({
        index: renderTarget.index,
        surfaceHandle: BigInt(renderTarget.surfaceHandle),
        width: renderTarget.width,
        height: renderTarget.height,
    }));

    let disposed = false;
    return {
        poolId: data.poolId,
        renderTargets,
        async dispose() {
            if (disposed) {
                return;
            }
            // Latch only after the native release succeeds: a rejected release
            // (e.g. the bound source is still live) must stay retryable.
            await WebRTCModule.releaseCustomVideoRenderTargetPool(data.poolId);
            disposed = true;
        },
    };
}

// Create the backing native video track and resolve its hop-free push channel.
// Shared by both source factories; not exported.
async function createBackingTrack(
    poolId?: string,
): Promise<{ stream: MediaStream; trackId: string; pushChannel: CustomVideoPushChannel }> {
    await ensureInstalled();

    let data: BridgeCustomVideoTrack;
    try {
        data = await WebRTCModule.createCustomVideoSource({ poolId });
    } catch (error) {
        throw new MediaStreamError(error);
    }

    const { streamId, track } = data;
    const stream = new MediaStream({
        streamId,
        streamReactTag: streamId,
        tracks: [track],
    });

    const pushChannel = global.__fishjamWebrtcGetCustomVideoPushChannel!(track.id);
    return { stream, trackId: track.id, pushChannel };
}

/**
 * Create a **forwarding** custom video source: you forward finished native buffers
 * with {@link forwardFrame}.
 *
 * Returns the {@link MediaStream} to publish plus a worklet-serializable
 * {@link ForwardSink}.
 *
 * New Architecture only: rejects with a clear error on the old architecture.
 */
export async function createForwardingSource(): Promise<CustomVideoSourceResult<ForwardSink>> {
    const { stream, trackId, pushChannel } = await createBackingTrack();
    const sink: ForwardSink = { kind: 'forward', trackId, pushChannel };
    return { stream, sink };
}

/**
 * Create a **render-target** custom video source over a pool you allocated: you
 * render into the pool's surfaces and submit each frame by index with
 * {@link renderFrame}. The pool binds to exactly one source — attaching an
 * already-used or disposed pool rejects.
 *
 * Returns the {@link MediaStream} to publish plus a worklet-serializable
 * {@link RenderSink}.
 *
 * New Architecture only: rejects with a clear error on the old architecture.
 *
 * @param init The render-target pool from {@link createCustomVideoRenderTargetPool}.
 */
export async function createRenderTargetSource(init: {
    pool: CustomVideoRenderTargetPool;
}): Promise<CustomVideoSourceResult<RenderSink>> {
    // Validate the pool eagerly so a malformed call fails with a clear error instead
    // of a TypeError deep in the bridge.
    if (typeof init?.pool?.poolId !== 'string') {
        throw invalidInitError(
            'createRenderTargetSource: init.pool must be a pool returned by createCustomVideoRenderTargetPool.',
        );
    }

    const { stream, trackId, pushChannel } = await createBackingTrack(init.pool.poolId);
    const sink: RenderSink = { kind: 'render', trackId, pushChannel };
    return { stream, sink };
}

/**
 * Hand a rendered frame to a **render-target** source for encoding.
 *
 * Call once per frame, after rendering into the render target named by
 * {@link RenderFrameArgs.renderTargetIndex}. Worklet-safe: it dispatches
 * synchronously to native on whatever thread you call it from (a frame-processor
 * worklet or the JS thread). Provide a {@link RenderFrameArgs.fence} when the GPU
 * work may still be in flight, or omit it to deliver immediately.
 */
export function renderFrame(sink: RenderSink, frame: RenderFrameArgs): void {
    'worklet';
    sink.pushChannel.push(frame);
}

/**
 * Forward a finished native buffer to a **forwarding** source.
 *
 * Call once per frame with a retainable IOSurface-backed `CVPixelBufferRef` /
 * `AHardwareBuffer*` pointer (see {@link ForwardFrameArgs.nativeBuffer}). Worklet-safe:
 * it dispatches synchronously to native on whatever thread you call it from, and the
 * SDK retains the buffer before returning, so you may release/dispose your own
 * reference immediately after.
 */
export function forwardFrame(sink: ForwardSink, frame: ForwardFrameArgs): void {
    'worklet';
    sink.pushChannel.push(frame);
}
