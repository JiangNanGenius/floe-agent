#!/usr/bin/env node
/*
 * Unit tests for the exact inline core shipped in REMOTE.html. The core is
 * executed in a DOM-free VM context twice: once with WebCrypto, once with the
 * pure-JS fallback used by a plain-HTTP LAN origin.
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(here, '../../Resources/BridgeRemote/REMOTE.html'), 'utf8');
const match = html.match(/<script id="floe-core">\n([\s\S]*?)\n<\/script>/);
if (!match) throw new Error('shipped core script not found');
const coreSource = match[1];

let failures = 0;
function check(condition, message) {
  if (!condition) { failures += 1; console.error('FAIL ' + message); }
  else console.log('PASS ' + message);
}
function equal(actual, expected, message) {
  check(actual === expected, message + (actual === expected ? '' : ' (got ' + JSON.stringify(actual) + ', expected ' + JSON.stringify(expected) + ')'));
}
function loadCore(cryptoObject) {
  const sandbox = {
    TextEncoder,
    TextDecoder,
    console,
    crypto: cryptoObject,
    btoa: (value) => Buffer.from(value, 'binary').toString('base64'),
    atob: (value) => Buffer.from(value, 'base64').toString('binary')
  };
  vm.createContext(sandbox);
  vm.runInContext(coreSource, sandbox, { filename: 'REMOTE.html#floe-core' });
  return sandbox.FloeRemoteCore;
}

const fallbackCrypto = { getRandomValues: (array) => webcrypto.getRandomValues(array) };
const cores = [
  ['webcrypto', loadCore(webcrypto)],
  ['fallback', loadCore(fallbackCrypto)]
];

for (const [name, C] of cores) {
  console.log('-- ' + name + ' --');
  const encoder = new TextEncoder();
  equal(C.hex(await C.sha256(encoder.encode('abc'))),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    name + ': SHA-256 FIPS vector');
  equal(C.hex(C._test.hmacFallback(encoder.encode('Jefe'), encoder.encode('what do ya want for nothing?'))),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    name + ': HMAC-SHA256 RFC 4231 case 2');
  equal(C.hex(await C.hmac(encoder.encode('Jefe'), encoder.encode('what do ya want for nothing?'))),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    name + ': async HMAC matches RFC 4231');

  const key = new Uint8Array(32); for (let i = 0; i < 32; i++) key[i] = i;
  const nonce = new Uint8Array(16); for (let i = 0; i < 16; i++) nonce[i] = i;
  const plain = encoder.encode('{"id":1,"jsonrpc":"2.0","method":"device_info"}');
  const env = await C.sealRequest(plain, key, '630dcd29', nonce, 1700000000);
  equal(env.ct, 'LBWCQvXPN3n1VJyojcZyCT+qamW0x3ZEeZftn9zQ5NohSRVhTnMrexYNVUnnbeo=', name + ': request ciphertext known vector');
  equal(env.tag, '59519f46ceec95fbc41aad96b85098cae37fc8e91f4f63b5228bcc672fb0d0fe', name + ': request tag known vector');
  const respEnv = { v: 1, nonce: C.hex(nonce), ct: 'LWca1EWiHk4JimI4eCduEwxp3qSclaRMXU5BQkcw6Yo8vWPtRDu1cZH3okaD', tag: 'd8c8bbce687a80a243893a2507821623f37b76d0abd24246c2e301a2b211fbc1' };
  equal(await C.openResponse(respEnv, key, nonce), '{"id":1,"jsonrpc":"2.0","result":{"ok":true}}', name + ': response open known vector');
  let rejected = false;
  try { await C.openResponse(Object.assign({}, respEnv, { tag: '00'.repeat(32) }), key, nonce); } catch (_) { rejected = true; }
  check(rejected, name + ': response MAC mismatch is rejected before JSON parse');

  const scalar = C.unhex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4');
  const u = C.unhex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c');
  equal(C.hex(C.x25519ScalarMult(scalar, u)),
    'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552',
    name + ': X25519 RFC 7748 5.2');
  const alicePrivate = C.unhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
  const bobPrivate = C.unhex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
  equal(C.hex(C.x25519Public(alicePrivate)), '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a', name + ': X25519 Alice public');
  equal(C.hex(C.x25519Public(bobPrivate)), 'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f', name + ': X25519 Bob public');

  const shared = new Uint8Array(32); for (let i = 0; i < 32; i++) shared[i] = i;
  const clientPub = new Uint8Array(32); for (let i = 0; i < 32; i++) clientPub[i] = 32 + i;
  const devicePub = new Uint8Array(32); for (let i = 0; i < 32; i++) devicePub[i] = 64 + i;
  const tokenCt = new Uint8Array(32); for (let i = 0; i < 32; i++) tokenCt[i] = 96 + i;
  const wrapped = await C.deriveWrappedKey(shared, clientPub, devicePub, tokenCt);
  equal(C.hex(wrapped), '9e03975ff2b31dc20854a2d9c6d6bcdb11f48dae2bd46249c2030f709f934636', name + ': X25519 pair wrap known vector');
  equal(await C.tokenId(wrapped), '155e7a1d', name + ': wrapped token id');

  const rect = { left: 0, top: 0, width: 300, height: 300 };
  const box = C.fitBox(rect, 100, 200, 'contain');
  equal(box.x0, 75, name + ': contain letterbox x0');
  equal(box.w, 150, name + ': contain letterbox width');
  const point = C.clientToPoint(150, 150, rect, 100, 200, 'contain', 50, 100);
  equal(point.x, 25, name + ': contain point x');
  equal(point.y, 50, name + ': contain point y');
  check(C.clientToPoint(10, 10, rect, 100, 200, 'contain', 50, 100) === null, name + ': click in letterbox is rejected');
  const cover = C.fitBox(rect, 100, 200, 'cover');
  equal(cover.w, 300, name + ': cover width');
  equal(cover.h, 600, name + ': cover height');
  const fill = C.fitBox(rect, 100, 200, 'fill');
  equal(fill.w, 300, name + ': fill width');
  equal(fill.h, 300, name + ': fill height');
  equal(C.normalizePoint({ x: -4, y: 1200 }, 390, 844).x, 0, name + ': point clamp x');
  equal(C.normalizePoint({ x: -4, y: 1200 }, 390, 844).y, 844, name + ': point clamp y');

  const ftyp = new Uint8Array(16); ftyp.set([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d], 0);
  equal(C.detectStreamKind(ftyp), 'mp4', name + ': fMP4 detection');
  const ts = new Uint8Array(188 * 2); ts[0] = 0x47; ts[188] = 0x47;
  equal(C.detectStreamKind(ts), 'mpegts', name + ': MPEG-TS detection');
  const avc = new Uint8Array(24); avc.set([0, 0, 0, 20, 0x61, 0x76, 0x63, 0x43, 1, 0x4d, 0x40, 0x28], 0);
  equal(C.avcCodecFromInit(avc), 'avc1.4d4028', name + ': avcC codec extraction');
}

if (failures) {
  console.error('CORE FAILURES ' + failures);
  process.exit(1);
}
console.log('CORE CHECKS OK');
