// SPDX-License-Identifier: MPL-2.0
//
// Bounded, CSP-safe integration for the pinned three.js r176 KTX2Loader.
//
// Why this exists
// ---------------
// `basis_transcoder.js` (three@0.176.0 examples/jsm/libs/basis) is an embind
// build. Its embind runtime creates every invoker function with
// `new Function(...)` (`newFunc(Function, args)` in `craftInvokerFunction`).
// The engineering preview CSP is `script-src 'self' 'wasm-unsafe-eval'`; that
// allows WebAssembly compilation but not JavaScript code generation from
// strings. A dedicated worker inherits the document CSP, so those calls throw
// an EvalError while the worker initializes. KTX2Loader's BasisWorker only
// listens for the success path of `transcoderPending` and never observes the
// rejection, and WorkerPool never rejects its pending promise. The result is a
// silent 60 s page timeout with no worker error event.
//
// This module keeps the same pinned transcoder and WebAssembly bytes, but:
//   * replaces only the embind `craftInvokerFunction` code generator with a
//     closure-based invoker that performs the same wire conversions without
//     `Function` (no `'unsafe-eval'`, no CSP change, no new dependency);
//   * adds a worker-scoped `unhandledrejection`/`error` guard that reports one
//     bounded, sanitized diagnostic through a dedicated MessagePort, so the
//     normal KTX2Loader message protocol (and WorkerPool) is untouched;
//   * bounds worker creation/init/transcode, terminates the failed pool, and
//     fails the scene through the existing `onError` bridge.
//
// If the pinned glue no longer matches the expected marker, the patch is
// skipped (fail-open for environments where Function is allowed) and the
// bounded worker guard still turns a silent hang into an explicit error.
//
// The invoker semantics mirror the Emscripten embind glue in the pinned
// basis_transcoder.js (Apache-2.0); this adaptation is MPL-2.0.

export const KTX2_DECODE_TIMEOUT_MS = 30000;

// Self-contained: this source is embedded in the classic worker before the
// pinned Basis glue. It must not reference module-scope bindings.
const CSP_SAFE_EMBIND_INVOKER_SOURCE = String.raw`
function FLOE_CSP_EMBIND_INVOKER(humanName, argTypes, classType, cppInvokerFunc, cppTargetFunc, isAsync, throwBindingError, runDestructors) {
  var argCount = argTypes.length;
  var isClassMethodFunc = argTypes[1] !== null && classType !== null;
  var needsDestructorStack = false;
  for (var typeIndex = 1; typeIndex < argCount; typeIndex += 1) {
    if (argTypes[typeIndex] !== null && argTypes[typeIndex].destructorFunction === undefined) {
      needsDestructorStack = true;
      break;
    }
  }
  var returns = argTypes[0].name !== 'void';
  var expected = argCount - 2;
  return function () {
    if (arguments.length !== expected) {
      throwBindingError('function ' + humanName + ' called with ' + arguments.length + ' arguments, expected ' + expected);
    }
    var destructors = needsDestructorStack ? [] : null;
    var wired = new Array(expected);
    var thisWired = null;
    if (isClassMethodFunc) thisWired = argTypes[1].toWireType(destructors, this);
    for (var argIndex = 0; argIndex < expected; argIndex += 1) {
      wired[argIndex] = argTypes[argIndex + 2].toWireType(destructors, arguments[argIndex]);
    }
    var callArgs = [cppTargetFunc];
    if (isClassMethodFunc) callArgs.push(thisWired);
    for (var wiredIndex = 0; wiredIndex < wired.length; wiredIndex += 1) callArgs.push(wired[wiredIndex]);
    var rv = cppInvokerFunc.apply(undefined, callArgs);
    if (needsDestructorStack) {
      runDestructors(destructors);
    } else {
      for (var destructorIndex = isClassMethodFunc ? 1 : 2; destructorIndex < argCount; destructorIndex += 1) {
        var destructorType = argTypes[destructorIndex];
        if (destructorType && destructorType.destructorFunction !== null && destructorType.destructorFunction !== undefined) {
          destructorType.destructorFunction(destructorIndex === 1 ? thisWired : wired[destructorIndex - 2]);
        }
      }
    }
    if (returns) return argTypes[0].fromWireType(rv);
    return undefined;
  };
}
`;

