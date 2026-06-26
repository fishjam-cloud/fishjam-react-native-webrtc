package com.oney.WebRTCModule;

import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;

import org.webrtc.VideoCapturer;
import org.webrtc.VideoSource;

/**
 * Capturer-less video capture controller for the Android custom-video-track:
 * the app renders frames on the GPU into AHardwareBuffer (AHB) backed surfaces
 * instead of a camera/screen {@link VideoCapturer} producing them.
 *
 * <p>It owns an AHB pool allocated with
 * {@code GPU_FRAMEBUFFER | GPU_SAMPLED_IMAGE} so JS/WebGPU can import each buffer
 * (by {@code surfaceHandle}) and render into it. {@link #pushFrame} hands each
 * app-rendered AHB to a {@link CustomVideoFrameDelivery}, which imports it as a
 * GL OES texture, waits a sync-fd GPU fence, wraps it in a
 * {@code TextureBufferImpl}/{@code VideoFrame}, and feeds the {@link VideoSource}'s
 * {@code CapturerObserver}.
 *
 * <p>It extends {@link AbstractVideoCaptureController} purely so it slots into the
 * existing {@code GetUserMediaImpl.TrackPrivate} lifecycle ({@code getSettings()},
 * {@code stopCapture()}, {@code dispose()}). It has no real {@link VideoCapturer},
 * so the capturer-driven base methods are overridden.
 */
class CustomVideoCaptureController extends AbstractVideoCaptureController {
    private static final String TAG = WebRTCModule.TAG;

    /**
     * Native {@code AHardwareBuffer*} handles (as {@code long}s), index-stable for
     * the lifetime of the controller. JS imports each handle exactly once (by its
     * {@code index}) and renders into it forever after.
     */
    private final long[] bufferHandles;
    private boolean disposed = false;

    /**
     * Delivers pushed frames into WebRTC (AHB&nbsp;→&nbsp;OES texture&nbsp;→&nbsp;
     * {@code VideoFrame}, gated by a sync-fd fence). Created in
     * {@link #attachVideoSource(VideoSource)} once the capturer-less
     * {@link VideoSource} exists, since delivery targets its {@code CapturerObserver}.
     * Null until attached.
     */
    private CustomVideoFrameDelivery frameDelivery;

    /**
     * @param width    pixel width of every AHB.
     * @param height   pixel height of every AHB.
     * @param poolSize number of AHBs to pre-allocate (max frames in flight).
     * @throws IllegalArgumentException if width/height/poolSize are not positive.
     * @throws RuntimeException         if any AHB allocation fails.
     */
    CustomVideoCaptureController(int width, int height, int poolSize) {
        // fps is irrelevant for an app-pushed track; reuse width/height as the
        // target/actual dimensions so getSettings() reports the real size.
        super(width, height, /* fps */ 0);

        if (width <= 0 || height <= 0 || poolSize <= 0) {
            throw new IllegalArgumentException("width, height and poolSize must all be positive");
        }

        bufferHandles = new long[poolSize];
        for (int index = 0; index < poolSize; index++) {
            long handle = AHardwareBufferPool.allocateFramebufferAHB(width, height);
            if (handle == 0) {
                // Release whatever we already allocated before bailing out.
                for (int released = 0; released < index; released++) {
                    AHardwareBufferPool.releaseAHB(bufferHandles[released]);
                    bufferHandles[released] = 0;
                }
                throw new RuntimeException(
                        "AHardwareBuffer allocation failed at index " + index + " (" + width + "x" + height + ")");
            }
            bufferHandles[index] = handle;
        }
    }

    /**
     * Builds the JS-facing buffer descriptors, one per AHB, in index order.
     * Shape matches iOS and the {@code createCustomVideoTrack.ts} contract:
     * {@code { index, surfaceHandle: String(handle), width, height }}. The handle
     * is a decimal string of the {@code AHardwareBuffer*} so a 64-bit pointer
     * survives JS; convert with {@code BigInt(surfaceHandle)} before
     * {@code device.importSharedTextureMemory({ handle })}.
     */
    WritableArray getBufferDescriptors() {
        WritableArray descriptors = Arguments.createArray();
        for (int index = 0; index < bufferHandles.length; index++) {
            WritableMap descriptor = Arguments.createMap();
            descriptor.putInt("index", index);
            descriptor.putString("surfaceHandle", Long.toString(bufferHandles[index]));
            descriptor.putInt("width", getWidth());
            descriptor.putInt("height", getHeight());
            descriptors.pushMap(descriptor);
        }
        return descriptors;
    }

