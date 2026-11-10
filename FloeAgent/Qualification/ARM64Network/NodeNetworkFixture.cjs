// SPDX-License-Identifier: MPL-2.0
// Synthetic guest-only fixture. Start after the Linux environment is ready.
'use strict';
const http = require('node:http');
const net = require('node:net');
const dgram = require('node:dgram');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const basePort = Number(process.argv[2] || 18080);
const family = process.argv[3] || 'ipv4';
if (!Number.isInteger(basePort) || basePort < 1024 || basePort > 65532 ||
    !['ipv4', 'ipv6', 'dual'].includes(family)) {
  throw new Error('Usage: node NodeNetworkFixture.cjs [base-port] [ipv4|ipv6|dual]');
}
const block = Buffer.allocUnsafe(64 * 1024);
for (let i = 0; i < block.length; i++) block[i] = i & 255;
const small = Buffer.from('FLOE_NETWORK_FIXTURE_V1\n');
const page = Buffer.from('<!doctype html><meta charset="utf-8"><title>Network fixture</title>' +
  '<h1>Floe network fixture</h1><p id="status">Loading</p><script>' +
  'Promise.all(Array.from({length:12},(_,i)=>fetch("/small?r="+i).then(r=>r.text())))' +
  '.then(a=>document.getElementById("status").textContent="Ready: "+a.length)' +
  '.catch(e=>document.getElementById("status").textContent=e.message)</script>');

function sizeArgument(url, fallback) {
  const value = Number(url.searchParams.get('bytes') || fallback);
  if (!Number.isInteger(value) || value < 1 || value > 64 * 1024 * 1024) {
    throw new Error('bytes must be an integer in 1...67108864');
  }
  return value;
}
function expectedHash(bytes) {
  const hash = crypto.createHash('sha256');
  for (let done = 0; done < bytes; done += block.length) {
    hash.update(block.subarray(0, Math.min(block.length, bytes - done)));
  }
  return hash.digest('hex');
}
function streamBytes(res, bytes) {
  let sent = 0;
  const pump = () => {
    if (res.destroyed || res.writableEnded) return;
    while (sent < bytes) {
      const chunk = block.subarray(0, Math.min(block.length, bytes - sent));
      sent += chunk.length;
      if (!res.write(chunk)) { res.once('drain', pump); return; }
    }
    res.end();
  };
  pump();
}
let probingLocal = false;
async function localProbe(res) {
  if (probingLocal) { res.statusCode = 429; res.end('Probe already running\n'); return; }
  probingLocal = true;
  try {
    const samples = [];
    for (const path of ['/small', '/small', '/small', '/large?bytes=8388608']) {
      const started = process.hrtime.bigint();
      const sample = await new Promise((resolve, reject) => {
        const request = http.get({ host: family === 'ipv6' ? '::1' : '127.0.0.1',
          port: basePort, path, agent: false, timeout: 120000 }, response => {
          const headersAt = process.hrtime.bigint();
          let bytes = 0;
          response.on('data', chunk => { bytes += chunk.length; });
          response.once('error', reject);
          response.once('end', () => resolve({ path, bytes, status: response.statusCode,
            headersSeconds: Number(headersAt - started) / 1e9,
            totalSeconds: Number(process.hrtime.bigint() - started) / 1e9 }));
        });
        request.once('timeout', () => request.destroy(new Error('Local probe timeout')));
        request.once('error', reject);
      });
      if (sample.status !== 200 || sample.bytes !== (path === '/small' ? small.length : 8388608)) {
        throw new Error('Local probe response mismatch');
      }
      samples.push(sample);
    }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ path: 'guest-kernel-loopback',
      includesGuestHTTPClientCPU: true, samples }));
  } catch (error) {
    res.statusCode = 500;
    res.end(String(error.message) + '\n');
  } finally {
    probingLocal = false;
  }
}
function route(req, res) {
  const began = process.hrtime.bigint();
  res.setHeader('Cache-Control', 'no-store');
  try {
    const url = new URL(req.url, 'http://fixture.invalid');
    if (url.pathname === '/local-probe') { void localProbe(res); return; }
    let data;
    if (url.pathname === '/small') data = small;
    else if (url.pathname === '/') {
      data = page;
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
    } else if (url.pathname === '/large') {
      const bytes = sizeArgument(url, 8 * 1024 * 1024);
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Content-Length', bytes);
      streamBytes(res, bytes);
      return;
    } else if (url.pathname === '/manifest') {
      const bytes = sizeArgument(url, 8 * 1024 * 1024);
      data = Buffer.from(JSON.stringify({ bytes, sha256: expectedHash(bytes) }));
      res.setHeader('Content-Type', 'application/json');
    } else if (url.pathname === '/dynamic') {
      let result = 0;
      for (let i = 0; i < 100000; i++) result = (Math.imul(result, 1664525) + i + 1013904223) >>> 0;
      data = Buffer.from(JSON.stringify({ result }));
      res.setHeader('Content-Type', 'application/json');
    } else if (url.pathname === '/gzip') {
      // Deliberately per-request work, measured separately from /large.
      data = zlib.gzipSync(block);
      res.setHeader('Content-Encoding', 'gzip');
      res.setHeader('Content-Type', 'application/octet-stream');
    } else {
      res.statusCode = 404;
      data = Buffer.from('Unknown fixture route\n');
    }
    res.setHeader('Content-Length', data.length);
    res.setHeader('X-Fixture-Handler-Ns', String(process.hrtime.bigint() - began));
    res.end(data);
  } catch (error) {
    res.statusCode = 400;
    res.end(String(error.message) + '\n');
  }
}

