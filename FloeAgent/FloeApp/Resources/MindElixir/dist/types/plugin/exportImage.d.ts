import type { MindElixirInstance } from '../types';
/**
 * @deprecated This method is deprecated and will be removed in a future version.
 * Use modern-screenshot library instead with domToSvg(mind.nodes, options).
 * See: https://github.com/SSShooter/mind-elixir-core#export-as-a-image
 */
export declare const exportSvg: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Blob;
/**
 * @deprecated This method is deprecated and will be removed in a future version.
 * Use modern-screenshot library instead with domToPng(mind.nodes, options).
 * See: https://github.com/SSShooter/mind-elixir-core#export-as-a-image
 */
export declare const exportPng: (this: MindElixirInstance, noForeignObject?: boolean, injectCss?: string) => Promise<Blob | null>;
