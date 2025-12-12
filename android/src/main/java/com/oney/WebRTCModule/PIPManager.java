package com.oney.WebRTCModule;

import android.app.PictureInPictureParams;
import android.os.Build;
import android.util.Log;
import android.util.Rational;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import androidx.annotation.RequiresApi;
import androidx.core.view.ViewCompat;
import androidx.fragment.app.FragmentActivity;

import com.facebook.react.bridge.ReactContext;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;

/**
 * Manages Picture-in-Picture functionality for WebRTCView.
 * This class encapsulates all PIP-related logic to minimize changes to the main WebRTCView class.
 */
public class PIPManager {
    private static final String TAG = WebRTCModule.TAG;

    private final WeakReference<WebRTCView> webRTCViewRef;
    private final WeakReference<FragmentActivity> activityRef;
    private final ViewGroup rootView;

    // PIP state
    private boolean pipEnabled = false;
    private boolean pipActive = false;
    private boolean startAutomatically = true;
    /**
     * Note: This property is stored for API consistency with iOS but has no effect on Android.
     * On Android, PIP mode exit is controlled by the system - when the user expands the PIP
     * window or returns to the app, Android automatically exits PIP mode. There is no way to
     * keep PIP active while the app is in the foreground on Android (unlike iOS where we can
     * observe UIApplicationWillEnterForegroundNotification and conditionally stop PIP).
     */
    private boolean stopAutomatically = true;
    private int preferredWidth = 0;
    private int preferredHeight = 0;

    // Fragment management
    private String pipHelperFragmentTag;

    // View state during PIP
    private final List<Integer> rootViewChildrenOriginalVisibility = new ArrayList<>();
    private FrameLayout pipContentContainer;
    private ViewGroup pipViewOriginalParent;
    private int pipViewOriginalIndex;

    @RequiresApi(Build.VERSION_CODES.O)
    private PictureInPictureParams.Builder pictureInPictureParamsBuilder;

    public PIPManager(WebRTCView webRTCView) {
        this.webRTCViewRef = new WeakReference<>(webRTCView);

        ReactContext reactContext = (ReactContext) webRTCView.getContext();
        FragmentActivity activity = (FragmentActivity) reactContext.getCurrentActivity();
        this.activityRef = new WeakReference<>(activity);

        if (activity != null) {
            View decorView = activity.getWindow().getDecorView();
            this.rootView = decorView.findViewById(android.R.id.content);
        } else {
            this.rootView = null;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pictureInPictureParamsBuilder = new PictureInPictureParams.Builder();
        }
    }

    /**
     * Called when the WebRTCView is attached to a window.
     */
    public void onAttachedToWindow() {
        if (pipEnabled) {
            attachPipHelperFragment();
        }
    }

    /**
     * Called when the WebRTCView is detached from a window.
     */
    public void onDetachedFromWindow() {
        detachPipHelperFragment();
    }

    /**
     * Sets whether this view should be shown in Picture-in-Picture mode.
     *
     * @param enabled Whether PIP is enabled for this view.
     */
    public void setPipEnabled(boolean enabled) {
        if (this.pipEnabled == enabled) {
            return;
        }
        this.pipEnabled = enabled;

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            return;
        }

