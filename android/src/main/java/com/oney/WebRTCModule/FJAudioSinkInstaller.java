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

    private native HybridData initHybrid(CallInvokerHolderImpl callInvokerHolder);

    private native void installSink();

    private native boolean isInstalled();
}
