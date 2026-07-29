import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';

import { hasActiveCallKitSession } from './CallKit';
import { addListener, removeListener } from './EventEmitter';
import { type CallEndedReason, hasActiveTelecomCall } from './Telecom';
import {
    clearPendingCallIntent,
    clearPendingIncomingCall,
    getPendingAnswerRequestId,
    getPendingCallIntent,
    getPendingIncomingCall,
    getVoIPToken,
    type VoIPCallIntent,
} from './VoIP';
import { useCallKitEvent } from './useCallKit';

// If you don't provide displayName it will default to incoming call, isVideo to false
export type VoIPIncomingPayload = {
    roomName: string;
    displayName: string;
    /**
     * Stable id of the caller, taken from the push payload's `handle` (falls back to
     * `displayName`). On iOS this is what lands in Recents and comes back as the redial
     * intent's handle; on Android it is the call's Telecom address.
     */
    handle: string;
    isVideo: boolean;
    /**
     * Optional URL of the caller's avatar, forwarded verbatim from the push payload.
     * On Android it is downloaded and shown in the incoming-call notification and
     * full-screen UI; on iOS CallKit cannot render it, so it is provided only for
     * your own in-app UI.
     */
    avatarUrl?: string;
};

export type VoIPEventHandlers = {
    onIncoming?: (payload: VoIPIncomingPayload) => void;
    onAnswered?: (requestId: string) => void;
    onEnded?: (reason?: CallEndedReason) => void;
    onRegistered?: (token: string) => void;
    onHeldChanged?: (onHold: boolean) => void;
    onMuteChanged?: (muted: boolean) => void;
    onCallIntent?: (intent: VoIPCallIntent) => void;
    onWaitingCallDeclined?: (payload: VoIPIncomingPayload) => void;
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

    useCallKitEvent('answer', (requestId) => {
        if (requestId) {
            handlersRef.current.onAnswered?.(requestId);
        }
    });
    useCallKitEvent('ended', (reason) => {
        clearPendingIncomingCall();
        handlersRef.current.onEnded?.(reason);
    });
    useCallKitEvent('held', (onHold) => {
        handlersRef.current.onHeldChanged?.(Boolean(onHold));
    });
    useCallKitEvent('muted', (muted) => {
        handlersRef.current.onMuteChanged?.(Boolean(muted));
    });

    useEffect(() => {
        // VoIP push events (registered / incoming) arrive on the VoIP push channel.
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
                    payload.incoming as VoIPIncomingPayload,
                );
            }
            if ('waitingDeclined' in payload) {
                assertRoomName(payload.waitingDeclined);

                handlersRef.current.onWaitingCallDeclined?.(
                    payload.waitingDeclined as VoIPIncomingPayload,
                );
            }
            if ('callIntent' in payload) {
                const intent = payload.callIntent as VoIPCallIntent;
                handlersRef.current.onCallIntent?.(intent);
                clearPendingCallIntent();
            }
        });

        getVoIPToken().then((token) => {
            if (token) {
                handlersRef.current.onRegistered?.(token);
            }
        });

        const pendingCall = getPendingIncomingCall();
        if (pendingCall && hasActiveCallKitSession()) {
            try {
                assertRoomName(pendingCall);
                handlersRef.current.onIncoming?.(
                    pendingCall as unknown as VoIPIncomingPayload,
                );

                const requestId = getPendingAnswerRequestId();
                if (requestId) {
                    handlersRef.current.onAnswered?.(requestId);
                }
            } catch {
                // Ignore a malformed buffered payload.
            }
        }

        const pendingCallIntent = getPendingCallIntent();
        if (pendingCallIntent) {
            handlersRef.current.onCallIntent?.(pendingCallIntent);
            clearPendingCallIntent();
        }

        return () => {
            removeListener(listener.current);
        };
    }, []);
};

const useVoIPEventsAndroid = (handlers: VoIPEventHandlers): void => {
    const handlersRef = useRef(handlers);
    handlersRef.current = handlers;
    const listener = useRef({});

    useEffect(() => {
        addListener(listener.current, 'telecomActionPerformed', (event) => {
            if (!event || typeof event !== 'object') {
                return;
            }
            const payload = event as {
                event?: string;
                requestId?: string;
                reason?: CallEndedReason;
                held?: boolean;
                muted?: boolean;
            };
            if (payload.event === 'answer' && payload.requestId) {
                handlersRef.current.onAnswered?.(payload.requestId);
            } else if (payload.event === 'ended') {
                clearPendingIncomingCall();
                handlersRef.current.onEnded?.(payload.reason);
            } else if (
                payload.event === 'holdChanged' &&
                typeof payload.held === 'boolean'
            ) {
                handlersRef.current.onHeldChanged?.(payload.held);
            } else if (
                payload.event === 'muteChanged' &&
                typeof payload.muted === 'boolean'
            ) {
                handlersRef.current.onMuteChanged?.(payload.muted);
            }
        });

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
                    payload.incoming as VoIPIncomingPayload,
                );
            }
            if ('waitingDeclined' in payload) {
                assertRoomName(payload.waitingDeclined);

                handlersRef.current.onWaitingCallDeclined?.(
                    payload.waitingDeclined as VoIPIncomingPayload,
                );
            }
        });

        getVoIPToken().then((token) => {
            if (token) {
                handlersRef.current.onRegistered?.(token);
            }
        });

        const pendingCall = getPendingIncomingCall();
        if (pendingCall && hasActiveTelecomCall()) {
            try {
                assertRoomName(pendingCall);
                handlersRef.current.onIncoming?.(
                    pendingCall as unknown as VoIPIncomingPayload,
                );

                const requestId = getPendingAnswerRequestId();
                if (requestId) {
                    handlersRef.current.onAnswered?.(requestId);
                }
            } catch {
                // Ignore a malformed buffered payload.
            }
        }

        return () => {
            removeListener(listener.current);
        };
    }, []);
};

export const useVoIPEvents = Platform.select({
    ios: useVoIPEventsIos,
    android: useVoIPEventsAndroid,
}) as typeof useVoIPEventsIos;
