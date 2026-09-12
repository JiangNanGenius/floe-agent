import type { MainLineParams, SubLineParams } from './utils/generateBranch';
import type { MindElixirInstance } from './types/index';
export declare function markmapMain({ pT, pL, pW, pH, cT, cL, cW, cH, direction }: MainLineParams): string;
export declare function markmapSub(this: MindElixirInstance, { pT, pL, pW, pH, cT, cL, cW, cH, direction, isFirst }: SubLineParams): string;
export declare function straightMain({ pT, pL, pW, pH, cT, cL, cW, cH, direction }: MainLineParams): string;
export declare function straightSub(this: MindElixirInstance, { pT, pL, pW, pH, cT, cL, cW, cH, direction }: SubLineParams): string;
export declare function straightUnderlineMain({ pT, pL, pW, pH, cT, cL, cW, cH, direction }: MainLineParams): string;
export declare function straightUnderlineSub(this: MindElixirInstance, { pT, pL, pW, pH, cT, cL, cW, cH, direction }: SubLineParams): string;
