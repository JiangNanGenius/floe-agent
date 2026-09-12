/**
 * Add css to a DOM-Element or returns the current
 * value of a property.
 *
 * @param el The Element.
 * @param attr The attribute or an object which holds css key-properties.
 * @param val The value for a single attribute.
 * @returns {*}
 */
export declare const css: ({ style }: HTMLElement, attr: Partial<Record<keyof CSSStyleDeclaration, string | number>> | string, val?: string | number) => void;
