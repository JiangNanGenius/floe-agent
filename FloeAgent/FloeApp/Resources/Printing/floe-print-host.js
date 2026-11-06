/** Copyright (c) 2026 Floe Contributors — MPL-2.0
 *
 * floe-print-host.js — minimal offline host around the vendored Kiri:Moto
 * slicing subset (FloeAgent/ThirdParty/KiriMoto). Floe-authored adapter; the
 * slicing algorithms remain upstream Kiri:Moto (MIT), see ../UPSTREAM-LICENSE.md.
 *
 * Executed in Node (ESM); target WebKit binding remains mainline work.
 * Use a dedicated computation realm. No network access: the SLA WASM raster module is resolved through the caller-provided
 * local resolver.
 *
 * This host intentionally bypasses the upstream app/worker protocol and calls
 * the FDM/SLA driver stages (slice -> prepare -> export) directly with Floe
 * typed settings. Only Floe-owned, typed settings and Floe-owned G-code
 * templates are accepted; arbitrary imported template/script evaluation is not
 * part of this boundary.
 */
'use strict';
import {ownedProfiles} from './profiles.js';
const trustedSettings = new WeakSet();
const freezeTree=o=>{if(o && typeof o==='object'){Object.values(o).forEach(freezeTree);Object.freeze(o);}};
freezeTree(ownedProfiles);
let realmBusy=false;
const hostDetails=new WeakMap();
export const ADAPTER_VERSION='floe-print-p0-2';
export function createSettings(kind, overrides = {}) {
    if (!Object.hasOwn(ownedProfiles, kind)) throw new PrintHostError('E_KIND','unsupported kind');
    const limits = kind === 'fdm' ? {sliceHeight:[0.02,1],outputTemp:[100,450],outputBedTemp:[0,150],outputFeedrate:[1,500]} : {slaSlice:[0.005,0.5],slaLayerOn:[0.1,120],slaBaseOn:[0.1,600]};
    if (!overrides || typeof overrides !== 'object' || Array.isArray(overrides)) throw new PrintHostError('E_SETTINGS','overrides object required');
    const s=structuredClone(ownedProfiles[kind]);
    // Geometry fidelity is owned by this adapter, not an inherited profile default.
    // No silhouette rounding, solidification, automatic arc fitting or compensation.
    if (kind === 'fdm') {
        Object.assign(s.process,{fdmArcEnabled:false,sliceSolidify:false,sliceCompInner:0,sliceCompOuter:0});
    }
    s.filter={FDM:s.device.deviceName,SLA:s.device.deviceName};
    s.origin={x:0,y:0,z:0};s.widget={};
    for(const [key,value] of Object.entries(overrides)) {
        const range=limits[key];
        if(!Object.hasOwn(limits,key) || !range || typeof value !== 'number' || !Number.isFinite(value) || value < range[0] || value > range[1]) throw new PrintHostError('E_SETTING_RANGE','unsupported or invalid override: '+key);
        s.process[key]=value;
        if(key==='sliceHeight') s.process.firstSliceHeight=value;
    }
    const freeze=o=>{if(o && typeof o === 'object'){Object.values(o).forEach(freeze);Object.freeze(o);}};freeze(s);trustedSettings.add(s);return s;
}


/** Capabilities actually verified by this package (fail-closed). */
export const SUPPORTED_CAPABILITIES = Object.freeze({
    adapterVersion: ADAPTER_VERSION,
    engines: Object.freeze([{ id: 'kiri-moto', version: '4.7.3', commit: 'ff7692241c48c3495da0bb8eb7455f906f3abb2d' }]),
    meshInputs: Object.freeze(['triangle-soup-mm']),
    fdm: Object.freeze([{ artifact: 'gcode-text', extensions: ['gcode'] }]),
    sla: Object.freeze([{ artifact: 'resin-binary', format: 'ctb', formatVersion: 3, extension: 'ctb' }]),
    unsupported: Object.freeze([
        '3MF project roundtrip (geometry-only 3MF exists elsewhere)',
        'multicolor / multi-material / multi-toolhead output',
        'editable supports, hollowing, drainage, multi-plate',
        'sla formats other than CTB v3 (GOO/Photon/PW/encrypted CTB not enabled here)',
        'unknown devices / unknown format versions are rejected, never silently remapped',
    ]),
});

