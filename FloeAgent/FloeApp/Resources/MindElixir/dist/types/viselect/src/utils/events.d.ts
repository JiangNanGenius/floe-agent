type AnyFunction = (...arg: any) => any;
/**
 * Add event(s) to element(s).
 * @param elements DOM-Elements
 * @param events Event names
 * @param fn Callback
 * @param options Optional options
 * @return Array passed arguments
 */
export declare const on: (items: (EventTarget | undefined) | (EventTarget | undefined)[], events: string | string[], fn: AnyFunction, options?: {}) => void;
/**
 * Remove event(s) from element(s).
 * @param elements DOM-Elements
 * @param events Event names
 * @param fn Callback
 * @param options Optional options
 * @return Array passed arguments
 */
export declare const off: (items: (EventTarget | undefined) | (EventTarget | undefined)[], events: string | string[], fn: AnyFunction, options?: {}) => void;
/**
 * Simplifies a pointer / touch / mouse-event
 * @param evt
 */
export declare const simplifyEvent: (evt: any) => {
    target: HTMLElement;
    x: number;
    y: number;
};
export {};
