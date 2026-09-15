// Regenerate only with the version used by the embedded Node runtime.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
if (process.version !== 'v18.20.4') throw Error('Use Node 18.20.4 to pin its Unicode semantics');
const root = path.resolve(__dirname, '../FloeApp/Resources/NodeTools');
const source = fs.readFileSync(path.join(root, 'pnpm/dist/pnpm.cjs'));
const ranges = {};
for (const property of ['Lu', 'Ll', 'Alpha', 'N', 'C']) {
  const regex = new RegExp(`\\p{${property}}`, 'u');
  const segments = []; let first = null, last = null;
  const escape = value => `\\u{${value.toString(16)}}`;
  const flush = () => { if (first !== null) segments.push(escape(first) + (first === last ? '' : '-' + escape(last))); };
  for (let value = 0; value <= 0x10ffff; value++) {
    if (regex.test(String.fromCodePoint(value))) {
      if (first === null) first = value;
      last = value;
    } else if (first !== null) { flush(); first = last = null; }
  }
  flush(); ranges[property] = segments.join('');
}
const result = { node: process.version, unicode: process.versions.unicode,
  sourceSHA256: crypto.createHash('sha256').update(source).digest('hex'),
  occurrenceCount: [...source.toString().matchAll(/\\p\{([^}]+)\}/g)].length, ranges };
fs.writeFileSync(path.join(root, 'pnpm-unicode.json'), JSON.stringify(result, null, 2) + '\n');
console.log(`Pinned ${result.occurrenceCount} property expressions using Unicode ${result.unicode}`);
