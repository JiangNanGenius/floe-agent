import { EventTarget } from './EventEmitter';
import type { AreaLocation, SelectionEvents } from './types';
import type { PartialSelectionOptions } from './types';
import type { SelectAllSelectors } from './utils/selectAll';
export * from './types';
export default class SelectionArea extends EventTarget<SelectionEvents> {
    static version: string;
    private readonly _options;
    private _selection;
    private readonly _area;
    private readonly _clippingElement;
    private _targetElement?;
    private _targetBoundary?;
    private _targetBoundaryScrolled;
    private _targetRect?;
    private _selectables;
    private _latestElement?;
    private _areaLocation;
    private _areaRect;
    private _singleClick;
    private _frame;
    private _scrollAvailable;
    private _scrollingActive;
    private _scrollSpeed;
    private _scrollDelta;
    constructor(opt: PartialSelectionOptions);
    _toggleStartEvents(activate?: boolean): void;
    _onTapStart(evt: PointerEvent, silent?: boolean): void;
    _onSingleTap(evt: PointerEvent): void;
    _delayedTapMove(evt: PointerEvent): void;
    _setupSelectionArea(): void;
    _onTapMove(evt: PointerEvent): void;
    _handleMoveEvent(evt: PointerEvent): void;
    _onScroll(): void;
    _onStartAreaScroll(): void;
    _recalculateSelectionAreaRect(): void;
    _redrawSelectionArea(): void;
    _onTapStop(evt: PointerEvent | null, silent: boolean): void;
    _updateElementSelection(): void;
    _emitEvent(name: keyof SelectionEvents, evt: PointerEvent | null): unknown;
    _keepSelection(): void;
    /**
     * Manually triggers the start of a selection
     * @param evt A PointerEvent-like object
     * @param silent If beforestart should be fired
     */
    trigger(evt: PointerEvent, silent?: boolean): void;
    /**
     * Can be used if during a selection elements have been added
     * Will update everything that can be selected
     */
    resolveSelectables(): void;
    /**
     * Same as deselecting, but for all elements currently selected
     * @param includeStored If the store should also get cleared
     * @param quiet If move / stop events should be fired
     */
    clearSelection(includeStored?: boolean, quiet?: boolean): void;
    /**
     * @returns {Array} Selected elements
     */
    getSelection(): Element[];
    /**
     * @returns {HTMLElement} The selection area element
     */
    getSelectionArea(): HTMLElement;
    /**
     * @returns {Element[]} Available selectable elements for current selection
     */
    getSelectables(): Element[];
    /**
     * Set the location of the selection area
     * @param location A partial AreaLocation object
     */
    setAreaLocation(location: Partial<AreaLocation>): void;
    /**
     * @returns {AreaLocation} The current location of the selection area
     */
    getAreaLocation(): AreaLocation;
    /**
     * Cancel the current selection process, pass true to fire a stop event after cancel
     * @param keepEvent If a stop event should be fired
     */
    cancel(keepEvent?: boolean): void;
    /**
     * Unbinds all events and removes the area-element.
     */
    destroy(): void;
    /**
     * Enable selecting elements
     */
    enable: (activate?: boolean) => void;
    /**
     * Disable selecting elements
     */
    disable: () => void;
    /**
     * Adds elements to the selection
     * @param query CSS Query, can be an array of queries
     * @param quiet If this should not trigger the move event
     */
    select(query: SelectAllSelectors, quiet?: boolean): Element[];
    /**
     * Removes a particular element from the selection
     * @param query CSS Query, can be an array of queries
     * @param quiet If this should not trigger the move event
     */
    deselect(query: SelectAllSelectors, quiet?: boolean): void;
}
