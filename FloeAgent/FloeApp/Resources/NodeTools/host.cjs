'use strict';
// One persistent runtime, one worker at a time. A response is sent only after
// worker exit, so cancellation completion also proves ownership is released.
const fs = require('node:fs');
const { StringDecoder } = require('node:string_decoder');
const decoder = new StringDecoder('utf8');
const { Worker } = require('node:worker_threads');
const inputFD = Number(process.argv[2] ?? 0);
const outputFD = Number(process.argv[3] ?? 1);
const input = fs.createReadStream(null, { fd: inputFD, autoClose: false });
const output = fs.createWriteStream(null, { fd: outputFD, autoClose: false });
let current = null;
function reply(value) { output.write(JSON.stringify(value) + '\n'); }
async function stop(reason) {
  if (!current) return;
  current.reason = reason;
  await current.worker.terminate();
}
function start(job) {
  if (current) { reply({ id: job.id, status: 'busy', code: 125, stderr: 'Previous worker has not stopped' }); return; }
  if (typeof job.id !== 'string' || !Array.isArray(job.args) || !Number.isFinite(job.timeoutMs) ||
      job.timeoutMs < 1 || job.timeoutMs > 600000 || !Number.isInteger(job.maxOutputBytes) ||
      job.maxOutputBytes < 1 || job.maxOutputBytes > 1048576) {
    reply({ id: job.id, status: 'invalid', code: 125, stderr: 'Invalid Node request' }); return;
  }
  let worker;
  try {
    const path = require('node:path');
    if (typeof job.cwd !== 'string' || !path.isAbsolute(job.cwd) || !require('node:fs').statSync(job.cwd).isDirectory()) throw Error('A valid absolute working directory is required');
    const data = { floeJob: true, stdin: job.stdin ?? '', cwd: job.cwd, args: job.args };
    if (job.entry) data.entry = path.resolve(job.cwd, job.entry);
    else if (['-e', '--eval', '-p', '--print'].includes(job.args[0])) {
      if (typeof job.args[1] !== 'string') throw Error('JavaScript source is required');
      data.source = job.args[1]; data.print = ['-p', '--print'].includes(job.args[0]); data.args = job.args.slice(2);
    } else if (['-v', '--version'].includes(job.args[0])) data.source = 'console.log(process.version)';
    else if (job.args[0] && !job.args[0].startsWith('-')) { data.entry = path.resolve(job.cwd, job.args[0]); data.args = job.args.slice(1); }
    else throw Error('Supported Node invocation: script, -e, -p or --version');
    worker = new Worker(path.join(__dirname, 'worker.cjs'), { stdout: true, stderr: true,
      env: job.env, workerData: data, resourceLimits: { maxOldGenerationSizeMb: 256 }, execArgv: [] });
  } catch (error) {
    reply({ id: job.id, status: 'failed', code: 125, stderr: String(error) }); return;
  }
  const state = { worker, id: job.id, stdout: [], stderr: [], bytes: 0, truncated: false, reason: null };
  current = state;
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
  worker.on('error', error => capture('stderr', String(error)));
  const timer = setTimeout(() => { void stop('timedOut'); }, job.timeoutMs);
  worker.on('exit', code => {
    clearTimeout(timer);
    current = null;
    reply({ id: job.id, status: state.reason ?? 'ok', code,
      stdout: Buffer.from(Buffer.concat(state.stdout).toString('utf8')).toString('base64'), stderr: Buffer.from(Buffer.concat(state.stderr).toString('utf8')).toString('base64'),
      encoding: 'base64', truncated: state.truncated });
  });
}
let buffered = '';
input.on('data', chunk => {
  buffered += decoder.write(chunk);
  if (Buffer.byteLength(buffered) > 2 * 1024 * 1024) { reply({ status: 'invalid', code: 125, stderr: 'Request size limit exceeded' }); input.destroy(); return; }
  let newline;
  while ((newline = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, newline); buffered = buffered.slice(newline + 1);
    try {
      const request = JSON.parse(line);
      if (request.cancel) { if (current?.id === request.cancel) void stop('cancelled'); }
      else start(request);
    } catch (error) { reply({ status: 'invalid', code: 125, stderr: String(error) }); }
  }
});
input.on('end', () => { void stop('cancelled').finally(() => output.end()); });
reply({ status: 'ready', version: process.version });
