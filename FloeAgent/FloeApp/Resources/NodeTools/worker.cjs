'use strict';
const { workerData } = require('node:worker_threads');
require('./worker-preload.cjs');
const path = require('node:path');
const Module = require('node:module');
if (workerData.entry) {
  process.argv = [process.execPath, workerData.entry, ...workerData.args];
  Module.runMain(workerData.entry);
} else {
  process.argv = [process.execPath, ...workerData.args];
  global.require = Module.createRequire(path.join(workerData.cwd, '_floe_eval.cjs'));
  global.__filename = path.join(workerData.cwd, '_floe_eval.cjs');
  global.__dirname = workerData.cwd;
  const value = require('node:vm').runInThisContext(workerData.source, { filename: '[eval]' });
  if (workerData.print) console.log(value);
}
