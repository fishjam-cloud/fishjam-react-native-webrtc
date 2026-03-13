const listeners = new Map<string, Set<(event: unknown) => void>>();

const callFromNative = (eventName: string, payload: unknown) => {
    listeners.get(eventName)?.forEach((handler) => handler(payload));
};

const ensureListenerSet = (eventName: string) => {
    if (!listeners.has(eventName)) {
        listeners.set(eventName, new Set());
    }

    return listeners.get(eventName);
};

const WebRTCModule = {
    startCallKitSession: jest.fn(),
    endCallKitSession: jest.fn(),
    hasActiveCallKitSession: false,
    audioSessionDidActivate: jest.fn(),
    audioSessionDidDeactivate: jest.fn(),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
};

export const NativeModules = {
    WebRTCModule,
};

export class NativeEventEmitter {
    module: unknown;

    constructor(module: unknown) {
        this.module = module;
    }

    addListener(eventName: string, handler: (event: unknown) => void) {
        ensureListenerSet(eventName)?.add(handler);

        return {
            remove: () => {
                listeners.get(eventName)?.delete(handler);
            },
        };
    }

    removeAllListeners(eventName?: string) {
        if (eventName) {
            listeners.delete(eventName);
            return;
        }

        listeners.clear();
    }
}

export const Platform = {
    OS: 'ios',
};

export const __mockReactNative = {
    callFromNative,
    clearListeners: () => listeners.clear(),
    WebRTCModule,
};
