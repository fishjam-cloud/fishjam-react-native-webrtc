package com.oney.WebRTCModule;

import android.graphics.Matrix;
import android.os.Handler;
import android.util.Log;

import org.webrtc.EglBase;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.TextureBufferImpl;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSource;
import org.webrtc.YuvConverter;

/**
 * Delivers app-rendered {@code AHardwareBuffer} (AHB) frames into a WebRTC
 * {@link VideoSource} for the Android custom-video-track.
 *
 * <p>Waits a sync-fd GPU fence, then ships an OES-texture-backed
 * {@link VideoFrame}. libwebrtc encodes from a GL texture (not an AHB), so per
 * pooled AHB we build a {@code GL_TEXTURE_EXTERNAL_OES} texture aliasing it ONCE
 * (native: AHB&nbsp;→&nbsp;EGLImage&nbsp;→&nbsp;OES) and reuse it for every frame.
 *
 * <h2>Threading / EGL context</h2>
 * All GL work — the AHB import, the fence wait, and the {@code onFrameCaptured}
 * delivery — runs on ONE dedicated thread: the {@link SurfaceTextureHelper}
 * handler thread. We create that helper from WebRTC's root EGL context
 * ({@link EglUtils#getRootEglBaseContext()}), so its handler-thread EGL context
 * is share-linked to the root and the OES texture is visible to WebRTC's encoder
 * GL thread. The helper makes its (shared) context current on its own thread, so
 * any native call we post to {@link SurfaceTextureHelper#getHandler()} runs with
 * that context current — exactly what {@code eglCreateImageKHR} /
 * {@code glEGLImageTargetTexture2DOES} / {@code eglWaitSyncKHR} require. The same
 * handler and a {@link YuvConverter} created on it back the
 * {@link TextureBufferImpl} {@code toI420()} fallback used by the SW encoder /
 * screenshots.
 */
final class CustomVideoFrameDelivery {
    static {
        // Loads the native library backing the GL import/sync entry points below.
        System.loadLibrary("webrtc-custom-video-track");
    }

    private static final String TAG = WebRTCModule.TAG;

    private final VideoSource videoSource;
    private final int width;
    private final int height;

    /** Dedicated shared-context GL thread (handler + EGL context current on it). */
    private final SurfaceTextureHelper surfaceTextureHelper;
    private final Handler glHandler;
    /** Created on {@link #glHandler}; backs TextureBufferImpl.toI420(). */
    private YuvConverter yuvConverter;

    /** Per-pool-index AHB handles (AHardwareBuffer* as longs), index-stable. */
    private final long[] bufferHandles;
    /** Per-index cached EGLImageKHR (as long); 0 until first import. */
    private final long[] cachedEglImages;
    /** Per-index cached OES GL texture id; 0 until first import. */
    private final int[] cachedTextureIds;

    /** Lifecycle / drain bookkeeping, guarded by {@code stateLock}. */
    private final Object stateLock = new Object();
    private boolean accepting = false;
    private int inFlightCount = 0;
    /** Set by {@link #drain()}: stopped accepting and all in-flight deliveries ran. */
    private boolean drained = false;
    /** Set by {@link #releaseGlResources()}: OES textures/EGLImages freed, STH disposed. */
    private boolean glResourcesReleased = false;

    /** Identity transform: the WebGPU render already produced an upright RGBA image. */
    private static final Matrix IDENTITY_MATRIX = new Matrix();

    CustomVideoFrameDelivery(VideoSource videoSource, long[] bufferHandles, int width, int height) {
        this.videoSource = videoSource;
        this.bufferHandles = bufferHandles;
        this.width = width;
        this.height = height;
        this.cachedEglImages = new long[bufferHandles.length];
        this.cachedTextureIds = new int[bufferHandles.length];

        EglBase.Context rootContext = EglUtils.getRootEglBaseContext();
        if (rootContext == null) {
            throw new IllegalStateException("Root EGL context unavailable; cannot deliver custom video frames");
        }
        // Handler-thread EGL context is share-linked to the root, so the imported
        // OES texture is usable by WebRTC's encoder GL thread.
        this.surfaceTextureHelper = SurfaceTextureHelper.create("CustomVideoGL", rootContext);
        if (surfaceTextureHelper == null) {
            throw new IllegalStateException("SurfaceTextureHelper.create returned null");
        }
        this.glHandler = surfaceTextureHelper.getHandler();
        // YuvConverter must be created on the GL thread (it allocates GL resources).
        this.glHandler.post(() -> yuvConverter = new YuvConverter());
    }

