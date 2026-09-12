import type { MindElixirInstance, SummarySvg } from '.';
export interface SummaryStyle {
    /**
     * stroke color of the summary
     */
    stroke?: string;
    /**
     * color of the summary label
     */
    labelColor?: string;
}
export interface SummaryOptions {
    style?: SummaryStyle;
}
/**
 * @public
 */
export interface Summary {
    id: string;
    label: string;
    /**
     * parent node id of the summary
     */
    parent: string;
    /**
     * start index of the summary
     */
    start: number;
    /**
     * end index of the summary
     */
    end: number;
    /**
     * style of the summary
     */
    style?: SummaryStyle;
}
export declare const createSummary: (this: MindElixirInstance, options?: SummaryOptions) => void;
export declare const createSummaryFrom: (this: MindElixirInstance, summary: Omit<Summary, 'id'>) => void;
export declare const removeSummary: (this: MindElixirInstance, id: string) => void;
export declare const selectSummary: (this: MindElixirInstance, el: SummarySvg) => void;
export declare const unselectSummary: (this: MindElixirInstance) => void;
export declare const renderSummary: (this: MindElixirInstance) => void;
export declare const editSummary: (this: MindElixirInstance, el: SummarySvg) => void;
