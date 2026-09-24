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
    // PDF/Office documents open as real internal CodeBlitz editor tabs, not
    // as native outer tabs: a lightweight placeholder component claims the
    // resource, reports its content rectangle through the bridge, and the
    // native side overlays the real PDF/Office surface clipped to exactly
    // that rectangle. The bytes never travel the BrowserFS text path, so the
    // errno-95 ENOTSUP decode failure cannot occur for these documents.
    const { EditorComponentRegistry, EditorOpenType } = Alex.requireModule('@opensumi/ide-editor');
    const React = Alex.requireModule('react');
    const { URI } = Alex.requireModule('@opensumi/ide-core-common');
    const FLOE_NATIVE_DOCUMENT_COMPONENT = 'floe-native-document';
    // Real close detection: a component unmount is NOT a tab close (pane
    // rebuilds and workbench teardown unmount too). The truth is the set
    // difference of the workbench's open resources, observed through
    // onDidEditorGroupsChanged (grid descendant state changes include
    // in-group tab closes) and getAllOpenedUris.
    const trackedNativeDocs = new Map();
    const syncNativeDocuments = () => {
      const open = new Set();
      for (const uri of editor.getAllOpenedUris()) {
        if (uri.scheme !== 'file') continue;
        const rel = pathKey(uri.path.toString());
        if (trackedNativeDocs.has(rel)) open.add(rel);
      }
      for (const [rel, kind] of Array.from(trackedNativeDocs)) {
        if (!open.has(rel)) {
          trackedNativeDocs.delete(rel);
          notify('nativeDocument', { path: rel, kind, phase: 'unmount' });
        }
      }
    };
    editor.onDidEditorGroupsChanged(() => syncNativeDocuments());
    const FloeNativeDocument = (props) => {
      const ref = React.useRef(null);
      const resourcePath = props.resource?.uri?.path?.toString() || '';
      const relative = pathKey(resourcePath);
      const kind = policy && policy.kindForPath(relative) === 'pdf' ? 'pdf' : 'office';
      React.useEffect(() => {
        const node = ref.current;
        trackedNativeDocs.set(relative, kind);
        let visible = true;
        const report = () => {
          if (!node) return;
          const rect = node.getBoundingClientRect();
          notify('nativeDocument', {
            path: relative, kind,
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
            visible: visible && rect.width > 1 && rect.height > 1
          });
        };
        report();
        if (!node) return undefined;
        const resize = new ResizeObserver(report);
        resize.observe(node);
        // Tab switches keep the previous editor mounted but hidden: the
        // intersection observation carries the real visibility so the native
        // overlay hides even if the hidden node keeps a nonzero box.
        const intersection = new IntersectionObserver((entries) => {
          const nowVisible = entries.some(entry => entry.isIntersecting) && !!node.offsetWidth && !!node.offsetHeight;
          if (nowVisible === visible) return;
          visible = nowVisible;
          report();
        }, { threshold: 0 });
        intersection.observe(node);
        window.addEventListener('resize', report);
        return () => {
          resize.disconnect();
          intersection.disconnect();
          window.removeEventListener('resize', report);
          // No unmount notify here: a rebuild unmount is not a tab close.
          // syncNativeDocuments reports the real close.
        };
      }, [relative]);
      // The placeholder is transparent: the native overlay supplies the real
      // surface. A subtle pattern keeps the tab honest if the bridge lags.
      return React.createElement('div', {
        ref, className: 'floe-native-document',
        style: { width: '100%', height: '100%', minHeight: '100%', background: 'var(--editor-background, transparent)' }
      });
    };
    const nativeDocumentRegistry = app.injector.get(EditorComponentRegistry);
    nativeDocumentRegistry.registerEditorComponent({
      component: FloeNativeDocument, uid: FLOE_NATIVE_DOCUMENT_COMPONENT, scheme: 'file'
    });
    // Weight 20 outranks the built-in file resolver (10), so PDF/Office paths
    // are claimed before the text editor can attempt a binary read.
    nativeDocumentRegistry.registerEditorComponentResolver(
      scheme => scheme === 'file' ? 20 : -1,
      (resource, results) => {
        const relative = pathKey(resource.uri.path.toString());
        const kind = policy ? policy.kindForPath(relative) : 'unknown';
        if (kind === 'pdf' || kind === 'office') {
          results.push({ type: EditorOpenType.component, componentId: FLOE_NATIVE_DOCUMENT_COMPONENT, weight: 20 });
        }
      }
    );
    const active = resource => {
      const path = resource?.uri?.path?.toString();
      notify('active', { path: path?.startsWith('/workspace/Floe/') ? pathKey(path) : null });
    };
    editor.onActiveResourceChange(active); active(editor.currentResource);
    window.floeIDE = {
      // Open a workspace-relative PDF/Office path as an internal CodeBlitz
      // editor tab (custom document component); the native overlay follows.
      openDocument: async (path) => {
        const relative = pathKey('/' + String(path || '').replace(/^\//, ''));
        if (!policy || (policy.kindForPath(relative) !== 'pdf' && policy.kindForPath(relative) !== 'office')) return false;
        await editor.open(new URI('file:///workspace/Floe' + relative));
        return true;
      },
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