        if (enabled && ViewCompat.isAttachedToWindow(webRTCView)) {
            attachPipHelperFragment();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                updateAutoEnterEnabled();
            }
        } else if (!enabled) {
            detachPipHelperFragment();
        }
    }

    /**
     * Returns whether this view should be shown in PIP mode.
     *
     * @return Whether PIP is enabled for this view.
     */
    public boolean isPipEnabled() {
        return pipEnabled;
    }

    /**
     * Sets whether PIP should start automatically when the app goes to background.
     *
     * @param value Whether to start automatically.
     */
    public void setStartAutomatically(boolean value) {
        this.startAutomatically = value;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            updateAutoEnterEnabled();
        }
    }

    /**
     * Sets whether PIP should stop automatically when the app returns to foreground.
     *
     * Note: This property is stored for API consistency with iOS but has no effect on Android.
     * On Android, PIP mode exit is controlled by the system - when the user expands the PIP
     * window or returns to the app, Android automatically exits PIP mode via
     * {@link #onPipExit()}. There is no way to keep PIP active while the app is in the
     * foreground on Android (unlike iOS where the app can observe foreground notifications
     * and conditionally stop PIP).
     *
     * @param value Whether to stop automatically (iOS-only, ignored on Android).
     */
    public void setStopAutomatically(boolean value) {
        this.stopAutomatically = value;
    }

    /**
     * Sets the preferred size for the PIP window.
     * This is used to calculate the aspect ratio for the PIP window.
     *
     * @param width The preferred width.
     * @param height The preferred height.
     */
    public void setPreferredSize(int width, int height) {
        this.preferredWidth = width;
        this.preferredHeight = height;
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private void updateAutoEnterEnabled() {
        if (pictureInPictureParamsBuilder != null && pipEnabled) {
            pictureInPictureParamsBuilder.setAutoEnterEnabled(startAutomatically);
            updatePictureInPictureParams();
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private void updatePictureInPictureParams() {
        FragmentActivity activity = activityRef != null ? activityRef.get() : null;
        if (activity == null) {
            Log.w(TAG, "Cannot update PiP params: activity reference is null");
            return;
        }

        try {
            activity.setPictureInPictureParams(pictureInPictureParamsBuilder.build());
        } catch (IllegalStateException e) {
            Log.e(TAG, "Failed to update PiP params - PiP may not be enabled in manifest", e);
        }
    }

    /**
     * Starts Picture-in-Picture mode.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    public void startPictureInPicture() {
        FragmentActivity activity = activityRef != null ? activityRef.get() : null;
        if (activity == null) {
            Log.w(TAG, "Cannot start PiP: activity reference is null");
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            Log.w(TAG, "Cannot start PiP: WebRTCView reference is null");
            return;
        }

        try {
            // Use preferred size if set, otherwise fall back to current view dimensions
            int width = preferredWidth > 0 ? preferredWidth : webRTCView.getWidth();
            int height = preferredHeight > 0 ? preferredHeight : webRTCView.getHeight();
            if (width > 0 && height > 0) {
                pictureInPictureParamsBuilder.setAspectRatio(new Rational(width, height));
            }
            activity.enterPictureInPictureMode(pictureInPictureParamsBuilder.build());
        } catch (IllegalStateException e) {
            Log.e(TAG, "Failed to enter PiP mode", e);
        }
    }

    /**
     * Stops Picture-in-Picture mode (no-op on Android, PIP exits when user dismisses or expands).
     */
    public void stopPictureInPicture() {
        Log.d(TAG, "stopPictureInPicture called - on Android, PIP exits when user dismisses or expands");
    }

    /**
     * Called by PIPHelperFragment when PIP mode is entered.
     */
    public void onPipEnter() {
        if (rootView == null) {
            Log.w(TAG, "Cannot enter PiP layout: rootView is null");
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            Log.w(TAG, "Cannot enter PiP layout: WebRTCView reference is null");
            return;
        }

        pipActive = true;
        Log.d(TAG, "PIP mode entered");

        // Hide all root view children
        hideAllRootViewChildren();

        // Create a container for the pip content
        pipContentContainer = new FrameLayout(webRTCView.getContext());
        pipContentContainer.setLayoutParams(new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ));

        // Store original parent info and move this view to our container
        pipViewOriginalParent = (ViewGroup) webRTCView.getParent();
        if (pipViewOriginalParent != null) {
            pipViewOriginalIndex = pipViewOriginalParent.indexOfChild(webRTCView);
            pipViewOriginalParent.removeView(webRTCView);
        }

        pipContentContainer.addView(webRTCView, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ));

        // Add our container to rootView
        rootView.addView(pipContentContainer);
    }

    /**
     * Called by PIPHelperFragment when PIP mode is exited.
     */
    public void onPipExit() {
        if (rootView == null) {
            Log.w(TAG, "Cannot exit PiP layout: rootView is null");
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            Log.w(TAG, "Cannot exit PiP layout: WebRTCView reference is null");
            return;
        }

        pipActive = false;
        Log.d(TAG, "PIP mode exited");

        // Remove pip content container from rootView
        if (pipContentContainer != null) {
            // Restore this view to its original parent
            pipContentContainer.removeView(webRTCView);

            if (pipViewOriginalParent != null) {
                // Restore to original position
                int index = Math.min(pipViewOriginalIndex, pipViewOriginalParent.getChildCount());
                pipViewOriginalParent.addView(webRTCView, index);
            }

            rootView.removeView(pipContentContainer);
            pipContentContainer = null;
        }

        // Restore root view children visibility
        restoreRootViewChildren();

        // Clean up references
        pipViewOriginalParent = null;
        pipViewOriginalIndex = 0;
    }

    private void hideAllRootViewChildren() {
        rootViewChildrenOriginalVisibility.clear();

        for (int i = 0; i < rootView.getChildCount(); i++) {
            View child = rootView.getChildAt(i);
            rootViewChildrenOriginalVisibility.add(child.getVisibility());
            child.setVisibility(View.GONE);
        }
    }

    private void restoreRootViewChildren() {
        for (int i = 0; i < rootViewChildrenOriginalVisibility.size() && i < rootView.getChildCount(); i++) {
            rootView.getChildAt(i).setVisibility(rootViewChildrenOriginalVisibility.get(i));
        }
        rootViewChildrenOriginalVisibility.clear();
    }

    private void attachPipHelperFragment() {
        FragmentActivity activity = activityRef != null ? activityRef.get() : null;
        if (activity == null) {
            Log.w(TAG, "Cannot attach PIP helper: activity reference is null");
            return;
        }

        if (pipHelperFragmentTag != null) {
            // Already attached
            return;
        }

        PIPHelperFragment fragment = new PIPHelperFragment(this);
        pipHelperFragmentTag = fragment.getFragmentId();
        activity.getSupportFragmentManager()
            .beginTransaction()
            .add(fragment, pipHelperFragmentTag)
            .commitAllowingStateLoss();

        Log.d(TAG, "PIP helper fragment attached");
    }

    private void detachPipHelperFragment() {
        FragmentActivity activity = activityRef != null ? activityRef.get() : null;
        if (activity == null || pipHelperFragmentTag == null) {
            return;
        }

        androidx.fragment.app.Fragment fragment =
            activity.getSupportFragmentManager().findFragmentByTag(pipHelperFragmentTag);
        if (fragment != null) {
            activity.getSupportFragmentManager()
                .beginTransaction()
                .remove(fragment)
                .commitAllowingStateLoss();
        }

        pipHelperFragmentTag = null;
        Log.d(TAG, "PIP helper fragment detached");
    }

    /**
     * Returns whether PIP mode is currently active.
     *
     * @return Whether PIP is active.
     */
    public boolean isPipActive() {
        return pipActive;
    }
}

