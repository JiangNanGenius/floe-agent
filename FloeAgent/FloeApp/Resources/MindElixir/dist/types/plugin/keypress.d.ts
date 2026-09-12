import type { KeypressOptions, MindElixirInstance } from '../types/index';
type ZoomOffset = {
    x: number;
    y: number;
};
type WheelZoomStepInput = {
    deltaMode: number;
    deltaY: number;
    scaleSensitivity: number;
    viewportHeight: number;
};
export declare const normalizeWheelDelta: ({ deltaMode, deltaY, viewportHeight }: Omit<WheelZoomStepInput, 'scaleSensitivity'>) => number;
export declare const getWheelZoomScaleDelta: ({ deltaMode, deltaY, scaleSensitivity, viewportHeight }: WheelZoomStepInput) => number;
export declare const handleKeypressZoom: (mei: MindElixirInstance, direction: 'in' | 'out', offset?: ZoomOffset) => void;
export declare const handleWheelZoom: (mei: MindElixirInstance, e: WheelEvent) => void;
export default function (mind: MindElixirInstance, options: boolean | KeypressOptions): void;
export {};
