package com.oney.WebRTCModule;

import com.facebook.jni.HybridData;
import com.facebook.proguard.annotations.DoNotStrip;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.turbomodule.core.CallInvokerHolderImpl;

/**
 * Installs the JS global {@code __fishjamWebrtcSetAudioSink(handler)} that the
 * JS SDK uses to receive extracted audio. Android counterpart of the iOS
 * install channel.
 *
 * <p>A JSI global must be set on the JS thread with the live runtime, which a
 * React method (running on the native-modules thread) can't do directly. So we
 * pass the React {@link CallInvokerHolderImpl} down to C++ ({@link #initHybrid}),
 * and the shared native {@code FJAudioSink} hops onto the JS thread via that
 * CallInvoker, sets the global, and calls {@link #onSinkInstalled()} back here.
 * The install Promise is resolved only then, so JS never observes a missing
 * global.
 */
@DoNotStrip
final class FJAudioSinkInstaller {
    static {
        System.loadLibrary("fishjam-webrtc-audio");
    }

    private final HybridData mHybridData;

    // Set on the native-modules thread (install) and cleared on the JS thread
    // (onSinkInstalled); guarded by `this` for the cross-thread handoff.
    private Promise pendingInstall;

    FJAudioSinkInstaller(ReactApplicationContext reactContext) {
        mHybridData = initHybrid((CallInvokerHolderImpl) reactContext.getJSCallInvokerHolder());
    }

    /** Installs the JSI global, resolving {@code promise} once it is in place. */
    void install(Promise promise) {
        if (isInstalled()) {
            promise.resolve(true);
            return;
        }
        synchronized (this) {
            pendingInstall = promise;
        }
        installSink();
    }

    /** Invoked from C++ on the JS thread once the global has been set. */
    @DoNotStrip
    private void onSinkInstalled() {
        Promise promise;
        synchronized (this) {
            promise = pendingInstall;
            pendingInstall = null;
        }
        if (promise != null) {
            promise.resolve(true);
        }
    }

    /**
     * Sets (or replaces) the output config for a track's converter. The native
     * miniaudio converter is created lazily on the first {@link #onAudioData} call,
     * once the input rate/channels are known. Called on the native-modules thread.
     *
     * @param lpfOrder linear resampler low-pass filter order; pass {@code 8}
     *     (miniaudio's {@code MA_MAX_FILTER_ORDER}) for high quality, {@code 1}
     *     otherwise.
     */
    native void configureTrack(int pcId, String trackId, int outRate, int outChannels,
            boolean formatF32, int lpfOrder, double batchMs);

    /**
     * Forwards one int16 PCM chunk to the native converter. {@code audioData} must
     * be a direct {@link java.nio.ByteBuffer}; it is only valid for the duration of
     * this call, so C++ copies the bytes before returning. Called on a WebRTC audio
     * thread.
     */
    native void onAudioData(String trackId, java.nio.ByteBuffer audioData, int sampleRate,
            int channels, int frames);

    /** Tears down and removes a track's converter. Called on the native-modules thread. */
    native void removeTrack(String trackId);

    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    private native void installSink();

    private native boolean isInstalled();
}
