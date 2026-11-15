// SPDX-License-Identifier: MPL-2.0
// Cocos Creator 3.8 project component installed by FloeGameInstrumentation.
// It is attached to the explicitly selected scene by the project installer.
// The component is inert outside a Floe-owned development run: onLoad returns
// before creating a timer, persisting the node or registering any field when
// the compiled Floe host has not injected window.FloeDeveloper.
import { _decorator, Component, director, game } from 'cc';

const { ccclass } = _decorator;
const GLOBAL_KEY = '__floeCocosBridge';
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;

function cleanText(value: any): string {
    const text = typeof value === 'string' ? value : String(value == null ? '' : value);
    return text.replace(CONTROL, ' ').slice(0, 4096);
}

function developer(): any {
    try {
        return (globalThis as any).FloeDeveloper || null;
    } catch (_error) {
        return null;
    }
}

function hostReady(D: any): boolean {
    return !!D && typeof D.registerPushed === 'function' &&
        typeof D.updatePushed === 'function' &&
        typeof D.takeCommands === 'function' &&
        typeof D.ackCommand === 'function';
}

@ccclass('FloeDeveloperBridge')
export class FloeDeveloperBridge extends Component {
    private tickTimer: any = null;
    private installed = false;
    private boundHost: any = null;

    onLoad(): void {
        const D = developer();
        if (!hostReady(D)) return;
        if (!this.install(D)) return;
        try {
            director.addPersistRootNode(this.node);
        } catch (_error) {
            // A node already persisted by the project remains usable.
        }
        this.boundHost = D;
        (globalThis as any)[GLOBAL_KEY] = true;
        this.installed = true;
        this.tickTimer = setInterval(() => this.tick(), 100);
    }

    onDestroy(): void {
        this.shutdown();
    }

    private install(D: any): boolean {
        if (this.installed) return true;
        const fields = [
            { id: 'scene.name', label: 'Scene', labelZhHans: '场景', group: 'Cocos', groupZhHans: 'Cocos', kind: 'readOnlyText', symbol: 'square.stack' },
            { id: 'engine.paused', label: 'Paused', labelZhHans: '已暂停', group: 'Cocos', groupZhHans: 'Cocos', kind: 'readOnlyBoolean', symbol: 'pause' },
            { id: 'engine.frames', label: 'Frames', labelZhHans: '帧数', group: 'Cocos', groupZhHans: 'Cocos', kind: 'readOnlyNumber', symbol: 'film' },
            { id: 'engine.elapsed', label: 'Elapsed', labelZhHans: '已运行', group: 'Cocos', groupZhHans: 'Cocos', kind: 'readOnlyNumber', symbol: 'clock' },
            { id: 'engine.frameRate', label: 'Frame rate', labelZhHans: '帧率', group: 'Cocos', groupZhHans: 'Cocos', kind: 'readOnlyNumber', symbol: 'speedometer' }
        ];
        const actions = [
            { id: 'engine.pause', label: 'Pause', labelZhHans: '暂停', group: 'Cocos', groupZhHans: 'Cocos', symbol: 'pause.fill', isQuick: true },
            { id: 'engine.resume', label: 'Resume', labelZhHans: '继续', group: 'Cocos', groupZhHans: 'Cocos', symbol: 'play.fill', isQuick: true },
            { id: 'engine.step', label: 'Step frame', labelZhHans: '单步一帧', group: 'Cocos', groupZhHans: 'Cocos', symbol: 'forward.frame.fill', parameters: [
                { id: 'frames', label: 'Frames', labelZhHans: '帧数', kind: 'integer', minimum: 1, maximum: 10, isRequired: true, defaultValue: 1 }
            ] }
        ];
        try {
            const accepted = D.registerPushed({ runtime: 'Cocos Creator 3.x Web export', fields: fields, actions: actions });
            if (accepted === false) return false;
            if (typeof D.setRuntime === 'function') D.setRuntime('Cocos Creator');
            return true;
        } catch (_error) {
            return false;
        }
    }

    private shutdown(): void {
        if (this.tickTimer !== null) {
            clearInterval(this.tickTimer);
            this.tickTimer = null;
        }
        if (this.installed) {
            this.installed = false;
            this.boundHost = null;
            try { (globalThis as any)[GLOBAL_KEY] = false; } catch (_error) {}
            try { director.removePersistRootNode(this.node); } catch (_error) {}
        }
    }

    private tick(): void {
        const D = developer();
        if (!hostReady(D) || D !== this.boundHost) {
            this.shutdown();
            return;
        }
        const d: any = director as any;
        const g: any = game as any;
        const scene: any = typeof d.getScene === 'function' ? d.getScene() : null;
        const values: any = {
            'scene.name': scene && scene.name ? cleanText(scene.name) : '—',
            'engine.paused': typeof d.isPaused === 'function' ? !!d.isPaused() : false,
            'engine.frames': typeof d.getTotalFrames === 'function' ? Number(d.getTotalFrames()) : 0,
            'engine.elapsed': typeof g.totalTime === 'number' ? g.totalTime / 1000 : 0,
            'engine.frameRate': typeof g.frameRate === 'number' ? g.frameRate : 0
        };
        try {
            D.updatePushed(values);
        } catch (_error) {
            this.shutdown();
            return;
        }
        let commands: any;
        try {
            commands = D.takeCommands();
        } catch (_error) {
            this.shutdown();
            return;
        }
        if (!Array.isArray(commands)) return;
        for (const command of commands) {
            let applied = false;
            let message: string | undefined;
            try {
                if (command && command.kind === 'action' && command.action === 'engine.pause' && typeof d.pause === 'function') {
                    d.pause();
                    applied = true;
                } else if (command && command.kind === 'action' && command.action === 'engine.resume' && typeof d.resume === 'function') {
                    d.resume();
                    applied = true;
                } else if (command && command.kind === 'action' && command.action === 'engine.step') {
                    applied = this.step(d, command.arguments);
                    if (!applied) message = 'Pause the game before stepping a frame.';
                } else if (command) {
                    message = 'Unknown or read-only command.';
                }
            } catch (error) {
                message = String(error);
            }
            try {
                D.ackCommand(command.id, { ok: applied, message: message });
            } catch (_error) {
                this.shutdown();
                return;
            }
        }
    }

    private step(d: any, args: any): boolean {
        if (typeof d.isPaused !== 'function' || !d.isPaused()) return false;
        if (typeof d.tick !== 'function') return false;
        const frames = Math.max(1, Math.min(10, Math.floor(Number(args && args.frames) || 1)));
        try {
            for (let index = 0; index < frames; index += 1) {
                d.resume();
                d.tick(1 / 60);
                d.pause();
            }
            return true;
        } catch (_error) {
            try { d.pause(); } catch (_ignored) {}
            return false;
        }
    }
}
