const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const hostPath = path.resolve(__dirname, '../../FloeApp/Resources/NodeTools/host.cjs');
function host(liveInput = false, exitWithOpenCommandPipe = false) {
  const args = exitWithOpenCommandPipe
    ? ['-e', `process.once('SIGUSR2', () => process.exit(0)); require(${JSON.stringify(hostPath)});`]
    : [hostPath];
  // Match the native bridge's command descriptor contract; fd 3 is the
  // independent user stdin channel in the interactive cases.
  const setup = `import os, sys; os.set_blocking(0, False); ${liveInput ? 'os.set_blocking(3, False); ' : ''}os.execv(sys.argv[1], sys.argv[1:])`;
  const child = spawn('python3', ['-c', setup, process.execPath, ...args],
    { stdio: liveInput ? ['pipe', 'pipe', 'inherit', 'pipe'] : ['pipe', 'pipe', 'inherit'] });
  const waiting = new Map();
  let ready;
  const started = new Promise(resolve => { ready = resolve; });
  readline.createInterface({ input: child.stdout }).on('line', line => {
    const result = JSON.parse(line);
    if (result.status === 'ready') ready(result);
    const resolve = waiting.get(result.id);
    if (resolve) { waiting.delete(result.id); resolve(result); }
  });
  return { child, started,
    send(job) { return new Promise(resolve => { waiting.set(job.id, resolve); child.stdin.write(JSON.stringify(job) + '\n'); }); },
    cancel(id) { child.stdin.write(JSON.stringify({ cancel: id }) + '\n'); },
    close() { child.stdin.end(); }
  };
}
function request(id, source, extras = {}) {
  return { id, args: ['-e', source], cwd: process.cwd(), env: {}, maxOutputBytes: 1024, timeoutMs: 3000, ...extras };
}
function stdout(result) { return Buffer.from(result.stdout, 'base64').toString(); }
test('runtime exits with the idle command pipe still open after a completed job', { timeout: 7000 }, async () => {
  const h = host(false, true);
  let timer;
  const exited = new Promise((resolve, reject) => {
    h.child.once('exit', (code, signal) => resolve({ code, signal }));
    timer = setTimeout(() => reject(Error('Runtime exit waited for command pipe EOF')), 5000);
  });
  try {
    await h.started;
    assert.equal(stdout(await h.send(request('before-exit', 'console.log(42)'))), '42\n');
    // Deliberately keep child.stdin open through exit; closing it would hide
    // the libuv thread-pool join deadlock reproduced in the embedded host.
    h.child.kill('SIGUSR2');
    assert.deepEqual(await exited, { code: 0, signal: null });
  } finally {
    clearTimeout(timer);
    if (h.child.exitCode === null) h.child.kill('SIGKILL');
    h.close();
  }
});
test('one host repeats workers, preserves cwd/env/stdin and bounds output', { timeout: 15000 }, async () => {
  const h = host(); await h.started;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'floe-node-test-'));
  try {
    fs.writeFileSync(path.join(root, 'value.txt'), 'file-data');
    const first = await h.send(request('first', "console.log(process.env.FLOE_TEST, require('fs').readFileSync('value.txt','utf8')); process.stdin.on('data', b => process.stdout.write(b));", { cwd: root, env: { FLOE_TEST: 'scoped' }, stdin: Buffer.from('input-data').toString('base64') }));
    assert.equal(first.code, 0); assert.equal(stdout(first), 'scoped file-data\ninput-data');
    const next = await h.send(request('next', "console.log(process.env.FLOE_TEST ?? 'unset')"));
    assert.equal(stdout(next), 'unset\n');
    const version = await h.send(request('version', '', { args: ['-v'] }));
    assert.equal(stdout(version).trim(), process.version);
    const fromStdin = await h.send(request('stdin-script', '', { args: ['-'], stdin: Buffer.from("console.log('from stdin')").toString('base64') }));
    assert.equal(fromStdin.code, 0); assert.equal(stdout(fromStdin), 'from stdin\n');
    const bounded = await h.send(request('bounded', "process.stdout.write('x'.repeat(1000000))", { maxOutputBytes: 100 }));
    assert.equal(stdout(bounded).length, 100); assert.equal(bounded.truncated, true);
    const exit = await h.send(request('exit', 'process.exit(7)'));
    assert.equal(exit.code, 7);
    const after = await h.send(request('after', "console.log('alive')"));
    assert.equal(stdout(after), 'alive\n');
  } finally { h.close(); fs.rmSync(root, { recursive: true, force: true }); }
});
test('running cancellation and CPU timeout stop the worker before next job', { timeout: 15000 }, async () => {
  const h = host(); await h.started;
  try {
    const running = h.send(request('cancel', 'while(true){}'));
    setTimeout(() => h.cancel('cancel'), 100);
    assert.equal((await running).status, 'cancelled');
    assert.equal((await h.send(request('timeout', 'while(true){}', { timeoutMs: 100 }))).status, 'timedOut');
    assert.equal(stdout(await h.send(request('last', 'console.log(42)'))), '42\n');
  } finally { h.close(); }
});
test('pinned package manager entry points start on the shared host', { timeout: 60000 }, async () => {
  const h = host(); await h.started;
  try {
    for (const [name, entry, version] of [['npm', 'bin/npm-cli.js', '10.9.2'], ['pnpm', 'bin/pnpm.cjs', '9.15.9'], ['yarn', 'bin/yarn.js', '1.22.22']]) {
      const result = await h.send(request(name, '', { entry: path.resolve(path.dirname(hostPath), name, entry), args: ['--version'], env: { HOME: os.tmpdir() }, timeoutMs: 15000 }));
      assert.equal(result.code, 0, `${name}: ${Buffer.from(result.stderr ?? '', 'base64').toString()}`);
      assert.equal(stdout(result).trim(), version);
    }
  } finally { h.close(); }
});
test('worker routes relative async, stream, Buffer and file URL filesystem operations', { timeout: 15000 }, async () => {
  const h = host(); await h.started;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'floe-node-paths-'));
  try {
    const script = `(async () => {
      const fs = require('node:fs'); const p = fs.promises;
      await p.writeFile('a.txt', 'scoped'); await p.rename('a.txt', 'b.txt');
      await p.symlink('b.txt', 'link.txt');
      let text = ''; for await (const b of fs.createReadStream('link.txt')) text += b;
      const esm = await import('node:fs/promises');
      console.log(text, await esm.readFile(Buffer.from('b.txt'), 'utf8'),
        await p.readFile(require('node:url').pathToFileURL(process.cwd() + '/b.txt'), 'utf8'));
    })().catch(e => { console.error(e); process.exitCode = 1; });`;
    const entry = path.join(root, 'paths.cjs');
    fs.writeFileSync(entry, script);
    const result = await h.send(request('paths', '', { entry, args: [], cwd: root }));
    assert.equal(result.code, 0, Buffer.from(result.stderr ?? '', 'base64').toString());
    assert.equal(stdout(result), 'scoped scoped scoped\n');
    assert.equal(fs.readlinkSync(path.join(root, 'link.txt')), 'b.txt');
    assert.equal(fs.readFileSync(path.join(root, 'b.txt'), 'utf8'), 'scoped');
  } finally { h.close(); fs.rmSync(root, { recursive: true, force: true }); }
});

