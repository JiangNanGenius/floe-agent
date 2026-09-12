import type { Arrow } from '../arrow';
import type { Summary } from '../summary';
import type { NodeObj } from '../types/index';
type NodeOperation = {
    name: 'moveNodeIn' | 'copyNode' | 'addChild' | 'insertParent' | 'insertBefore' | 'beginEdit';
    obj: NodeObj;
} | {
    name: 'insertSibling';
    type: 'before' | 'after';
    obj: NodeObj;
} | {
    name: 'reshapeNode';
    obj: NodeObj;
    origin: NodeObj;
} | {
    name: 'finishEdit';
    obj: NodeObj;
    origin: string;
} | {
    name: 'moveNodeAfter' | 'moveNodeBefore' | 'moveNodeIn';
    objs: NodeObj[];
    toObj: NodeObj;
};
type MultipleNodeOperation = {
    name: 'removeNodes';
    objs: NodeObj[];
} | {
    name: 'copyNodes';
    objs: NodeObj[];
};
export type SummaryOperation = {
    name: 'createSummary';
    obj: Summary;
} | {
    name: 'removeSummary';
    obj: {
        id: string;
    };
} | {
    name: 'finishEditSummary';
    obj: Summary;
};
export type ArrowOperation = {
    name: 'createArrow';
    obj: Arrow;
} | {
    name: 'removeArrow';
    obj: {
        id: string;
    };
} | {
    name: 'finishEditArrowLabel';
    obj: Arrow;
} | {
    name: 'reshapeArrow';
    obj: Arrow;
    origin: Arrow;
};
export type Operation = NodeOperation | MultipleNodeOperation | SummaryOperation | ArrowOperation;
export type OperationType = Operation['name'];
export type EventMap = {
    operation: (info: Operation) => void;
    selectNewNode: (nodeObj: NodeObj) => void;
    selectNodes: (nodeObj: NodeObj[]) => void;
    unselectNodes: (nodeObj: NodeObj[]) => void;
    expandNode: (nodeObj: NodeObj) => void;
    changeDirection: (direction: number) => void;
    linkDiv: () => void;
    scale: (scale: number) => void;
    move: (data: {
        dx: number;
        dy: number;
    }) => void;
    /**
     *  please use throttling to prevent performance degradation
     */
    updateArrowDelta: (arrow: Arrow) => void;
    selectArrow: (arrow: Arrow) => void;
    unselectArrow: () => void;
    selectSummary: (summary: Summary) => void;
    unselectSummary: () => void;
    showContextMenu: (e: MouseEvent) => void;
};
export declare function createBus<T extends Record<string, (...args: any[]) => void> = EventMap>(): {
    handlers: Record<keyof T, ((...arg: any[]) => void)[]>;
    addListener: <K extends keyof T>(type: K, handler: T[K]) => void;
    fire: <K extends keyof T>(type: K, ...payload: Parameters<T[K]>) => void;
    removeListener: <K extends keyof T>(type: K, handler: T[K]) => void;
};
export {};
