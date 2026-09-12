import type { MindElixirInstance } from '../types/index';
export declare function createPanHelper(mei: MindElixirInstance): {
    x: number;
    y: number;
    moved: boolean;
    mousedown: boolean;
    handlePointerDown(e: PointerEvent): void;
    handlePointerMove(e: PointerEvent): boolean;
    handlePointerUp(e: PointerEvent): void;
    clear(): void;
};
