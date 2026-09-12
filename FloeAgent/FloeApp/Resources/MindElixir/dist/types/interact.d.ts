import type { Topic } from './types/dom';
import type { MindElixirData, MindElixirInstance } from './types/index';
export declare const scrollIntoView: (this: MindElixirInstance, el: HTMLElement, forceCenter?: boolean) => void;
export declare const selectNode: (this: MindElixirInstance, tpc: Topic, isNewNode?: boolean, e?: MouseEvent) => void;
export declare const selectNodes: (this: MindElixirInstance, tpcs: Topic[]) => void;
export declare const unselectNodes: (this: MindElixirInstance, tpcs: Topic[]) => void;
export declare const clearSelection: (this: MindElixirInstance) => void;
export declare const stringifyData: (data: object) => string;
/**
 * @function
 * @instance
 * @name getDataString
 * @description Get all node data as string.
 * @memberof MapInteraction
 * @return {string}
 */
export declare const getDataString: (this: MindElixirInstance) => string;
/**
 * @function
 * @instance
 * @name getData
 * @description Get all node data as object.
 * @memberof MapInteraction
 * @return {Object}
 */
export declare const getData: (this: MindElixirInstance) => MindElixirData;
/**
 * @function
 * @instance
 * @name enableEdit
 * @memberof MapInteraction
 */
export declare const enableEdit: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name disableEdit
 * @memberof MapInteraction
 */
export declare const disableEdit: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name scale
 * @description Change the scale of the mind map.
 * @memberof MapInteraction
 * @param {number}
 */
export declare const scale: (this: MindElixirInstance, scaleVal: number, offset?: {
    x: number;
    y: number;
}) => void;
/**
 * Better to use with option `alignment: 'nodes'`.
 */
export declare const scaleFit: (this: MindElixirInstance) => void;
/**
 * Move the map by `dx` and `dy`.
 *
 * Returns whether the map actually moved, so callers (e.g. wheel handler)
 * can let the event bubble when the map is stuck at the edge.
 */
export declare const move: (this: MindElixirInstance, dx: number, dy: number, smooth?: boolean) => boolean;
/**
 * @function
 * @instance
 * @name toCenter
 * @description Reset position of the map to center.
 * @memberof MapInteraction
 */
export declare const toCenter: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name install
 * @description Install plugin.
 * @memberof MapInteraction
 */
export declare const install: (this: MindElixirInstance, plugin: (instance: MindElixirInstance) => void) => void;
/**
 * @function
 * @instance
 * @name focusNode
 * @description Enter focus mode, set the target element as root.
 * @memberof MapInteraction
 * @param {TargetElement} el - Target element return by E('...'), default value: currentTarget.
 */
export declare const focusNode: (this: MindElixirInstance, el: Topic) => void;
/**
 * @function
 * @instance
 * @name cancelFocus
 * @description Exit focus mode.
 * @memberof MapInteraction
 */
export declare const cancelFocus: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name initLeft
 * @description Child nodes will distribute on the left side of the root node.
 * @memberof MapInteraction
 */
export declare const initLeft: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name initRight
 * @description Child nodes will distribute on the right side of the root node.
 * @memberof MapInteraction
 */
export declare const initRight: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name initSide
 * @description Child nodes will distribute on both left and right side of the root node.
 * @memberof MapInteraction
 */
export declare const initSide: (this: MindElixirInstance) => void;
/**
 * @function
 * @instance
 * @name initDown
 * @description Child nodes will distribute below the root node (top-down layout).
 * @memberof MapInteraction
 */
export declare const initDown: (this: MindElixirInstance) => void;
export declare const expandNode: (this: MindElixirInstance, el: Topic, isExpand?: boolean) => void;
export declare const expandNodeAll: (this: MindElixirInstance, el: Topic, isExpand?: boolean) => void;
/**
 * @function
 * @instance
 * @name refresh
 * @description Refresh mind map, you can use it after modified `this.nodeData`. Only `nodeData`, `arrows`, `summaries` and `meta` are applied; `data.theme` is ignored, use `changeTheme` to switch theme explicitly.
 * @memberof MapInteraction
 * @param {TargetElement} data mind elixir data
 */
export declare const refresh: (this: MindElixirInstance, data?: MindElixirData) => void;