// One capture-phase listener records the dedicated diagnostic port; it never
// intercepts the init/transcode messages consumed by BasisWorker. Failures are
// sanitized so no blob/preview URL with its local token reaches native logs.
const WORKER_GUARD_SOURCE = String.raw`
(function () {
  var diagnosticPort = null;
  var phase = 'boot';
  function report(reason) {
    var message = '';
    try { message = reason && reason.message ? reason.message : String(reason); } catch (error) { message = 'worker failure'; }
    message = String(message)
      .replace(/blob:[^\s"'()]+/g, 'blob:[local]')
      .replace(/https?:\/\/127\.0\.0\.1:\d+\/[^\s"'()]*/g, '[local preview]')
      .slice(0, 300);
    try { if (diagnosticPort) diagnosticPort.postMessage({phase: phase, message: message}); } catch (error) {}
  }
  self.addEventListener('message', function (event) {
    var data = event && event.data;
    if (!data || typeof data !== 'object') return;
    if (data.type === 'init') {
      phase = 'init';
      if (event.ports && event.ports[0]) diagnosticPort = event.ports[0];
    } else if (data.type === 'transcode') {
      phase = 'transcode';
    }
  }, true);
  self.addEventListener('unhandledrejection', function (event) {
    try { event.preventDefault(); } catch (error) {}
    report(event && event.reason);
  });
  self.addEventListener('error', function (event) {
    report(event && (event.error || event.message));
  });
})();
`;

const CRAFT_INVOKER_MARKER = 'function craftInvokerFunction(';
const CRAFT_INVOKER_END_MARKER = 'var __embind_register_class_constructor=';
const CRAFT_INVOKER_REPLACEMENT =
  'function craftInvokerFunction(humanName,argTypes,classType,cppInvokerFunc,cppTargetFunc,isAsync){'
  + 'return FLOE_CSP_EMBIND_INVOKER(humanName,argTypes,classType,cppInvokerFunc,cppTargetFunc,isAsync,throwBindingError,runDestructors);}';

const METHOD_CALLER_MARKER = 'var __emval_get_method_caller=';
const METHOD_CALLER_END_MARKER = 'var __emval_get_module_property=';
// Same generated-call semantics as embind's caller, without `Function`.
// kind 0 = method (this=obj), kind 1 = constructor, kind 2 = call.
const METHOD_CALLER_REPLACEMENT =
  'var __emval_get_method_caller=(argCount,argTypes,kind)=>{'
  + 'var types=emval_lookupTypes(argCount,argTypes);'
  + 'var retType=types.shift();'
  + 'argCount--;'
  + 'var caller=function(obj,func,destructorsRef,args){'
  + 'var values=new Array(argCount);'
  + 'var offset=0;'
  + 'for(var index=0;index<argCount;index+=1){'
  + 'values[index]=types[index].readValueFromPointer(args+offset);'
  + 'offset+=types[index]["argPackAdvance"];'
  + '}'
  + 'var rv;'
  + 'if(kind===1){rv=reflectConstruct(func,values);}'
  + 'else if(kind===0){rv=func.apply(obj,values);}'
  + 'else{rv=func.apply(values[0],values.slice(1));}'
  + 'if(!retType.isVoid){return emval_returnValue(retType,destructorsRef,rv);}'
  + 'return undefined;'
  + '};'
  + 'var functionName="methodCaller<("+types.map(function(type){return type.name;}).join(", ")+") => "+retType.name+">";'
  + 'return emval_addMethodCaller(createNamedFunction(functionName,caller));'
  + '};';

function replaceOnce(content, startMarker, endMarker, replacement, required) {
  const start = content.indexOf(startMarker);
  if (start < 0) return null;
  if (content.indexOf(startMarker, start + 1) >= 0) return null;
  const end = content.indexOf(endMarker, start);
  if (end < 0) return null;
  const original = content.slice(start, end);
  if (required && original.indexOf(required) < 0) return null;
  return content.slice(0, start) + replacement + content.slice(end);
}

/**
 * Replace embind's two runtime `Function` code generators with closure-based
 * equivalents. Returns null when the pinned glue does not match both expected
 * definitions; callers then keep the original glue (the worker guard still
 * bounds any resulting rejection/timeout).
 */
export function patchCSPUnsafeEmbind(jsContent) {
  if (typeof jsContent !== 'string') return null;
  const craftPatched = replaceOnce(
    jsContent, CRAFT_INVOKER_MARKER, CRAFT_INVOKER_END_MARKER,
    CRAFT_INVOKER_REPLACEMENT, 'newFunc(Function,args)');
  if (craftPatched === null) return null;
  return replaceOnce(
    craftPatched, METHOD_CALLER_MARKER, METHOD_CALLER_END_MARKER,
    METHOD_CALLER_REPLACEMENT, 'newFunc(Function,params)');
}

