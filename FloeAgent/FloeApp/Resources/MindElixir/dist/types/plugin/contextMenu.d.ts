import type { MindElixirInstance } from '../types/index';
import './contextMenu.css';
import type { LangPack } from '../i18n';
export type ContextMenuOption = {
    focus?: boolean;
    link?: boolean;
    extend?: {
        name: string;
        key?: string;
        onclick: (e: MouseEvent) => void;
    }[];
    locale?: LangPack;
};
export default function (mind: MindElixirInstance, option: true | ContextMenuOption): () => void;
