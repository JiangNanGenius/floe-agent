// SPDX-License-Identifier: MPL-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

test('Notes bridge supplies a complete menu locale and preserves source metadata across edits', () => {
  let instance;
  const sent = [];
  const observers = [], frames = [], domEvents = {};
  const surface = {addEventListener: (event, callback) => { domEvents[event] = callback; }};
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
  const context = {
    requestAnimationFrame: callback => frames.push(callback),
    ResizeObserver: class { constructor(callback) { this.callback = callback; observers.push(this); } observe(target) { this.target = target; } },
    MindElixir: {default: Engine}, crypto: require('node:crypto').webcrypto,
    window: {webkit: {messageHandlers: {floeNotes: {postMessage: value => sent.push(value)}}}, addEventListener() {}},
    document: {addEventListener() {}, querySelector: () => surface} };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../FloeApp/Resources/MindElixir/floe.js'), 'utf8'), context);
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
