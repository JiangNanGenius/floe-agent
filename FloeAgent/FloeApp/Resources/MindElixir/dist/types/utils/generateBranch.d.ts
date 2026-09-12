import type { MindElixirInstance } from '..';
import { DirectionClass } from '../types/index';
export interface MainLineParams {
    pT: number;
    pL: number;
    pW: number;
    pH: number;
    cT: number;
    cL: number;
    cW: number;
    cH: number;
    direction: DirectionClass;
    containerHeight: number;
    containerWidth?: number;
}
export interface SubLineParams {
    pT: number;
    pL: number;
    pW: number;
    pH: number;
    cT: number;
    cL: number;
    cW: number;
    cH: number;
    direction: DirectionClass;
    isFirst: boolean | undefined;
}
export declare function main({ pT, pL, pW, pH, cT, cL, cW, cH, direction, containerHeight, containerWidth }: MainLineParams): string;
export declare function sub(this: MindElixirInstance, { pT, pL, pW, pH, cT, cL, cW, cH, direction, isFirst }: SubLineParams): string;
