// Host-owned integration. Ketcher's pinned distribution is kept unchanged.
(() => {
  const post = (type, data = {}) => window.webkit.messageHandlers.chemistry.postMessage({ type, ...data });
  const api = {
    loading: true, disposed: false, version: 0, timer: null, capturing: false, lastKet: null,
    async load(source) {
      this.loading = true;
      clearTimeout(this.timer);
      await window.ketcher.setMolecule(source);
      this.lastKet = await window.ketcher.getKet();
      this.loading = false;
      post('loaded');
    },
    changed() {
      if (this.loading || this.disposed) return;
      this.version++;
      post('dirty');
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.capture(), 350);
    },
    async capture() {
      if (this.disposed || this.loading) return;
      if (this.capturing) { this.timer = setTimeout(() => this.capture(), 100); return; }
      this.capturing = true;
      const version = this.version;
      try {
        const k = window.ketcher;
        const ket = await k.getKet();
        let source = null, format = null, smiles = null, properties = null;
        try {
          if (k.containsReaction()) { source = await k.getRxn('v3000'); format = 'rxn'; }
          else { source = await k.getMolfile('v3000'); format = 'mol'; }
        } catch (_) { /* Incomplete diagrams still have a lossless KET document. */ }
        try { smiles = await k.getSmiles(); } catch (_) {}
        try { properties = await k.indigo.calculate(ket, { properties: ['gross', 'molecular-weight'] }); } catch (_) {}
        if (version !== this.version) { this.timer = setTimeout(() => this.capture(), 100); return; }
        if (ket !== this.lastKet) {
          post('snapshot', { ket, source, format, smiles, properties, version });
          this.lastKet = ket;
        } else { post('unchanged'); }
      } catch (error) { post('error', { message: String(error) }); }
      finally { this.capturing = false; }
    },
    async flush() {
      clearTimeout(this.timer);
      while (this.capturing) await new Promise(resolve => setTimeout(resolve, 20));
      await this.capture();
    },
    dispose() {
      this.disposed = true; clearTimeout(this.timer);
      if (this.observer) this.observer.disconnect();
      if (this.subscription) window.ketcher.editor.unsubscribe('change', this.subscription);
    }
  };
  window.floeChemistry = api;
  const start = Date.now();
  const wait = setInterval(() => {
    if (api.disposed) { clearInterval(wait); return; }
    if (window.ketcher && window.ketcher.editor) {
      clearInterval(wait);
      api.subscription = window.ketcher.editor.subscribe('change', () => api.changed());
      // The hidden clipboard field keeps hardware shortcuts without raising the
      // software keyboard for every drawing tap. Visible label fields stay native.
      const adaptClipboard = () => document.querySelectorAll('.cliparea').forEach(element => element.setAttribute('inputmode', 'none'));
      adaptClipboard();
      api.observer = new MutationObserver(adaptClipboard);
      api.observer.observe(document.body, { childList: true, subtree: true });
      post('ready');
    } else if (Date.now() - start > 60000) {
      clearInterval(wait); post('error', { message: 'The offline structure editor did not finish loading.' });
    }
  }, 100);
})();