/** Build the complete classic-worker source with the guard and CSP-safe glue. */
export function buildGuardedKTX2WorkerSource(jsContent, KTX2LoaderClass) {
  const fn = KTX2LoaderClass.BasisWorker.toString();
  const body = [
    '/* constants */',
    'let _EngineFormat = ' + JSON.stringify(KTX2LoaderClass.EngineFormat),
    'let _EngineType = ' + JSON.stringify(KTX2LoaderClass.EngineType),
    'let _TranscoderFormat = ' + JSON.stringify(KTX2LoaderClass.TranscoderFormat),
    'let _BasisFormat = ' + JSON.stringify(KTX2LoaderClass.BasisFormat),
    '/* basis_transcoder.js */',
    jsContent,
    '/* worker */',
    fn.substring(fn.indexOf('{') + 1, fn.lastIndexOf('}'))
  ].join('\n');
  return guardExistingKTX2WorkerSource(body);
}

/** Adapt the owned worker Blob made by upstream init, preserving its lifecycle. */
export function guardExistingKTX2WorkerSource(source) {
  const patched = patchCSPUnsafeEmbind(source);
  return {source: [CSP_SAFE_EMBIND_INVOKER_SOURCE, WORKER_GUARD_SOURCE,
                   patched || source].join('\n'), patched: patched !== null};
}

function sanitizeDiagnostic(value) {
  return String(value == null ? '' : value)
    .replace(/blob:[^\s"'()]+/g, 'blob:[local]')
    .replace(/https?:\/\/127\.0\.0\.1:\d+\/[^\s"'()]*/g, '[local preview]')
    .slice(0, 300);
}

/** The worker's own transcode failure message, sanitized for native logs. */
export function transcodeErrorMessage(result) {
  if (!result || result.type !== 'error') return null;
  return sanitizeDiagnostic(result.error || 'transcode failed');
}

/**
 * Race one worker reply against a single loader failure and a hard deadline.
 * Extracted so the bounded lifecycle is testable without a real Worker.
 */
export function boundedWorkerReply({start, failure, timeoutMs, onTimeout}) {
  let timer = 0;
  const reply = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      try { onTimeout?.(); } catch (error) {}
      reject(new Error('no response within ' + timeoutMs + ' ms'));
    }, timeoutMs);
    try {
      Promise.resolve(start()).then(resolve, reject);
    } catch (error) {
      reject(error);
    }
  });
  return Promise.race([reply, failure]).finally(() => clearTimeout(timer));
}

/**
 * Install the guarded init/worker lifecycle on an existing KTX2Loader instance.
 * `onFailure` must be the scene's existing error bridge; it is called at most
 * once per loader, before/with the pending texture rejection.
 */
