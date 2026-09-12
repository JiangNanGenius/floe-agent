export type Intersection = 'center' | 'cover' | 'touch';
/**
 * Check if two DOM-Elements intersects each other.
 * @param a BoundingClientRect of the first element.
 * @param b BoundingClientRect of the second element.
 * @param mode Options are center, cover or touch.
 * @returns {boolean} If both elements intersects each other.
 */
export declare const intersects: (a: DOMRect, b: DOMRect, mode?: Intersection) => boolean;
