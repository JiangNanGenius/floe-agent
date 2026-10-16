#!/usr/bin/env node
// Module test for the document.convert DOCX East Asian font repair (F275-07).
//
// The bundled converter generates .docx through @turbodocx/html-to-docx with
// `font:'Arial'`, which names only a Latin family and points East Asian text at
// the theme's minor HAnsi font (also Arial). Arial has no CJK glyphs, so Chinese
// text renders as empty squares in the native editor. `applyEastAsianFonts`
// (ThirdParty/DocumentConversion/docx-east-asian-fonts.js) rewrites the package
// to name the installed system CJK family on every run, in the document
// defaults, theme and font table, and marks the East Asian language zh-CN,
// exactly like the native Word builder — while Latin text keeps Arial.
//
// This drives the real library + the real production module (no App, no
// simulator), then reopens the result with mammoth to prove the package is still
// a valid, readable OOXML document. It also asserts the shipped bundle and its
// inventory were regenerated with the fix.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve, sep } from 'node:path';
import crypto from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const dcDir = resolve(here, '..', 'ThirdParty', 'DocumentConversion');
const resourcesDir = resolve(here, '..', 'FloeApp', 'Resources', 'DocumentConversion');
const require = createRequire(dcDir + sep);

const htmlToDocxExport = require('@turbodocx/html-to-docx');
const HTMLtoDOCX = htmlToDocxExport.default || htmlToDocxExport;
const JSZip = require('jszip');
const mammoth = require('mammoth');
const { applyEastAsianFonts, eastAsianFont, eastAsianLang } =
  await import(pathToFileURL(join(dcDir, 'docx-east-asian-fonts.js')).href);

// Mirror converter.js finish(): same wrapper and options.
const DOCX_OPTIONS = { font: 'Arial', fontSize: 24, table: { row: { cantSplit: true } }, pageNumber: false };
function wrap(bodyHtml) {
  return '<!doctype html><html><head><meta charset="utf-8"></head><body>' + bodyHtml + '</body></html>';
}
async function rawDocx(bodyHtml) {
  const out = await HTMLtoDOCX(wrap(bodyHtml), null, DOCX_OPTIONS);
  return out instanceof Uint8Array ? out : new Uint8Array(await out.arrayBuffer());
}
async function readParts(bytes) {
  const zip = await JSZip.loadAsync(bytes);
  const read = async (p) => (zip.file(p) ? zip.file(p).async('string') : null);
  return {
    document: await read('word/document.xml'),
    styles: await read('word/styles.xml'),
    theme: await read('word/theme/theme1.xml'),
    fontTable: await read('word/fontTable.xml'),
  };
}
function runs(documentXml) {
  return [...documentXml.matchAll(/<w:r(?:\s[^>]*)?>([\s\S]*?)<\/w:r>/g)].map((m) => m[1]);
}

let checks = 0;
function ok(name) { checks += 1; console.log('  ok -', name); }

