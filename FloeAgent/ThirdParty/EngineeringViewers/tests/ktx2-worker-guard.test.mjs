// SPDX-License-Identifier: MPL-2.0
//
// CSP-safe, bounded KTX2/Basis worker checks. This is a component probe of the
// pinned r176 transcoder and the exact guard/patch source that scene.js embeds;
// it is not WKWebView proof. The App-host witness
// (EngineeringSceneResourceWitnessTests/testKTX2BasisTextureTranscodesAndRenders)
// remains the native acceptance gate.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {KTX2Loader} from 'three/examples/jsm/loaders/KTX2Loader.js';
import {
  boundedWorkerReply,
  buildGuardedKTX2WorkerSource,
  patchCSPUnsafeEmbind,
  transcodeErrorMessage,
  installGuardedKTX2Loader
} from '../ktx2-worker-guard.js';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resources = path.resolve(root, '../../FloeApp/Resources/EngineeringViewers');
const jsContent = readFileSync(path.join(resources, 'basis_transcoder.js'), 'utf8');
const wasm = readFileSync(path.join(resources, 'basis_transcoder.wasm'));
const ktx = readFileSync(
  path.resolve(root, '../../Tests/Fixtures/EngineeringScene/textures/quadrants-ktx2.ktx2'));
const initConfig = {astcSupported: false, astcHDRSupported: false, etc1Supported: false,
  etc2Supported: false, dxtSupported: false, bptcSupported: false, pvrtcSupported: false};

function blockedFunction() {
  throw new EvalError("Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script.");
}
// The native constructor is constructible and passes `instanceof Function`;
// keep both properties while refusing every call (as CSP does).
blockedFunction.prototype = Function.prototype;

function runWorker(source, {blockFunctions = false, timeoutMs = 15000, afterInit} = {}) {
  return new Promise((resolve) => {
    const messages = [];
    const diagnostics = [];
    const listeners = {message: [], captureMessage: [], unhandledrejection: [], error: []};
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish({kind: 'timeout', messages, diagnostics}), timeoutMs);
    const context = {
      console: {log() {}, warn() {}, error() {}},
      WebAssembly, TextDecoder, TextEncoder, Uint8Array, Uint16Array, ArrayBuffer,
      Promise, Error, TypeError, EvalError, Math, JSON, Object, Array, String, Number,
      Reflect, performance, setTimeout, clearTimeout, atob, fetch,
      location: {href: 'http://127.0.0.1/probe/index.html'},
      importScripts() { throw new Error('unexpected network request'); }
    };
    if (blockFunctions) context.Function = blockedFunction;
    context.self = context;
    context.addEventListener = (kind, callback, capture) => {
      if (kind === 'message' && capture) listeners.captureMessage.push(callback);
      else if (listeners[kind]) listeners[kind].push(callback);
    };
    context.postMessage = (value) => {
      messages.push(value);
      if (value && value.type === 'transcode') finish({kind: 'transcode', value, messages, diagnostics});
      if (value && value.type === 'error') finish({kind: 'worker-error', value, messages, diagnostics});
    };
    vm.createContext(context);
    vm.runInContext(source, context, {filename: 'ktx2-worker.generated.js'});
    const port = {postMessage: (value) => diagnostics.push(value)};
    const init = {
      data: {type: 'init', config: initConfig,
        transcoderBinary: wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength)},
      ports: [port]
    };
    const transcode = {data: {type: 'transcode', id: 1,
      buffer: ktx.buffer.slice(ktx.byteOffset, ktx.byteOffset + ktx.byteLength)}};
    for (const listener of listeners.captureMessage) listener(init);
    for (const listener of listeners.message) listener(init);
    if (listeners.unhandledrejection.length === 0) {
      throw new Error('guarded worker must register an unhandledrejection listener');
    }
    if (afterInit) {
      afterInit({
        diagnostics,
        messages,
        reject(reason) {
          for (const listener of listeners.unhandledrejection) {
            listener({reason, preventDefault() {}});
          }
        }
      });
    }
    for (const listener of listeners.message) listener(transcode);
  });
}

test('the pinned embind glue is patched fail-closed and has no runtime invoker codegen', () => {
  assert.match(jsContent, /newFunc\(Function,args\)/);
  assert.match(jsContent, /newFunc\(Function,params\)/);
  const patched = patchCSPUnsafeEmbind(jsContent);
  assert.ok(patched, 'the exact r176 markers must be recognised');
  assert.equal(patched.includes('newFunc(Function,args)'), false);
  assert.equal(patched.includes('newFunc(Function,params)'), false);
  assert.ok(patched.includes('FLOE_CSP_EMBIND_INVOKER'));
  assert.equal(patchCSPUnsafeEmbind('not the pinned glue'), null);
  const built = buildGuardedKTX2WorkerSource(jsContent, KTX2Loader);
  assert.equal(built.patched, true);
  assert.match(built.source, /unhandledrejection/);
  assert.match(built.source, /diagnosticPort/);
});

