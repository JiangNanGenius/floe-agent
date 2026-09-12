import type { MindElixirInstance, MindElixirData } from './index';
import linkDiv from './linkDiv';
import { editTopic, createWrapper, createParent, createChildren, createTopic, findEle } from './utils/dom';
import { getObjById, generateNewObj } from './utils/index';
import { layout } from './utils/layout';
import { changeTheme, changeCompact } from './utils/theme';
import * as nodeOperation from './nodeOperation';
import * as arrow from './arrow';
import * as summary from './summary';
export type OperationMap = typeof nodeOperation;
export type Operations = keyof OperationMap;
export type MindElixirMethods = typeof methods;
/**
 * Methods that mind-elixir instance can use
 *
 * @public
 */
declare const methods: {
    scrollIntoView: (this: MindElixirInstance, el: HTMLElement, forceCenter?: boolean) => void;
    selectNode: (this: MindElixirInstance, tpc: import("./index").Topic, isNewNode?: boolean, e?: MouseEvent) => void;
    selectNodes: (this: MindElixirInstance, tpcs: import("./index").Topic[]) => void;
    unselectNodes: (this: MindElixirInstance, tpcs: import("./index").Topic[]) => void;
    clearSelection: (this: MindElixirInstance) => void;
    stringifyData: (data: object) => string;
    getDataString: (this: MindElixirInstance) => string;
    getData: (this: MindElixirInstance) => MindElixirData;
    enableEdit: (this: MindElixirInstance) => void;
    disableEdit: (this: MindElixirInstance) => void;
    scale: (this: MindElixirInstance, scaleVal: number, offset?: {
        x: number;
        y: number;
    }) => void;
    scaleFit: (this: MindElixirInstance) => void;
    move: (this: MindElixirInstance, dx: number, dy: number, smooth?: boolean) => boolean;
    toCenter: (this: MindElixirInstance) => void;
    install: (this: MindElixirInstance, plugin: (instance: MindElixirInstance) => void) => void;
    focusNode: (this: MindElixirInstance, el: import("./index").Topic) => void;
    cancelFocus: (this: MindElixirInstance) => void;
    initLeft: (this: MindElixirInstance) => void;
    initRight: (this: MindElixirInstance) => void;
    initSide: (this: MindElixirInstance) => void;
    initDown: (this: MindElixirInstance) => void;
    expandNode: (this: MindElixirInstance, el: import("./index").Topic, isExpand?: boolean) => void;
    expandNodeAll: (this: MindElixirInstance, el: import("./index").Topic, isExpand?: boolean) => void;
    refresh: (this: MindElixirInstance, data?: MindElixirData) => void;
    exportSvg: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Blob;
    exportPng: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Promise<Blob | null>;
    getObjById: typeof getObjById;
    generateNewObj: typeof generateNewObj;
    layout: typeof layout;
    linkDiv: typeof linkDiv;
    editTopic: typeof editTopic;
    createWrapper: typeof createWrapper;
    createParent: typeof createParent;
    createChildren: typeof createChildren;
    createTopic: typeof createTopic;
    findEle: typeof findEle;
    changeTheme: typeof changeTheme;
    changeCompact: typeof changeCompact;
    init(this: MindElixirInstance, data: MindElixirData): Error | undefined;
    destroy(this: Partial<MindElixirInstance>): void;
    /**
     * @public
     * @param {boolean} enable
     */
    enableMobileMultiSelect(this: MindElixirInstance, enable: boolean): void;
    createSummary: (this: MindElixirInstance, options?: summary.SummaryOptions) => void;
    createSummaryFrom: (this: MindElixirInstance, summary: Omit<summary.Summary, 'id'>) => void;
    removeSummary: (this: MindElixirInstance, id: string) => void;
    selectSummary: (this: MindElixirInstance, el: import("./index").SummarySvg) => void;
    unselectSummary: (this: MindElixirInstance) => void;
    renderSummary: (this: MindElixirInstance) => void;
    editSummary: (this: MindElixirInstance, el: import("./index").SummarySvg) => void;
    createArrow: (this: MindElixirInstance, from: import("./index").Topic, to: import("./index").Topic, options?: arrow.ArrowOptions) => void;
    createArrowFrom: (this: MindElixirInstance, arrow: Omit<arrow.Arrow, 'id'>) => void;
    removeArrow: (this: MindElixirInstance, linkSvg?: import("./index").ArrowSvg) => void;
    selectArrow: (this: MindElixirInstance, link: import("./index").ArrowSvg) => void;
    unselectArrow: (this: MindElixirInstance) => void;
    renderArrow(this: MindElixirInstance): void;
    editArrowLabel(this: MindElixirInstance, el: import("./index").ArrowSvg): void;
    tidyArrow(this: MindElixirInstance): void;
    reshapeArrow: (this: MindElixirInstance, arrow: arrow.Arrow, patchData: Partial<arrow.Arrow>) => void;
    addChild: (this: MindElixirInstance, el?: import("./index").Topic | undefined, node?: import("./types").NodeObj<unknown> | undefined) => Promise<void>;
    beginEdit: (this: MindElixirInstance, el?: import("./index").Topic | undefined) => Promise<void>;
    copyNode: (this: MindElixirInstance, node: import("./index").Topic, to: import("./index").Topic) => Promise<void>;
    copyNodes: (this: MindElixirInstance, tpcs: import("./index").Topic[], to: import("./index").Topic) => Promise<void>;
    insertParent: (this: MindElixirInstance, el?: import("./index").Topic | undefined, node?: import("./types").NodeObj<unknown> | undefined) => Promise<void>;
    insertSibling: (this: MindElixirInstance, type: "after" | "before", el?: import("./index").Topic | undefined, node?: import("./types").NodeObj<unknown> | undefined) => Promise<void>;
    moveDownNode: (this: MindElixirInstance, el?: import("./index").Topic | undefined) => Promise<void>;
    moveNodeAfter: (this: MindElixirInstance, from: import("./index").Topic[], to: import("./index").Topic) => Promise<void>;
    moveNodeBefore: (this: MindElixirInstance, from: import("./index").Topic[], to: import("./index").Topic) => Promise<void>;
    moveNodeIn: (this: MindElixirInstance, from: import("./index").Topic[], to: import("./index").Topic) => Promise<void>;
    moveUpNode: (this: MindElixirInstance, el?: import("./index").Topic | undefined) => Promise<void>;
    removeNodes: (this: MindElixirInstance, tpcs: import("./index").Topic[]) => Promise<void>;
    reshapeNode: (this: MindElixirInstance, tpc: import("./index").Topic, patchData: Partial<import("./types").NodeObj<unknown>>) => Promise<void>;
    rmSubline: (this: MindElixirInstance, tpc: import("./index").Topic) => Promise<void>;
    setNodeTopic: (this: MindElixirInstance, el: import("./index").Topic, topic: string) => Promise<void>;
};
export default methods;
