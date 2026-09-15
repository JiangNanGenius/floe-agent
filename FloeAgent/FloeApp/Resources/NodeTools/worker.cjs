'use strict';
const { workerData } = require('node:worker_threads');
require('./worker-preload.cjs');
if (workerData.sourceFromStdin) workerData.source = require('node:fs').readFileSync(0, 'utf8');
const path = require('node:path');
const Module = require('node:module');
const { pathToFileURL } = require('node:url');
const roots = [...Module._nodeModulePaths(workerData.cwd), ...(process.env.NODE_PATH ?? '').split(path.delimiter).filter(Boolean)];
Module.register('./environment-loader.mjs', pathToFileURL(__filename), { data: { roots } });
if (workerData.entry) {
  process.argv = [process.execPath, workerData.entry, ...workerData.args];
  Module.runMain(workerData.entry);
} else {
  process.argv = [process.execPath, ...workerData.args];
  global.require = Module.createRequire(path.join(workerData.cwd, '_floe_eval.cjs'));
  global.__filename = path.join(workerData.cwd, '_floe_eval.cjs');
  global.__dirname = workerData.cwd;
  // Compile an ordinary CommonJS wrapper so dynamic import keeps Node's
  // module context. vm.Script callbacks require a process-wide experimental
  // flag and fail in the embedded runtime.
  const evaluation = new Module(global.__filename, module);
  evaluation.filename = global.__filename;
  evaluation.paths = Module._nodeModulePaths(workerData.cwd);
  evaluation._compile(workerData.print ? `console.log(eval(${JSON.stringify(workerData.source)}))` : workerData.source, global.__filename);
}
