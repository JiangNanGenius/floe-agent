import './index.css';
import './markdown.css';
import { LEFT, RIGHT, SIDE, DOWN, DARK_THEME, THEME } from './const';
import { createBus } from './utils/pubsub';
import { findEle } from './utils/dom';
import type { MindElixirData, Options, Theme, ThemeCssVar, NodeObj, MindElixirInstance, NodeObjExport, Alignment, KeypressOptions, Before } from './types/index';
import type { Topic, ArrowSvg, SummarySvg, Wrapper, Parent, Children } from './types/dom';
import type { Arrow, ArrowOptions } from './arrow';
import type { Summary, SummaryOptions } from './summary';
import type { ContextMenuOption } from './plugin/contextMenu';
import type { MainLineParams, SubLineParams } from './utils/generateBranch';
import type { LinkPanHelperInstance } from './utils/LinkPanHelper';
import type { EventMap, Operation } from './utils/pubsub';
import type SelectionArea from './viselect/src';
import { createPanHelper } from './utils/panHelper';
type ResolvedTheme = Omit<Theme, 'cssVar'> & {
    cssVar: ThemeCssVar;
};
declare class MindElixir {
    static readonly LEFT = 0;
    static readonly RIGHT = 1;
    static readonly SIDE = 2;
    static readonly DOWN = 3;
    static readonly THEME: Theme & {
        cssVar: ThemeCssVar;
    };
    static readonly DARK_THEME: Theme & {
        cssVar: ThemeCssVar;
    };
    /**
     * @memberof MindElixir
     * @static
     */
    static version: string;
    /**
     * @function
     * @memberof MindElixir
     * @static
     * @name E
     * @param {string} id Node id.
     * @return {TargetElement} Target element.
     * @example
     * E('bd4313fbac40284b')
     */
    static E: typeof findEle;
    /**
     * @function new
     * @memberof MindElixir
     * @static
     * @param {String} topic root topic
     */
    static new: (topic: string) => MindElixirData;
    el: HTMLElement;
    theme: ResolvedTheme;
    markdown?: (markdown: string, obj: NodeObj | Arrow | Summary) => string;
    imageProxy?: (url: string) => string;
    disposable: Array<() => void>;
    dragged: Topic[] | null;
    spacePressed: boolean;
    isFocusMode: boolean;
    nodeDataBackup: NodeObj;
    nodeData: NodeObj;
    arrows: Arrow[];
    summaries: Summary[];
    currentNodes: Topic[];
    currentSummary: SummarySvg | null;
    currentArrow: ArrowSvg | null;
    scaleVal: number;
    tempDirection: 0 | 1 | 2 | 3 | null;
    meta?: Record<string, any>;
    container: HTMLElement;
    map: HTMLElement;
    root: HTMLElement;
    nodes: HTMLElement;
    lines: SVGElement;
    summarySvg: SVGElement;
    linkController: SVGElement;
    labelContainer: HTMLElement;
    P2: HTMLElement;
    P3: HTMLElement;
    line1: SVGElement;
    line2: SVGElement;
    arrowSvg: SVGElement;
    /**
     * @internal
     */
    helper1?: LinkPanHelperInstance;
    /**
     * @internal
     */
    helper2?: LinkPanHelperInstance;
    bus: ReturnType<typeof createBus<EventMap>>;
    history: Operation[];
    undo: () => void;
    redo: () => void;
    /**
     * Reset the undo/redo stack and update the internal baseline snapshot to the
     * current diagram state. Call this after loading new data into an existing
     * instance (e.g. after `refresh()`) to prevent users from undoing back into
     * a previously loaded diagram.
     *
     * Only available when `allowUndo` is `true` (the default).
     */
    clearHistory?: () => void;
    selection: SelectionArea;
    panHelper: ReturnType<typeof createPanHelper>;
    ptState?: number;
    direction: 0 | 1 | 2 | 3;
    locale: string;
    draggable: boolean;
    editable: boolean;
    contextMenu: boolean | ContextMenuOption;
    toolBar: boolean;
    keypress: boolean | KeypressOptions;
    mouseSelectionButton: 0 | 2;
    before: Before;
    newTopicName: string;
    allowUndo: boolean;
    overflowHidden: boolean;
    compact: boolean;
    generateMainBranch: (this: MindElixirInstance, params: MainLineParams) => string;
    generateSubBranch: (this: MindElixirInstance, params: SubLineParams) => string;
    selectionContainer: string | HTMLElement;
    alignment: Alignment;
    scaleSensitivity: number;
    scaleMin: number;
    scaleMax: number;
    handleWheel: true | ((e: WheelEvent) => void);
    pasteHandler: (e: ClipboardEvent) => void;
    mobileMultiSelect: boolean;
    init: (this: MindElixirInstance, data: MindElixirData) => Error | undefined;
    destroy: (this: Partial<MindElixirInstance>) => void;
    enableMobileMultiSelect: (this: MindElixirInstance, enable: boolean) => void;
    exportSvg: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Blob;
    exportPng: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Promise<Blob | null>;
    createSummary: (this: MindElixirInstance, options?: SummaryOptions) => void;
    createSummaryFrom: (this: MindElixirInstance, summary: Omit<Summary, 'id'>) => void;
    removeSummary: (this: MindElixirInstance, id: string) => void;
    selectSummary: (this: MindElixirInstance, el: SummarySvg) => void;
    unselectSummary: (this: MindElixirInstance) => void;
    renderSummary: (this: MindElixirInstance) => void;
    editSummary: (this: MindElixirInstance, el: SummarySvg) => void;
    renderArrow: (this: MindElixirInstance) => void;
    editArrowLabel: (this: MindElixirInstance, el: ArrowSvg) => void;
    tidyArrow: (this: MindElixirInstance) => void;
    createArrow: (this: MindElixirInstance, from: Topic, to: Topic, options?: ArrowOptions) => void;
    createArrowFrom: (this: MindElixirInstance, arrow: Omit<Arrow, 'id'>) => void;
    removeArrow: (this: MindElixirInstance, linkSvg?: ArrowSvg) => void;
    selectArrow: (this: MindElixirInstance, link: ArrowSvg) => void;
    unselectArrow: (this: MindElixirInstance) => void;
    reshapeArrow: (this: MindElixirInstance, arrow: Arrow, patchData: Partial<Arrow>) => void;
    rmSubline: (this: MindElixirInstance, tpc: Topic) => Promise<void>;
    reshapeNode: (this: MindElixirInstance, tpc: Topic, patchData: Partial<NodeObj<unknown>>) => Promise<void>;
    insertSibling: (this: MindElixirInstance, type: 'before' | 'after', el?: Topic | undefined, node?: NodeObj<unknown> | undefined) => Promise<void>;
    insertParent: (this: MindElixirInstance, el?: Topic | undefined, node?: NodeObj<unknown> | undefined) => Promise<void>;
    addChild: (this: MindElixirInstance, el?: Topic | undefined, node?: NodeObj<unknown> | undefined) => Promise<void>;
    copyNode: (this: MindElixirInstance, node: Topic, to: Topic) => Promise<void>;
    copyNodes: (this: MindElixirInstance, tpcs: Topic[], to: Topic) => Promise<void>;
    moveUpNode: (this: MindElixirInstance, el?: Topic | undefined) => Promise<void>;
    moveDownNode: (this: MindElixirInstance, el?: Topic | undefined) => Promise<void>;
    removeNodes: (this: MindElixirInstance, tpcs: Topic[]) => Promise<void>;
    moveNodeIn: (this: MindElixirInstance, from: Topic[], to: Topic) => Promise<void>;
    moveNodeBefore: (this: MindElixirInstance, from: Topic[], to: Topic) => Promise<void>;
    moveNodeAfter: (this: MindElixirInstance, from: Topic[], to: Topic) => Promise<void>;
    beginEdit: (this: MindElixirInstance, el?: Topic | undefined) => Promise<void>;
    setNodeTopic: (this: MindElixirInstance, el: Topic, topic: string) => Promise<void>;
    scrollIntoView: (this: MindElixirInstance, el: HTMLElement, forceCenter?: boolean) => void;
    selectNode: (this: MindElixirInstance, tpc: Topic, isNewNode?: boolean, e?: MouseEvent) => void;
    selectNodes: (this: MindElixirInstance, tpcs: Topic[]) => void;
    unselectNodes: (this: MindElixirInstance, tpcs: Topic[]) => void;
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
    focusNode: (this: MindElixirInstance, el: Topic) => void;
    cancelFocus: (this: MindElixirInstance) => void;
    initLeft: (this: MindElixirInstance) => void;
    initRight: (this: MindElixirInstance) => void;
    initSide: (this: MindElixirInstance) => void;
    initDown: (this: MindElixirInstance) => void;
    expandNode: (this: MindElixirInstance, el: Topic, isExpand?: boolean) => void;
    expandNodeAll: (this: MindElixirInstance, el: Topic, isExpand?: boolean) => void;
    refresh: (this: MindElixirInstance, data?: MindElixirData) => void;
    getObjById: (id: string, data: NodeObj) => NodeObj | null;
    generateNewObj: (this: MindElixirInstance) => NodeObjExport;
    layout: (this: MindElixirInstance) => void;
    linkDiv: (this: MindElixirInstance, mainNode?: Wrapper) => void;
    editTopic: (this: MindElixirInstance, el: Topic) => void;
    createWrapper: (this: MindElixirInstance, nodeObj: NodeObj, omitChildren?: boolean) => {
        grp: Wrapper;
        top: Parent;
        tpc: Topic;
    };
    createParent: (this: MindElixirInstance, nodeObj: NodeObj) => {
        p: Parent;
        tpc: Topic;
    };
    createChildren: (this: MindElixirInstance, wrappers: Wrapper[]) => Children;
    createTopic: (this: MindElixirInstance, nodeObj: NodeObj) => Topic;
    findEle: (this: MindElixirInstance, id: string, el?: HTMLElement) => Topic;
    changeTheme: (this: MindElixirInstance, theme: Theme, shouldRefresh?: boolean) => void;
    changeCompact: (this: MindElixirInstance, compact: boolean) => void;
    get currentNode(): Topic | null;
    constructor({ el, direction, editable, contextMenu, toolBar, keypress, mouseSelectionButton, selectionContainer, before, newTopicName, allowUndo, generateMainBranch, generateSubBranch, overflowHidden, compact, theme, alignment, scaleSensitivity, scaleMax, scaleMin, handleWheel, markdown, imageProxy, pasteHandler, mobileMultiSelect, }: Options);
}
export default MindElixir;
export { LEFT, RIGHT, SIDE, DOWN, THEME, DARK_THEME };
export type * from './utils/pubsub';
export type * from './types/index';
export type * from './types/dom';
