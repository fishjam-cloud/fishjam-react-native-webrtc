package com.oney.WebRTCModule;

import android.app.Notification;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.util.Random;

/**
 * This class implements an Android {@link Service}, a foreground one specifically, and it's
 * responsible for presenting an ongoing notification when a conference is in progress.
 * The service will help keep the app running while in the background.
 *
 * See: https://developer.android.com/guide/components/services
 */
public class MediaProjectionService extends Service {
    private static final String TAG = MediaProjectionService.class.getSimpleName();

    static final int NOTIFICATION_ID = new Random().nextInt(99999) + 10000;

    // Runs once the service has actually entered the foreground (after startForeground in
    // onStartCommand). MediaProjection capture must only begin after this, otherwise — with no
    // pre-existing foreground service — the projection captures a black surface.
    private static Runnable onForegroundedCallback;

    public static void launch(Context context) {
        launch(context, null);
    }

    public static void launch(Context context, Runnable onForegrounded) {
        if (!WebRTCModuleOptions.getInstance().enableMediaProjectionService) {
            Log.w(TAG, "Media projection service launch aborted. enableMediaProjectionService is false");
            // Legacy path (no dedicated media projection service): proceed immediately.
            runCallback(onForegrounded);
            return;
        }

        onForegroundedCallback = onForegrounded;

        MediaProjectionNotification.createNotificationChannel(context);
        Intent intent = new Intent(context, MediaProjectionService.class);
        ComponentName componentName;

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                componentName = context.startForegroundService(intent);
            } else {
                componentName = context.startService(intent);
            }
        } catch (RuntimeException e) {
            // Avoid crashing due to ForegroundServiceStartNotAllowedException (API level 31).
            // See: https://developer.android.com/guide/components/foreground-services#background-start-restrictions
            Log.w(TAG, "Media projection service not started", e);
            // Best effort: still attempt capture so the request doesn't hang.
            onForegroundedCallback = null;
            runCallback(onForegrounded);
            return;
        }

        if (componentName == null) {
            Log.w(TAG, "Media projection service not started");
            onForegroundedCallback = null;
            runCallback(onForegrounded);
        } else {
            Log.i(TAG, "Media projection service started");
        }
    }

    private static void runCallback(Runnable callback) {
        if (callback != null) {
            callback.run();
        }
    }

    public static void abort(Context context) {
        if (!WebRTCModuleOptions.getInstance().enableMediaProjectionService) {
            return;
        }

        Intent intent = new Intent(context, MediaProjectionService.class);
        context.stopService(intent);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification notification = MediaProjectionNotification.buildMediaProjectionNotification(this);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        // Now that the mediaProjection foreground service is running, it's safe to start capture.
        Runnable callback = onForegroundedCallback;
        onForegroundedCallback = null;
        if (callback != null) {
            callback.run();
        }

        return START_NOT_STICKY;
    }
}