    /** Begin accepting pushed frames. */
    void start() {
        synchronized (stateLock) {
            accepting = true;
        }
    }

    /**
     * Pushes one app-rendered frame. Fire-and-forget: schedules the import +
     * fence wait + delivery on the GL thread and returns immediately.
     *
     * @param bufferIndex pool index of the AHB the app rendered into.
     * @param fenceFd     dup'd sync-fd of the GPU render-complete fence, or -1 for
     *                    the no-fence fallback (deliver immediately). EGL takes
     *                    ownership of the fd on the GL thread.
     * @param timestampNs frame presentation timestamp in nanoseconds.
     * @param rotation    frame rotation in degrees (0/90/180/270).
     */
    void pushFrame(int bufferIndex, int fenceFd, long timestampNs, int rotation) {
        if (bufferIndex < 0 || bufferIndex >= bufferHandles.length) {
            Log.w(TAG, "pushFrame: bufferIndex " + bufferIndex + " out of range");
            closeFd(fenceFd);
            return;
        }

        // Reserve an in-flight slot only while accepting. stopCapture() synchronises
        // against this so the drain loop is guaranteed to converge.
        synchronized (stateLock) {
            if (!accepting || drained) {
                closeFd(fenceFd);
                return;
            }
            inFlightCount++;
        }

        glHandler.post(() -> {
            // The fd is owned by this Runnable until handed to nativeWaitSyncFd
            // (which transfers ownership to EGL). Track it so the error paths close
            // it exactly once and never double-close after the hand-off.
            int[] ownedFd = {fenceFd};
            try {
                deliverOnGlThread(bufferIndex, ownedFd, timestampNs, rotation);
            } catch (Throwable t) {
                Log.e(TAG, "pushFrame: delivery failed for index " + bufferIndex, t);
            } finally {
                // Close the fence fd iff it was never handed to native (import
                // failure or a throw before nativeWaitSyncFd). After hand-off
                // ownedFd[0] is -1, so this is a no-op.
                closeFd(ownedFd[0]);
                finishInFlight();
            }
        });
    }

    /** Runs entirely on the GL thread (shared EGL context current). */
    private void deliverOnGlThread(int bufferIndex, int[] ownedFd, long timestampNs, int rotation) {
        // 1. Import (once) the AHB at this index into an OES texture; reuse after.
        int textureId = cachedTextureIds[bufferIndex];
        if (textureId == 0) {
            long[] imported = nativeImportAhbToOesTexture(bufferHandles[bufferIndex]);
            if (imported == null || imported.length != 2 || imported[1] == 0) {
                Log.e(TAG, "AHB import failed for index " + bufferIndex);
                return;  // outer catch/finally closes ownedFd[0]
            }
            cachedEglImages[bufferIndex] = imported[0];
            cachedTextureIds[bufferIndex] = (int) imported[1];
            textureId = cachedTextureIds[bufferIndex];
        }

        // 2. Wait the GPU fence BEFORE the encoder samples this texture. This is a
        //    client (CPU) wait that blocks THIS GL delivery thread until the render
        //    completes, so the texture is gated for the encoder's separate context
        //    too (a server-side wait would only order this context). EGL takes
        //    ownership of the fd here (<0 is a no-op), so drop our ownership
        //    immediately to avoid a double-close on any later throw.
        int fenceFd = ownedFd[0];
        ownedFd[0] = -1;
        nativeWaitSyncFd(fenceFd);

        // 3. Wrap the OES texture as a VideoFrame and deliver. The release callback
        //    is a no-op: the texture is pool-owned and reused across frames, NOT
        //    freed per frame (freed in release() on teardown). TextureBufferImpl
        //    needs the GL-thread handler + a YuvConverter on it for toI420().
        TextureBufferImpl buffer = new TextureBufferImpl(width, height,
                VideoFrame.TextureBuffer.Type.OES, textureId, IDENTITY_MATRIX, glHandler, yuvConverter,
                /* releaseCallback */ () -> {});
        VideoFrame frame = new VideoFrame(buffer, rotation, timestampNs);
        try {
            videoSource.getCapturerObserver().onFrameCaptured(frame);
        } finally {
            frame.release();  // balances TextureBufferImpl's initial +1 ref
        }
    }

