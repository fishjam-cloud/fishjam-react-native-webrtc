package com.oney.WebRTCModule;

import com.facebook.proguard.annotations.DoNotStrip;

/**
 * Outcome of {@link GetUserMediaImpl#attachCameraFrameTap}: either the tap now installed on the
 * track, or the error code to throw to JS. Read from C++ through fbjni field accessors, so the
 * attach costs one hop to the module executor.
 */
@DoNotStrip
final class CameraFrameTapAttachment {
    /** Empty on success. */
    @DoNotStrip
    final String errorCode;

    /** Non-null exactly when {@link #errorCode} is empty. */
    @DoNotStrip
    final CameraFrameTapProcessor tap;

    private CameraFrameTapAttachment(String errorCode, CameraFrameTapProcessor tap) {
        this.errorCode = errorCode;
        this.tap = tap;
    }

    static CameraFrameTapAttachment attached(CameraFrameTapProcessor tap) {
        return new CameraFrameTapAttachment("", tap);
    }

    static CameraFrameTapAttachment failed(String errorCode) {
        return new CameraFrameTapAttachment(errorCode, null);
    }
}
