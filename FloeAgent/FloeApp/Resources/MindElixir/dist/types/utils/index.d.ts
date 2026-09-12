import type { Topic } from '../types/dom';
import type { NodeObj, MindElixirInstance, NodeObjExport } from '../types/index';
export declare function encodeHTML(s: string): string;
export declare const isMobile: () => boolean;
export declare const getObjById: (id: string, data: NodeObj) => NodeObj | null;
/**
 * Add parent property to every node
 */
export declare const fillParent: (data: NodeObj, parent?: NodeObj) => void;
export declare const setExpand: (node: NodeObj, isExpand: boolean, level?: number) => void;
export declare function refreshIds(data: NodeObj): void;
export declare const throttle: <T extends (...args: never[]) => void>(fn: T, wait: number) => (...args: Parameters<T>) => void;
export declare function getArrowPoints(p3x: number, p3y: number, p4x: number, p4y: number): {
    x1: number;
    y1: number;
    x2: number;
    y2: number;
};
export declare function generateUUID(): string;
export declare const generateNewObj: (this: MindElixirInstance) => NodeObjExport;
export declare function deepClone<T>(obj: T): T;
export declare const getOffsetLT: (parent: HTMLElement, child: HTMLElement) => {
    offsetLeft: number;
    offsetTop: number;
};
export declare const setAttributes: (el: HTMLElement | SVGElement, attrs: {
    [key: string]: string;
}) => void;
export declare const isTopic: (target?: HTMLElement) => target is Topic;
export declare const unionTopics: (nodes: Topic[]) => Topic[];
export declare const getTranslate: (styleText: string) => {
    x: number;
    y: number;
};
export declare const on: (list: { [K in keyof GlobalEventHandlersEventMap]: {
    dom: EventTarget;
    evt: K;
    func: (this: EventTarget, ev: GlobalEventHandlersEventMap[K]) => void;
}; }[keyof GlobalEventHandlersEventMap][]) => () => void;
export declare const getDistance: (p1: {
    x: number;
    y: number;
}, p2: {
    x: number;
    y: number;
}) => number;
