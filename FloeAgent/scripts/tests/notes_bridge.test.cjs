// SPDX-License-Identifier: MPL-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const bridgeSource = fs.readFileSync(path.join(__dirname, '../../FloeApp/Resources/MindElixir/floe.js'), 'utf8');
const styleSource = fs.readFileSync(path.join(__dirname, '../../FloeApp/Resources/MindElixir/floe.css'), 'utf8');

// Minimal DOM shared by the bridge tests. `getElementById` walks the attached
// body tree so created buttons and the engine's inline editor are findable.
function makeDom() {
  const document = {
    documentElement: { attributes: {}, setAttribute(name, value) { this.attributes[name] = value; } },
    visibilityState: 'visible',
    listeners: {},
    addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); },
  };
  const element = tag => ({
    tagName: String(tag).toUpperCase(), id: '', className: '', type: '', textContent: '', innerText: '',
    style: {}, dataset: {}, children: [], listeners: {}, isConnected: true,
    setAttribute(name, value) { this[name] = value; },
    addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); },
    appendChild(child) { this.children.push(child); child.parentElement = this; return child; },
    remove() {
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this);
      this.parentElement = null;
      this.removed = true;
    },
    focus() { this.focused = true; },
    querySelector() { return null; },
  });
  document.createElement = element;
  document.getElementById = id => {
    const stack = [document.body];
    while (stack.length) {
      const node = stack.pop();
      if (!node) continue;
      if (node.id === id) return node;
      if (node.children) stack.push(...node.children);
    }
    return null;
  };
  document.querySelector = () => null;
  document.body = element('body');
  return document;
}

function fire(element, type, event) {
  for (const callback of (element && element.listeners[type]) || []) callback(event || {});
}

function bridgeContext({ Engine, document }) {
  const sent = [], observers = [], frames = [];
  const surface = { addEventListener() {} };
  const context = {
    requestAnimationFrame: callback => frames.push(callback),
    setTimeout: (callback, delay) => { const handle = setTimeout(callback, delay); handle.unref?.(); return handle; },
    clearTimeout: handle => clearTimeout(handle),
    ResizeObserver: class { constructor(callback) { this.callback = callback; observers.push(this); } observe(target) { this.target = target; } },
    MindElixir: { default: Engine },
    crypto: require('node:crypto').webcrypto,
    window: { webkit: { messageHandlers: { floeNotes: { postMessage: value => sent.push(value) } } }, addEventListener() {} },
    document,
  };
  document.querySelector = selector => (selector === '#map' ? surface : null);
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  const flush = () => { while (frames.length) frames.shift()(); };
  return { context, sent, observers, frames, surface, flush };
}

