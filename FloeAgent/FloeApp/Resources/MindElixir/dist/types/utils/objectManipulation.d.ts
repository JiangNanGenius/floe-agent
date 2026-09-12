import type { NodeObj } from '../types';
export declare function removeNodeObj(obj: NodeObj): number;
export declare function insertNodeObj(newObj: NodeObj, type: 'before' | 'after', obj: NodeObj): void;
export declare function insertParentNodeObj(obj: NodeObj, newObj: NodeObj): void;
export declare function moveNodeObj(type: 'in' | 'before' | 'after', from: NodeObj, to: NodeObj): void;
