package com.oney.WebRTCModule;

import androidx.fragment.app.Fragment;

import java.lang.ref.WeakReference;
import java.util.UUID;

/**
 * A headless Fragment that listens for Picture-in-Picture mode changes
 * and notifies the PIPManager.
 */
public class PIPHelperFragment extends Fragment {
    private final String fragmentId;
    private final WeakReference<PIPManager> pipManagerRef;

    /**
     * Required public no-argument constructor for fragment recreation.
     * After process death, pipManager will be null and callbacks become no-ops.
     */
    public PIPHelperFragment() {
        this.pipManagerRef = new WeakReference<>(null);
        this.fragmentId = "PIPHelperFragment_orphaned";
    }

    public PIPHelperFragment(PIPManager pipManager) {
        this.pipManagerRef = new WeakReference<>(pipManager);
        this.fragmentId = "PIPHelperFragment_" + UUID.randomUUID().toString();
    }

    public String getFragmentId() {
        return fragmentId;
    }

    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode);

        PIPManager pipManager = pipManagerRef.get();
        if (pipManager == null) {
            return;
        }

        if (isInPictureInPictureMode) {
            pipManager.onPipEnter();
        } else {
            pipManager.onPipExit();
        }
    }
}
