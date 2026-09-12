import type { MindElixirData } from '../types';
export interface NodePlaintextMeta {
    refId: string;
}
export interface ArrowPlaintextMeta {
    parentId: string | null;
    index: number;
}
export declare const plaintextExample = "- Root Node\n  - Child Node 1\n    - Child Node 1-1 {\"color\": \"#e87a90\", \"fontSize\": \"18px\"}\n    - Child Node 1-2\n    - Child Node 1-3\n    - }:2 Summary of first two nodes\n  - Child Node 2\n    - Child Node 2-1 [^node-2-1]\n    - Child Node 2-2 [^id2]\n    - Child Node 2-3\n    - > [^node-2-1] <-Bidirectional Link-> [^id2]\n  - Child Node 3\n    - Child Node 3-1 [^id3]\n    - Child Node 3-2 [^id4]\n    - Child Node 3-3 [^id5] {\"fontFamily\": \"Arial\", \"fontWeight\": \"bold\"}\n    - > [^id3] >-Unidirectional Link-> [^id4]\n  - Child Node 4\n    - Child Node 4-1 [^id6]\n    - Child Node 4-2 [^id7]\n    - Child Node 4-3 [^id8]\n    - } Summary of all previous nodes\n    - Child Node 4-4\n- > [^node-2-1] <-Link position is not restricted, as long as the id can be found during rendering-> [^id8]\n\n";
/**
 * Convert plaintext format to MindElixirData
 *
 * Format:
 * - Root node
 *   - Child 1
 *     - Child 1-1 [^id1]
 *     - Child 1-2 {"color": "#e87a90", "fontSize": "18px", "fontFamily": "Arial"}
 *     - }:2 Summary of first two nodes
 *   - Child 2 [^id2]
 *     - > [^id1] <-label-> [^id2]
 *
 * When the plaintext contains more than one top-level node, a synthetic root
 * node is automatically created to wrap them as first-level children.
 *
 * @param plaintext - The plaintext string to convert
 * @param rootName - Optional name for the synthetic root node when multiple
 *   top-level nodes are detected (defaults to 'Root')
 * @returns MindElixirData object
 */
export declare function plaintextToMindElixir(plaintext: string, rootName?: string): MindElixirData;
