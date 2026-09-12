const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const hostPath = path.resolve(__dirname, '../../FloeApp/Resources/NodeTools/host.cjs');
function host() {
  const child = spawn(process.execPath, [hostPath], { stdio: ['pipe', 'pipe', 'inherit'] });
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
