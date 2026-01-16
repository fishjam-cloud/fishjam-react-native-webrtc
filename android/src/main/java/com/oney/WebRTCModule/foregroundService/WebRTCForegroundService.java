package com.oney.WebRTCModule.foregroundService;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.Build;
import android.os.IBinder;

import androidx.core.app.NotificationCompat;

public class WebRTCForegroundService extends Service {
    private static final int FOREGROUND_SERVICE_ID = 1668;

    private final IBinder binder = new LocalBinder();

    public class LocalBinder extends Binder {
        public WebRTCForegroundService getService() {
            return WebRTCForegroundService.this;
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        restartService(intent);
        return START_NOT_STICKY;
    }

    public void restartService(Intent intent) {
        if (intent == null) {
            return;
        }

        String channelId = intent.getStringExtra("channelId");
        String channelName = intent.getStringExtra("channelName");
        String notificationTitle = intent.getStringExtra("notificationTitle");
        String notificationContent = intent.getStringExtra("notificationContent");
        int[] foregroundServiceTypesArray = intent.getIntArrayExtra("foregroundServiceTypes");

        if (channelId == null || channelName == null || notificationTitle == null || notificationContent == null) {
            return;
        }

        int foregroundServiceType = 0;
        if (foregroundServiceTypesArray != null) {
            for (int value : foregroundServiceTypesArray) {
                foregroundServiceType |= value;
            }
        }

        PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE
        );

        Notification notification = new NotificationCompat.Builder(this, channelId)
                .setContentTitle(notificationTitle)
                .setContentText(notificationContent)
                .setContentIntent(pendingIntent)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .build();

        createNotificationChannel(channelId, channelName);
        startForegroundWithNotification(notification, foregroundServiceType);
    }

    private void startForegroundWithNotification(Notification notification, int foregroundServiceType) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(FOREGROUND_SERVICE_ID, notification, foregroundServiceType);
        } else {
            startForeground(FOREGROUND_SERVICE_ID, notification);
        }
    }

    private void createNotificationChannel(String channelId, String channelName) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }

        NotificationChannel serviceChannel = new NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_HIGH
        );
        NotificationManager notificationManager = getSystemService(NotificationManager.class);
        if (notificationManager != null) {
            notificationManager.createNotificationChannel(serviceChannel);
        }
    }
}
