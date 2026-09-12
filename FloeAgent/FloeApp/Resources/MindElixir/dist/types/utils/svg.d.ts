import type { Arrow } from '../arrow';
import type { Summary } from '../summary';
import type { MindElixirInstance } from '../types';
import type { ArrowSvg } from '../types/dom';
export declare const svgNS = "http://www.w3.org/2000/svg";
export interface SvgTextOptions {
    anchor?: 'start' | 'middle' | 'end';
    color?: string;
    dataType: string;
    svgId: string;
}
/**
 * Create a div label for SVG elements with positioning
 */
export declare const calculatePrecisePosition: (element: HTMLElement) => void;
export declare const createLabel: (text: string, x: number, y: number, options: SvgTextOptions) => HTMLDivElement;
/**
 * Find SVG element by label ID
 */
export declare const findSvgByLabelId: (labelId: string) => SVGElement | null;
/**
 * Find label element by SVG ID
 */
export declare const findLabelBySvgId: (svgId: string) => HTMLDivElement | null;
export declare const createPath: (d: string, color: string, width: string) => SVGPathElement;
export declare const createLinkSvg: (klass: string) => SVGSVGElement;
export declare const createLine: () => SVGLineElement;
export declare const createArrowGroup: (d: string, arrowd1: string, arrowd2: string, style?: {
    stroke?: string;
    strokeWidth?: string | number;
    strokeDasharray?: string;
    opacity?: string | number;
}) => ArrowSvg;
export declare const editSvgText: (mei: MindElixirInstance, textEl: HTMLDivElement, node: Summary | Arrow) => void;
