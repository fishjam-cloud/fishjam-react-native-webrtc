package com.oney.WebRTCModule;

/**
 * Thin Java front for the native AHardwareBuffer (AHB) primitives used by the
 * Android custom-video-track.
 *
 * <p>Allocates and releases AHBs that are both GPU-renderable
 * ({@code GPU_FRAMEBUFFER}) and GPU-sampleable ({@code GPU_SAMPLED_IMAGE}). The
 * allocated {@code AHardwareBuffer*} is returned as a {@code long} so JS can
 * import it via react-native-webgpu ({@code importSharedTextureMemory}) and
 * render into it; the rendered AHB is then delivered into WebRTC by
 * {@link CustomVideoFrameDelivery}.
 *
 * <p>All methods are {@code static native}; the implementation lives in
 * {@code android/src/main/cpp/ahardware_buffer_pool.cpp} and is packaged into
 * {@code libwebrtc-custom-video-track.so}. The AHardwareBuffer APIs require API
 * level 26+, so callers must reject on {@code SDK_INT < 26} before referencing
 * this class (which would otherwise trigger its {@code System.loadLibrary}).
 */
final class AHardwareBufferPool {
    static {
        System.loadLibrary("webrtc-custom-video-track");
    }

    private AHardwareBufferPool() {}

    /**
     * Allocates one RGBA8 {@code AHardwareBuffer} with
     * {@code AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER}
     * and returns the {@code AHardwareBuffer*} as a {@code long} (0 on failure).
     * The native side acquires an extra reference so the buffer outlives the
     * call; balance it with {@link #releaseAHB(long)}.
     *
     * <p>Requires API level 26+ (AHardwareBuffer APIs are
     * {@code __INTRODUCED_IN(26)}).
     *
     * @param width  pixel width.
     * @param height pixel height.
     * @return the native {@code AHardwareBuffer*} as a {@code long}, or 0.
     */
    static native long allocateFramebufferAHB(int width, int height);

    /**
     * Releases an {@code AHardwareBuffer} previously returned by
     * {@link #allocateFramebufferAHB(int, int)}. No-op when {@code handle == 0}.
     *
     * @param handle the native {@code AHardwareBuffer*} as a {@code long}.
     */
    static native void releaseAHB(long handle);
}
