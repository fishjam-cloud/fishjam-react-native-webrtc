import { useEffect, useState } from 'react';
import { NativeModules, PermissionsAndroid, Platform } from 'react-native';

const { WebRTCModule } = NativeModules;

export type ForegroundServiceConfig = {
  enableCamera?: boolean;
  enableMicrophone?: boolean;
  enableScreenSharing?: boolean;
  channelId?: string;
  channelName?: string;
  notificationTitle?: string;
  notificationContent?: string;
};

const requestNotificationsPermission = async () => {
  try {
    const result = await PermissionsAndroid.request(
      PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS
    );
    if (result !== PermissionsAndroid.RESULTS.GRANTED) {
      console.warn(
        "Notifications permission not granted. User won't be able to see that the app is in background."
      );
    }
  } catch (err) {
    console.warn(err);
  }
};

const useForegroundServiceAndroid = ({
  enableCamera,
  enableMicrophone,
  enableScreenSharing,
  channelId,
  channelName,
  notificationContent,
  notificationTitle,
}: ForegroundServiceConfig) => {
  const [isConfigured, setIsConfigured] = useState(false);

  useEffect(() => {
    if (!isConfigured) {
      return;
    }
    WebRTCModule.startForegroundService({
      enableCamera,
      enableMicrophone,
      enableScreenSharing,
      channelId,
      channelName,
      notificationContent,
      notificationTitle,
    }).catch(console.error);
  }, [
    channelId,
    channelName,
    enableCamera,
    enableMicrophone,
    enableScreenSharing,
    isConfigured,
    notificationContent,
    notificationTitle,
  ]);

  useEffect(() => {
    const runConfiguration = async () => {
      await requestNotificationsPermission();
      setIsConfigured(true);
    };
    runConfiguration();
    return () => {
      WebRTCModule.stopForegroundService().catch(console.error);
    };
  }, []);
};

const emptyFunction = () => {};

export const useForegroundService = Platform.select({
  android: useForegroundServiceAndroid,
  default: emptyFunction,
});
