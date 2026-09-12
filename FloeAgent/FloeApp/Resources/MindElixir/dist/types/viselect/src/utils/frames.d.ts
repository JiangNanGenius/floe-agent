type AnyFunction = (...args: any[]) => void;
export interface Frames<F extends AnyFunction = AnyFunction> {
    next(...args: Parameters<F>): void;
    cancel(): void;
}
export declare const frames: <F extends AnyFunction>(fn: F) => Frames<F>;
export {};
