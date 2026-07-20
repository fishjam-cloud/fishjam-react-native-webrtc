package com.oney.WebRTCModule;

import com.facebook.jni.HybridData;
import com.facebook.proguard.annotations.DoNotStrip;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.turbomodule.core.CallInvokerHolderImpl;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Installs the JS global {@code __fishjamWebrtcGetCustomAudioSink(trackId)} through
 * which the JS SDK obtains the per-track sink used to push custom audio samples,
 * and owns the per-track pacing schedulers that feed those samples into the
 * WebRTC external audio source in real time.
 *
 * <p>Two directions cross the JNI boundary here:
 * <ul>
 *   <li><b>Install</b> — a JSI global must be set on the JS thread with the live
 *       runtime, which a React method (native-modules thread) can't do directly.
 *       We pass the React {@link CallInvokerHolderImpl} down to C++
 *       ({@link #initHybrid}); the shared native {@code FJAudioPush} hops onto the
 *       JS thread via that CallInvoker, sets the global, and calls
 *       {@link #onPushInstalled()} back here so the Promise resolves only once the
 *       global exists.</li>
 *   <li><b>Emit</b> — each registered track's native pacing scheduler runs a feeder
 *       thread that produces one 10 ms frame at a time; C++ calls
 *       {@link #emitAudioFrame} (on that feeder thread) to hand the frame back to
 *       Java, which routes it through the {@link AudioFrameEmitter} to the matching
 *       {@code org.webrtc.ExternalAudioSource}.</li>
 * </ul>
 *
 * <p>Unlike the custom-video installer there is no per-push callback: pushes are
 * routed to the schedulers inside {@code FJAudioPush} without touching Java.
 */
@DoNotStrip
final class FJAudioPushInstaller {
    static {
        System.loadLibrary("webrtc-custom-audio-track");
    }

    /** Routes one paced 10 ms frame to its track's external audio source. */
    interface AudioFrameEmitter {
        void emit(String trackId, ByteBuffer directBuffer, int numberOfFrames);
    }

    private final HybridData mHybridData;
    private final AudioFrameEmitter audioFrameEmitter;

    // Callers waiting for the JSI global to be installed. Guarded by `this`.
    private final List<Promise> pendingInstalls = new ArrayList<>();

    FJAudioPushInstaller(ReactApplicationContext reactContext, AudioFrameEmitter audioFrameEmitter) {
        this.audioFrameEmitter = audioFrameEmitter;
        mHybridData = initHybrid((CallInvokerHolderImpl) reactContext.getJSCallInvokerHolder());
    }

    /**
     * Installs (or re-installs) the JSI global, resolving {@code promise} once it
     * is in place. Always (re)invokes the native install, never short-circuiting
     * on a cached flag: after a JS reload this installer persists while the JS
     * runtime is recreated, so the global must be re-set on the new runtime.
     * {@code FJAudioPush::install} owns idempotency, so redundant calls are
     * harmless — the first completion resolves every pending promise.
     */
    void install(Promise promise) {
        synchronized (this) {
            pendingInstalls.add(promise);
        }
        installPush();
    }

    /**
     * Creates and starts the pacing scheduler for {@code trackId}. Call after the
     * track's source has been registered with the {@link AudioFrameEmitter}, since
     * the feeder thread starts emitting (silence) immediately.
     */
    void registerTrack(String trackId, int sampleRateHz, int channelCount, int maxBufferedDurationMs) {
        nativeRegisterTrack(trackId, sampleRateHz, channelCount, maxBufferedDurationMs);
    }

    /** Stops the feeder thread and removes the scheduler. Safe for unknown ids. */
    void unregisterTrack(String trackId) {
        nativeUnregisterTrack(trackId);
    }

    /** Invoked from C++ on the JS thread once the global has been set. */
    @DoNotStrip
    private void onPushInstalled() {
        List<Promise> promises;
        synchronized (this) {
            promises = new ArrayList<>(pendingInstalls);
            pendingInstalls.clear();
        }
        for (Promise p : promises) {
            p.resolve(true);
        }
    }

    /**
     * Invoked from C++ on a scheduler feeder thread (attached to the JVM by the
     * C++ ThreadScope) for every paced 10 ms frame. {@code directBuffer} is a
     * direct ByteBuffer of interleaved signed 16-bit PCM, valid only for the
     * duration of this call. Dispatches synchronously so the buffer can be reused
     * once this returns.
     */
    @DoNotStrip
    private void emitAudioFrame(String trackId, ByteBuffer directBuffer, int numberOfFrames) {
        audioFrameEmitter.emit(trackId, directBuffer, numberOfFrames);
    }

    @DoNotStrip
    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    @DoNotStrip
    private native void installPush();

    @DoNotStrip
    private native void nativeRegisterTrack(
            String trackId, int sampleRateHz, int channelCount, int maxBufferedDurationMs);

    @DoNotStrip
    private native void nativeUnregisterTrack(String trackId);
}
