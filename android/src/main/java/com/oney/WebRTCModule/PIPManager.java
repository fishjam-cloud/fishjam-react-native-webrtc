package com.oney.WebRTCModule;

import android.app.PictureInPictureParams;
import android.graphics.Color;
import android.os.Build;
import android.util.Log;
import android.util.Rational;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.FrameLayout;

import androidx.annotation.RequiresApi;
import androidx.core.view.ViewCompat;
import androidx.fragment.app.FragmentActivity;

import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.UiThreadUtil;

import org.webrtc.EglBase;
import org.webrtc.RendererCommon.RendererEvents;
import org.webrtc.SurfaceViewRenderer;
import org.webrtc.VideoTrack;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;

/**
 * Manages Picture-in-Picture functionality for WebRTCView.
 * 
 * Creates a new SurfaceViewRenderer for PiP mode rather than moving the existing view,
 * which avoids manipulating React's managed view hierarchy.
 */
public class PIPManager {
    private static final String TAG = WebRTCModule.TAG;

    private final WeakReference<WebRTCView> webRTCViewRef;
    private final WeakReference<FragmentActivity> activityRef;
    private final ViewGroup rootView;

    private boolean pipEnabled = false;
    private boolean pipActive = false;
    private boolean startAutomatically = true;
    private boolean stopAutomatically = true;
    private int preferredWidth = 0;
    private int preferredHeight = 0;

    private String pipHelperFragmentTag;
    private final List<Integer> rootViewChildrenOriginalVisibility = new ArrayList<>();
    private FrameLayout pipContentContainer;
    private SurfaceViewRenderer pipSurfaceViewRenderer;
    private boolean pipRendererAttached = false;

    @RequiresApi(Build.VERSION_CODES.O)
    private PictureInPictureParams.Builder pictureInPictureParamsBuilder;

    private final RendererEvents pipRendererEvents = new RendererEvents() {
        @Override
        public void onFirstFrameRendered() {
            if (pipSurfaceViewRenderer != null) {
                pipSurfaceViewRenderer.post(() -> {
                    if (pipSurfaceViewRenderer != null) {
                        pipSurfaceViewRenderer.setBackgroundColor(Color.TRANSPARENT);
                    }
                });
            }
        }

        @Override
        public void onFrameResolutionChanged(int videoWidth, int videoHeight, int rotation) {
        }
    };

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

    public void onAttachedToWindow() {
        if (pipEnabled) {
            attachPipHelperFragment();
        }
    }

    public void onDetachedFromWindow() {
        if (pipActive) {
            onPipExit();
        }
        detachPipHelperFragment();
    }

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

    public boolean isPipEnabled() {
        return pipEnabled;
    }

    public void setStartAutomatically(boolean value) {
        this.startAutomatically = value;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            updateAutoEnterEnabled();
        }
    }

    public void setStopAutomatically(boolean value) {
        this.stopAutomatically = value;
    }

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
            return;
        }

        try {
            activity.setPictureInPictureParams(pictureInPictureParamsBuilder.build());
        } catch (IllegalStateException e) {
            Log.e(TAG, "Failed to update PiP params", e);
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    public void startPictureInPicture() {
        FragmentActivity activity = activityRef != null ? activityRef.get() : null;
        if (activity == null) {
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            return;
        }

        try {
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

    public void stopPictureInPicture() {
        // No-op on Android - PIP exits when user dismisses or expands
    }

    public void onPipEnter() {
        if (rootView == null) {
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        if (webRTCView == null) {
            return;
        }

        VideoTrack videoTrack = webRTCView.getVideoTrack();
        if (videoTrack == null) {
            return;
        }

        pipActive = true;
        hideAllRootViewChildren();

        pipContentContainer = new FrameLayout(webRTCView.getContext());
        pipContentContainer.setLayoutParams(new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ));

        pipSurfaceViewRenderer = new SurfaceViewRenderer(webRTCView.getContext());
        pipSurfaceViewRenderer.setBackgroundColor(Color.BLACK);
        pipSurfaceViewRenderer.setMirror(webRTCView.getMirror());
        pipSurfaceViewRenderer.setScalingType(webRTCView.getScalingType());

        pipContentContainer.addView(pipSurfaceViewRenderer, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ));

        rootView.addView(pipContentContainer);

        pipSurfaceViewRenderer.getViewTreeObserver().addOnGlobalLayoutListener(
            new ViewTreeObserver.OnGlobalLayoutListener() {
                @Override
                public void onGlobalLayout() {
                    if (pipSurfaceViewRenderer == null) return;
                    pipSurfaceViewRenderer.getViewTreeObserver().removeOnGlobalLayoutListener(this);
                    initializePipRenderer(webRTCView, videoTrack);
                }
            }
        );
    }

    private void initializePipRenderer(WebRTCView webRTCView, VideoTrack videoTrack) {
        if (pipSurfaceViewRenderer == null) {
            return;
        }

        EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();
        if (sharedContext == null) {
            Log.e(TAG, "Cannot create PiP renderer: no EGL context");
            return;
        }

        try {
            pipSurfaceViewRenderer.setZOrderMediaOverlay(true);
            pipSurfaceViewRenderer.init(sharedContext, pipRendererEvents);

            ThreadUtils.runOnExecutor(() -> {
                try {
                    videoTrack.addSink(pipSurfaceViewRenderer);
                    pipRendererAttached = true;
                } catch (Throwable tr) {
                    Log.e(TAG, "Failed to add PiP renderer to video track", tr);
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize PiP SurfaceViewRenderer", e);
        }
    }

    public void onPipExit() {
        if (rootView == null) {
            return;
        }

        WebRTCView webRTCView = webRTCViewRef.get();
        pipActive = false;

        if (pipSurfaceViewRenderer != null) {
            final SurfaceViewRenderer renderer = pipSurfaceViewRenderer;
            final boolean wasAttached = pipRendererAttached;

            pipRendererAttached = false;
            pipSurfaceViewRenderer = null;

            VideoTrack videoTrack = wasAttached && webRTCView != null
                ? webRTCView.getVideoTrack()
                : null;

            if (videoTrack != null) {
                ThreadUtils.runOnExecutor(() -> {
                    try {
                        videoTrack.removeSink(renderer);
                    } catch (Throwable tr) {
                    }
                    UiThreadUtil.runOnUiThread(renderer::release);
                });
            } else {
                renderer.release();
            }
        }

        if (pipContentContainer != null) {
            rootView.removeView(pipContentContainer);
            pipContentContainer = null;
        }

        restoreRootViewChildren();
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
        if (activity == null || pipHelperFragmentTag != null) {
            return;
        }

        PIPHelperFragment fragment = new PIPHelperFragment(this);
        pipHelperFragmentTag = fragment.getFragmentId();
        activity.getSupportFragmentManager()
            .beginTransaction()
            .add(fragment, pipHelperFragmentTag)
            .commitAllowingStateLoss();
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
    }

    public boolean isPipActive() {
        return pipActive;
    }
}