// ---------------------------------------------------------------------------
console.log('# mixed Chinese/Latin document declares an installed CJK family everywhere');
{
  const body =
    '<h1>栖光发布会预算</h1>' +
    '<p>中文与 English 混排 mixed content 测试，包含<strong>加粗</strong>和<em>斜体</em>。</p>' +
    '<ul><li>场地费用</li><li>拍摄制作</li></ul>' +
    '<table><tr><th>项目</th><th>金额</th></tr><tr><td>场地</td><td>1800</td></tr></table>';
  const fixed = await applyEastAsianFonts(await rawDocx(body));
  const p = await readParts(fixed);

  const runList = runs(p.document);
  assert.ok(runList.length > 0, 'document must contain runs');
  for (const [i, r] of runList.entries()) {
    assert.match(r, /<w:rFonts\b/, `run ${i} must carry rFonts`);
    assert.ok(r.includes(`w:eastAsia="${eastAsianFont}"`), `run ${i} must name the CJK family`);
    assert.ok(r.includes('w:ascii="Arial"'), `run ${i} must keep Arial for Latin`);
  }
  ok(`every one of ${runList.length} runs names ${eastAsianFont} + Arial`);

  const defaults = p.styles.match(/<w:rPrDefault>[\s\S]*?<\/w:rPrDefault>/);
  assert.ok(defaults, 'styles must define docDefaults');
  assert.ok(defaults[0].includes(`w:eastAsia="${eastAsianFont}"`), 'docDefaults must name the CJK family');
  assert.ok(defaults[0].includes('w:ascii="Arial"'), 'docDefaults must keep Arial');
  assert.ok(!defaults[0].includes('w:eastAsiaTheme'), 'docDefaults must not rely on eastAsiaTheme');
  assert.match(p.styles, /<w:lang\b[^>]*w:eastAsia="zh-CN"/, 'docDefaults lang must set eastAsia zh-CN');
  ok('styles docDefaults use explicit eastAsia + zh-CN, no eastAsiaTheme');

  const eaCount = (p.theme.match(/<a:ea typeface="PingFang SC"\s*\/>/g) || []).length;
  assert.ok(eaCount >= 2, `theme major+minor ea must be PingFang SC (found ${eaCount})`);
  assert.match(p.theme, /<a:latin typeface="Arial"/, 'theme latin must stay Arial');
  ok('theme major/minor East Asian font is PingFang SC; latin stays Arial');

  assert.ok(p.fontTable.includes(`w:name="${eastAsianFont}"`), 'fontTable must declare the CJK family');
  ok('fontTable declares PingFang SC');

  // Validity: a real OOXML reader reopens the package and preserves content.
  const back = await mammoth.convertToHtml({ buffer: Buffer.from(fixed) });
  assert.ok(back.value.includes('场地'), 'reopened docx must preserve Chinese content');
  assert.ok(back.value.includes('English'), 'reopened docx must preserve Latin content');
  assert.ok(back.value.includes('1800'), 'reopened docx must preserve table content');
  ok('mammoth reopens the fixed package and preserves Chinese/Latin/table content');
}

// ---------------------------------------------------------------------------
console.log('# English-only document is unchanged in behaviour and keeps Arial');
{
  const fixed = await applyEastAsianFonts(await rawDocx('<p>Plain English only paragraph.</p>'));
  const p = await readParts(fixed);
  const runList = runs(p.document);
  assert.ok(runList.length > 0, 'english doc must contain runs');
  for (const r of runList) assert.ok(r.includes('w:ascii="Arial"'), 'latin stays Arial');
  const back = await mammoth.convertToHtml({ buffer: Buffer.from(fixed) });
  assert.ok(back.value.includes('Plain English only'), 'english content preserved');
  ok('English-only conversion stays valid; Latin remains Arial');
}

// ---------------------------------------------------------------------------
console.log('# reprocessing is idempotent (no duplicated rFonts)');
{
  const once = await applyEastAsianFonts(await rawDocx('<p>再次处理测试 reprocess</p>'));
  const twice = await applyEastAsianFonts(once);
  const a = (await readParts(once)).document;
  const b = (await readParts(twice)).document;
  const count = (s) => (s.match(/w:eastAsia="PingFang SC"/g) || []).length;
  assert.equal(count(b), count(a), 'second pass must not add more rFonts');
  ok(`eastAsia declarations stable across a second pass (${count(a)})`);
}

// ---------------------------------------------------------------------------
console.log('# shipped bundle + inventory were regenerated with the fix');
{
  const bundlePath = join(resourcesDir, 'converter.js');
  const bundle = readFileSync(bundlePath);
  assert.ok(bundle.includes(Buffer.from('PingFang SC')), 'bundle must contain the CJK family');
  const sourceConverter = readFileSync(join(dcDir, 'converter.js'), 'utf8');
  assert.match(sourceConverter, /import\s*\{\s*applyEastAsianFonts\s*\}\s*from\s*'\.\/docx-east-asian-fonts\.js'/,
    'converter.js must import the font module');
  assert.match(sourceConverter, /bytes\s*=\s*await applyEastAsianFonts\(bytes\)/,
    'converter.js finish() must apply the font fix to docx output');
  const inventory = JSON.parse(readFileSync(join(dcDir, 'inventory.json'), 'utf8'));
  const digest = crypto.createHash('sha256').update(bundle).digest('hex');
  assert.equal(inventory.sha256, digest, 'inventory.json sha256 must match the built bundle');
  ok(`bundle sha256 ${digest.slice(0, 12)}… matches inventory and wires applyEastAsianFonts`);
}

console.log(`\nAll ${checks} document-conversion font checks passed.`);
