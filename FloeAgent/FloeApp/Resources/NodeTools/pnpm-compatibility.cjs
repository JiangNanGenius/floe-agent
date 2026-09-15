'use strict';
// nodejs-mobile 18 omits ICU's property escape tables. Apply an exact,
// digest-bound character-range expansion to the pinned pnpm CLI only.
// Do not mutate the upstream files or change --check/lock verification.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const table = require('./pnpm-unicode.json');
function expand(source) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== table.sourceSHA256) throw Error('pnpm compatibility input does not match the reviewed source');
  let count = 0;
  const result = source.toString('utf8').replace(/\\p\{([^}]+)\}/g, (_, property) => {
    if (!Object.hasOwn(table.ranges, property)) throw Error('Unreviewed pnpm Unicode property: ' + property);
    count++; return table.ranges[property];
  });
  if (count !== table.occurrenceCount) throw Error('pnpm compatibility expression count changed');
  return result;
}
function install(Module) {
  const original = Module._extensions['.js'];
  const target = path.join(__dirname, 'pnpm/dist/pnpm.cjs');
  Module._extensions['.js'] = function(module, filename) {
    if (filename !== target) return original(module, filename);
    module._compile(expand(fs.readFileSync(filename)), filename);
  };
}
module.exports = { expand, install };