    /**
     * Wires this controller to the capturer-less {@link VideoSource} created by
     * {@link GetUserMediaImpl#createCustomVideoTrack}. Builds the
     * {@link CustomVideoFrameDelivery} that imports the AHBs and ships frames into
     * the source. Must be called before {@link #startCapture()}.
     */
    void attachVideoSource(VideoSource videoSource) {
        if (frameDelivery != null) {
            return;
        }
        frameDelivery = new CustomVideoFrameDelivery(videoSource, bufferHandles, getWidth(), getHeight());
    }

    /**
     * Pushes one app-rendered frame for delivery into WebRTC. Fire-and-forget.
     *
     * @param bufferIndex        pool index of the AHB the app rendered into.
     * @param fenceHandle        the exported GPU fence handle. On Android this is a
     *                           {@code sync-fd} file descriptor
     *                           ({@code GPUSharedFence.export()} →
     *                           {@code {type:'sync-fd', handle: fd}}). {@code 0} (or
     *                           a non-positive fd) means the no-fence fallback
     *                           (deliver immediately).
     * @param fenceSignaledValue unused on Android (the sync-fd already encodes the
     *                           signal); kept for parity with the shared JSI
     *                           contract / iOS.
     * @param timestampNs        frame presentation timestamp in nanoseconds.
     * @param rotation           frame rotation in degrees (0/90/180/270).
     */
    void pushFrame(int bufferIndex, long fenceHandle, long fenceSignaledValue, long timestampNs, int rotation) {
        if (frameDelivery == null) {
            Log.w(TAG, "pushFrame before attachVideoSource; dropping frame");
            return;
        }
        frameDelivery.pushFrame(bufferIndex, fenceFdFromHandle(fenceHandle), timestampNs, rotation);
    }

    /**
     * Maps the JSI-resolved fence handle (a sync-fd carried as a 64-bit value) to
     * an fd. Returns -1 for the no-fence fallback ({@code 0}, negative, or beyond
     * the {@code int} fd range). The fd's ownership then transfers to
     * {@link CustomVideoFrameDelivery}/EGL.
     */
    private static int fenceFdFromHandle(long fenceHandle) {
        return fenceHandle > 0 && fenceHandle <= Integer.MAX_VALUE ? (int) fenceHandle : -1;
    }

    @Override
    public String getDeviceId() {
        return "custom-video";
    }

    @Override
    public WritableMap getSettings() {
        WritableMap settings = Arguments.createMap();
        settings.putString("deviceId", getDeviceId());
        settings.putString("groupId", "");
        settings.putInt("width", getWidth());
        settings.putInt("height", getHeight());
        return settings;
    }

    // There is no real VideoCapturer for an app-pushed track.
    @Override
    protected VideoCapturer createVideoCapturer() {
        return null;
    }

    @Override
    public void initializeVideoCapturer() {
        // No-op: frames are pushed by the app, not pulled from a capturer.
    }

    @Override
    public void startCapture() {
        // Begin accepting app-pushed frames. There is no real capturer to start;
        // frames arrive via pushFrame() and are delivered by frameDelivery.
        if (frameDelivery != null) {
            frameDelivery.start();
        }
    }

    @Override
    public boolean stopCapture() {
        // Stop accepting and drain in-flight frames, then free the GL import
        // resources (EGLImages/OES textures) and the GL thread. Report success so
        // TrackPrivate proceeds to dispose().
        if (frameDelivery != null) {
            frameDelivery.release();
        }
        return true;
    }

    @Override
    public void dispose() {
        if (disposed) {
            return;
        }
        disposed = true;
        // Safety net: stopCapture normally releases delivery; release() is idempotent.
        if (frameDelivery != null) {
            frameDelivery.release();
            frameDelivery = null;
        }
        for (int index = 0; index < bufferHandles.length; index++) {
            if (bufferHandles[index] != 0) {
                AHardwareBufferPool.releaseAHB(bufferHandles[index]);
                bufferHandles[index] = 0;
            }
        }
    }
}