export class PrintHostError extends Error {
    constructor(code, message) { super(message); this.code = code; }
}

/** Validate a typed FDM/SLA settings bundle. Rejects hostile/unknown config. */
export function validateSettings(kind, settings) {
    if (!settings || typeof settings !== 'object') throw new PrintHostError('E_SETTINGS', 'settings object required');
    if (!trustedSettings.has(settings)) throw new PrintHostError('E_SETTINGS','use createSettings with owned profile and numeric overrides');
    const { device, process, controller } = settings;
    if (!device || !process) throw new PrintHostError('E_SETTINGS', 'device and process required');
    const num = (o, k, min, max) => {
        const v = o[k];
        if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max)
            throw new PrintHostError('E_SETTING_RANGE', `${k} out of range: ${v}`);
        return v;
    };
    if (kind === 'fdm') {
        if (process.fdmArcEnabled || process.sliceSolidify || process.sliceCompInner || process.sliceCompOuter)
            throw new PrintHostError('E_GEOMETRY_POLICY','owned profile must preserve model corners');
        if (!Array.isArray(device.extruders) || device.extruders.length !== 1)
            throw new PrintHostError('E_DEVICE', 'fdm device requires extruders[]');
        num(device, 'bedWidth', 1, 2000); num(device, 'bedDepth', 1, 2000); num(device, 'maxHeight', 1, 2000);
        num(device.extruders[0], 'extNozzle', 0.05, 5); num(device.extruders[0], 'extFilament', 0.5, 10);
        num(process, 'sliceHeight', 0.02, 1); num(process, 'outputTemp', 100, 450);
        num(process, 'outputBedTemp', 0, 150); num(process, 'outputFeedrate', 1, 500);
        if (device.bedBelt) throw new PrintHostError('E_DEVICE', 'belt printers not supported');
    } else if (kind === 'sla') {
        if ((device.slaFormat || 'ctb') !== 'ctb')
            throw new PrintHostError('E_FORMAT', `unsupported sla format: ${device.slaFormat}`);
        if (device.slaFormatVersion !== undefined && device.slaFormatVersion !== 3)
            throw new PrintHostError('E_FORMAT_VERSION', `unsupported ctb version: ${device.slaFormatVersion}`);
        num(device, 'resolutionX', 100, 16384); num(device, 'resolutionY', 100, 16384);
        num(device, 'bedWidth', 10, 2000); num(device, 'bedDepth', 10, 2000); num(device, 'maxHeight', 1, 2000);
        num(process, 'slaSlice', 0.005, 0.5); num(process, 'slaLayerOn', 0.1, 120);
        num(process, 'slaBaseOn', 0.1, 600); num(process, 'slaBaseLayers', 0, 1000);
    } else {
        throw new PrintHostError('E_KIND', `unknown kind: ${kind}`);
    }
    if (controller && typeof controller !== 'object') throw new PrintHostError('E_SETTINGS', 'controller must be object');
    return true;
}

/** Validate a typed triangle mesh (mm). */
export function validateMesh(mesh) {
    if (!mesh || !mesh.positions) throw new PrintHostError('E_MESH', 'mesh.positions required');
    const p = mesh.positions;
    if(p.length > 9_000_000) throw new PrintHostError('E_SIZE','mesh exceeds predevelopment limit');
    if (!(p instanceof Float32Array) && !(p instanceof Float64Array) && !Array.isArray(p))
        throw new PrintHostError('E_MESH', 'positions must be Float32Array-compatible');
    if (p.length < 9 || p.length % 9 !== 0) throw new PrintHostError('E_MESH', `positions length ${p.length} not a multiple of 9`);
    let bad = 0;
    for (let i = 0; i < p.length; i++) if (!Number.isFinite(p[i])) bad++;
    if(!p.some(v=>v!==0)) throw new PrintHostError('E_MESH','empty geometry');
    if (bad) throw new PrintHostError('E_MESH', `${bad} non-finite coordinates`);
    return p.length / 9;
}

/** Freeze a job-owned Float32 triangle soup before any asynchronous stage/callback.
 * Keep source positions unchanged; never normalize, weld, decimate or autoscale.
 * A Float64 feature that collapses during engine conversion is rejected explicitly.
 */