test('Notes bridge supplies a complete menu locale and preserves source metadata across edits', () => {
  let instance;
  const sent = [];
  const observers = [], frames = [], domEvents = {};
  const flush = () => { while (frames.length) frames.shift()(); };
  class Engine {
    constructor(options) {
      instance = this;
      for (const key of ['addChild','addParent','addSibling','removeNode','focus','cancelFocus','moveUp','moveDown','link','linkBidirectional','clickTips','summary']) {
        assert.equal(typeof options.contextMenu.locale[key], 'string');
      }
      assert.equal(options.markdown('<img src=x> & English'), '&lt;img src=x&gt; &amp; English');
      this.layouts = 0; this.fits = 0; this.nodes = {};
      this.listeners = {};
      this.bus = {addListener: (event, callback) => { this.listeners[event] = callback; }};
    }
    init(data) { this.data = data; }
    getData() { return this.data; }
    refresh(data) { this.data = data; }
    changeTheme() {}
    linkDiv() { this.layouts++; }
    scaleFit() { this.fits++; }
    findEle(id) { return {nodeObj:{id}}; }
    selectNodes(elements) { this.currentNodes = elements; this.listeners.selectNodes(); }
  }
  const dom = makeDom();
  const surface = { addEventListener: (event, callback) => { domEvents[event] = callback; } };
  dom.querySelector = () => surface;
  const context = {
    requestAnimationFrame: callback => frames.push(callback),
    setTimeout: (callback, delay) => { const handle = setTimeout(callback, delay); handle.unref?.(); return handle; },
    clearTimeout: handle => clearTimeout(handle),
    ResizeObserver: class { constructor(callback) { this.callback = callback; observers.push(this); } observe(target) { this.target = target; } },
    MindElixir: {default: Engine}, crypto: require('node:crypto').webcrypto,
    window: {webkit: {messageHandlers: {floeNotes: {postMessage: value => sent.push(value)}}}, addEventListener() {}},
    document: dom,
  };
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  const id = '11111111-1111-4111-8111-111111111111';
  const source = {documentID: id, revision: 1};
  const imageID = '22222222-2222-4222-8222-222222222222';
  const attachments = [{id: '33333333-3333-4333-8333-333333333333', resourceID:imageID, fileName:'图表.png', mediaType:'image/png', kind:'image', caption:'中英双语 chart'}];
  const document = {id, revision: 2, nodes: [{id, title:'学习 English', note:'', order:0, isCollapsed:false, isAIGenerated:true, source, attachments, imageResourceID:imageID}], connections: []};
  context.window.floeRender({document, dark:false, images:{[imageID]:{url:'data:image/png;base64,fixture',width:80,height:40}}});
  flush();
  assert.equal(instance.fits, 1);
  assert.equal(observers.length, 2);
  assert.equal(instance.data.nodeData.image.width, 80);
  instance.data.nodeData.topic = '编辑后的主题';
  instance.listeners.operation({name: 'finishEdit'});
  const edit = sent.at(-1);
  assert.equal(edit.type, 'edit'); assert.equal(edit.revision, 2);
  assert.equal(edit.nodes[0].title, '编辑后的主题');
  assert.equal(edit.nodes[0].source.documentID, id);
  assert.equal(edit.nodes[0].isAIGenerated, true);
  assert.equal(edit.nodes[0].imageResourceID, imageID);
  assert.equal(JSON.stringify(edit.nodes[0].attachments), JSON.stringify(attachments));
  instance.currentNodes = [{nodeObj:{id}}];
  context.window.floeRender({document:{...document,revision:3},dark:false});
  assert.equal(instance.currentNodes[0].nodeObj.id, id);
  assert.equal(sent.at(-1).type, 'selection');
  assert.equal(instance.editable, true);
  flush();
  assert.equal(instance.fits, 1, 'editing must preserve user zoom');
  const before = instance.layouts;
  observers[1].callback(); domEvents.load(); observers[1].callback();
  flush();
  assert.equal(instance.layouts, before + 1, 'image and tree resizes coalesce to one connector update');
  assert.equal(instance.fits, 1);
  observers[0].callback(); flush();
  assert.equal(instance.fits, 2, 'resizing the PDF window fits the map');
  context.window.floeRender({document:{...document,revision:4,mindMapDirection:3},dark:false});
  flush();
  assert.equal(instance.direction, 3, 'Agent layout changes reach the engine');
  context.window.floeRender({document:{...document,id:imageID,revision:0},dark:false});
  flush();
  assert.equal(instance.fits, 3, 'opening another map fits its own tree');
});

// Tree-backed engine stand-in for the add-action tests. It mirrors the pinned
// engine's call order: addChild fires the operation before editing, while
// insertSibling edits first and fires the operation afterwards.
class TreeEngine {
  constructor(options) {
    TreeEngine.last = this;
    this.options = options;
    this.editable = true;
    this.direction = 2;
    this.layouts = 0;
    this.fits = 0;
    this.currentNodes = [];
    this.listeners = {};
    this.input = null;
    this.elements = new Map();
    this.nextID = 0;
    this.bus = {
      addListener: (event, callback) => { (this.listeners[event] ||= []).push(callback); },
      fire: (event, payload) => { for (const callback of this.listeners[event] || []) callback(payload); },
    };
    this.container = { style: { setProperty() {} } };
    this.nodes = { id: 'me-nodes' };
  }
  get currentNode() { return this.currentNodes[this.currentNodes.length - 1]; }
  elementFor(node) {
    const element = {
      id: 'topic-' + node.id, className: '', nodeObj: node, isConnected: true, style: {},
      focus() { this.focused = true; },
    };
    this.elements.set(node.id, element);
    return element;
  }
  wireParents(node, parent) {
    node.parent = parent;
    (node.children || []).forEach(child => this.wireParents(child, node));
  }
  layout() {
    this.elements = new Map();
    const visit = node => { this.elementFor(node); (node.children || []).forEach(visit); };
    visit(this.data.nodeData);
  }
  init(data) { this.data = data; this.wireParents(data.nodeData, null); this.layout(); }
  refresh(data) {
    // The real engine rebuilds `me-nodes`, which removes an open inline editor.
    if (this.input) { this.input.remove(); this.input = null; }
    this.data = data;
    this.wireParents(data.nodeData, null);
    this.clearSelection();
    this.layout();
    this.editable = true;
  }
  getData() { return this.data; }
  changeTheme() {}
  linkDiv() { this.layouts += 1; }
  scaleFit() { this.fits += 1; }
  findEle(id) { return this.elements.get(id) || null; }
  clearSelection() {
    if (!this.currentNodes.length) return;
    this.currentNodes = [];
    this.bus.fire('unselectNodes', []);
  }
  selectNode(element) {
    if (!element) return;
    this.currentNodes = [element];
    this.bus.fire('selectNodes', [element.nodeObj]);
  }
  selectNodes(elements) {
    this.currentNodes = elements;
    this.bus.fire('selectNodes', elements.map(element => element.nodeObj));
  }
  editTopic(element) {
    const node = element.nodeObj;
    const input = activeDocument.createElement('div');
    input.id = 'input-box';
    input.textContent = node.topic;
    input.focus = () => { input.focused = true; };
    input.blur = () => {
      const text = String(input.textContent || '').trim();
      input.remove();
      this.input = null;
      if (text && text !== node.topic) {
        node.topic = text;
        this.bus.fire('operation', { name: 'finishEdit', obj: node });
      }
    };
    activeDocument.body.appendChild(input);
    this.input = input;
    this.bus.fire('operation', { name: 'beginEdit', obj: node });
    return input;
  }
  addChild(element) {
    const target = element || this.currentNode;
    const parent = target.nodeObj;
    const created = { id: 'engine-' + (++this.nextID), topic: this.options.newTopicName, note: '', expanded: true, children: [] };
    (parent.children ||= []).push(created);
    const createdElement = this.elementFor(created);
    this.bus.fire('operation', { name: 'addChild', obj: created });
    this.editTopic(createdElement);
    this.selectNode(createdElement);
  }
  insertSibling(type, element) {
    const target = element || this.currentNode;
    const node = target.nodeObj;
    if (!node.parent) return;
    const siblings = node.parent.children;
    const index = siblings.indexOf(node);
    const created = { id: 'engine-' + (++this.nextID), topic: this.options.newTopicName, note: '', expanded: true, children: [] };
    siblings.splice(type === 'before' ? index : index + 1, 0, created);
    const createdElement = this.elementFor(created);
    this.editTopic(createdElement);
    this.bus.fire('operation', { name: 'insertSibling', type, obj: created });
    this.selectNode(createdElement);
  }
}

