import type { Topic, Wrapper, Parent, Children, Expander } from '../types/dom';
import type { MindElixirInstance, NodeObj } from '../types/index';
export declare const findEle: (this: MindElixirInstance, id: string, el?: HTMLElement) => Topic;
export declare const shapeTpc: (this: MindElixirInstance, tpc: Topic, nodeObj: NodeObj) => void;
export declare const createWrapper: (this: MindElixirInstance, nodeObj: NodeObj, omitChildren?: boolean) => {
    grp: Wrapper;
    top: Parent;
    tpc: Topic;
};
export declare const createParent: (this: MindElixirInstance, nodeObj: NodeObj) => {
    p: Parent;
    tpc: Topic;
};
export declare const createChildren: (this: MindElixirInstance, wrappers: Wrapper[]) => Children;
export declare const createTopic: (this: MindElixirInstance, nodeObj: NodeObj) => Topic;
export declare function selectText(div: HTMLElement): void;
export declare const editTopic: (this: MindElixirInstance, el: Topic) => void;
export declare const createExpander: (expanded: boolean | undefined) => Expander;
