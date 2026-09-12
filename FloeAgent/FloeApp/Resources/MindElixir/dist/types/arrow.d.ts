import type { ArrowSvg, Topic } from './types/dom';
import { type MindElixirInstance, type Uid } from './index';
export interface ArrowStyle {
    /**
     * stroke color of the arrow
     */
    stroke?: string;
    /**
     * stroke width of the arrow
     */
    strokeWidth?: string | number;
    /**
     * stroke dash array for dashed lines
     */
    strokeDasharray?: string;
    /**
     * opacity of the arrow
     */
    opacity?: string | number;
    /**
     * color of the arrow label
     */
    labelColor?: string;
}
export interface Arrow<M = unknown> {
    id: string;
    /**
     * label of arrow
     */
    label: string;
    /**
     * id of start node
     */
    from: Uid;
    /**
     * id of end node
     */
    to: Uid;
    /**
     *  offset of control point from start point
     */
    delta1?: {
        x: number;
        y: number;
    };
    /**
     * offset of control point from end point
     */
    delta2?: {
        x: number;
        y: number;
    };
    /**
     * whether the arrow is bidirectional
     */
    bidirectional?: boolean;
    /**
     * style properties for the arrow
     */
    style?: ArrowStyle;
    /**
     * Generic metadata for the arrow, can be used to store any custom data.
     */
    metadata?: M;
}
export interface DivData {
    cx: number;
    cy: number;
    w: number;
    h: number;
    ctrlX: number;
    ctrlY: number;
}
export interface ArrowOptions {
    bidirectional?: boolean;
    style?: ArrowStyle;
}
export declare const createArrow: (this: MindElixirInstance, from: Topic, to: Topic, options?: ArrowOptions) => void;
export declare const createArrowFrom: (this: MindElixirInstance, arrow: Omit<Arrow, 'id'>) => void;
export declare const removeArrow: (this: MindElixirInstance, linkSvg?: ArrowSvg) => void;
export declare const selectArrow: (this: MindElixirInstance, link: ArrowSvg) => void;
export declare const unselectArrow: (this: MindElixirInstance) => void;
export declare function renderArrow(this: MindElixirInstance): void;
export declare function editArrowLabel(this: MindElixirInstance, el: ArrowSvg): void;
export declare function tidyArrow(this: MindElixirInstance): void;
export declare const reshapeArrow: (this: MindElixirInstance, arrow: Arrow, patchData: Partial<Arrow>) => void;
