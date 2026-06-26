package com.oney.WebRTCModule;

import com.facebook.jni.HybridData;
import com.facebook.proguard.annotations.DoNotStrip;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.turbomodule.core.CallInvokerHolderImpl;

import java.util.ArrayList;
import java.util.List;

/**
 * Installs the JS global {@code __fishjamWebrtcPushCustomVideoFrame(frame)} that the
 * JS SDK calls to push custom video frames.
 *
 * <p>A JSI global must be set on the JS thread with the live runtime, which a
 * React method (running on the native-modules thread) can't do directly. So we
 * pass the React {@link CallInvokerHolderImpl} down to C++ ({@link #initHybrid}),
 * and the shared native {@code FJVideoPush} hops onto the JS thread via that
 * CallInvoker, sets the global, and calls {@link #onPushInstalled()} back here.
 * The install Promise is resolved only then, so JS never observes a missing
 * global.
 *
 * <p>Every frame the global pushes is forwarded by C++ back to
 * {@link #deliverFrame} (on the JS thread), which routes it through the
 * {@link FrameRouter} supplied by {@link WebRTCModule} to the matching
 * {@link CustomVideoFrameDelivery}.
 */
@DoNotStrip
final class FJVideoPushInstaller {
    static {
        System.loadLibrary("webrtc-custom-video-track");
    }

    /** Routes one JS-pushed frame to its track's delivery engine. */
    interface FrameRouter {
        void route(
                String trackId, int bufferIndex, long timestampNs, int rotation, long fenceHandle, long fenceSignaledValue);
    }

    private final HybridData mHybridData;
    private final FrameRouter frameRouter;

    // Callers waiting for the JSI global to be installed. Guarded by `this`.
    private final List<Promise> pendingInstalls = new ArrayList<>();

    FJVideoPushInstaller(ReactApplicationContext reactContext, FrameRouter frameRouter) {
        this.frameRouter = frameRouter;
        mHybridData = initHybrid((CallInvokerHolderImpl) reactContext.getJSCallInvokerHolder());
    }

    /** Installs the JSI global, resolving {@code promise} once it is in place. */
    void install(Promise promise) {
        boolean alreadyInFlight;
        synchronized (this) {
            if (isInstalled()) {
                promise.resolve(true);
                return;
            }
            alreadyInFlight = !pendingInstalls.isEmpty();
            pendingInstalls.add(promise);
        }
        if (!alreadyInFlight) {
            installPush();
        }
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
     * Invoked from C++ on the JS thread for every frame pushed through the JSI
     * global. {@code fenceHandle} is a sync-fd ({@code 0} = no fence);
     * {@code fenceSignaledValue} is unused on Android.
     */
    @DoNotStrip
    private void deliverFrame(
            String trackId, int bufferIndex, long timestampNs, int rotation, long fenceHandle, long fenceSignaledValue) {
        frameRouter.route(trackId, bufferIndex, timestampNs, rotation, fenceHandle, fenceSignaledValue);
    }

    @DoNotStrip
    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    @DoNotStrip
    private native void installPush();

    @DoNotStrip
    private native boolean isInstalled();
}
