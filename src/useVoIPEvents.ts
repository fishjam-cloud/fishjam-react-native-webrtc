import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';

import { addListener, removeListener } from './EventEmitter';
import { getVoipToken } from './PushKit';
import { useCallKitEvent } from './useCallKit';

// If you don't provide displayName it will default to incoming call, isVideo to false
export type VoipIncomingPayload = {
    roomName: string;
    displayName: string;
    isVideo: boolean;
};

export type VoIPEventHandlers = {
    onIncoming?: (payload: VoipIncomingPayload) => void;
    onAnswered?: () => void;
    onEnded?: () => void;
    onRegistered?: (token: string) => void;
};

const assertRoomName = (raw: unknown): string => {
    if (!raw || typeof raw !== 'object') {
        throw new Error('VoIP incoming payload must be an object');
    }

    const dict = raw as Record<string, unknown>;
    const roomName = dict.roomName as string;
    if (typeof roomName !== 'string' || roomName.trim() === '') {
        throw new Error('VoIP incoming payload missing roomName');
    }
    return roomName;
};

const useVoIPEventsIos = (handlers: VoIPEventHandlers): void => {
    // Keep the latest handlers in a ref so the subscription stays stable across
    // renders even when callers pass an inline object.
    const handlersRef = useRef(handlers);
    handlersRef.current = handlers;
    const listener = useRef({});

    useCallKitEvent('answer', () => handlersRef.current.onAnswered?.());
    useCallKitEvent('ended', () => handlersRef.current.onEnded?.());

    useEffect(() => {
        // PushKit events (registered / incoming) arrive on the VoIP push channel.
        addListener(listener.current, 'voipPushEvent', (event) => {
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
                assertRoomName(payload.incoming);

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
            removeListener(listener.current);
        };
    }, []);
};

const emptyFunction = () => {};

export const useVoIPEvents = Platform.select({
    ios: useVoIPEventsIos,
    default: emptyFunction,
}) as typeof useVoIPEventsIos;