export function snapshotMesh(mesh) {
    validateMesh(mesh);
    const source=mesh.positions;
    if (ArrayBuffer.isView(source) && typeof SharedArrayBuffer !== 'undefined' && source.buffer instanceof SharedArrayBuffer)
        throw new PrintHostError('E_MESH_OWNERSHIP','shared mesh buffers require an immutable snapshot before slicing');
    const positions=new Float32Array(source);
    for (let i=0;i<positions.length;i++) {
        if (!Number.isFinite(positions[i]) || Math.abs(positions[i]-source[i])>0.00001)
            throw new PrintHostError('E_MESH_PRECISION','geometry cannot be represented within the engine coordinate precision');
    }
    const area=(p,i)=>{
        const ax=p[i+3]-p[i],ay=p[i+4]-p[i+1],az=p[i+5]-p[i+2];
        const bx=p[i+6]-p[i],by=p[i+7]-p[i+1],bz=p[i+8]-p[i+2];
        return Math.hypot(ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx);
    };
    if (!(source instanceof Float32Array)) {
        for (let i=0;i<positions.length;i+=9) {
            if (area(source,i)>1e-10 && area(positions,i)<=1e-10)
                throw new PrintHostError('E_MESH_PRECISION','a real mesh feature would collapse during coordinate conversion');
        }
    }
    return Object.freeze({positions});
}

function checkSignal(signal) {
    if (signal && signal.aborted) throw new PrintHostError('E_CANCELLED', 'cancelled by request owner');
}

/** Install minimal worker/browser shims required by the upstream modules. */
function installShims(wasmResolver) {
    const g = globalThis;
    if (!g.self) g.self = g;
    if (!g.self.kiri_api) g.self.kiri_api = {};          // app API stub, unused in slice path
    if (!g.self.kiri) g.self.kiri = {};
    if (!g.self.kiri_worker) g.self.kiri_worker = { current: {}, minions: { concurrent: 0 } };
    if (!g.self.navigator && !g.navigator) g.navigator = { userAgent: 'floe-print-host', hardwareConcurrency: 4 };
    if (!g.self.location) g.self.location = { hostname: 'local', port: 0, protocol: 'file' };
    // local-only fetch for the SLA wasm module; anything else is a hard failure
    g.self.fetch = g.fetch = async function (url, opts = {}) {
        const u = String(url);
        if (u !== '/wasm/kiri-sla.wasm') throw new PrintHostError('E_NETWORK', `refusing non-local fetch: ${u}`);
        const buf = await wasmResolver(u.substring('/wasm/'.length));
        return { arrayBuffer: async () => buf, ok: true };
    };
}

let hostSeq = 0;

/**
 * Create a slicing host over the vendored engine modules.
 * @param {object} o { engineRoot: string absolute-or-relative path/URL to KiriMoto/src,
 *                     wasmResolver: async (name) => ArrayBuffer }
 */
export async function createPrintHost(o) {
    if (!o || !o.engineRoot) throw new PrintHostError('E_HOST', 'engineRoot required');
    if (typeof o.wasmResolver !== 'function') throw new PrintHostError('E_HOST', 'wasmResolver required');
    if(realmBusy) throw new PrintHostError('E_BUSY','engine is slicing');
    if(!/^(file:|floe-print:)/.test(o.engineRoot)) throw new PrintHostError('E_HOST','local engine URL required');
    installShims(o.wasmResolver);
    const root = o.engineRoot;
    const imp = (p) => import(new URL(p, root.endsWith('/') ? root : root + '/').href);
    await imp('add/class.js');
    await imp('add/three.js');
    await imp('kiri/core/codec.js');
    const {polygons:poly}=await imp('geo/polygons.js');
    Object.assign(self.kiri_worker.minions, {
      subtract: async ({a,b,outA,outB,z,area,wasm}) => {poly.subtract(a,b,outA,outB,z,area,{wasm});},
      union: async (polys,minarea) => poly.union(polys,minarea,true),
      fill: async (polys,angle,spacing,output,minLen,maxLen) => poly.fillArea(polys,angle,spacing,[],minLen,maxLen)
    });
    const [license, widgetMod, fdmWork, slaWork, slaFormats] = await Promise.all([
        imp('moto/license.js'), imp('kiri/core/widget.js'),
        imp('kiri/mode/fdm/work/init-work.js'), imp('kiri/mode/sla/work/init-work.js'),
        imp('kiri/mode/sla/core/formats.js'),
    ]);
    const { FDM } = fdmWork, { SLA } = slaWork;
    if (!FDM.slice || !FDM.prepare || !FDM.export) throw new PrintHostError('E_HOST', 'FDM driver incomplete');
    if (!SLA.slice || !SLA.prepare || !SLA.export) throw new PrintHostError('E_HOST', 'SLA driver incomplete');
    const host=Object.freeze({id:`host-${Date.now().toString(36)}-${hostSeq++}`, engine:Object.freeze({id:'kiri-moto',version:license.version,pin:'ff7692241c48c3495da0bb8eb7455f906f3abb2d'})});
    const widgets=new Set();
    hostDetails.set(host,{
        newWidget:(id,group)=>{const w=widgetMod.newWidget(id,group);widgets.add(w);return w;},FDM,SLA,slaFormats,
        ownedCount:()=>widgets.size,
        cleanup:()=>{
            self.kiri_worker.current.print?.disposeSafeEval?.();
            for(const w of widgets){w.mesh?.geometry?.dispose();widgetMod.Widget.Groups.remove(w);w.slices=undefined;}
            widgets.clear();self.kiri_worker.current.print=undefined;
        }
    });
    return host;
}

