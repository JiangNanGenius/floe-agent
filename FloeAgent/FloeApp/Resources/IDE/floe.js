// SPDX-License-Identifier: MPL-2.0
(async function () {
  'use strict';
  const config = window.floeIDEConfiguration || {};
  const bridge = window.webkit?.messageHandlers?.floeIDE;
  const notify = (operation, value = {}) => bridge.postMessage({ operation, path: '/', ...value }).catch(() => {});
  const contents = new Map(), dirty = new Map(), revisions = new Map();
  const signature = async content => {
    const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(content));
    return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('');
  };
  const pathKey = path => '/' + path.replace(/^\/?workspace\/Floe\//, '').replace(/^\//, '');
  let lastDirty = false;
  function publishDirty() { const value = dirty.size > 0; if (value !== lastDirty) { lastDirty = value; notify('dirty', { dirty: value }); } }
  try {
    if (!bridge) throw new Error('Workspace connection unavailable');
    const { BrowserFS } = Alex.requireModule('@codeblitzjs/ide-sumi-core');
    const { Buffer } = Alex.requireModule('buffer');
    const NativeFilesystem = FloeNativeFilesystem(BrowserFS, Buffer, async request => {
      const result = await bridge.postMessage(request);
      if (request.operation === 'read' && !result.error) {
        const key = pathKey(request.path);
        if (!contents.has(key)) contents.set(key, await signature(Buffer.from(result.contentBase64, 'base64').toString('utf8')));
      }
      return result;
    }, async (path, content) => {
      const key = pathKey(path), digest = await signature(content); contents.set(key, digest);
      if (dirty.get(key) === digest) dirty.delete(key);
      publishDirty(); notify('saved', { path });
    });
    BrowserFS.addFileSystemType('FloeNative', NativeFilesystem);
    window.MonacoEnvironment = { getWorkerUrl: () => new URL("vendor/editor.worker.js", location.href).href };
    const app = Alex.createApp({
      appConfig: {
        workspaceDir: 'Floe', defaultPanels: { left: innerWidth >= 650 ? '@opensumi/ide-explorer' : '' }, useCdnIcon: false, extWorkerHost: '',
        onigWasmUri: new URL('vendor/onig.wasm', location.href).href,
        app: {brandName: 'Floe', productName: 'Floe IDE', logo: '', icon: ''},
        defaultPreferences: {
          'general.icon': '', 'general.language': config.language || 'en-US',
          'general.theme': config.dark ? 'opensumi-design-dark-theme' : 'opensumi-design-light-theme',
          'editor.fontSize': 15, 'editor.minimap.enabled': false,
          'editor.wordWrap': 'on', 'editor.tabSize': 4,
          'files.autoSave': 'off', 'files.confirmExit': 'always',
          'telemetry.enable': false
        }
      },
      runtimeConfig: {
        scenario: null, unregisterActivityBarExtra: true,
        defaultOpenFile: config.initialPath || undefined,
        workspace: {
          filesystem: { fs: 'FloeNative', options: {} },
          async onDidChangeTextDocument({filepath, content}) {
            const key = pathKey(filepath), revision = (revisions.get(key) || 0) + 1;
            revisions.set(key, revision); dirty.set(key, null); publishDirty();
            const digest = await signature(content);
            if (revisions.get(key) !== revision) return;
            if (contents.get(key) === digest) dirty.delete(key); else dirty.set(key, digest);
            publishDirty();
          }
        }
      }
    });
    await app.start(document.getElementById('root'));
    const { WorkbenchEditorService } = Alex.requireModule('@opensumi/ide-editor');
    const editor = app.injector.get(WorkbenchEditorService);
    const active = resource => {
      const path = resource?.uri?.path?.toString();
      if (path?.startsWith('/workspace/Floe/')) notify('active', { path: pathKey(path) });
    };
    editor.onActiveResourceChange(active); active(editor.currentResource);
    window.floeIDE = {
      saveAll: async () => { await editor.saveAll(); return dirty.size === 0; },
      destroy: () => app.destroy()
    };
    await notify('ready');
  } catch (e) {
    const failure = document.getElementById('failure');
    failure.hidden = false; failure.textContent = 'IDE: ' + (e.message || String(e));
    document.getElementById('root').hidden = true;
    if (bridge) notify('failed', { message: e.message || String(e) });
  }
})();