test('live stdin accepts a line without waiting for EOF', { timeout: 10000 }, async () => {
  const h = host(true); await h.started;
  try {
    const running = h.send(request('live', "process.stdin.once('data', b => { console.log(b.toString().trim()); process.exit(0); });", { stdinFD: 3 }));
    setTimeout(() => h.child.stdio[3].write('interactive-line\n'), 100);
    const result = await running;
    assert.equal(result.code, 0); assert.equal(stdout(result), 'interactive-line\n');
  } finally { h.child.stdio[3].end(); h.close(); }
});
test('cancellation releases a live stdin reader before the next job', { timeout: 10000 }, async () => {
  const h = host(true); await h.started;
  const cleanup = setTimeout(() => h.child.stdio[3].end(), 5000);
  try {
    const running = h.send(request('waiting-input', "process.stdin.resume();", { stdinFD: 3, timeoutMs: 8000 }));
    setTimeout(() => h.cancel('waiting-input'), 200);
    const started = Date.now();
    assert.equal((await running).status, 'cancelled');
    assert.ok(Date.now() - started < 2000, 'cancellation must not wait for stdin EOF');
    assert.equal(stdout(await h.send(request('after-input', 'console.log(42)'))), '42\n');
  } finally { clearTimeout(cleanup); h.child.stdio[3].end(); h.close(); }
});
test('sync stdin read and node - remain cancellable while no bytes arrive', { timeout: 10000 }, async () => {
  for (const args of [['-e', "require('fs').readFileSync(0, 'utf8')"], ['-']]) {
    const h = host(true); await h.started;
    try {
      const running = h.send(request('sync-input', '', { args, stdinFD: 3 }));
      setTimeout(() => h.cancel('sync-input'), 100);
      assert.equal((await running).status, 'cancelled');
      assert.equal(stdout(await h.send(request('after-sync', 'console.log(42)'))), '42\n');
    } finally { h.child.stdio[3].end(); h.close(); }
  }
});

