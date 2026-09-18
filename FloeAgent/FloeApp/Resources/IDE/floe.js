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
    const policy = window.FloeIDEPolicy;
    const { BrowserFS } = Alex.requireModule('@codeblitzjs/ide-sumi-core');
    const { Buffer } = Alex.requireModule('buffer');
    const NativeFilesystem = FloeNativeFilesystem(BrowserFS, Buffer, async request => {
      const result = await bridge.postMessage(request);
      if (request.operation === 'read' && !result.error) {
        const key = pathKey(request.path);
        if (!contents.has(key)) contents.set(key, await signature(Buffer.from(result.contentBase64, 'base64').toString('utf8')));
      }
      // Typed routing: a refused binary/Office read is handed to the native
      // surface instead of being shown as a decode failure.
      if (result.error && result.error.code === 'ENOTSUP') notify('routing', { path: pathKey(request.path) });
      return result;
    }, async (path, content) => {
      const key = pathKey(path), digest = await signature(content); contents.set(key, digest);
      if (dirty.get(key) === digest) dirty.delete(key);
      publishDirty(); notify('saved', { path });
    });
    BrowserFS.addFileSystemType('FloeNative', NativeFilesystem);
    window.MonacoEnvironment = { getWorkerUrl: () => new URL("vendor/editor.worker.js", location.href).href };
    // CodeBlitz 2.4.6 merges extension arrays additively. Its default icon
    // contribution points at a CDN even with useCdnIcon=false. Remove only
    // that contribution from the shared pinned metadata; use bundled Codicons.
    for (const metadata of Alex.getDefaultAppConfig().extensionMetadata || []) {
      if (metadata.extension?.name === 'vsicons-slim') {
        metadata.packageJSON.contributes.iconThemes = [];
      }
    }
    document.body.classList.add('default-file-icons', 'show-file-icons');
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
        // Only a text/code file may be handed to Monaco. Native routing owns
        // Office/PDF/CAD/image/media/archive documents; a non-text initial
        // path would otherwise be decoded as garbage and saved back as text.
        defaultOpenFile: (config.initialPath && (!policy || policy.isTextualPath(config.initialPath)))
          ? config.initialPath : undefined,
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
      notify('active', { path: path?.startsWith('/workspace/Floe/') ? pathKey(path) : null });
    };
    editor.onActiveResourceChange(active); active(editor.currentResource);
    window.floeIDE = {
      hasDirty: () => editor.hasDirty(),
      applyResolution: async (path, expectedDraft, result) => {
        const documents = await editor.getAllOpenedDocuments();
        const document = documents.find(item => pathKey(item.uri.path.toString()) === pathKey(path));
        if (!document || document.getText() !== expectedDraft) return false;
        document.updateContent(result);
        return true;
      },
      saveAll: async () => {
        await editor.saveAll();
        // Use the workbench's actual open documents: a closed/discarded tab
        // must not remain dirty just because our content callback saw it once.
        const unsaved = editor.hasDirty();
        await notify('dirty', { dirty: unsaved });
        return !unsaved;
      },
      // Programmatic text insertion for native automation; keyboard
      // synthesis cannot reach Monaco's hidden textarea from XCTest.
      insertText: async (path, text) => {
        const documents = await editor.getAllOpenedDocuments();
        // The same file can be open in more than one tab; update every
        // matching document so the visible buffer and the save agree.
        const matches = documents.filter(item => pathKey(item.uri.path.toString()) === pathKey(path));
        if (matches.length === 0) return false;
        for (const document of matches) {
          document.updateContent(document.getText() + text);
        }
        return true;
      },
      getText: async (path) => {
        const documents = await editor.getAllOpenedDocuments();
        const document = documents.find(item => pathKey(item.uri.path.toString()) === pathKey(path));
        return document ? document.getText() : null;
      },
      // Per-file save for native tab close. The document model's own `save()`
      // runs the verified BrowserFS write path (native CAS + digest check);
      // `false` means there was nothing to save, never that a save failed.
      savePath: async (path) => {
        const documents = await editor.getAllOpenedDocuments();
        const matches = documents.filter(item => pathKey(item.uri.path.toString()) === pathKey(path));
        if (matches.length === 0) return false;
        for (const document of matches) {
          if (document.dirty) await document.save();
        }
        return true;
      },
      dirtyPath: async (path) => {
        const documents = await editor.getAllOpenedDocuments();
        return documents.some(item =>
          pathKey(item.uri.path.toString()) === pathKey(path) && item.dirty === true);
      },
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
