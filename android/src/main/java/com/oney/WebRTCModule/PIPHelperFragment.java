package com.oney.WebRTCModule;

import androidx.fragment.app.Fragment;

import java.util.UUID;

/**
 * A headless Fragment that listens for Picture-in-Picture mode changes
 * and notifies the WebRTCView.
 */
public class PIPHelperFragment extends Fragment {
    private final String fragmentId;
    private final WebRTCView webRTCView;

    public PIPHelperFragment(WebRTCView webRTCView) {
        this.webRTCView = webRTCView;
        this.fragmentId = "PIPHelperFragment_" + UUID.randomUUID().toString();
    }

    public String getFragmentId() {
        return fragmentId;
    }

    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode);

        if (isInPictureInPictureMode) {
            webRTCView.onPipEnter();
        } else {
            webRTCView.onPipExit();
        }
    }
}