    private void finishInFlight() {
        synchronized (stateLock) {
            inFlightCount--;
            if (inFlightCount <= 0) {
                stateLock.notifyAll();
            }
        }
    }

    /**
     * Full teardown: {@link #drain()} then {@link #releaseGlResources()}. Idempotent.
     *
     * <p>Used as the safety-net path. The correct custom-video teardown ordering
     * (see {@code GetUserMediaImpl.TrackPrivate.dispose}) calls the two halves
     * separately so the {@code VideoSource}/{@code VideoTrack} can be disposed
     * BETWEEN them — the encoder must be quiesced before the GL textures/AHBs are
     * freed, otherwise it samples a deleted texture / freed buffer (UAF).
     */
    void release() {
        drain();
        releaseGlResources();
    }

    /**
     * Stops accepting new pushes and blocks until every in-flight delivery runnable
     * has run, so no Runnable is still using a cached OES texture / AHB. Does NOT
     * free GL resources — call {@link #releaseGlResources()} for that, but only
     * AFTER the {@code VideoSource}/{@code VideoTrack} have been disposed so the
     * encoder is quiesced and no longer retains a delivered frame. Idempotent.
     */
    void drain() {
        synchronized (stateLock) {
            if (drained) {
                return;
            }
            accepting = false;
            drained = true;
            // Wait for armed deliveries to run and decrement inFlightCount.
            while (inFlightCount > 0) {
                try {
                    stateLock.wait();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
    }

    /**
     * Frees every cached EGLImage/OES texture on the GL thread, then disposes the
     * {@link SurfaceTextureHelper}. MUST be called after {@link #drain()} AND after
     * the encoder has been quiesced (its {@code VideoSource}/{@code VideoTrack}
     * disposed), so no encoder context can still sample the textures. Idempotent.
     */
    void releaseGlResources() {
        synchronized (stateLock) {
            if (glResourcesReleased) {
                return;
            }
            glResourcesReleased = true;
        }

        // Free GL resources on the GL thread (context current there), then dispose.
        final Object done = new Object();
        synchronized (done) {
            glHandler.post(() -> {
                for (int index = 0; index < cachedTextureIds.length; index++) {
                    if (cachedTextureIds[index] != 0 || cachedEglImages[index] != 0) {
                        nativeReleaseImportedTexture(cachedEglImages[index], cachedTextureIds[index]);
                        cachedEglImages[index] = 0;
                        cachedTextureIds[index] = 0;
                    }
                }
                if (yuvConverter != null) {
                    yuvConverter.release();
                    yuvConverter = null;
                }
                synchronized (done) {
                    done.notifyAll();
                }
            });
            try {
                done.wait();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        surfaceTextureHelper.dispose();
    }

    /**
     * Closes a fence fd that never reached native ownership (e.g. out-of-range
     * index, or pushed while not accepting). Once the fd is handed to
     * {@link #nativeWaitSyncFd(int)} it is owned/closed by native/EGL, so Java
     * must NOT also close it on those paths.
     */
    private static void closeFd(int fenceFd) {
        if (fenceFd >= 0) {
            nativeCloseFd(fenceFd);
        }
    }

    // --- Native (custom_video_gl.cpp); GL ones MUST be called on the GL thread. ---

    private static native long[] nativeImportAhbToOesTexture(long ahbHandle);

    private static native void nativeWaitSyncFd(int fenceFd);

    private static native void nativeReleaseImportedTexture(long eglImageHandle, int texId);

    /** Closes a raw fd; safe to call from any thread (no GL/EGL state touched). */
    private static native void nativeCloseFd(int fenceFd);
}
