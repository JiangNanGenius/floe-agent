/* SPDX-License-Identifier: MPL-2.0 — local-only bridge; document text is never executable. */
(() => {
  'use strict';
  let map, documentID, revision, applying = false, pending = false;
  const ids = new Map();
  let fitScheduled = false, needsFit = false;
  // Top-left add actions and inline-edit tracking. The engine starts a text
  // editor immediately after adding a node; a commit round-trip must not
  // discard it, and a deferred commit must still reach the native store.
  let lastSelectedID = null, editing = null, deferredCommit = false, hintTimer = null;
  // Set when a refresh keeps in-progress editor text the native store has not
  // seen yet; closing that editor must commit it even without a finishEdit.
  let pendingEditCommit = false;
  // A commit disables editing until the native refresh lands. Never leave the
  // editor frozen if that round-trip is dropped.
  let pendingTimer = null;
  const armPendingWatchdog = () => {
    if (typeof setTimeout !== 'function') return;
    if (pendingTimer && typeof clearTimeout === 'function') clearTimeout(pendingTimer);
    pendingTimer = setTimeout(() => {
      pendingTimer = null;
      if (pending && map) { pending = false; map.editable = true; scheduleLayout(); }
    }, 2000);
  };
  const scheduleLayout = (fit = false) => {
    needsFit ||= fit;
    if (fitScheduled) return;
    fitScheduled = true;
    const update = () => {
      fitScheduled = false;
      // CSS measures the tree from real topic/image sizes. Redraw edges only:
      // rebuilding nodes here would discard the active text editor and selection.
      map?.linkDiv?.();
      if (needsFit) map?.scaleFit?.();
      needsFit = false;
    };
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(update);
    else update();
  };
  const uuid = id => {
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id))) return id;
    if (!ids.has(id)) ids.set(id, crypto.randomUUID());
    return ids.get(id);
  };
  const escapeText = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const send = value => window.webkit.messageHandlers.floeNotes.postMessage(value);
  const inputBox = () => (typeof document.getElementById === 'function' ? document.getElementById('input-box') : null);
  const isEditing = () => !!inputBox();
  const topicText = box => {
    const rendered = typeof box.innerText === 'string' ? box.innerText.trim() : '';
    const raw = String(box.textContent || '').trim();
    return rendered || raw;
  };
  // An open editor has text the engine has not written back yet (blur does).
  // Copy it into the engine data so any later commit carries it.
  const syncEditingText = () => {
    if (!map || !editing) return;
    const box = inputBox();
    if (!box) return;
    const text = topicText(box);
    if (!text) return;
    let element = null;
    for (const key of [editing.rawID, editing.id]) {
      if (!key) continue;
      try { element = map.findEle(key); } catch { element = null; }
      if (element && element.nodeObj) break;
    }
    if (element?.nodeObj) element.nodeObj.topic = text;
  };
  const flushCommit = force => {
    if (!deferredCommit && !pendingEditCommit && !force) return;
    deferredCommit = false; pendingEditCommit = false;
    commit(force);
  };
  const showHint = message => {
    if (typeof document.createElement !== 'function' || !document.body) return;
    let hint = typeof document.getElementById === 'function' ? document.getElementById('floe-hint') : null;
    if (!hint) {
      hint = document.createElement('div');
      hint.id = 'floe-hint';
      hint.className = 'floe-hint';
      hint.setAttribute('role', 'status');
      hint.setAttribute('aria-live', 'polite');
      document.body.appendChild(hint);
    }
    hint.textContent = message;
    hint.classList?.add('show');
    if (hintTimer && typeof clearTimeout === 'function') clearTimeout(hintTimer);
    if (typeof setTimeout === 'function') {
      hintTimer = setTimeout(() => {
        hintTimer = null;
        hint.classList?.remove('show');
      }, 2400);
    }
  };
  const selectedElement = () => {
    if (!map) return null;
    const current = map.currentNode || (map.currentNodes || [])[0];
    if (current && current.isConnected !== false) return current;
    if (lastSelectedID) {
      try {
        const element = map.findEle(lastSelectedID);
        if (element) return element;
      } catch { /* fall through to the no-selection hint */ }
    }
    return null;
  };
  const placeCaret = (box, selectAll) => {
    if (!box || typeof document.createRange !== 'function') return;
    try {
      const range = document.createRange();
      range.selectNodeContents(box);
      if (!selectAll) range.collapse(false);
      const selection = typeof window.getSelection === 'function' ? window.getSelection() : null;
      if (!selection) return;
      selection.removeAllRanges();
      selection.addRange(range);
    } catch { /* caret placement is cosmetic */ }
  };
  const captureEdit = () => {
    if (!editing) return null;
    const box = inputBox();
    if (!box) return null;
    return { id: editing.id, text: topicText(box), initial: editing.initial || '' };
  };
  const restoreEdit = edit => {
    if (!map) return;
    let element = null;
    try { element = map.findEle(edit.id); } catch { element = null; }
    if (!element) return;
    try { map.editTopic(element); } catch { return; }
    const box = inputBox();
    if (!box) return;
    if (typeof box.focus === 'function') { try { box.focus(); } catch { /* keyboard stays closed */ } }
    // Typed text keeps the caret at the end so typing continues; untouched
    // default text stays selected so the next keystroke replaces it.
    placeCaret(box, !edit.text || edit.text === edit.initial);
  };
  const runAction = kind => {
    if (!map) { showHint('导图还在加载，请稍后再试。'); return; }
    if (!map.editable) { showHint('正在保存，请稍候再新增。'); return; }
    const element = selectedElement();
    if (!element) {
      showHint(kind === 'sibling' ? '请先选择参考主题，再新增同级节点。' : '请先选择主题，再新增子节点。');
      return;
    }
    if (kind === 'sibling' && !(element.nodeObj && element.nodeObj.parent)) {
      showHint('中心主题没有同级节点，请选择分支主题。');
      return;
    }
    try {
      if (kind === 'sibling') map.insertSibling('after', element);
      else map.addChild(element);
    } catch { showHint('新增失败，请重试。'); return; }
    const box = inputBox();
    if (box) {
      if (typeof box.focus === 'function') { try { box.focus(); } catch { /* engine selection is enough */ } }
      // Keep the new topic name selected so the first keystroke replaces it,
      // matching the engine's own begin-edit behavior on a fresh node.
      placeCaret(box, true);
    }
  };
  const installActions = () => {
    if (typeof document.createElement !== 'function' || !document.body) return;
    if (typeof document.getElementById === 'function' && document.getElementById('floe-actions')) return;
    const bar = document.createElement('div');
    bar.id = 'floe-actions'; bar.className = 'floe-actions';
    bar.setAttribute('role', 'toolbar');
    bar.setAttribute('aria-label', '新增主题');
    const add = (id, label, kind) => {
      const button = document.createElement('button');
      button.id = id; button.type = 'button'; button.className = 'floe-action';
      button.textContent = label;
      button.setAttribute('aria-label', label);
      let lastRun = 0;
      const invoke = event => {
        if (event && typeof event.preventDefault === 'function') { event.preventDefault(); event.stopPropagation(); }
        const now = Date.now();
        if (now - lastRun < 400) return; // pointerup and click describe the same tap
        lastRun = now;
        runAction(kind);
      };
      button.addEventListener('pointerup', invoke);
      button.addEventListener('click', invoke);
      bar.appendChild(button);
    };
    add('floe-add-child', '新增子节点', 'child');
    add('floe-add-sibling', '新增同级节点', 'sibling');
    document.body.appendChild(bar);
  };
  const applyTheme = dark => {
    const root = document.documentElement;
    if (root && typeof root.setAttribute === 'function') root.setAttribute('data-floe-theme', dark ? 'dark' : 'light');
  };
  function commit(force = false) {
    if (applying || pending || !map) return;
    // Never refresh over an open inline editor unless the change is a new node:
    // the pending edit is flushed when the editor closes.
    if (!force && isEditing()) { deferredCommit = true; return; }
    pending = true; map.editable = false;
    syncEditingText();
    const data = map.getData(), nodes = [];
    const stack = [{ value: data.nodeData, parent: null, order: 0 }];
    while (stack.length) {
      const {value, parent, order} = stack.pop();
      const id = uuid(value.id);
      const node = {id, title: String(value.topic || ''), note: String(value.note || ''), order, isCollapsed: value.expanded === false};
      if (parent) node.parentID = parent;
      node.style = Object.fromEntries(Object.entries(value.style || {}).map(([key,value]) => [key,String(value)]));
      node.tags = (value.tags || []).map(tag => typeof tag === 'string' ? tag : String(tag.text || ''));
      node.icons = (value.icons || []).map(String);
      if (value.direction === 0 || value.direction === 1) node.direction = value.direction;
      if (value.branchColor) node.branchColor = value.branchColor;
      if (value.hyperLink) node.hyperLink = value.hyperLink;
      if (value.style?.background) node.color = value.style.background;
      // Metadata is supplied only by the native model; never HTML from a pasted node.
      if (value.metadata?.isAIGenerated !== undefined) node.isAIGenerated = value.metadata.isAIGenerated;
      if (value.metadata?.source) node.source = value.metadata.source;
      if (value.metadata?.imageResourceID) node.imageResourceID = value.metadata.imageResourceID;
      if (value.metadata?.attachments) node.attachments = value.metadata.attachments;
      nodes.push(node);
      (value.children || []).forEach((child, order) => stack.push({value: child, parent: id, order}));
    }
    const connections = (data.arrows || []).map(a => ({id:uuid(a.id), from:uuid(a.from), to:uuid(a.to), title:String(a.label || ''), delta1:a.delta1, delta2:a.delta2, bidirectional:a.bidirectional, style:Object.fromEntries(Object.entries(a.style || {}).map(([k,v]) => [k,String(v)]))}));
    const summaries = (data.summaries || []).map(s => ({...s,id:uuid(s.id),parent:uuid(s.parent)}));
    send({type:'edit', documentID, revision, nodes, connections, direction:data.direction ?? 2, summaries});
    armPendingWatchdog();
  }
  window.floeRender = payload => {
    applyTheme(!!payload.dark);
    installActions();
    const changedDocument = documentID !== payload.document.id;
    const selection = (changedDocument ? [] : map?.currentNodes || []).map(element => uuid(element.nodeObj.id));
    // A native refresh rebuilds the tree, which removes the inline text editor
    // the add actions just opened. Capture it and reopen it once the tree is
    // refreshed so typing continues without another canvas tap.
    const activeEdit = changedDocument ? null : captureEdit();
    if (changedDocument) { editing = null; deferredCommit = false; pendingEditCommit = false; }
    if (pendingTimer && typeof clearTimeout === 'function') { clearTimeout(pendingTimer); pendingTimer = null; }
    applying = true; pending = false; ids.clear();
    try {
    documentID = payload.document.id; revision = payload.document.revision;
    const nodes = payload.document.nodes;
    const lookup = new Map(nodes.map(n => [n.id, {
      id:n.id, topic:n.title, note:n.note, expanded:!n.isCollapsed, children:[], image:(payload.images || {})[n.imageResourceID],
      style:n.style || (n.color ? {background:n.color} : {}), tags:n.tags, icons:n.icons, direction:n.direction, branchColor:n.branchColor, hyperLink:n.hyperLink, metadata:{attachments:n.attachments, source:n.source, imageResourceID:n.imageResourceID, isAIGenerated:n.isAIGenerated}
    }]));
    if (activeEdit && lookup.has(activeEdit.id) && activeEdit.text) {
      lookup.get(activeEdit.id).topic = activeEdit.text;
      if (activeEdit.text !== activeEdit.initial) pendingEditCommit = true;
    }
    let root;
    for (const node of [...nodes].sort((a,b) => a.order-b.order)) {
      if (node.parentID) lookup.get(node.parentID).children.push(lookup.get(node.id));
      else root = lookup.get(node.id);
    }
    const data = {nodeData:root, arrows:payload.document.connections.map(a => ({id:a.id,from:a.from,to:a.to,label:a.title,delta1:a.delta1,delta2:a.delta2,bidirectional:a.bidirectional,style:a.style})), direction:payload.document.mindMapDirection ?? 2, summaries:payload.document.summaries || []};
    if (!map) {
      const Engine = MindElixir.default;
      const instance = new Engine({el:'#map',direction:2,editable:true,allowUndo:false,toolBar:true,
        keypress:true,contextMenu:{locale:{
          addChild:'插入子节点',addParent:'插入父节点',addSibling:'插入同级节点',removeNode:'删除节点',
          focus:'专注',cancelFocus:'取消专注',moveUp:'上移',moveDown:'下移',link:'连接',
          linkBidirectional:'双向连接',clickTips:'请点击目标节点',summary:'摘要'
        }},newTopicName:'新主题',markdown:escapeText,
        theme:payload.dark ? Engine.DARK_THEME : Engine.THEME});
      instance.init(data); map = instance;
      scheduleLayout(true);
      if (typeof ResizeObserver === 'function') {
        new ResizeObserver(() => scheduleLayout(true)).observe(document.querySelector('#map'));
        // Topic dimensions change after image decode, wrapping, folding, or edits.
        // Observe the tree, not its transformed viewport (zoom must not recurse).
        new ResizeObserver(() => scheduleLayout()).observe(map.nodes);
      }
      map.bus.addListener('operation', operation => {
        if (operation.name === 'beginEdit') {
          if (operation.obj && operation.obj.id !== undefined) {
            editing = {id:uuid(operation.obj.id), rawID:operation.obj.id, initial:String(operation.obj.topic || '')};
          }
          return;
        }
        if (operation.name === 'finishEdit') { editing = null; pendingEditCommit = false; scheduleLayout(); commit(); return; }
        scheduleLayout();
        // Node creation starts a text editor in the same tick; commit right away
        // so undo and save stay accurate, then restore the editor after refresh.
        commit(['addChild','insertSibling','insertParent'].includes(operation.name));
      });
      map.bus.addListener('expandNode', () => { scheduleLayout(); commit(); });
      document.querySelector('#map').addEventListener('load', () => scheduleLayout(), true);
      const reportSelection = () => {
        const selected = map.currentNodes[0] ? uuid(map.currentNodes[0].nodeObj.id) : null;
        if (selected) lastSelectedID = selected;
        else lastSelectedID = null;
        send({type:'selection',documentID,revision,nodeID:selected});
      };
      map.bus.addListener('selectNodes', reportSelection);
      map.bus.addListener('unselectNodes', reportSelection);
      document.addEventListener('keydown', event => {
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
          event.preventDefault(); event.stopImmediatePropagation();
          send({type:event.shiftKey ? 'redo' : 'undo',documentID,revision});
        }
      },true);
    } else {
      // refresh(data) in the pinned engine does not apply data.direction.
      map.direction = data.direction;
      map.refresh(data); map.editable = true;
      map.changeTheme(payload.dark ? MindElixir.default.DARK_THEME : MindElixir.default.THEME);
      const elements = selection.filter(id => lookup.has(id)).flatMap(id => { try { return [map.findEle(id)]; } catch { return []; } });
      if (elements.length) map.selectNodes(elements);
      if (activeEdit && lookup.has(activeEdit.id)) restoreEdit(activeEdit);
      scheduleLayout(changedDocument);
    }
    } finally { applying = false; }
  };
  // The inline editor is the only place text can be lost when the page goes
  // away; flush a deferred commit on teardown and on editor close.
  document.addEventListener('focusout', event => {
    if (!event.target || event.target.id !== 'input-box') return;
    if (typeof setTimeout !== 'function') return;
    setTimeout(() => {
      if (isEditing()) return;
      // A blur can also follow a refresh that restored in-progress editor text;
      // flushCommit covers both the restored text and any deferred operation.
      flushCommit(false);
    }, 0);
  }, true);
  window.addEventListener('pagehide', () => flushCommit(true));
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flushCommit(true); });
  window.floeFlush = () => flushCommit(true);
  window.addEventListener('error', event => send({type:'error',message:String(event.message)}));
  window.addEventListener('unhandledrejection', () => send({type:'error',message:'导图操作失败，请重新打开文档。'}));
  send({type:'ready'});
})();
