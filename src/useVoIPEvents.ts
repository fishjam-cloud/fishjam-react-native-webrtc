import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import { getVoipToken } from './PushKit';

export type VoipIncomingPayload = { roomName: string; displayName: string };

export type VoIPEventHandlers = {
    onIncoming?: (payload: VoipIncomingPayload) => void;
    onAnswered?: () => void;
    onEnded?: () => void;
    onRegistered?: (token: string) => void;
};

const useVoIPEventsIos = (handlers: VoIPEventHandlers): void => {
    // Keep the latest handlers in a ref so the subscription stays stable across
    // renders even when callers pass an inline object.
    const handlersRef = useRef(handlers);
    handlersRef.current = handlers;

    useEffect(() => {
        // CallKit actions (answer / ended) arrive on the CallKit channel.
        const callKitListener = {};
        addListener(callKitListener, 'callKitActionPerformed', (event) => {
            if (!event || typeof event !== 'object') {
                return;
            }
            const payload = event as Record<string, unknown>;
            if ('answer' in payload) {
                handlersRef.current.onAnswered?.();
            }
            if ('ended' in payload) {
                handlersRef.current.onEnded?.();
            }
        });

        // PushKit events (registered / incoming) arrive on the VoIP push channel.
        const voipListener = {};
        addListener(voipListener, 'voipPushEvent', (event) => {
            if (!event || typeof event !== 'object') {
                return;
            }
            const payload = event as Record<string, unknown>;
            if ('registered' in payload) {
                handlersRef.current.onRegistered?.(
                    payload.registered as string,
                );
            }
            if ('incoming' in payload) {
                handlersRef.current.onIncoming?.(
                    payload.incoming as VoipIncomingPayload,
                );
            }
        });

        // The VoIP token is usually issued before JS subscribes
        // Read the current token and deliver it to the handler on mount
        const token = getVoipToken();
        if (token) {
            handlersRef.current.onRegistered?.(token);
        }

        return () => {
            removeListener(callKitListener);
            removeListener(voipListener);
        };
    }, []);
};

const emptyFunction = () => {};

export const useVoIPEvents = Platform.select({
    ios: useVoIPEventsIos,
    default: emptyFunction,
}) as typeof useVoIPEventsIos;