function driveStage(fn, args, onProgress, signal) {
    return new Promise((resolve, reject) => {
        try {
            fn(...args, (update, msg) => {
                checkSignal(signal);
                if (onProgress) onProgress(update, msg);
            }, (err) => err ? reject(err instanceof Error ? err : new PrintHostError('E_STAGE', String(err))) : resolve());
        } catch (e) { reject(e); }
    });
}

/**
 * Slice an FDM job. Returns { requestId, text, info }.
 * job: { requestId, mesh:{positions}, settings:{device,process,controller}, onProgress, signal }
 */
async function sliceFDMInternal(host, job) {
    const { requestId, mesh, onProgress, signal } = job;
    const supplied = job.settings;
    const settings = structuredClone(supplied);
    if (!requestId) throw new PrintHostError('E_REQUEST', 'requestId required');
    validateSettings('fdm', supplied);
    const tris = validateMesh(mesh);
    checkSignal(signal);

    const group = []; group.id = `g-${requestId}`;
    const widget = host.newWidget(`w-${requestId}`, group);
    widget.settings = settings;
    widget.track.pos = {x:0,y:0,z:0};
    widget.loadVertices(mesh.positions,{normalize:false,autoscale:false});

    checkSignal(signal);
    await driveStage(host.FDM.slice, [settings, widget], (u, m) => onProgress && onProgress({ stage: 'slice', value: u, message: m }), signal);
    checkSignal(signal);
    await host.FDM.prepare([widget], settings, (u,m) => {checkSignal(signal);onProgress?.({stage:'prepare',value:u,message:m});});
    checkSignal(signal);

    const print = globalThis.self.kiri_worker.current.print;
    if (!print) throw new PrintHostError('E_HOST', 'prepare did not produce a print');
    await print.ready();
    const chunks = [];
    let outputBytes=0;
    let lines = 0;
    host.FDM.export(print, (segment) => {
        checkSignal(signal);
        if (typeof segment === 'string') { outputBytes+=new TextEncoder().encode(segment).length; if(outputBytes>64*1024*1024) throw new PrintHostError('E_SIZE','G-code output exceeds limit');chunks.push(segment); lines += segment.split('\n').length; }
    });
    checkSignal(signal);
    const text = chunks.join('\r\n');
    if (!text || text.length < 100) throw new PrintHostError('E_OUTPUT', 'empty g-code output');
    return { requestId, kind: 'fdm', text, info: { triangles: tris, lines, bytes: text.length, widgetStats: widget.stats } };
}

/**
 * Slice an SLA job into a CTB v3 binary. Returns { requestId, file, info }.
 */
