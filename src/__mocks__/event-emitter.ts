type EventHandler = (...args: unknown[]) => void;

export default class EventEmitter {
    private listeners: Map<string, Set<EventHandler>>;

    constructor() {
        this.listeners = new Map();
    }

    addListener(eventName: string, handler: EventHandler) {
        if (!this.listeners.has(eventName)) {
            this.listeners.set(eventName, new Set());
        }

        this.listeners.get(eventName)?.add(handler);

        return {
            remove: () => {
                this.listeners.get(eventName)?.delete(handler);
            },
        };
    }

    emit(eventName: string, ...args: unknown[]) {
        this.listeners.get(eventName)?.forEach((handler) => handler(...args));
    }
}
