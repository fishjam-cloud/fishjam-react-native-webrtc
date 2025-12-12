package com.oney.WebRTCModule;

import androidx.fragment.app.Fragment;

import java.lang.ref.WeakReference;
import java.util.UUID;

/**
 * A headless Fragment that listens for Picture-in-Picture mode changes
 * and notifies the WebRTCView.
 */
public class PIPHelperFragment extends Fragment {
    private final String fragmentId;
    private final WeakReference<WebRTCView> webRTCViewRef;

    /**
     * Required public no-argument constructor for fragment recreation.
     * After process death, webRTCView will be null and callbacks become no-ops.
     */
    public PIPHelperFragment() {
        this.webRTCViewRef = new WeakReference<>(null);
        this.fragmentId = "PIPHelperFragment_orphaned";
    }

    public PIPHelperFragment(WebRTCView webRTCView) {
        this.webRTCViewRef = new WeakReference<>(webRTCView);
        this.fragmentId = "PIPHelperFragment_" + UUID.randomUUID().toString();
    }

    public String getFragmentId() {
        return fragmentId;
    }

    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode);

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            return;
        }

        if (isInPictureInPictureMode) {
            webRTCView.onPipEnter();
        } else {
            webRTCView.onPipExit();
        }
    }
}