async function sliceSLAInternal(host, job) {
    const { requestId, mesh, onProgress, signal } = job;
    const supplied = job.settings;
    const settings = structuredClone(supplied);
    if (!requestId) throw new PrintHostError('E_REQUEST', 'requestId required');
    validateSettings('sla', supplied);
    const tris = validateMesh(mesh);
    const fmt = host.slaFormats.getSLAFormatRecord(settings.device);
    if (!fmt || !fmt.available || fmt.id !== 'ctb') throw new PrintHostError('E_FORMAT', `ctb unavailable for device: ${JSON.stringify(fmt)}`);
    checkSignal(signal);

    const group = []; group.id = `g-${requestId}`;
    const widget = host.newWidget(`w-${requestId}`, group);
    widget.settings = settings;
    widget.track.pos = {x:0,y:0,z:0};
    widget.loadVertices(mesh.positions,{normalize:false,autoscale:false});

    checkSignal(signal);
    await driveStage(host.SLA.slice, [settings, widget], (u, m) => onProgress && onProgress({ stage: 'slice', value: u, message: m }), signal);
    checkSignal(signal);
    await host.SLA.prepare([widget], settings, (u, m) => onProgress && onProgress({ stage: 'prepare', value: u, message: m }));
    checkSignal(signal);

    const print = globalThis.self.kiri_worker.current.print;
    if (!print) throw new PrintHostError('E_HOST', 'prepare did not produce a print');
    await print.ready();
    const out = await new Promise((resolve, reject) => {
        const r = host.SLA.export(print, () => {}, (done, transfer) => resolve({ done, transfer }), (dbg) => { if (job.onDebug) job.onDebug(dbg); });
        if (r && r.then) r.then(resolve, reject);
    });
    checkSignal(signal);
    const file = out && out.done && out.done.file;
    if (!(file instanceof ArrayBuffer) || file.byteLength < 256 || file.byteLength > 128*1024*1024) throw new PrintHostError('E_OUTPUT', 'invalid ctb output');
    return {
        requestId, kind: 'sla', file,
        info: {
            triangles: tris, bytes: file.byteLength,
            width: out.done.width, height: out.done.height,
            layers: out.done.layers, volume: out.done.volume,
        },
    };
}

async function sliceOwned(host, job, kind, run) {
    if(realmBusy) throw new PrintHostError('E_BUSY','one slice per compute realm');
    if(!job || typeof job.requestId!=='string' || !job.requestId || job.requestId.length>128) throw new PrintHostError('E_REQUEST','stable request identity required');
    validateSettings(kind,job.settings);validateMesh(job.mesh);checkSignal(job.signal);
    const mesh=snapshotMesh(job.mesh);
    const {bedWidth,bedDepth,maxHeight}=job.settings.device;
    // Check both original and engine coordinates, so rounding cannot admit an
    // originally out-of-bed input or move an accepted point beyond the bed.
    for (const p of [job.mesh.positions,mesh.positions]) {
        for (let i=0;i<p.length;i+=3) if(Math.abs(p[i])>bedWidth/2 || Math.abs(p[i+1])>bedDepth/2 || p[i+2]<0 || p[i+2]>maxHeight)
            throw new PrintHostError('E_BOUNDS','mesh lies outside the selected bed');
    }
    const p=mesh.positions;
    let solid=false;
    for(let i=0;i<p.length;i+=9) {
        for(let j=i;j<i+9;j+=3) if(Math.abs(p[j])>bedWidth/2 || Math.abs(p[j+1])>bedDepth/2 || p[j+2]<0 || p[j+2]>maxHeight) throw new PrintHostError('E_BOUNDS','mesh lies outside the selected bed');
        const ax=p[i+3]-p[i],ay=p[i+4]-p[i+1],az=p[i+5]-p[i+2],bx=p[i+6]-p[i],by=p[i+7]-p[i+1],bz=p[i+8]-p[i+2];
        if(Math.hypot(ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx)>1e-10) solid=true;
    }
    if(!solid) throw new PrintHostError('E_MESH','all triangles are degenerate');
    const internal=hostDetails.get(host);
    if(!internal) throw new PrintHostError('E_HOST','unknown host');
    realmBusy=true;
    const ownedJob={...job,mesh};
    try {const result=await run(internal,ownedJob);checkSignal(ownedJob.signal);return result;}
    finally {try{internal.cleanup();}finally{realmBusy=false;}}
}
export const sliceFDM=(host,job)=>sliceOwned(host,job,'fdm',sliceFDMInternal);
export const sliceSLA=(host,job)=>sliceOwned(host,job,'sla',sliceSLAInternal);

export function hostDiagnostics(host) {const h=hostDetails.get(host);if(!h)throw new PrintHostError("E_HOST","unknown host");return {busy:realmBusy,ownedWidgets:h.ownedCount()};}