test('CSP-blocked Function still transcodes the owned UASTC KTX2 to 64x64 RGBA32', async () => {
  const built = buildGuardedKTX2WorkerSource(jsContent, KTX2Loader);
  const reply = await runWorker(built.source, {blockFunctions: true});
  assert.equal(reply.kind, 'transcode', JSON.stringify(reply.messages || reply.error));
  assert.equal(reply.value.type, 'transcode');
  assert.equal(reply.value.data.width, 64);
  assert.equal(reply.value.data.height, 64);
  assert.equal(reply.value.data.faces.length, 1);
  const mip = reply.value.data.faces[0].mipmaps[0];
  assert.equal(mip.width, 64);
  assert.equal(mip.height, 64);
  assert.equal(mip.data.length, 64 * 64 * 4);
  // The owned quadrants are red / green / blue / yellow; sample the four
  // quadrants so this is a real pixel decode, not a size-only success.
  const rgba = mip.data;
  const pixel = (x, y) => Array.from(rgba.slice((y * 64 + x) * 4, (y * 64 + x) * 4 + 4));
  const topLeft = pixel(16, 16);
  const topRight = pixel(48, 16);
  const bottomLeft = pixel(16, 48);
  const bottomRight = pixel(48, 48);
  assert.ok(topLeft[0] > 180 && topLeft[1] < 90 && topLeft[2] < 90, 'top-left quadrant must be red');
  assert.ok(topRight[1] > 150 && topRight[0] < 100 && topRight[2] < 110, 'top-right quadrant must be green');
  assert.ok(bottomLeft[2] > 180 && bottomLeft[0] < 100 && bottomLeft[1] < 130, 'bottom-left quadrant must be blue');
  assert.ok(bottomRight[0] > 180 && bottomRight[1] > 150 && bottomRight[2] < 130, 'bottom-right quadrant must be yellow');
  assert.equal(reply.diagnostics.length, 0, 'a successful decode must not report a worker failure');
});

test('the worker guard reports one sanitized diagnostic on a private port only', async () => {
  const built = buildGuardedKTX2WorkerSource(jsContent, KTX2Loader);
  const seen = [];
  const reply = await runWorker(built.source, {
    afterInit: ({diagnostics, reject}) => {
      // Worker-scope unhandledrejection is not a Node event; feed the exact
      // listener a rejected init reason containing both URL classes.
      reject(new Error(
        'EvalError: refused blob:http://127.0.0.1:65535/secret-token/basis_transcoder.js '
        + 'from http://127.0.0.1:65535/secret-token/index.html'));
      seen.push(...diagnostics);
    }
  });
  assert.equal(reply.kind, 'transcode', 'the diagnostic port must not replace the transcode protocol');
  assert.equal(seen.length, 1);
  assert.equal(seen[0].phase, 'init');
  assert.match(seen[0].message, /EvalError/);
  assert.equal(seen[0].message.includes('secret-token'), false);
  assert.equal(seen[0].message.includes('127.0.0.1'), false);
  assert.ok(seen[0].message.length <= 300);
});

test('boundedWorkerReply rejects on a silent worker and on an explicit failure', async () => {
  let timedOut = false;
  const silent = boundedWorkerReply({
    start: () => new Promise(() => {}),
    failure: new Promise(() => {}),
    timeoutMs: 25,
    onTimeout: () => { timedOut = true; }
  });
  await assert.rejects(silent, /timeout|no response/);
  assert.equal(timedOut, true);

  const failure = new Promise((resolve, reject) => {
    setTimeout(() => reject(new Error('decoder failed')), 5);
  });
  await assert.rejects(boundedWorkerReply({
    start: () => new Promise(() => {}),
    failure,
    timeoutMs: 1000,
    onTimeout: () => { throw new Error('must not time out'); }
  }), /decoder failed/);

  const value = await boundedWorkerReply({
    start: () => Promise.resolve(42),
    failure: new Promise(() => {}),
    timeoutMs: 1000,
    onTimeout: () => { throw new Error('must not time out'); }
  });
  assert.equal(value, 42);
});


test('worker transcode errors become one sanitized message, not a destructuring TypeError', () => {
  assert.equal(transcodeErrorMessage({type: 'transcode'}), null);
  const message = transcodeErrorMessage({
    type: 'error',
    error: 'invalid texture from blob:http://127.0.0.1:65535/secret/quadrant.ktx2'
  });
  assert.match(message, /invalid texture/);
  assert.equal(message.includes('secret'), false);
  assert.equal(message.includes('127.0.0.1'), false);
});

