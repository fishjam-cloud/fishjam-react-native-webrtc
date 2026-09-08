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

    /** Never null: a failed hop becomes the {@code E_ATTACH_FAILED} code. */
    @DoNotStrip
    private CameraFrameTapAttachment attachCameraFrameTap(String trackId) {
        try {
            return runOnExecutor(() -> getUserMediaImpl.attachCameraFrameTap(trackId));
        } catch (Exception e) {
            Log.w(TAG, "Attaching the camera frame tap to track " + trackId + " failed", e);
            return CameraFrameTapAttachment.failed("E_ATTACH_FAILED");
        }
    }

    @DoNotStrip
    private CameraFrameTapProcessor getCameraFrameTap(String trackId) {
        try {
            return runOnExecutor(() -> getUserMediaImpl.getCameraFrameTap(trackId));
        } catch (Exception e) {
            Log.w(TAG, "Looking up the camera frame tap of track " + trackId + " failed", e);
            return null;
        }
    }

    /**
     * Stays no-throw: a failure here would surface inside JS teardown, where nothing can act on
     * it. It is logged as an error instead, since a tap left on the source keeps blitting.
     */
    @DoNotStrip
    private void detachCameraFrameTap(String trackId) {
        try {
            runOnExecutor(() -> {
                getUserMediaImpl.detachCameraFrameTap(trackId);
                return null;
            });
        } catch (Exception e) {
            Log.e(TAG, "Detaching the camera frame tap from track " + trackId + " failed", e);
        }
    }

    private <T> T runOnExecutor(Callable<T> callable) throws Exception {
        return ThreadUtils.submitToExecutor(callable).get(EXECUTOR_TIMEOUT_SECONDS, TimeUnit.SECONDS);
    }

    @DoNotStrip
    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    @DoNotStrip
    private native void installNative();
}