const closers = [];
const active = new Set();
const loopback = process.env.FLOE_NETWORK_FIXTURE_BIND_LOOPBACK === '1';
const v4 = loopback ? '127.0.0.1' : '0.0.0.0';
const v6 = loopback ? '::1' : '::';
const addresses = family === 'dual' ? [v4, v6] : [family === 'ipv6' ? v6 : v4];
const listenTasks = [];
for (const host of addresses) {
  const isIPv6 = host.includes(':');
  const options = { host, ipv6Only: isIPv6 };
  for (const [offset, factory] of [[0, () => http.createServer(route)],
      [1, () => net.createServer(socket => socket.pipe(socket))]]) {
    const server = factory();
    server.on('connection', socket => {
      if (active.size >= 64) { socket.destroy(); return; }
      active.add(socket);
      socket.once('close', () => active.delete(socket));
      socket.on('error', () => {});
    });
    closers.push(() => server.close());
    listenTasks.push(new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen({ ...options, port: basePort + offset }, resolve);
    }));
  }
  const udp = dgram.createSocket({ type: isIPv6 ? 'udp6' : 'udp4', ipv6Only: isIPv6 });
  udp.on('message', (bytes, peer) => udp.send(bytes, peer.port, peer.address, () => {}));
  closers.push(() => udp.close());
  listenTasks.push(new Promise((resolve, reject) => {
    udp.once('error', reject);
    udp.bind(basePort + 2, host, resolve);
  }));
}
function stop(code) {
  for (const socket of active) socket.destroy();
  for (const close of closers) { try { close(); } catch (_) {} }
  process.exitCode = code;
}
Promise.all(listenTasks).then(() => {
  process.stdout.write(JSON.stringify({ fixture: 'FLOE_NETWORK_FIXTURE_V1', ready: true,
    family, httpPort: basePort, tcpEchoPort: basePort + 1, udpEchoPort: basePort + 2,
    node: process.version, arch: process.arch }) + '\n');
}, error => {
  process.stderr.write('Fixture bind failed: ' + error.message + '\n');
  stop(1);
});
process.once('SIGTERM', () => stop(0));
process.once('SIGINT', () => stop(0));
