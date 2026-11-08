// SPDX-License-Identifier: MPL-2.0
// Internal, bundled editor engine. No model-authored JavaScript is evaluated.
export const clone = value => structuredClone(value);
export const uid = () => globalThis.crypto?.randomUUID?.() ?? `id-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
export const t = (zh, en) => (globalThis.navigator?.language ?? 'en').startsWith('zh') ? zh : en;
export const finite = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
export const required = (value, message) => { if (value === undefined || value === null) throw new Error(message); return value; };
export const utf8 = value => new TextEncoder().encode(value);
export const text = value => new TextDecoder().decode(value);
export function bytes64(bytes) {
  let result = ''; const array = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (let i = 0; i < array.length; i += 0x4000) result += String.fromCharCode(...array.subarray(i, i + 0x4000));
  return btoa(result);
}
export function from64(value) { const s = atob(value); return Uint8Array.from(s, c => c.charCodeAt(0)); }
export function artifact(name, mediaType, bytes) { return { name, mediaType, base64: bytes64(typeof bytes === 'string' ? utf8(bytes) : bytes) }; }
export function element(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key in node && !key.startsWith('aria')) node[key] = value;
    else node.setAttribute(key, value);
  }
  for (const child of children.flat()) if (child !== undefined && child !== null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return node;
}
export function parseXML(value) {
  if (/<!DOCTYPE|<!ENTITY/i.test(value)) throw new Error(t('文件包含不支持的外部定义。', 'External document definitions are not supported.'));
  const doc = new DOMParser().parseFromString(value, 'application/xml');
  if (doc.querySelector('parsererror')) throw new Error(t('无法读取这个 XML 文件。', 'Unable to read this XML file.'));
  return doc;
}
export const escapeXML = value => String(value).replace(/[<>&"']/g, c => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;', '"':'&quot;', "'":'&apos;' }[c]));

function diff(before, after, path = [], forward = [], inverse = []) {
  if (JSON.stringify(before) === JSON.stringify(after)) return { forward, inverse };
  if (before && after && typeof before === 'object' && typeof after === 'object'
      && Array.isArray(before) === Array.isArray(after)
      && (!Array.isArray(before) || before.length === after.length && before.length < 512)) {
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    for (const key of keys) diff(before[key], after[key], [...path, key], forward, inverse);
  } else {
    forward.push({ path, value: after === undefined ? null : clone(after), remove: after === undefined });
    inverse.unshift({ path, value: before === undefined ? null : clone(before), remove: before === undefined });
  }
  return { forward, inverse };
}
function apply(data, patches) {
  for (const patch of patches) {
    if(!Array.isArray(patch.path)||patch.path.length>64||patch.path.some(key=>typeof key!=='string'&&typeof key!=='number'))throw new Error('Invalid history path');
    if (!patch.path.length) { data = clone(patch.value); continue; }
    let parent = data;
    for (const key of patch.path.slice(0, -1)) {
      if(!parent||typeof parent!=='object'||!Object.hasOwn(parent,key))throw new Error('Invalid history path');
      parent = parent[key];
    }
    if(!parent||typeof parent!=='object')throw new Error('Invalid history target');
    const key = patch.path.at(-1);
    if(Array.isArray(parent)&&(!/^\d+$/.test(String(key))||Number(key)>parent.length))throw new Error('Invalid history array index');
    if (patch.remove) delete parent[key]; else Object.defineProperty(parent,key,{value:clone(patch.value),writable:true,enumerable:true,configurable:true});
  }
  return data;
}

export class EditorEngine {
  constructor(configuration) {
    this.configuration = configuration;
    this.commands = new Map(); this.pending = new Map(); this.revision = 0;
    this.envelope = null; this.payload = { data: configuration.create(), history: { past: [], future: [] } };
    this.requestTail = Promise.resolve(); this.abortController = new AbortController(); this.state = this.payload.data;
    this.nativeChrome=false;
    let selection;
    Object.defineProperty(this,'selection',{get:()=>selection,set:value=>{selection=value;this.notifyPresentation();},configurable:false});
    this.register({ id: 'document.save', title: t('保存', 'Save'), group: t('工程', 'Project'), access: 'edit', fields: [] }, () => ({ saved: true }));
    this.register({ id: 'document.inspect', title: t('工程信息', 'Project information'), group: t('工程', 'Project'), access: 'read', fields: [] }, () => ({ kind: configuration.kind, revision: this.revision, document: this.state }));
    this.register({ id: 'document.rename', title: t('重命名', 'Rename'), group: t('工程', 'Project'), access: 'edit', fields: [{ key: 'title', label: t('名称', 'Name'), type: 'text' }] }, args => { this.state.title = String(args.title || this.state.title); });
    this.register({ id: 'history.undo', title: t('撤销', 'Undo'), group: t('工程', 'Project'), access: 'edit', fields: [] }, () => {
      const entry = this.payload.history.past.pop(); if (!entry) return { changed: false };
      this.state = this.payload.data = apply(this.state, entry.inverse); this.payload.history.future.push(entry); return { changed: true };
    });
    this.register({ id: 'history.redo', title: t('重做', 'Redo'), group: t('工程', 'Project'), access: 'edit', fields: [] }, () => {
      const entry = this.payload.history.future.pop(); if (!entry) return { changed: false };
      this.state = this.payload.data = apply(this.state, entry.forward); this.payload.history.past.push(entry); return { changed: true };
    });
    this.register({ id: 'history.list', title: t('修订记录', 'Revision history'), group: t('工程', 'Project'), access: 'read', fields: [] }, () => this.payload.history.past.map(({ id, title, date }) => ({ id, title, date })));
  }
  register(descriptor, handler) {
    if (this.commands.has(descriptor.id)) throw new Error('Duplicate bundled editor command: ' + descriptor.id);
    this.commands.set(descriptor.id, { descriptor, handler }); return this;
  }
  catalog() { return [...this.commands.values()].map(({descriptor}) => {
    const args={};
    const fields=(descriptor.fields??[]).map(field=>{
      const options=typeof field.options==='function'?field.options(this,args):field.options;
      const initial=typeof field.default==='function'?field.default(this,args):field.default;
      if(initial!==undefined)args[field.key]=initial;
      return {...field,default:initial,options};
    });
    return {...descriptor,fields};
  }); }
  commandIndex(){return [...this.commands.values()].map(({descriptor})=>({id:descriptor.id,title:descriptor.title,group:descriptor.group,access:descriptor.access,hidden:descriptor.hidden??false,sideEffecting:descriptor.sideEffecting??false,fields:(descriptor.fields??[]).map(({key,label,type})=>({key,label,type}))}));}
  formDescription(id,values={},discovery=null){
    const descriptor=this.command(id),args={...values};
    const fields=(descriptor.fields??[]).map(field=>{
      const options=typeof field.options==='function'?field.options(this,args):field.options;
      const initial=Object.hasOwn(values,field.key)?values[field.key]:typeof field.default==='function'?field.default(this,args):field.default;
      if(initial!==undefined)args[field.key]=initial;
      if(discovery){
        const query=String(discovery.query??'').slice(0,200).toLocaleLowerCase();
        const offset=Number(discovery.offset??0),limit=Number(discovery.limit??40);
        if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(limit)||limit<1||limit>100)throw new Error('Invalid discovery page');
        const all=Array.isArray(options)?options:null;
        const matched=all?.filter(option=>!query||JSON.stringify(option).toLocaleLowerCase().includes(query));
        const optionsPage=all?{total:all.length,matched:matched.length,offset,limit,hasMore:offset+limit<matched.length}:undefined;
        const serialized=JSON.stringify(initial);
        return {...field,default:serialized?.length>8192?undefined:initial,defaultOmitted:serialized?.length>8192?true:undefined,options:matched?matched.slice(offset,offset+limit):options,optionsPage};
      }
      return {...field,default:initial,options};
    });return {...descriptor,fields};
  }
  nativeSnapshot(){return this.configuration.nativeSnapshot?.(this)??{kind:this.configuration.kind,title:this.state.title,selection:this.selection??null};}
  async setNativeChrome(value){this.nativeChrome=Boolean(value);if(this.root)this.root.classList.toggle('native-chrome',this.nativeChrome);await this.configuration.nativeChromeChanged?.(this,this.nativeChrome);this.notifyPresentation();}
  notifyPresentation(){
    if(!this.nativeChrome||this.presentationScheduled||!globalThis.webkit?.messageHandlers?.floeEditor)return;
    this.presentationScheduled=true;
    setTimeout(()=>{this.presentationScheduled=false;globalThis.webkit?.messageHandlers?.floeEditor?.postMessage({type:'presentationChanged'});},60);
  }
  command(id) { return required(this.commands.get(id), 'Unknown editor command').descriptor; }
  async load(envelope) {
    if (envelope.kind !== this.configuration.kind) throw new Error('Wrong editor document');
    this.envelope = envelope; this.revision = envelope.revision;
    this.payload = envelope.content?.data ? clone(envelope.content) : { data: clone(envelope.content ?? this.configuration.create()), history: { past: [], future: [] } };
    this.payload.history ??= { past: [], future: [] }; this.state = this.payload.data;
    this.configuration.normalize?.(this.state);
    await this.render(); return { ready: true, commands: this.catalog().length };
  }
  async execute(request) {
    if (request.revision !== this.revision) throw new Error(t('作品已改变，请刷新。', 'The work has changed. Refresh it.'));
    const entry = required(this.commands.get(request.command), 'Unknown editor command');
    const mutation = ['edit', 'importFile'].includes(entry.descriptor.access);
    const previous = mutation ? clone(this.state) : null;
    try {
      this.abortController = new AbortController();
      this.nativeToken = request.nativeToken;
      const result = await entry.handler(request.arguments ?? {}, this.abortController.signal);
      if (this.abortController.signal.aborted) throw new Error(t('已取消。', 'Cancelled.'));
      if(mutation)this.configuration.normalize?.(this.state);
      if (mutation && !request.command.startsWith('history.') && request.command !== 'document.save') {
        const changes = diff(previous, this.state);
        if (changes.forward.length) {
          this.payload.history.future = [];
          this.payload.history.past.push({ id: uid(), title: entry.descriptor.title, date: new Date().toISOString(), ...changes });
          while (this.payload.history.past.length > 64 || this.payload.history.past.length > 1 && JSON.stringify(this.payload.history).length > 16 * 1024 * 1024) this.payload.history.past.shift();
        }
      }
      await this.render();
      // Queries and presentation changes do not commit project data. Avoid
      // copying an entire font/raster/history back for each native selection.
      let value=result?.result??result??null;
      if(result&&typeof result==='object'&&Object.hasOwn(result,'artifacts')&&!Object.hasOwn(result,'result')){
        const {artifacts,...details}=result;value=Object.keys(details).length?details:null;
      }
      return { state: mutation?clone(this.payload):null, result: value, artifacts: result?.artifacts ?? [] };
    } catch (error) {
      if (previous) this.state = this.payload.data = previous;
      await this.render(); throw error;
    } finally {
      this.nativeToken = undefined;
    }
  }
  async perform(command, args = {}) {
    const action = async () => {
      if (!globalThis.webkit?.messageHandlers?.floeEditor) {
        const response = await this.execute({ command, arguments: args, revision: this.revision });
        if (['edit', 'importFile'].includes(this.command(command).access)) this.revision++;
        this.downloadArtifacts(response.artifacts); return response;
      }
      const requestID = uid();
      const promise = new Promise((resolve, reject) => this.pending.set(requestID, { resolve, reject }));
      webkit.messageHandlers.floeEditor.postMessage({ type: 'request', requestID, command, arguments: args, revision: this.revision });
      return promise;
    };
    const result = this.requestTail.then(action, action); this.requestTail = result.catch(() => {});
    return result.catch(error => { this.status(error.message, true); throw error; });
  }
  hostReply(value) {
    const entry = this.pending.get(value.requestID); if (!entry) return;
    this.pending.delete(value.requestID);
    if (value.error) entry.reject(new Error(value.error)); else { entry.resolve(value.result); this.status(t('已完成', 'Done')); }
  }
  async native(operation, args) {
    if (!globalThis.webkit?.messageHandlers?.floeEditor || !this.nativeToken) throw new Error(t('这项操作需要内置原生服务。','This action requires the bundled native service.'));
    const requestID=uid();const promise=new Promise((resolve,reject)=>this.pending.set(requestID,{resolve,reject}));
    webkit.messageHandlers.floeEditor.postMessage({type:'native',requestID,operation,arguments:args,token:this.nativeToken});return promise;
  }
  acknowledge(revision) { this.revision = revision; }
  cancel() { this.abortController.abort(); this.configuration.cancel?.(); }
  async render() {
    if (typeof document === 'undefined') return;
    if (!this.root) this.createChrome();
    await this.configuration.render?.(this);
    this.titleNode.textContent = this.state.title ?? this.configuration.title;
    this.root.classList.toggle('native-chrome',this.nativeChrome);this.notifyPresentation();
  }
  createChrome() {
    this.titleNode = element('strong', { text: this.configuration.title });
    this.statusNode = element('span', { class: 'status', role: 'status' });
    this.toolbar = element('div', { class: 'toolbar' });
    this.sidebar = element('aside', { class: 'sidebar' });
    this.canvas = element('main', { class: 'canvas', tabIndex: 0 });
    this.inspector = element('aside', { class: 'inspector' });
    this.root = element('div', { class: 'editor-root' },
      element('header', {}, this.titleNode, element('button', { text: t('图层／列表', 'Outline'), onclick: () => this.root.classList.toggle('show-sidebar') }),
        this.toolbar, this.statusNode),
      element('div', { class: 'workspace' }, this.sidebar, this.canvas, this.inspector));
    document.body.replaceChildren(this.root);
    const groups = new Map();
    for (const { descriptor } of this.commands.values()) {
      if (descriptor.hidden) continue;
      const group = descriptor.group ?? t('操作', 'Actions'); if (!groups.has(group)) groups.set(group, []); groups.get(group).push(descriptor);
    }
    for (const [title, actions] of groups) {
      const select = element('select', { 'aria-label': title }, element('option', { value: '', text: title }));
      for (const action of actions) select.append(element('option', { value: action.id, text: action.title }));
      select.addEventListener('change', () => { if (select.value) this.showAction(this.command(select.value)); select.value = ''; });
      this.toolbar.append(select);
    }
  }
  showAction(action, preset = {}) {
    if(this.nativeChrome&&globalThis.webkit?.messageHandlers?.floeEditor){webkit.messageHandlers.floeEditor.postMessage({type:'showCommand',command:action.id,arguments:preset});return;}
    const dialog = element('dialog', { class: 'action-dialog' });
    const form = element('form', { method: 'dialog' }, element('h2', { text: action.title }));
    const controls = [];
    const readArguments=()=>{
      const args={...preset};
      for(const {field,input} of controls)args[field.key]=field.type==='number'||field.type==='range'?finite(input.value):field.type==='checkbox'?input.checked:input.value;
      return args;
    };
    const populate=(input,field,args,preferred)=>{
      const options=typeof field.options==='function'?field.options(this,args):field.options??[];
      input.replaceChildren(...options.map(o=>element('option',{value:typeof o==='object'?o.value:o,text:typeof o==='object'?o.label:o})));
      const values=options.map(o=>String(typeof o==='object'?o.value:o));
      const fallback=typeof field.default==='function'?field.default(this,args):field.default;
      input.value=values.includes(String(preferred))?String(preferred):values.includes(String(fallback))?String(fallback):values[0]??'';
    };
    for (const field of action.fields ?? []) {
      const args=readArguments();
      let input; const initial = preset[field.key] ?? (typeof field.default === 'function' ? field.default(this,args) : field.default ?? '');
      if (field.type === 'select') {
        input = element('select');populate(input,field,args,initial);
      } else if (field.type === 'textarea') input = element('textarea', { value: String(initial), rows: field.rows ?? 4 });
      else if (field.type === 'checkbox') input = element('input', { type: 'checkbox', checked: Boolean(initial) });
      else input = element('input', { type: field.type ?? 'text', value: String(initial), step: field.step ?? 'any', min: field.min, max: field.max });
      if (field.placeholder) input.placeholder = field.placeholder;
      input.name = field.key; controls.push({ field, input });
      form.append(element('label', {}, element('span', { text: field.label }), input));
    }
    controls.forEach(({input},index)=>input.addEventListener('change',()=>{
      for(const next of controls.slice(index+1))if(next.field.type==='select'&&typeof next.field.options==='function')populate(next.input,next.field,readArguments(),next.input.value);
    }));
    const feedback = element('p', { class: 'feedback', role: 'alert' });
    const cancel = element('button', { type: 'button', text: t('取消', 'Cancel'), onclick: () => dialog.close() });
    const submit = element('button', { type: 'submit', class: 'primary', text: t('执行', 'Apply') });
    form.append(feedback, element('footer', {}, cancel, submit));
    form.addEventListener('submit', async event => {
      event.preventDefault(); submit.disabled = true;
      const args = readArguments();
      try {
        const result = await this.perform(action.id, args); dialog.close();
        if (action.access === 'read') this.showResult(action.title, result.result);
      } catch (error) { feedback.textContent = error.message; } finally { submit.disabled = false; }
    });
    dialog.append(form); document.body.append(dialog); dialog.addEventListener('close', () => dialog.remove()); dialog.showModal();
  }
  showResult(title, value) {
    if(this.nativeChrome&&globalThis.webkit?.messageHandlers?.floeEditor){webkit.messageHandlers.floeEditor.postMessage({type:'showResult',title,value});return;}
    const dialog = element('dialog', { class: 'result-dialog' });
    dialog.append(element('h2', { text: title }));
    if (Array.isArray(value) && value.length && value.every(row => row && typeof row === 'object' && !Array.isArray(row))) {
      const fields=[...new Set(value.flatMap(row=>Object.keys(row)))];
      const table=element('table',{class:'data-table'},element('thead',{},element('tr',{},fields.map(key=>element('th',{text:key})))));
      const rows=element('tbody');for(const row of value)rows.append(element('tr',{},fields.map(key=>element('td',{text:typeof row[key]==='object'?JSON.stringify(row[key]):String(row[key]??'')}))));table.append(rows);dialog.append(table);
      if(value.length>2&&typeof value[0].meters==='number'&&value.some(row=>typeof row.elevation==='number'&&Number.isFinite(row.elevation))) {
        const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox','0 0 540 200');
        const good=value.filter(v=>typeof v.elevation==='number'&&Number.isFinite(v.elevation)),min=Math.min(...good.map(v=>v.elevation)),max=Math.max(...good.map(v=>v.elevation));
        const line=document.createElementNS(ns,'polyline');line.setAttribute('points',good.map(v=>`${20+v.meters/(value.at(-1).meters||1)*500},${180-(v.elevation-min)/(max-min||1)*160}`).join(' '));line.setAttribute('fill','none');line.setAttribute('stroke','#2879c7');line.setAttribute('stroke-width','2');svg.append(line);dialog.prepend(svg);
      }
    } else dialog.append(element('pre', { text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }));
    dialog.append(element('button', { text: t('完成', 'Done'), onclick: () => dialog.close() }));
    document.body.append(dialog); dialog.addEventListener('close', () => dialog.remove()); dialog.showModal();
  }
  status(message, error = false) { if (this.statusNode) { this.statusNode.textContent = message; this.statusNode.classList.toggle('error', error); } }
  downloadArtifacts(artifacts = []) {
    if (typeof document === 'undefined') return;
    for (const item of artifacts) {
      const url = URL.createObjectURL(new Blob([from64(item.base64)], { type: item.mediaType }));
      const link = element('a', { href: url, download: item.name }); link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  }
}
export function expose(engine) {
  globalThis.FloeEditor = engine;
  if (typeof window !== 'undefined') {
    const ready = () => globalThis.webkit?.messageHandlers?.floeEditor?.postMessage({ type: 'ready' });
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
  }
  return engine;
}
