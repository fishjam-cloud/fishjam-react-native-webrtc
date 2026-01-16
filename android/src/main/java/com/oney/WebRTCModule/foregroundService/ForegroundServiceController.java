package com.oney.WebRTCModule.foregroundService;

import android.Manifest;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;

import androidx.core.content.ContextCompat;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.ReactApplicationContext;
import com.oney.WebRTCModule.WebRTCModuleOptions;

import java.util.ArrayList;
import java.util.List;

public class ForegroundServiceController {
    private final ReactApplicationContext reactContext;

    public ForegroundServiceController(ReactApplicationContext reactContext) {
        this.reactContext = reactContext;
    }

    public void start(ReadableMap config, Promise promise) {
        boolean enableCamera = config.hasKey("enableCamera") && config.getBoolean("enableCamera");
        boolean enableMicrophone = config.hasKey("enableMicrophone") && config.getBoolean("enableMicrophone");
        boolean enableScreenSharing = config.hasKey("enableScreenSharing") && config.getBoolean("enableScreenSharing");

        String channelId = config.hasKey("channelId")
                ? config.getString("channelId")
                : "com.fishjam.foregroundservice.channel";
        String channelName = config.hasKey("channelName")
                ? config.getString("channelName")
                : "Fishjam Notifications";
        String notificationTitle = config.hasKey("notificationTitle")
                ? config.getString("notificationTitle")
                : "[PLACEHOLDER] Tap to return to the call.";
        String notificationContent = config.hasKey("notificationContent")
                ? config.getString("notificationContent")
                : "[PLACEHOLDER] Your video call is ongoing";

        int[] foregroundServiceTypes = buildForegroundServiceTypes(enableCamera, enableMicrophone);
        if (foregroundServiceTypes.length == 0) {
            stop(promise);
            return;
        }

        WebRTCModuleOptions options = WebRTCModuleOptions.getInstance();
        options.enableMediaProjectionService = enableScreenSharing;

        Intent serviceIntent = new Intent(reactContext, WebRTCForegroundService.class);
        serviceIntent.putExtra("channelId", channelId);
        serviceIntent.putExtra("channelName", channelName);
        serviceIntent.putExtra("notificationTitle", notificationTitle);
        serviceIntent.putExtra("notificationContent", notificationContent);
        serviceIntent.putExtra("foregroundServiceTypes", foregroundServiceTypes);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            reactContext.startForegroundService(serviceIntent);
        } else {
            reactContext.startService(serviceIntent);
        }

        promise.resolve(null);
    }

    public void stop(Promise promise) {
        Intent serviceIntent = new Intent(reactContext, WebRTCForegroundService.class);
        reactContext.stopService(serviceIntent);
        promise.resolve(null);
    }

    private int[] buildForegroundServiceTypes(
            boolean enableCamera,
            boolean enableMicrophone) {
        List<Integer> serviceTypes = new ArrayList<>();

        if (enableCamera && hasPermission(Manifest.permission.CAMERA)) {
            serviceTypes.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA);
        }
        if (enableMicrophone && hasPermission(Manifest.permission.RECORD_AUDIO)) {
            serviceTypes.add(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        }

        int[] result = new int[serviceTypes.size()];
        for (int i = 0; i < serviceTypes.size(); i++) {
            result[i] = serviceTypes.get(i);
        }
        return result;
    }

    private boolean hasPermission(String permission) {
        return ContextCompat.checkSelfPermission(reactContext, permission)
                == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }
}