let activeDocument = null;

function createTreeEnvironment() {
  const document = makeDom();
  activeDocument = document;
  const bridge = bridgeContext({ Engine: TreeEngine, document });
  return Object.assign(bridge, { document });
}

function commitBack(environment, base, edit, revision) {
  environment.context.window.floeRender({
    document: {
      id: base.id, revision,
      nodes: edit.nodes, connections: edit.connections,
      mindMapDirection: edit.direction, summaries: edit.summaries,
    },
    dark: false,
  });
  environment.flush();
}

test('Floe add actions create topics, keep the editor alive and give clear feedback', async () => {
  const environment = createTreeEnvironment();
  const id = '11111111-1111-4111-8111-111111111111';
  const branchID = '22222222-2222-4222-8222-222222222222';
  const base = { id, revision: 2, nodes: [
    { id, title: '中心主题', note: '', order: 0, isCollapsed: false },
    { id: branchID, parentID: id, title: '分支 A', note: '', order: 0, isCollapsed: false },
  ], connections: [] };
  environment.context.window.floeRender({ document: base, dark: false });
  environment.flush();
  const engine = TreeEngine.last;
  const document = environment.document;

  const childButton = document.getElementById('floe-add-child');
  const siblingButton = document.getElementById('floe-add-sibling');
  assert.ok(childButton && siblingButton, 'the top-left add actions are installed');
  assert.equal(childButton.textContent, '新增子节点');
  assert.equal(siblingButton.textContent, '新增同级节点');
  assert.equal(document.documentElement.attributes['data-floe-theme'], 'light');

  // No selected topic: the tap is refused with a visible reason, not silently.
  fire(childButton, 'pointerup');
  assert.equal(document.getElementById('floe-hint').textContent, '请先选择主题，再新增子节点。');
  assert.equal(environment.sent.filter(value => value.type === 'edit').length, 0);

  // The center topic cannot receive a sibling.
  engine.selectNode(engine.findEle(id));
  fire(siblingButton, 'pointerup');
  assert.equal(document.getElementById('floe-hint').textContent, '中心主题没有同级节点，请选择分支主题。');
  assert.equal(environment.sent.filter(value => value.type === 'edit').length, 0);

  // A selected branch adds a child and starts editing immediately.
  engine.selectNode(engine.findEle(branchID));
  const layoutsBefore = engine.layouts;
  await new Promise(resolve => setTimeout(resolve, 420));
  fire(childButton, 'pointerup');
  environment.flush();
  const added = environment.sent.filter(value => value.type === 'edit').at(-1);
  assert.equal(added.type, 'edit');
  assert.equal(added.nodes.length, 3);
  const created = added.nodes.find(node => node.parentID === branchID);
  assert.ok(created, 'the new child is committed right away');
  assert.equal(created.title, '新主题');
  assert.ok(document.getElementById('input-box'), 'the inline editor opens without another canvas tap');
  assert.ok(engine.layouts > layoutsBefore, 'connectors are refreshed after adding');

  // The native commit round-trip must not discard the editor; zoom is kept.
  const fitsBefore = engine.fits;
  commitBack(environment, base, added, 3);
  assert.ok(document.getElementById('input-box'), 'a refresh reopens the inline editor');
  assert.equal(engine.editable, true);
  assert.equal(engine.fits, fitsBefore, 'editing preserves user zoom');
  assert.equal(engine.currentNodes[0].nodeObj.id, created.id, 'the new topic stays selected');

  // Typing then leaving the editor commits the real title once.
  const input = document.getElementById('input-box');
  input.textContent = '机会成本';
  input.blur();
  environment.flush();
  const edited = environment.sent.filter(value => value.type === 'edit').at(-1);
  assert.equal(edited.type, 'edit');
  assert.equal(edited.nodes.find(node => node.id === created.id).title, '机会成本');

  // Adding a sibling of the selected branch keeps the same guarantees.
  commitBack(environment, base, edited, 4);
  engine.selectNode(engine.findEle(branchID));
  await new Promise(resolve => setTimeout(resolve, 420));
  fire(siblingButton, 'pointerup');
  const siblingEdit = environment.sent.filter(value => value.type === 'edit').at(-1);
  assert.equal(siblingEdit.type, 'edit');
  const sibling = siblingEdit.nodes.find(node => node.parentID === id && node.id !== branchID && node.id !== created.id);
  assert.ok(sibling, 'the sibling is committed under the center topic');
  assert.ok(document.getElementById('input-box'), 'the sibling editor stays available');
});