test('managed service keeps HTTP alive while foreground workers run and stops before acknowledgement', { timeout: 15000 }, async () => {
  const h = host(); await h.started;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'floe-node-service-'));
  try {
    const source = `const server = require('node:http').createServer((req, res) => res.end(process.env.SERVICE_VALUE));
      server.listen(0, '127.0.0.1', () => require('node:fs').writeFileSync('port', String(server.address().port)));`;
    const started = await h.send(request('web-service', source, {
      service: 'start', cwd: root, env: { SERVICE_VALUE: 'owned-response' }, timeoutMs: 50
    }));
    assert.equal(started.status, 'started');
    const deadline = Date.now() + 5000;
    while (!fs.existsSync(path.join(root, 'port')) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    const port = fs.readFileSync(path.join(root, 'port'), 'utf8');
    const url = `http://127.0.0.1:${port}/`;
    assert.equal(await (await fetch(url)).text(), 'owned-response');
    assert.equal(stdout(await h.send(request('foreground-with-service', 'console.log(42)'))), '42\n');
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(await (await fetch(url)).text(), 'owned-response', 'foreground timeout must not expire a service');
    assert.equal((await h.send({ id: 'inspect-service', service: 'status', serviceID: 'web-service' })).status, 'running');
    assert.equal((await h.send({ id: 'stop-service', service: 'stop', serviceID: 'web-service' })).status, 'stopped');
    await assert.rejects(fetch(url));
    assert.equal((await h.send({ id: 'inspect-stopped', service: 'status', serviceID: 'web-service' })).status, 'notFound');
    assert.equal(stdout(await h.send(request('after-service', 'console.log(43)'))), '43\n');
  } finally { h.close(); fs.rmSync(root, { recursive: true, force: true }); }
});

test('service worker limits, bounded logs and independent cancellation', { timeout: 15000 }, async () => {
  const h = host(); await h.started;
  try {
    for (let i = 0; i < 3; i++) {
      assert.equal((await h.send(request(`service-${i}`, "setInterval(() => console.log('x'.repeat(10000)), 5)", { service: 'start', maxOutputBytes: 100 }))).status, 'started');
    }
    assert.equal((await h.send(request('overflow', 'setInterval(() => {}, 100)', { service: 'start' }))).status, 'busy');
    assert.equal((await h.send(request('service-0', '42', { service: 'start' }))).status, 'busy');
    await new Promise(resolve => setTimeout(resolve, 200));
    const logs = await h.send({ id: 'logs', service: 'status', serviceID: 'service-0' });
    assert.equal(stdout(logs).length, 100); assert.equal(logs.truncated, true);
    assert.equal((await h.send({ id: 'stop-one', service: 'stop', serviceID: 'service-0' })).status, 'stopped');
    assert.equal((await h.send({ id: 'other-alive', service: 'status', serviceID: 'service-1' })).status, 'running');
    assert.equal((await h.send(request('replacement', 'setInterval(() => {}, 100)', { service: 'start' }))).status, 'started');
  } finally { h.close(); }
});

test('a command that does not read stdin finishes while its producer remains open', { timeout: 10000 }, async () => {
  const h = host(true); await h.started;
  try {
    const result = await h.send(request('no-input-needed', 'console.log(42)', { stdinFD: 3 }));
    assert.equal(result.code, 0); assert.equal(stdout(result), '42\n');
  } finally { h.child.stdio[3].end(); h.close(); }
});
