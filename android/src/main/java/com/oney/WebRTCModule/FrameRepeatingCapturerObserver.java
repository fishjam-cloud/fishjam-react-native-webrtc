package com.oney.WebRTCModule;

import android.os.Handler;

import org.webrtc.CapturerObserver;
import org.webrtc.VideoFrame;

/**
 * A {@link CapturerObserver} decorator that re-delivers the last captured frame at a fixed
 * minimum cadence (~1 fps).
 *
 * Android's {@code ScreenCapturerAndroid} (MediaProjection / VirtualDisplay) only emits a frame
 * when the screen content actually changes — its {@code startCapture} framerate argument is
 * ignored. On a static screen no frames flow, so the encoder has no input frame to encode, and a
 * keyframe request (PLI/FIR) from a newly-joined receiver cannot be satisfied — the keyframe is
 * always attached to the *next* encoded frame. The result: late-joining WHEP/WebRTC viewers stay
 * black until the screen next changes (observed as a multi-tens-of-seconds wait that reproduces on
 * every reconnect).
 *
 * Re-delivering the most recent frame about once per second keeps a fresh frame available so the
 * encoder can always produce a keyframe on demand.
 *
 * Why a manual repeater (and not libwebrtc's built-in mechanism):
 * libwebrtc already implements exactly this as the {@code FrameCadenceAdapter} "zero-hertz" mode
 * (1 fps idle repeat — {@code kZeroHertzIdleRepeatRatePeriod = 1000ms} — plus prompt re-encode on a
 * keyframe request). However, zero-hertz only engages when the source is given
 * {@code VideoTrackSourceConstraints{min_fps == 0, max_fps > 0}}, and that signal is not reachable
 * from the Android Java API (it's an internal {@code AdaptedVideoTrackSource::ProcessConstraints}
 * call; {@code adaptOutputFormat}, {@code RtpParameters.maxFramerate} and {@code degradationPreference}
 * all feed different paths). So on Android the native repeater never turns on, and this decorator is
 * the equivalent at the one layer we control — the capturer feed. {@link #REPEAT_INTERVAL_MS} is kept
 * at 1000ms to match libwebrtc's idle cadence.
 *
 * Important implementation details:
 * - The cached frame is a memory (I420) COPY, never the capture texture. Screen capture is
 *   texture-backed and the SurfaceTexture has a single buffer; holding a texture frame blocks the
 *   capturer from delivering the next frame (which would freeze the stream on the first frame).
 * - All frame delivery and state run on the capturer's own handler thread (the same thread that
 *   calls {@link #onFrameCaptured}), so we never feed frames into the source from two threads.
 */
public class FrameRepeatingCapturerObserver implements CapturerObserver {
    private static final long REPEAT_INTERVAL_MS = 1000;
    // Throttle the (GPU readback) texture->I420 copy; a slightly-stale repeat is fine for a screen
    // that is about to go static, and this keeps the copy cost low while frames are flowing fast.
    private static final long CACHE_MIN_INTERVAL_NS = 500_000_000L; // 500ms

    private final CapturerObserver delegate;
    private final Handler handler;

    // All of the following are only ever touched on `handler`'s thread.
    private VideoFrame.Buffer lastBuffer;
    private int lastRotation;
    private long lastCacheNs;
    private boolean capturing;

    private final Runnable repeatRunnable = this::repeatLastFrame;

    /**
     * @param delegate the real observer (the VideoSource's capturer observer)
     * @param handler  the capturer's handler (e.g. {@code surfaceTextureHelper.getHandler()}); the
     *                 thread on which {@link #onFrameCaptured} is delivered.
     */
    public FrameRepeatingCapturerObserver(CapturerObserver delegate, Handler handler) {
        this.delegate = delegate;
        this.handler = handler;
    }

    @Override
    public void onCapturerStarted(boolean success) {
        handler.post(() -> capturing = success);
        delegate.onCapturerStarted(success);
    }

    @Override
    public void onCapturerStopped() {
        handler.post(() -> {
            capturing = false;
            handler.removeCallbacks(repeatRunnable);
            releaseCachedFrame();
        });
        delegate.onCapturerStopped();
    }

    @Override
    public void onFrameCaptured(VideoFrame frame) {
        // Forward the real frame immediately; never hold the capture texture.
        delegate.onFrameCaptured(frame);

        // Runs on the capturer handler thread, so no locking is needed.
        if (!capturing) {
            return;
        }

        final long now = System.nanoTime();
        if (lastBuffer == null || now - lastCacheNs >= CACHE_MIN_INTERVAL_NS) {
            // Copy to memory (I420) so we keep the content without pinning the capture texture.
            VideoFrame.Buffer i420 = frame.getBuffer().toI420();
            if (i420 != null) {
                releaseCachedFrame();
                lastBuffer = i420; // toI420() returns an already-retained buffer
                lastRotation = frame.getRotation();
                lastCacheNs = now;
            }
        }

        // A real frame just arrived — restart the idle timer.
        handler.removeCallbacks(repeatRunnable);
        handler.postDelayed(repeatRunnable, REPEAT_INTERVAL_MS);
    }

    private void repeatLastFrame() {
        if (!capturing || lastBuffer == null) {
            return;
        }
        lastBuffer.retain();
        VideoFrame repeated = new VideoFrame(lastBuffer, lastRotation, System.nanoTime());
        delegate.onFrameCaptured(repeated);
        repeated.release();

        handler.postDelayed(repeatRunnable, REPEAT_INTERVAL_MS);
    }

    private void releaseCachedFrame() {
        if (lastBuffer != null) {
            lastBuffer.release();
            lastBuffer = null;
        }
    }
}
