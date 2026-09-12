type AnyFunction = (...args: any[]) => any;
type EventMap = Record<string, AnyFunction>;
export declare class EventTarget<Events extends EventMap> {
    private readonly _listeners;
    addEventListener<K extends keyof Events>(event: K, cb: Events[K]): this;
    removeEventListener<K extends keyof Events>(event: K, cb: Events[K]): this;
    dispatchEvent<K extends keyof Events>(event: K, ...data: Parameters<Events[K]>): boolean;
    unbindAllListeners(): void;
    on: <K extends keyof Events>(event: K, cb: Events[K]) => this;
    off: <K extends keyof Events>(event: K, cb: Events[K]) => this;
    emit: <K extends keyof Events>(event: K, ...data: Parameters<Events[K]>) => boolean;
}
export {};
