package com.oney.WebRTCModule;

import android.util.Log;

import com.facebook.jni.HybridData;
import com.facebook.proguard.annotations.DoNotStrip;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.turbomodule.core.CallInvokerHolderImpl;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

/**
 * Installs the JS global {@code __fishjamWebrtcGetCameraFrameProcessor(trackId)} through
 * which the JS SDK attaches a frame consumer to a local camera track.
 *
 * <p>The native channel calls back into {@link #attachCameraFrameTap}, {@link #getCameraFrameTap}
 * and {@link #detachCameraFrameTap} on the JS thread; each hops to the module executor, which
 * owns the track registry, and waits for the result so the JS caller observes a settled state.
 */
@DoNotStrip
final class FJCameraFrameProcessorInstaller {
    private static final String TAG = FJCameraFrameProcessorInstaller.class.getSimpleName();
    private static final long EXECUTOR_TIMEOUT_SECONDS = 5;

    static {
        System.loadLibrary("webrtc-custom-video-track");
    }

    private final HybridData mHybridData;
    private final GetUserMediaImpl getUserMediaImpl;

    // Callers waiting for the JSI global to be installed. Guarded by `this`.
    private final List<Promise> pendingInstalls = new ArrayList<>();

    FJCameraFrameProcessorInstaller(ReactApplicationContext reactContext, GetUserMediaImpl getUserMediaImpl) {
        this.getUserMediaImpl = getUserMediaImpl;
        mHybridData = initHybrid((CallInvokerHolderImpl) reactContext.getJSCallInvokerHolder());
    }

    /** Installs (or re-installs after a JS reload) the JSI global, resolving {@code promise} once it exists. */
    void install(Promise promise) {
        synchronized (this) {
            pendingInstalls.add(promise);
        }
        installNative();
    }

    @DoNotStrip
    private void onInstalled() {
        List<Promise> promises;
        synchronized (this) {
            promises = new ArrayList<>(pendingInstalls);
            pendingInstalls.clear();
        }
        for (Promise promise : promises) {
            promise.resolve(true);
        }
    }

    /** Returns an empty string on success, otherwise the error code thrown to JS. */
    @DoNotStrip
    private String attachCameraFrameTap(String trackId) {
        String code = runOnExecutor(() -> getUserMediaImpl.attachCameraFrameTap(trackId));
        return code == null ? "E_ATTACH_FAILED" : code;
    }

    @DoNotStrip
    private CameraFrameTapProcessor getCameraFrameTap(String trackId) {
        return runOnExecutor(() -> getUserMediaImpl.getCameraFrameTap(trackId));
    }

    @DoNotStrip
    private void detachCameraFrameTap(String trackId) {
        runOnExecutor(() -> {
            getUserMediaImpl.detachCameraFrameTap(trackId);
            return null;
        });
    }

    private <T> T runOnExecutor(Callable<T> callable) {
        try {
            return ThreadUtils.submitToExecutor(callable).get(EXECUTOR_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (Exception e) {
            Log.w(TAG, "Camera frame tap call failed", e);
            return null;
        }
    }

    @DoNotStrip
    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    @DoNotStrip
    private native void installNative();
}
