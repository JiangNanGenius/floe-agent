import { Buffer } from 'buffer';
globalThis.Buffer = Buffer;
import { marked } from 'marked';
import mammoth from 'mammoth/mammoth.browser.js';
import Turndown from 'turndown';
import { gfm } from 'turndown-plugin-gfm';
import DOMPurify from 'dompurify';
import HTMLtoDOCX from '@turbodocx/html-to-docx';

const max = 16 * 1024 * 1024;
const escape = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function bytes64(s) { return Uint8Array.from(atob(s), c => c.charCodeAt(0)); }
function base64(bytes) {
  if(bytes.length > max) throw Error('Converted file exceeds 16 MiB');
  let s=''; for(let i=0;i<bytes.length;i+=16384) s+=String.fromCharCode(...bytes.subarray(i,i+16384));
  return btoa(s);
}
function clean(html) {
  const safe = DOMPurify.sanitize(html, {USE_PROFILES:{html:true}, FORBID_TAGS:['style','script','iframe','object','embed','form','input','video','audio','link','meta'], FORBID_ATTR:['srcset']});
  const doc = new DOMParser().parseFromString(safe, 'text/html');
  for (const el of doc.body.querySelectorAll('*')) {
    const style = el.getAttribute('style');
    if(style && /url\s*\(|expression|@import|\\/i.test(style)) el.removeAttribute('style');
    if(el.hasAttribute('href') && !/^(https?:|mailto:|#)/i.test(el.getAttribute('href'))) el.removeAttribute('href');
  }
  return doc;
}
function checkedImages(doc, resources, requireResolved) {
  for (const img of doc.images) {
    const src=img.getAttribute('src') || '';
    if(resources && Object.hasOwn(resources,src)) img.setAttribute('src',resources[src]);
    const value=img.getAttribute('src') || '';
    if(requireResolved && !/^data:image\/(png|jpeg|gif|webp);base64,/i.test(value)) throw Error('Image must be a provided local PNG, JPEG, GIF or WebP: '+value.slice(0,120));
  }
}
async function prepare(input) {
  const raw=bytes64(input.base64);
  if(raw.length>max) throw Error('Input exceeds 16 MiB');
  const warnings=[]; let html;
  if(input.format==='docx') {
    const r=await mammoth.convertToHtml({arrayBuffer:raw.buffer},{externalFileAccess:false});
    html=r.value; warnings.push(...r.messages.map(m=>m.message));
    warnings.push('Word conversion preserves semantic content; page geometry, floating objects, headers and unsupported styles may differ.');
  } else {
    const text=new TextDecoder('utf-8',{fatal:true}).decode(raw);
    html=input.format==='markdown' ? marked.parse(text,{gfm:true,async:false}) : input.format==='text' ? '<p>'+escape(text).replaceAll('\n','<br>')+'</p>' : text;
  }
  const doc=clean(html);
  if(DOMPurify.removed.length) warnings.push('Active or unsupported HTML was removed.');
  return {html:doc.body.innerHTML, images:[...new Set([...doc.images].map(i=>i.getAttribute('src')||''))], warnings};
}
async function finish(input) {
  const doc=clean(input.html); checkedImages(doc,input.resources,true);
  const html=doc.body.innerHTML;
  let bytes;
  if(input.format==='docx') {
    const result=await HTMLtoDOCX('<!doctype html><html><head><meta charset="utf-8"></head><body>'+html+'</body></html>',null,{font:'Arial',fontSize:24,table:{row:{cantSplit:true}},pageNumber:false});
    bytes = result instanceof Blob ? new Uint8Array(await result.arrayBuffer()) : new Uint8Array(result);
  } else if(input.format==='markdown') {
    const td=new Turndown({headingStyle:'atx',codeBlockStyle:'fenced',bulletListMarker:'-'}); td.use(gfm);
    bytes=new TextEncoder().encode(td.turndown(html)+'\n');
  } else if(input.format==='text') {
    for(const el of doc.body.querySelectorAll('br,p,div,li,h1,h2,h3,h4,h5,h6,tr,blockquote,pre')) el.append(doc.createTextNode('\n'));
    for(const cell of doc.body.querySelectorAll('td,th')) cell.append(doc.createTextNode('\t'));
    bytes=new TextEncoder().encode(doc.body.textContent || '');
  } else {
    bytes=new TextEncoder().encode('<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\';"><style>body{font-family:-apple-system,Arial,sans-serif;font-size:12pt;line-height:1.5;overflow-wrap:anywhere;color:#111}h1,h2,h3{break-after:avoid}table{border-collapse:collapse;width:100%}td,th{border:1px solid #aaa;padding:5px}img{max-width:100%;height:auto}pre{white-space:pre-wrap}blockquote{border-left:3px solid #bbb;padding-left:12px}</style></head><body>'+html+'</body></html>');
  }
  return {base64:base64(bytes)};
}
async function ready() { await Promise.all(Array.from(document.images).map(i=>i.decode())); await document.fonts.ready; return {ready:true}; }
async function configurePDF(input) {
  const font = new FontFace('FloeDocumentSans', bytes64(input.font).buffer, {weight:'100 900'});
  await font.load(); document.fonts.add(font);
  const style=document.createElement('style');
  style.textContent='body,body *{font-family:FloeDocumentSans,sans-serif!important;font-variant-ligatures:none;font-feature-settings:"locl" 0}';
  document.head.append(style);
  return ready();
}
window.FloeConversion={prepare,finish,ready,configurePDF};
