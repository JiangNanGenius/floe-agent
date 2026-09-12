import type { MindElixirInstance, NodeObj } from '../types';
import type { Topic, Wrapper } from '../types/dom';
export declare const judgeDirection: ({ map, direction }: MindElixirInstance, obj: NodeObj) => 0 | 1 | 3 | undefined;
export declare const addChildDom: (mei: MindElixirInstance, to: Topic, wrapper: Wrapper) => void;
export declare const removeNodeDom: (tpc: Topic, siblingLength: number) => void;
