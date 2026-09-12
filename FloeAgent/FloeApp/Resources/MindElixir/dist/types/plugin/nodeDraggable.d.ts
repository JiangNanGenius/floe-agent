import type { Topic } from '../types/dom';
import type { MindElixirInstance } from '../types/index';
export type InsertType = 'before' | 'after' | 'in' | null;
export declare const insertPreview: (tpc: Topic, insertType: InsertType) => Topic;
export declare const clearPreview: (el: Element | null) => void;
export declare const canMove: (el: Element, dragged: Topic[]) => boolean;
export declare const createGhost: (mei: MindElixirInstance) => HTMLDivElement;
export declare class EdgeMoveController {
    private mind;
    private isMoving;
    private interval;
    private speed;
    constructor(mind: MindElixirInstance);
    move(dx: number, dy: number): void;
    stop(): void;
}
export interface NodeDragState {
    isDragging: boolean;
    insertType: InsertType;
    meet: Topic | null;
    ghost: HTMLElement;
    edgeMoveController: EdgeMoveController;
    startX: number;
    startY: number;
    pointerId: number | null;
}
export declare function createNodeDragState(mind: MindElixirInstance): NodeDragState;
export declare function handleNodeDragStart(mind: MindElixirInstance, state: NodeDragState, e: PointerEvent, immediate?: boolean): boolean;
/**
 * Update ghost element position
 */
export declare function updateGhostPosition(ghost: HTMLElement, x: number, y: number): void;
/**
 * Show ghost element immediately to indicate drag is ready
 */
export declare function showDragGhost(mind: MindElixirInstance, state: NodeDragState): void;
export declare function handleNodeDragMove(mind: MindElixirInstance, state: NodeDragState, e: PointerEvent): void;
export declare function handleNodeDragEnd(mind: MindElixirInstance, state: NodeDragState, e: PointerEvent): void;
export declare function handleNodeDragCancel(mind: MindElixirInstance, state: NodeDragState): void;
export default function (_mind: MindElixirInstance): () => void;
