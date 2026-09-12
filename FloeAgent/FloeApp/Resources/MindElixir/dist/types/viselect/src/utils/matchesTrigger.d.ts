export type MouseButton = 0 | 1 | 2 | 3 | 4;
export type Modifier = 'ctrl' | 'alt' | 'shift';
export type MouseButtonWithModifiers = {
    button: MouseButton;
    modifiers: Modifier[];
};
export type Trigger = MouseButton | MouseButtonWithModifiers;
/**
 * Determines whether a PointerEvent/MouseEvent should execute until completion depending on
 * which button and modifier(s) are active for the event.
 * The Event will execute to completion if ANY of the triggers "matches"
 * @param event PointerEvent or MouseEvent that should be checked
 * @param triggers A list of Triggers that signify that the event should execute until completion
 * @returns Whether the event should execute until completion
 */
export declare const matchesTrigger: (event: PointerEvent | MouseEvent, triggers: Trigger[]) => boolean;
