import { useEffect, useRef } from "react";
import { Platform } from "react-native";

import { addListener, removeListener } from "./EventEmitter";

export type VoipIncomingPayload = { roomId: string; username: string };

export type VoIPEvent = {
  answer?: undefined;
  ended?: undefined;
  registered?: string;
  incoming?: VoipIncomingPayload;
};

export type VoIPEventHandlers = {
  onIncoming?: (payload: VoipIncomingPayload) => void;
  onAnswered?: () => void;
  onEnded?: () => void;
  onRegistered?: (token: string) => void;
}

const useVoIPEventsIos = (handlers: VoIPEventHandlers): void => {
  const listener = useRef({});
  useEffect(() => {
      addListener(listener.current, 'callKitActionPerformed', (event) => {
          if (!event || typeof event !== 'object') {
              return;
          }
          const payload = event as VoIPEvent;
          if ('answer' in payload) {handlers.onAnswered?.();}
          if ('ended' in payload) {handlers.onEnded?.();}
          if ('registered' in payload) {handlers.onRegistered?.(payload.registered as string);}
          if ('incoming' in payload) {handlers.onIncoming?.(payload.incoming as VoipIncomingPayload);}
      });
      return () => {
          removeListener(listener.current);
      };
  }, [handlers]);
};
const emptyFunction = () => {};

export const useVoIPEvents = Platform.select({
  ios: useVoIPEventsIos,
  default: emptyFunction,
}) as typeof useVoIPEventsIos;