test('Floe add actions keep typed text when a refresh interrupts and the editor closes without finishEdit', async () => {
  const environment = createTreeEnvironment();
  const id = '11111111-1111-4111-8111-111111111111';
  const base = { id, revision: 2, nodes: [
    { id, title: '中心主题', note: '', order: 0, isCollapsed: false },
  ], connections: [] };
  environment.context.window.floeRender({ document: base, dark: false });
  environment.flush();
  const engine = TreeEngine.last;
  const document = environment.document;

  engine.selectNode(engine.findEle(id));
  fire(document.getElementById('floe-add-child'), 'pointerup');
  environment.flush();
  const added = environment.sent.filter(value => value.type === 'edit').at(-1);
  commitBack(environment, base, added, 3);

  // Typing followed by an unrelated native refresh: the text is carried into
  // the engine data and the editor is reopened with it.
  let input = document.getElementById('input-box');
  input.textContent = '成本';
  commitBack(environment, base, added, 3);
  input = document.getElementById('input-box');
  assert.ok(input, 'the editor is still open after the refresh');
  assert.equal(input.textContent, '成本');

  // The engine only fires finishEdit when the text differs from the reopened
  // baseline, so closing this editor relies on the bridge flush.
  input.blur();
  fire(document, 'focusout', { target: input });
  await new Promise(resolve => setTimeout(resolve, 20));
  const saved = environment.sent.filter(value => value.type === 'edit').at(-1);
  assert.equal(saved.nodes.find(node => node.parentID === id).title, '成本');
});

test('Floe add actions recover when a native commit never returns', async () => {
  const environment = createTreeEnvironment();
  const id = '11111111-1111-4111-8111-111111111111';
  const base = { id, revision: 2, nodes: [
    { id, title: '中心主题', note: '', order: 0, isCollapsed: false },
  ], connections: [] };
  environment.context.window.floeRender({ document: base, dark: false });
  environment.flush();
  const engine = TreeEngine.last;
  const document = environment.document;

  engine.selectNode(engine.findEle(id));
  fire(document.getElementById('floe-add-child'), 'pointerup');
  environment.flush();
  assert.equal(engine.editable, false, 'a commit pauses editing until the refresh lands');
  fire(document.getElementById('floe-add-sibling'), 'pointerup');
  assert.equal(document.getElementById('floe-hint').textContent, '正在保存，请稍候再新增。');

  // Simulate a dropped native round-trip: the watchdog must unfreeze editing.
  await new Promise(resolve => setTimeout(resolve, 2150));
  assert.equal(engine.editable, true, 'a dropped round-trip must not freeze the editor');
  const editsBefore = environment.sent.filter(value => value.type === 'edit').length;
  fire(document.getElementById('floe-add-child'), 'pointerup');
  environment.flush();
  assert.equal(environment.sent.filter(value => value.type === 'edit').length, editsBefore + 1,
    'adding still works after the watchdog recovers');
});

test('Floe styles keep the add actions touch sized and the engine toolbar off the top-left', () => {
  assert.match(styleSource, /\.floe-action\{[^}]*min-height:44px/);
  assert.match(styleSource, /\.mind-elixir-toolbar\.lt\{top:auto;bottom:20px;left:20px\}/);
});
