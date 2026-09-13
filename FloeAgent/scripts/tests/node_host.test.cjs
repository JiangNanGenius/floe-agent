const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const hostPath = path.resolve(__dirname, '../../FloeApp/Resources/NodeTools/host.cjs');
function host(liveInput = false) {
  const child = liveInput
    ? spawn('python3', ['-c', 'import os, sys; os.set_blocking(3, False); os.execv(sys.argv[1], sys.argv[1:])', process.execPath, hostPath], { stdio: ['pipe', 'pipe', 'inherit', 'pipe'] })
    : spawn(process.execPath, [hostPath], { stdio: ['pipe', 'pipe', 'inherit'] });
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
