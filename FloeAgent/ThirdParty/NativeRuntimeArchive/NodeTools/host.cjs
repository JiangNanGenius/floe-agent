'use strict';
// One persistent runtime: one foreground worker plus explicitly owned services.
// Stop replies are sent only after worker exit, never at cancellation request time.
const fs = require('node:fs');
const { StringDecoder } = require('node:string_decoder');
const decoder = new StringDecoder('utf8');
const { Worker } = require('node:worker_threads');
const inputFD = Number(process.argv[2] ?? 0);
const outputFD = Number(process.argv[3] ?? 1);
// The native owner supplies a nonblocking command pipe. Poll bounded reads
// instead of parking a libuv filesystem worker on the idle pipe forever;
// libuv joins that worker during process exit, including XCTest host exit.
const output = fs.createWriteStream(null, { fd: outputFD, autoClose: false });
let current = null;
const services = new Map();
const maximumServices = 3;
function reply(value) { output.write(JSON.stringify(value) + '\n'); }
async function stop(reason, state = current) {
  if (!state) return;
  state.reason = reason;
  await state.worker.terminate();
}
function start(job, service = false) {
  if (service && (services.size >= maximumServices || services.has(job.id) || current?.id === job.id)) {
    reply({ id: job.id, status: 'busy', code: 125, stderr: 'Service limit or duplicate service ID' }); return;
  }
  if (!service && (current || services.has(job.id))) { reply({ id: job.id, status: 'busy', code: 125, stderr: 'Previous worker has not stopped' }); return; }
  if (typeof job.id !== 'string' || !Array.isArray(job.args) || !Number.isFinite(job.timeoutMs) ||
      job.timeoutMs < 1 || job.timeoutMs > 600000 || !Number.isInteger(job.maxOutputBytes) ||
      job.maxOutputBytes < 1 || job.maxOutputBytes > 1048576) {
    reply({ id: job.id, status: 'invalid', code: 125, stderr: 'Invalid Node request' }); return;
  }
  let worker;
  try {
    const path = require('node:path');
    if (typeof job.cwd !== 'string' || !path.isAbsolute(job.cwd) || !require('node:fs').statSync(job.cwd).isDirectory()) throw Error('A valid absolute working directory is required');
    const data = { floeJob: true, service, stdin: job.stdin ?? '', cwd: job.cwd, args: job.args };
    if (Number.isInteger(job.stdinFD) && job.stdinFD >= 3) data.stdinFD = job.stdinFD;
    if (job.entry) data.entry = path.resolve(job.cwd, job.entry);
    else if (['-e', '--eval', '-p', '--print'].includes(job.args[0])) {
      if (typeof job.args[1] !== 'string') throw Error('JavaScript source is required');
      data.source = job.args[1]; data.print = ['-p', '--print'].includes(job.args[0]); data.args = job.args.slice(2);
    } else if (['-v', '--version'].includes(job.args[0])) data.source = 'console.log(process.version)';
    else if (job.args[0] === '-' || !job.args.length) {
      if (data.stdinFD !== undefined) data.sourceFromStdin = true;
      else data.source = Buffer.from(job.stdin ?? '', 'base64').toString('utf8');
      data.stdin = ''; data.args = job.args.slice(1);
    }
    else if (job.args[0] && !job.args[0].startsWith('-')) { data.entry = path.resolve(job.cwd, job.args[0]); data.args = job.args.slice(1); }
    else throw Error('Supported Node invocation: script, -e, -p or --version');
    worker = new Worker(path.join(__dirname, 'worker.cjs'), { stdout: true, stderr: true,
      env: job.env, workerData: data, resourceLimits: { maxOldGenerationSizeMb: 256 }, execArgv: [] });
  } catch (error) {
    reply({ id: job.id, status: 'failed', code: 125, stderr: String(error) }); return;
  }
  const state = { worker, id: job.id, stdout: [], stderr: [], bytes: 0, truncated: false, reason: null };
  if (service) services.set(job.id, state);
  else current = state;
  function capture(channel, chunk) {
    const bytes = Buffer.from(chunk);
    const retained = bytes.subarray(0, Math.max(0, job.maxOutputBytes - state.bytes));
    state[channel].push(retained);
    state.bytes += retained.length;
    if (retained.length < bytes.length) state.truncated = true;
    // Do not retain empty buffers when a program writes indefinitely.
    if (!retained.length) state[channel].pop();
  }
  worker.stdout.on('data', chunk => capture('stdout', chunk));
  worker.stderr.on('data', chunk => capture('stderr', chunk));
  worker.on('error', error => capture('stderr', `${error.code ? error.code + ': ' : ''}${String(error)}`));
  const timer = service ? null : setTimeout(() => { void stop('timedOut', state); }, job.timeoutMs);
  worker.on('exit', code => {
    clearTimeout(timer);
    if (service) services.delete(job.id);
    else if (current === state) current = null;
    reply({ id: job.id, ...(service ? { event: 'serviceExited' } : {}), status: state.reason ?? 'ok', code,
      stdout: Buffer.from(Buffer.concat(state.stdout).toString('utf8')).toString('base64'), stderr: Buffer.from(Buffer.concat(state.stderr).toString('utf8')).toString('base64'),
      encoding: 'base64', truncated: state.truncated });
  });
  if (service) reply({ id: job.id, status: 'started', serviceID: job.id, note: 'Worker started; endpoint readiness must be verified separately' });
}
async function controlService(request) {
  const state = services.get(request.serviceID);
  if (!state) { reply({ id: request.id, status: 'notFound', code: 1 }); return; }
  if (request.service === 'stop') {
    await stop('cancelled', state);
    reply({ id: request.id, status: 'stopped', serviceID: request.serviceID, code: 0 });
  } else if (request.service === 'status') {
    reply({ id: request.id, status: state.reason ? 'stopping' : 'running', serviceID: state.id,
      stdout: Buffer.concat(state.stdout).toString('base64'), stderr: Buffer.concat(state.stderr).toString('base64'),
      encoding: 'base64', truncated: state.truncated });
  } else reply({ id: request.id, status: 'invalid', code: 125, stderr: 'Unknown service operation' });
}
let buffered = '';
let inputClosed = false;
function closeInput() {
  if (inputClosed) return;
  inputClosed = true;
  void Promise.all([current, ...services.values()].filter(Boolean).map(state => stop('cancelled', state))).finally(() => output.end());
}
function consume(chunk) {
  buffered += decoder.write(chunk);
  if (Buffer.byteLength(buffered) > 2 * 1024 * 1024) { reply({ status: 'invalid', code: 125, stderr: 'Request size limit exceeded' }); closeInput(); return; }
  let newline;
  while ((newline = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, newline); buffered = buffered.slice(newline + 1);
    try {
      const request = JSON.parse(line);
      if (request.cancel) {
        const state = current?.id === request.cancel ? current : services.get(request.cancel);
        if (state) void stop('cancelled', state);
      } else if (request.service === 'start') start(request, true);
      else if (request.service) void controlService(request).catch(error => reply({ id: request.id, status: 'failed', code: 125, stderr: String(error) }));
      else start(request);
    } catch (error) { reply({ status: 'invalid', code: 125, stderr: String(error) }); }
  }
}
const commandBuffer = Buffer.allocUnsafe(16384);
function readCommands() {
  if (inputClosed) return;
  // Bound each turn so a producer cannot starve worker exits/cancellation.
  for (let count = 0; count < 64 && !inputClosed; count++) {
    let length;
    try { length = fs.readSync(inputFD, commandBuffer, 0, commandBuffer.length, null); }
    catch (error) {
      if (error.code === 'EAGAIN' || error.code === 'EWOULDBLOCK') break;
      if (error.code === 'EINTR') continue;
      reply({ status: 'failed', code: 125, stderr: String(error) }); closeInput(); return;
    }
    if (length === 0) { closeInput(); return; }
    consume(commandBuffer.subarray(0, length));
  }
  if (!inputClosed) setTimeout(readCommands, 20);
}
reply({ status: 'ready', version: process.version });
readCommands();
