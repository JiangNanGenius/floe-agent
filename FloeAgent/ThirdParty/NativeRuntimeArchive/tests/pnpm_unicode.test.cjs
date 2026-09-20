const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const root = path.resolve(__dirname, '../../FloeApp/Resources/NodeTools');
const table = require(path.join(root, 'pnpm-unicode.json'));
const adapter = require(path.join(root, 'pnpm-compatibility.cjs'));
test('pinned pnpm expansion is bounded to the reviewed source', () => {
  const source = fs.readFileSync(path.join(root, 'pnpm/dist/pnpm.cjs'));
  const expanded = adapter.expand(source);
  assert.equal(expanded.includes('\\p{'), false);
  assert.throws(() => adapter.expand(Buffer.concat([source, Buffer.from('\n')])), /reviewed source/);
  assert.equal(table.occurrenceCount, 12);
});
test('Unicode ranges preserve all code points at the pinned runtime Unicode version',
  { skip: process.versions.unicode !== table.unicode }, () => {
    for (const [property, ranges] of Object.entries(table.ranges)) {
      const native = new RegExp(`\\p{${property}}`, 'u');
      const expanded = new RegExp(`[${ranges}]`, 'u');
      for (let value = 0; value <= 0x10ffff; value++) {
        const text = String.fromCodePoint(value);
        if (native.test(text) !== expanded.test(text)) assert.fail(`${property}: U+${value.toString(16)}`);
      }
    }
  });
