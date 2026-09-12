import type { Wrapper } from './types/dom';
import type { MindElixirInstance } from './types/index';
/**
 * Link nodes with svg,
 * only link specific node if `mainNode` is present
 *
 * procedure:
 * 1. generate main link
 * 2. generate links inside main node, if `mainNode` is presented, only generate the link of the specific main node
 * 3. generate custom link
 * 4. generate summary
 * @param mainNode regenerate sublink of the specific main node
 */
declare const linkDiv: (this: MindElixirInstance, mainNode?: Wrapper) => void;
export default linkDiv;
