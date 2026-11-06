/** Copyright (c) 2026 Floe Contributors — MPL-2.0
 * Node qualification runner: slices synthetic meshes with the vendored
 * Kiri:Moto subset and writes real FDM G-code + CTB v3 artifacts.
 * Evidence only — Node runtime does not prove iPad WebKit runtime.
 */
'use strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { createPrintHost, createSettings, sliceFDM, sliceSLA, SUPPORTED_CAPABILITIES } from '../floe-print-host.js';
import { MESH_FIXTURES, writeBinarySTL } from '../fixtures/mesh-fixtures.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));          // EngineJS/node
const ENGINE_SRC = path.resolve(HERE, '../../../../ThirdParty/KiriMoto/src');
const FIXTURES = path.resolve(HERE, '../fixtures');
const OUT_BASE = process.argv[2] ? path.resolve(process.argv[2]) : null;

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const read = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));

function artifactWriter(baseDir) {
    fs.mkdirSync(baseDir, { recursive: true });
    return {
        baseDir,
        // staged write: tmp file -> size/hash verify -> rename
        commit(name, data) {
            const tmp = path.join(baseDir, name + '.tmp');
            const dst = path.join(baseDir, name);
            fs.writeFileSync(tmp, data);
            const buf = fs.readFileSync(tmp);
            if (buf.length !== Buffer.byteLength(data)) throw new Error('size mismatch on write-back');
            const hash = sha256(buf);
            fs.renameSync(tmp, dst);
            return { path: dst, bytes: buf.length, sha256: hash };
        },
    };
}

async function main() {
    if (!OUT_BASE) {
        console.error('usage: node run-slices.mjs <output-dir>');
        process.exit(2);
    }
    const started=performance.now();
    const writer = artifactWriter(OUT_BASE);
    const meta = { date: new Date().toISOString(), runtime: `node ${process.version}`, capabilities: SUPPORTED_CAPABILITIES };

    const wasmResolver = async (name) => {
        const p = path.join(ENGINE_SRC, 'wasm', name);
        const b=fs.readFileSync(p);return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength);
    };

    console.log('[1/4] loading engine host...');
    const host = await createPrintHost({ engineRoot: pathToFileURL(ENGINE_SRC+'/').href, wasmResolver });
    meta.engine = host.engine;
    console.log('      engine version:', host.engine.version);

    const fdmSettings=createSettings('fdm');
    const slaSettings=createSettings('sla');
    const fdmDevice=fdmSettings.device, slaDevice=slaSettings.device;
    meta.inputs = {
        fixtures: Object.fromEntries(Object.entries(MESH_FIXTURES).map(([k, f]) => [k, {
            description: f.description, bounds: f.bounds, volumeMM3: f.volumeMM3,
            sha256: sha256(Buffer.from(f.build().buffer)),
        }])),
        devices: { fdm: fdmDevice.deviceName, sla: slaDevice.deviceName },
    };

    // --- FDM: cube + two-solid plate ---
    const fdmResults = {};
    for (const key of ['cube20', 'plate-two-solids']) {
        console.log(`[2/4] FDM slicing ${key}...`);
        const t0 = Date.now();
        const r = await sliceFDM(host, {
            requestId: `fdm-${key}-001`,
            mesh: { positions: MESH_FIXTURES[key].build() },
            settings: fdmSettings,
            onProgress: (p) => { if (p.stage && p.value === 1) console.log(`      ${p.stage} done`); },
        });
        const wall = Date.now() - t0;
        const name = `fdm-${key}.gcode`;
        const art = writer.commit(name, Buffer.from(r.text, 'utf8'));
        fdmResults[key] = { ...art, lines: r.info.lines, milliseconds: wall };
        console.log(`      -> ${art.bytes} bytes, ${r.info.lines} lines, ${wall} ms`);
    }

    // --- SLA: cube -> CTB v3 ---
    console.log('[3/4] SLA slicing cube20 -> CTB v3...');
    const slaStarted=performance.now();
    const sla = await sliceSLA(host, {
        requestId: 'sla-cube20-001',
        mesh: { positions: MESH_FIXTURES.cube20.build() },
        settings: slaSettings,
        onProgress: (p) => { if (p.stage && p.value === 1) console.log(`      ${p.stage} done`); },
    });
    const slaArt = writer.commit('sla-cube20.ctb', Buffer.from(sla.file));
    console.log(`      -> ${slaArt.bytes} bytes, layers=${sla.info.layers}, volume=${sla.info.volume.toFixed(1)} mm3`);

    // --- fixture STLs for cross-checking ---
    for (const key of Object.keys(MESH_FIXTURES)) {
        const stl = writeBinarySTL(MESH_FIXTURES[key].build(), `FLOE ${key}`);
        writer.commit(`${key}.stl`, Buffer.from(stl));
    }

    meta.results = { fdm: fdmResults, sla: { ...slaArt, milliseconds: performance.now()-slaStarted, layers: sla.info.layers, volumeMM3: sla.info.volume, width: sla.info.width, height: sla.info.height } };
    meta.performance={totalMilliseconds:performance.now()-started,maxRSSKiB:process.resourceUsage().maxRSS,platform:process.platform,arch:process.arch};
    meta.source={hostSHA256:sha256(fs.readFileSync(path.join(HERE,'../floe-print-host.js'))),profilesSHA256:sha256(fs.readFileSync(path.join(HERE,'../profiles.js'))),vendorManifestSHA256:sha256(fs.readFileSync(path.join(ENGINE_SRC,'../PROVENANCE.json')))};
    fs.writeFileSync(path.join(OUT_BASE, 'run-report.json'), JSON.stringify(meta, null, 2));
    console.log('[4/4] artifacts written to', OUT_BASE);
}

main().then(() => process.exit(0)).catch((e) => { console.error('FAILED:', e); process.exit(1); });
