// SPDX-License-Identifier: MPL-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

test('Notes bridge supplies a complete menu locale and preserves source metadata across edits', () => {
  let instance;
  const sent = [];
  class Engine {
    constructor(options) {
      instance = this;
      for (const key of ['addChild','addParent','addSibling','removeNode','focus','cancelFocus','moveUp','moveDown','link','linkBidirectional','clickTips','summary']) {
        assert.equal(typeof options.contextMenu.locale[key], 'string');
      }
      assert.equal(options.markdown('<img src=x> & English'), '&lt;img src=x&gt; &amp; English');
      this.listeners = {};
      this.bus = {addListener: (event, callback) => { this.listeners[event] = callback; }};
    }
    init(data) { this.data = data; }
    getData() { return this.data; }
    refresh(data) { this.data = data; }
    changeTheme() {}
  }
  const context = { MindElixir: {default: Engine}, crypto: require('node:crypto').webcrypto,
    window: {webkit: {messageHandlers: {floeNotes: {postMessage: value => sent.push(value)}}}, addEventListener() {}},
    document: {addEventListener() {}} };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../FloeApp/Resources/MindElixir/floe.js'), 'utf8'), context);
  const id = '11111111-1111-4111-8111-111111111111';
  const source = {documentID: id, revision: 1};
  const document = {id, revision: 2, nodes: [{id, title:'学习 English', note:'', order:0, isCollapsed:false, isAIGenerated:true, source}], connections: []};
  context.window.floeRender({document, dark:false});
  instance.data.nodeData.topic = '编辑后的主题';
  instance.listeners.operation({name: 'finishEdit'});
  const edit = sent.at(-1);
  assert.equal(edit.type, 'edit'); assert.equal(edit.revision, 2);
  assert.equal(edit.nodes[0].title, '编辑后的主题');
  assert.equal(edit.nodes[0].source.documentID, id);
  assert.equal(edit.nodes[0].isAIGenerated, true);
});