// Lifecycle faults are isolated here; real decode/pixels use the pinned
// worker above and the separate native App witness. These doubles exercise
// creation failures and late preparation that are hard to force in WebKit.
async function withOwnedLoader(body, {gate = Promise.resolve(), channelFailure = false,
                                     timeoutMs = 1000} = {}) {
  const previousWorker = globalThis.Worker;
  const previousChannel = globalThis.MessageChannel;
  const workers = [];
  const channels = [];
  const failures = [];
  const calls = {init: 0, dispose: 0};
  class WorkerDouble {
    constructor() { this.terminated = false; this.listeners = {}; workers.push(this); }
    postMessage() {}
    addEventListener(name, callback) { this.listeners[name] = callback; }
    terminate() { this.terminated = true; }
  }
  class ChannelDouble {
    constructor() {
      if (channelFailure) throw new Error('channel construction unavailable');
      this.port1 = {onmessage: null, closed: false, close() { this.closed = true; }};
      this.port2 = {closed: false, close() { this.closed = true; }};
      channels.push(this);
    }
  }
  globalThis.Worker = WorkerDouble;
  globalThis.MessageChannel = ChannelDouble;
  const pool = {
    workers: [],
    setWorkerCreator(creator) { this.creator = creator; },
    postMessage() {
      this.workers.push(this.creator());
      return new Promise(() => {});
    },
    dispose() { for (const worker of this.workers) worker.terminate(); this.workers = []; }
  };
  const loader = {
    workerPool: pool, workerConfig: {}, workerSourceURL: '', transcoderBinary: null,
    init() {
      calls.init += 1;
      this.transcoderPending = gate.then(() => {
        this.workerSourceURL = URL.createObjectURL(new Blob([jsContent]));
        this.transcoderBinary = new ArrayBuffer(8);
      });
      return this.transcoderPending;
    },
    dispose() {
      calls.dispose += 1;
      pool.dispose();
      if (this.workerSourceURL) URL.revokeObjectURL(this.workerSourceURL);
    }
  };
  installGuardedKTX2Loader(loader, {timeoutMs, onFailure: message => failures.push(message)});
  try { await body({loader, pool, workers, channels, failures, calls}); }
  finally {
    loader.dispose();
    globalThis.Worker = previousWorker;
    globalThis.MessageChannel = previousChannel;
  }
}

test('guard preserves one upstream init and dispose, and closes owned ports and pending work', async () => {
  await withOwnedLoader(async ({loader, pool, workers, channels, failures, calls}) => {
    const first = loader.init();
    assert.equal(loader.init(), first);
    await first;
    const pending = pool.postMessage({type: 'transcode'}, []);
    const rejected = assert.rejects(pending, /decoder closed/);
    assert.equal(workers.length, 1);
    assert.equal(channels.length, 1);
    loader.dispose();
    loader.dispose();
    await rejected;
    assert.deepEqual(calls, {init: 1, dispose: 1});
    assert.equal(workers[0].terminated, true);
    assert.equal(channels[0].port1.closed, true);
    assert.equal(channels[0].port2.closed, true);
    assert.equal(loader.workerSourceURL, '');
    assert.equal(loader.transcoderBinary, null);
    assert.deepEqual(failures, [], 'explicit cancellation is not a scene error');
  });
});

test('a diagnostic channel failure terminates a worker not yet registered in the pool', async () => {
  await withOwnedLoader(async ({loader, pool, workers, failures, calls}) => {
    await loader.init();
    await assert.rejects(pool.postMessage({type: 'transcode'}, []), /channel/);
    assert.equal(workers.length, 1);
    assert.equal(workers[0].terminated, true);
    assert.equal(pool.workers.length, 0);
    assert.equal(failures.length, 1);
    assert.equal(calls.dispose, 1);
  }, {channelFailure: true});
});

test('late upstream initialization cannot revive a disposed decoder or leak a Blob', async () => {
  let resume;
  const gate = new Promise(resolve => { resume = resolve; });
  await withOwnedLoader(async ({loader, workers, failures, calls}) => {
    const pending = loader.init();
    const rejected = assert.rejects(pending, /decoder closed/);
    loader.dispose();
    await rejected;
    resume();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(loader.workerSourceURL, '');
    assert.equal(loader.transcoderBinary, null);
    assert.equal(workers.length, 0);
    assert.deepEqual(calls, {init: 1, dispose: 1});
    assert.deepEqual(failures, []);
    await assert.rejects(loader.init(), /decoder closed/);
    assert.equal(calls.init, 1);
  }, {gate});
});

test('disposing an unused loader never decrements upstream initialization accounting', async () => {
  await withOwnedLoader(async ({loader, calls}) => {
    loader.dispose();
    loader.dispose();
    await assert.rejects(loader.init(), /decoder closed/);
    assert.deepEqual(calls, {init: 0, dispose: 0});
  });
});

test('initialization has a real deadline and late completion cannot recreate resources', async () => {
  let resume;
  const gate = new Promise(resolve => { resume = resolve; });
  await withOwnedLoader(async ({loader, failures, calls}) => {
    await assert.rejects(loader.init(), /initialization timeout|no response/);
    assert.equal(failures.length, 1);
    assert.equal(failures[0], 'initialization timeout');
    resume();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(loader.workerSourceURL, '');
    assert.deepEqual(calls, {init: 1, dispose: 1});
  }, {gate, timeoutMs: 5});
});
