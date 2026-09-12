/* SPDX-License-Identifier: MPL-2.0 — local-only bridge; document text is never executable. */
(() => {
  'use strict';
  let map, documentID, revision, applying = false, pending = false;
  const ids = new Map();
  const uuid = id => {
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id))) return id;
    if (!ids.has(id)) ids.set(id, crypto.randomUUID());
    return ids.get(id);
  };
  const escapeText = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const send = value => window.webkit.messageHandlers.floeNotes.postMessage(value);
  function commit() {
    if (applying || pending || !map) return;
    pending = true; map.editable = false;
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
      nodes.push(node);
      (value.children || []).forEach((child, order) => stack.push({value: child, parent: id, order}));
    }
    const connections = (data.arrows || []).map(a => ({id:uuid(a.id), from:uuid(a.from), to:uuid(a.to), title:String(a.label || ''), delta1:a.delta1, delta2:a.delta2, bidirectional:a.bidirectional, style:Object.fromEntries(Object.entries(a.style || {}).map(([k,v]) => [k,String(v)]))}));
    const summaries = (data.summaries || []).map(s => ({...s,id:uuid(s.id),parent:uuid(s.parent)}));
    send({type:'edit', documentID, revision, nodes, connections, direction:data.direction ?? 2, summaries});
  }
  window.floeRender = payload => {
    applying = true; pending = false; ids.clear();
    documentID = payload.document.id; revision = payload.document.revision;
    const nodes = payload.document.nodes;
    const lookup = new Map(nodes.map(n => [n.id, {
      id:n.id, topic:n.title, note:n.note, expanded:!n.isCollapsed, children:[],
      style:n.style || (n.color ? {background:n.color} : {}), tags:n.tags, icons:n.icons, direction:n.direction, branchColor:n.branchColor, hyperLink:n.hyperLink, metadata:{source:n.source, imageResourceID:n.imageResourceID, isAIGenerated:n.isAIGenerated}
    }]));
    let root;
    for (const node of [...nodes].sort((a,b) => a.order-b.order)) {
      if (node.parentID) lookup.get(node.parentID).children.push(lookup.get(node.id));
      else root = lookup.get(node.id);
    }
    const data = {nodeData:root, arrows:payload.document.connections.map(a => ({id:a.id,from:a.from,to:a.to,label:a.title,delta1:a.delta1,delta2:a.delta2,bidirectional:a.bidirectional,style:a.style})), direction:payload.document.mindMapDirection ?? 2, summaries:payload.document.summaries || []};
    if (!map) {
      const Engine = MindElixir.default;
      map = new Engine({el:'#map',direction:2,editable:true,allowUndo:false,toolBar:true,
        keypress:true,contextMenu:{locale:'zh_CN'},newTopicName:'新主题',markdown:escapeText,
        theme:payload.dark ? Engine.DARK_THEME : Engine.THEME});
      map.init(data);
      map.bus.addListener('operation', operation => { if (operation.name !== 'beginEdit') commit(); });
      map.bus.addListener('expandNode', commit);
      document.addEventListener('keydown', event => {
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
          event.preventDefault(); event.stopImmediatePropagation();
          send({type:event.shiftKey ? 'redo' : 'undo',documentID,revision});
        }
      },true);
    } else {
      map.refresh(data); map.editable = true;
      map.changeTheme(payload.dark ? MindElixir.default.DARK_THEME : MindElixir.default.THEME);
    }
    applying = false;
  };
  window.addEventListener('error', event => send({type:'error',message:String(event.message)}));
  window.addEventListener('unhandledrejection', () => send({type:'error',message:'导图操作失败，请重新打开文档。'}));
  send({type:'ready'});
})();
