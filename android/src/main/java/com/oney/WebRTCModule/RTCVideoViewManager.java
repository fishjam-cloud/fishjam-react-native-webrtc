package com.oney.WebRTCModule;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.annotations.ReactProp;
import com.facebook.react.uimanager.events.RCTEventEmitter;

import java.util.HashMap;
import java.util.Map;

public class RTCVideoViewManager extends SimpleViewManager<WebRTCView> {
    private static final String REACT_CLASS = "RTCVideoView";
    private static final String TAG = WebRTCModule.TAG;

    // Command constants for PIP
    private static final int COMMAND_START_PIP = 1;
    private static final int COMMAND_STOP_PIP = 2;

    @Override
    public String getName() {
        return REACT_CLASS;
    }

    @Override
    public WebRTCView createViewInstance(ThemedReactContext context) {
        return new WebRTCView(context);
    }

    /**
     * Sets the indicator which determines whether a specific {@link WebRTCView}
     * is to mirror the video specified by {@code streamURL} during its rendering.
     * For more details, refer to the documentation of the {@code mirror} property
     * of the JavaScript counterpart of {@code WebRTCView} i.e. {@code RTCView}.
     *
     * @param view The {@code WebRTCView} on which the specified {@code mirror} is
     * to be set.
     * @param mirror If the specified {@code WebRTCView} is to mirror the video
     * specified by its associated {@code streamURL} during its rendering,
     * {@code true}; otherwise, {@code false}.
     */
    @ReactProp(name = "mirror")
    public void setMirror(WebRTCView view, boolean mirror) {
        view.setMirror(mirror);
    }

    /**
     * In the fashion of
     * https://www.w3.org/TR/html5/embedded-content-0.html#dom-video-videowidth
     * and https://www.w3.org/TR/html5/rendering.html#video-object-fit, resembles
     * the CSS style {@code object-fit}.
     *
     * @param view The {@code WebRTCView} on which the specified {@code objectFit}
     * is to be set.
     * @param objectFit For details, refer to the documentation of the
     * {@code objectFit} property of the JavaScript counterpart of
     * {@code WebRTCView} i.e. {@code RTCView}.
     */
    @ReactProp(name = "objectFit")
    public void setObjectFit(WebRTCView view, String objectFit) {
        view.setObjectFit(objectFit);
    }

    @ReactProp(name = "streamURL")
    public void setStreamURL(WebRTCView view, String streamURL) {
        view.setStreamURL(streamURL);
    }

    /**
     * Sets the z-order of a specific {@link WebRTCView} in the stacking space of
     * all {@code WebRTCView}s. For more details, refer to the documentation of
     * the {@code zOrder} property of the JavaScript counterpart of
     * {@code WebRTCView} i.e. {@code RTCView}.
     *
     * @param view The {@code WebRTCView} on which the specified {@code zOrder} is
     * to be set.
     * @param zOrder The z-order to set on the specified {@code WebRTCView}.
     */
    @ReactProp(name = "zOrder")
    public void setZOrder(WebRTCView view, int zOrder) {
        view.setZOrder(zOrder);
    }

    /**
     * Sets the callback for when video dimensions change.
     *
     * @param view The {@code WebRTCView} on which the callback is to be set.
     * @param onDimensionsChange The callback to be called when video dimensions change.
     */
    @ReactProp(name = "onDimensionsChange")
    public void setOnDimensionsChange(WebRTCView view, boolean onDimensionsChange) {
        view.setOnDimensionsChange(onDimensionsChange);
    }

    /**
     * Sets the PIP options for this view.
     * Note: Android PIP works at the Activity level, not the view level.
     * The actual PIP implementation needs to be handled by the containing Activity.
     *
     * @param view The {@code WebRTCView} on which the PIP options are to be set.
     * @param pipOptions The PIP options map containing:
     *                   - enabled: boolean
     *                   - startAutomatically: boolean
     *                   - stopAutomatically: boolean
     *                   - preferredSize: { width: number, height: number }
     */
    @ReactProp(name = "pip")
    public void setPIP(WebRTCView view, @Nullable ReadableMap pipOptions) {
        // Android PIP is handled at the Activity level, not the view level.
        // The actual PIP implementation needs to be handled by the containing Activity.
        if (pipOptions != null) {
            Log.d(TAG, "pip prop set - Android PIP is handled at Activity level");
        }
    }

    @Override
    public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
        Map<String, Object> eventTypeConstants = new HashMap<>();
        Map<String, String> dimensionsChangeEvent = new HashMap<>();
        dimensionsChangeEvent.put("registrationName", "onDimensionsChange");
        eventTypeConstants.put("onDimensionsChange", dimensionsChangeEvent);
        return eventTypeConstants;
    }

    @Nullable
    @Override
    public Map<String, Integer> getCommandsMap() {
        Map<String, Integer> commands = new HashMap<>();
        commands.put("startPIP", COMMAND_START_PIP);
        commands.put("stopPIP", COMMAND_STOP_PIP);
        return commands;
    }

    @Override
    public void receiveCommand(@NonNull WebRTCView view, String commandId, @Nullable ReadableArray args) {
        int commandIdInt = Integer.parseInt(commandId);
        receiveCommand(view, commandIdInt, args);
    }

    @Override
    public void receiveCommand(@NonNull WebRTCView view, int commandId, @Nullable ReadableArray args) {
        switch (commandId) {
            case COMMAND_START_PIP:
                startPIP(view);
                break;
            case COMMAND_STOP_PIP:
                stopPIP(view);
                break;
            default:
                Log.w(TAG, "Unknown command: " + commandId);
                break;
        }
    }

    /**
     * Starts Picture-in-Picture mode.
     * Note: Android PIP works at the Activity level, not the view level.
     * The actual PIP implementation needs to be handled by the containing Activity.
     *
     * @param view The {@code WebRTCView} for which PIP should be started.
     */
    private void startPIP(WebRTCView view) {
        // Android PIP is handled at the Activity level, not the view level.
        // The actual PIP implementation needs to be handled by the containing Activity.
        Log.d(TAG, "startPIP called - Android PIP is handled at Activity level");
    }

    /**
     * Stops Picture-in-Picture mode.
     * Note: Android PIP works at the Activity level, not the view level.
     * The actual PIP implementation needs to be handled by the containing Activity.
     *
     * @param view The {@code WebRTCView} for which PIP should be stopped.
     */
    private void stopPIP(WebRTCView view) {
        // Android PIP is handled at the Activity level, not the view level.
        // The actual PIP implementation needs to be handled by the containing Activity.
        Log.d(TAG, "stopPIP called - Android PIP is handled at Activity level");
    }
}