export function installGuardedKTX2Loader(ktx2, {
  onFailure,
  timeoutMs = KTX2_DECODE_TIMEOUT_MS
} = {}) {
  const pool = ktx2.workerPool;
  const originalInit = ktx2.init.bind(ktx2);
  const originalDispose = ktx2.dispose.bind(ktx2);
  const originalPostMessage = pool.postMessage.bind(pool);
  const workers = new Set();
  const channels = new Set();
  let initPending = null;
  let initStarted = false;
  let upstreamDisposed = false;
  let disposed = false;
  let failureReject = null;
  let failedMessage = null;
  const failure = new Promise((resolve, reject) => { failureReject = reject; });
  // The failure promise may reject before the first bounded postMessage races
  // it (for example an early worker construction error). Mark it handled while
  // still letting every race observe the rejection.
  failure.catch(() => {});

  const release = () => {
    if (disposed) return;
    disposed = true;
    for (const channel of channels) {
      channel.port1.onmessage = null;
      try { channel.port1.close(); } catch (error) {}
      try { channel.port2.close(); } catch (error) {}
    }
    channels.clear();
    // Also own a newly created worker that has not reached WorkerPool's
    // array yet (for example when MessageChannel or postMessage throws).
    for (const worker of workers) { try { worker.terminate(); } catch (error) {} }
    workers.clear();
    if (initStarted && !upstreamDisposed) {
      upstreamDisposed = true;
      try { originalDispose(); } catch (error) {}
    } else {
      try { pool.dispose(); } catch (error) {}
    }
    ktx2.workerSourceURL = '';
    ktx2.transcoderBinary = null;
  };

  const fail = (message) => {
    if (failedMessage || disposed) return;
    failedMessage = sanitizeDiagnostic(message || 'texture decoder failed');
    try { failureReject(new Error(failedMessage)); } catch (error) {}
    release();
    try { onFailure?.(failedMessage); } catch (error) {}
  };

  ktx2.init = function guardedKTX2Init() {
    if (disposed) return Promise.reject(new Error(failedMessage || 'decoder closed'));
    if (initPending) return initPending;
    // Let the pinned loader prepare its own source, binary, manager and
    // active-loader accounting. Replacing init outright left that counter
    // unbalanced when upstream dispose decremented it.
    let upstream;
    try {
      upstream = originalInit();
      initStarted = true;
    } catch (error) {
      fail(error && error.message ? error.message : String(error));
      return Promise.reject(error);
    }
    const prepare = Promise.resolve(upstream).then(async () => {
      const originalURL = this.workerSourceURL;
      const discardLatePreparation = () => {
        if (this.workerSourceURL) URL.revokeObjectURL(this.workerSourceURL);
        this.workerSourceURL = '';
        this.transcoderBinary = null;
        pool.dispose();
      };
      if (disposed) {
        discardLatePreparation();
        throw new Error(failedMessage || 'decoder closed');
      }
      if (typeof originalURL !== 'string' || !originalURL.startsWith('blob:')) {
        throw new Error('invalid owned worker source');
      }
      // This is exclusively upstream's own Blob, never an asset-supplied URL.
      const response = await fetch(originalURL);
      if (!response.ok) throw new Error('unable to read owned worker source');
      const source = await response.text();
      if (disposed) {
        discardLatePreparation();
        throw new Error(failedMessage || 'decoder closed');
      }
      const built = guardExistingKTX2WorkerSource(source);
      this.workerSourceURL = URL.createObjectURL(new Blob([built.source], {type: 'text/javascript'}));
      URL.revokeObjectURL(originalURL);
      this.workerPool.setWorkerCreator(() => {
        if (disposed) throw new Error(failedMessage || 'decoder closed');
        let worker;
        try {
          worker = new Worker(this.workerSourceURL);
          workers.add(worker);
        } catch (error) {
          const reason = error && error.message ? error.message : String(error);
          fail('worker construction failed: ' + reason);
          throw error;
        }
        let channel;
        try {
          channel = new MessageChannel();
          channels.add(channel);
        } catch (error) {
          const reason = error && error.message ? error.message : String(error);
          fail('worker diagnostic channel failed: ' + reason);
          throw error;
        }
        channel.port1.onmessage = (event) => {
          const data = event && event.data && typeof event.data === 'object' ? event.data : {};
          const phase = data.phase ? data.phase + ': ' : '';
          fail(phase + (data.message || 'worker failure'));
        };
        worker.addEventListener('error', (event) => {
          fail('worker error: ' + (event && event.message ? event.message : 'failed'));
        }, {once: true});
        worker.addEventListener('messageerror', () => {
          fail('invalid worker response');
        }, {once: true});
        const transcoderBinary = this.transcoderBinary.slice(0);
        try {
          worker.postMessage(
            {type: 'init', config: this.workerConfig, transcoderBinary},
            [transcoderBinary, channel.port2]);
        } catch (error) {
          const reason = error && error.message ? error.message : String(error);
          fail('worker init failed: ' + reason);
          throw error;
        }
        return worker;
      });
      return built.patched;
    });
    initPending = boundedWorkerReply({
      start: () => prepare, failure, timeoutMs,
      onTimeout: () => fail('initialization timeout')
    });
    this.transcoderPending = initPending;
    initPending.catch((error) => {
      const reason = error && error.message ? error.message : String(error);
      fail('transcoder load failed: ' + reason);
    });
    return initPending;
  };

  const originalCreateTextureFrom = ktx2._createTextureFrom;
  if (typeof originalCreateTextureFrom === 'function') {
    ktx2._createTextureFrom = function guardedCreateTextureFrom(result, container) {
      const errorMessage = transcodeErrorMessage(result);
      if (errorMessage) {
        fail('transcode error: ' + errorMessage);
        return Promise.reject(new Error(errorMessage));
      }
      return originalCreateTextureFrom.call(this, result, container);
    };
  }

  pool.postMessage = function boundedKTX2PostMessage(message, transfer) {
    if (disposed) return Promise.reject(new Error(failedMessage || 'decoder closed'));
    return boundedWorkerReply({
      start: () => originalPostMessage(message, transfer),
      failure,
      timeoutMs,
      onTimeout: () => fail('decode timeout')
    });
  };

  ktx2.dispose = function guardedKTX2Dispose() {
    if (disposed) return;
    failureReject(new Error('decoder closed'));
    release();
  };
}
