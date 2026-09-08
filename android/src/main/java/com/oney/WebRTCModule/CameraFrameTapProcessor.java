package com.oney.WebRTCModule;

import android.graphics.Matrix;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;

import com.facebook.jni.HybridData;
import com.facebook.proguard.annotations.DoNotStrip;

import org.webrtc.GlRectDrawer;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;
import org.webrtc.VideoProcessor;
import org.webrtc.VideoSink;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Sits in a camera {@code VideoSource}'s {@link VideoProcessor} slot so a JSI consumer can
 * read the camera's frames without disturbing the raw track.
 *
 * <p>Every frame is forwarded to WebRTC first, exactly as it arrived. Then, if the native
 * admission core accepts it, the camera's OES texture is rendered (with the same transform
 * WebRTC's own {@code YuvConverter} applies before encoding) into an RGBA {@code
 * AHardwareBuffer} owned by the native side, which hands that buffer to the consumer. Runs
 * entirely on the {@link SurfaceTextureHelper} handler thread, whose EGL context is current.
 */
@DoNotStrip
final class CameraFrameTapProcessor implements VideoProcessor {
    private static final String TAG = CameraFrameTapProcessor.class.getSimpleName();
    private static final long RELEASE_TIMEOUT_MS = 2_000;

    static {
        System.loadLibrary("webrtc-custom-video-track");
    }

    @DoNotStrip
    private final HybridData mHybridData;

    private final CameraCaptureController captureController;
    private final Handler glHandler;
    private final Matrix verticalFlip = new Matrix();

    private VideoSink sink;
    private GlRectDrawer drawer;
    private volatile boolean released;

    CameraFrameTapProcessor(CameraCaptureController captureController, SurfaceTextureHelper surfaceTextureHelper) {
        this.captureController = captureController;
        this.glHandler = surfaceTextureHelper.getHandler();
        // Same flip YuvConverter applies: GL renders bottom-up, the consumer reads top-down.
        verticalFlip.preTranslate(0.5f, 0.5f);
        verticalFlip.preScale(1f, -1f);
        verticalFlip.preTranslate(-0.5f, -0.5f);
        mHybridData = initHybrid();
    }

    @Override
    public void onCapturerStarted(boolean success) {}

    @Override
    public void onCapturerStopped() {}

    @Override
    public void setSink(VideoSink sink) {
        this.sink = sink;
    }

    @Override
    public void onFrameCaptured(VideoFrame frame) {
        VideoSink currentSink = sink;
        if (currentSink != null) {
            currentSink.onFrame(frame);
        }
        if (released || !(frame.getBuffer() instanceof VideoFrame.TextureBuffer)) {
            return;
        }
        VideoFrame.TextureBuffer textureBuffer = (VideoFrame.TextureBuffer) frame.getBuffer();
        int width = textureBuffer.getWidth();
        int height = textureBuffer.getHeight();
        int framebuffer = beginBlit(width, height);
        if (framebuffer < 0) {
            return;
        }
        if (drawer == null) {
            drawer = new GlRectDrawer();
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
        GLES20.glViewport(0, 0, width, height);
        VideoFrameDrawer.drawTexture(drawer, textureBuffer, verticalFlip, width, height, 0, 0, width, height);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
        endBlit(frame.getRotation(), captureController.isFrontFacing(), frame.getTimestampNs());
    }

    /**
     * Frees the GL resources on the capture thread. Blocks the caller (the module executor)
     * until that ran, bounded by {@link #RELEASE_TIMEOUT_MS}. Must be called after the
     * processor was removed from the {@code VideoSource}, so no frame is being blitted.
     */
    void release() {
        released = true;
        CountDownLatch done = new CountDownLatch(1);
        boolean posted = glHandler.post(() -> {
            try {
                releaseGl();
                if (drawer != null) {
                    drawer.release();
                    drawer = null;
                }
            } finally {
                done.countDown();
            }
        });
        if (!posted) {
            return;
        }
        long deadline = SystemClock.uptimeMillis() + RELEASE_TIMEOUT_MS;
        try {
            if (!done.await(deadline - SystemClock.uptimeMillis(), TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "Timed out waiting for the capture thread to release the camera frame tap");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    @DoNotStrip
    private native HybridData initHybrid();

    @DoNotStrip
    private native int beginBlit(int width, int height);

    @DoNotStrip
    private native void endBlit(int rotationDegrees, boolean isFrontCamera, long timestampNanoseconds);

    @DoNotStrip
    private native void releaseGl();
}
