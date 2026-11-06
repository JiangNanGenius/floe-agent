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
 * scripts are plain text with fixed literal substitutions; no user text reaches
 * the upstream expression evaluator or general JavaScript runtime.
 */
'use strict';
import {ownedProfiles} from './profiles.js';
const trustedSettings = new WeakSet();
const freezeTree=o=>{if(o && typeof o==='object'){Object.values(o).forEach(freezeTree);Object.freeze(o);}};
freezeTree(ownedProfiles);
let realmBusy=false;
const hostDetails=new WeakMap();
export const ADAPTER_VERSION='floe-print-app-4';
export function createSettings(kind, overrides = {}, machine = null) {
    if (!Object.hasOwn(ownedProfiles, kind)) throw new PrintHostError('E_KIND','unsupported kind');
    const limits = kind === 'fdm' ? {sliceHeight:[0.02,1],outputTemp:[100,450],outputBedTemp:[0,150],outputFeedrate:[1,500],sliceFillSparse:[0,1],sliceShells:[0,20],sliceTopLayers:[0,30],sliceBottomLayers:[0,30],sliceSupportEnable:[0,1],sliceSupportDensity:[0.01,1],sliceSupportAngle:[0,90]} : {slaSlice:[0.005,0.5],slaLayerOn:[0.1,120],slaBaseOn:[0.1,600],slaShell:[0,20],slaSupportEnable:[0,1],slaSupportDensity:[0.01,1],slaSupportSize:[0.1,5],slaSupportLayers:[0,100]};
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
        if(['sliceShells','sliceTopLayers','sliceBottomLayers','slaSupportLayers','sliceSupportEnable','slaSupportEnable'].includes(key) && !Number.isInteger(value)) throw new PrintHostError('E_SETTING_RANGE','integer override required: '+key);
        s.process[key]=value;
        if(key==='sliceSupportEnable') { s.process.sliceSupportEnable=!!value;s.process.sliceSupportType=value?'auto':'disabled'; }
        if(key==='slaSupportEnable') s.process.slaSupportEnable=!!value;
        if(key==='sliceHeight') s.process.firstSliceHeight=value;
    }
    if (machine) configureMachine(s, kind, machine);
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
        'painted supports / drainage (automatic supports and per-plate slicing are available)',
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
    const rawText = chunks.join('\r\n');
    const text = settings.floe ? machineGCode(rawText, settings) : rawText;
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
    let outputMesh=mesh;
    if(kind==='sla' && job.settings.floe) {
        const r=job.settings.floe.resin, a=r.rotationDegrees*Math.PI/180, positions=new Float32Array(mesh.positions);
        let top=0;for(let i=2;i<positions.length;i+=3)top=Math.max(top,positions[i]);
        for(let i=0;i<positions.length;i+=3){
            let x=positions[i]*(r.mirrorX?-1:1),y=positions[i+1]*(r.mirrorY?-1:1);
            positions[i]=Math.round((x*Math.cos(a)-y*Math.sin(a))*1e6)/1e6;
            positions[i+1]=Math.round((x*Math.sin(a)+y*Math.cos(a))*1e6)/1e6;
            if(r.buildDirection==='towardPlatform')positions[i+2]=top-positions[i+2];
            if(Math.abs(positions[i])>bedWidth/2 || Math.abs(positions[i+1])>bedDepth/2)throw new PrintHostError('E_BOUNDS','oriented resin layout lies outside the bed');
        }
        outputMesh=Object.freeze({positions});
    }
    const ownedJob={...job,mesh:outputMesh};
    try {const result=await run(internal,ownedJob);checkSignal(ownedJob.signal);return result;}
    finally {try{internal.cleanup();}finally{realmBusy=false;}}
}
export const sliceFDM=(host,job)=>sliceOwned(host,job,'fdm',sliceFDMInternal);
export const sliceSLA=(host,job)=>sliceOwned(host,job,'sla',sliceSLAInternal);

export function hostDiagnostics(host) {const h=hostDetails.get(host);if(!h)throw new PrintHostError("E_HOST","unknown host");return {busy:realmBusy,ownedWidgets:h.ownedCount()};}


function configureMachine(settings, kind, supplied) {
    const m=structuredClone(supplied),d=settings.device,p=settings.process;
    const number=(v,min,max)=>typeof v==='number'&&Number.isFinite(v)&&v>=min&&v<=max;
    if(!m || !number(m.bedWidth,1,2000)||!number(m.bedDepth,1,2000)||!number(m.buildHeight,1,2000)||!['cartesian','i3','coreXY','delta','scara'].includes(m.kinematics)||!['frontLeft','center','rearLeft','custom'].includes(m.origin))throw new PrintHostError('E_MACHINE','invalid machine configuration');
    for(const key of ['originX','originY','originZ','headOffsetX','headOffsetY','headOffsetZ'])if(!number(m[key],-10000,10000))throw new PrintHostError('E_MACHINE','invalid machine offset');
    if(!Array.isArray(m.tools)||m.tools.length<1||m.tools.length>16)throw new PrintHostError('E_MACHINE','tool configuration required');
    const ids=new Set();
    for(const t of m.tools){
        if(!Number.isInteger(t.id)||t.id<0||t.id>15||ids.has(t.id)||!number(t.nozzleDiameter,.05,5)||!number(t.filamentDiameter,.5,10)||!['offsetX','offsetY','offsetZ'].every(k=>number(t[k],-1000,1000)))throw new PrintHostError('E_MACHINE','invalid tool configuration');ids.add(t.id);
    }
    const tool=m.tools.find(t=>t.id===m.selectedTool);if(!tool)throw new PrintHostError('E_MACHINE','selected tool unavailable');
    Object.assign(d,{bedWidth:m.bedWidth,bedDepth:m.bedDepth,maxHeight:m.buildHeight});
    if(kind==='fdm'){
        const vocabulary=new Set(['nozzle_temperature','bed_temperature','tool','layer','layer_z','bed_width','bed_depth']);
        if(!m.scripts||!['start','end','toolChange','beforeLayer','afterLayer','pause'].every(k=>{
            const b=m.scripts[k];return typeof b==='string'&&b.length<=32768&&!/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(b)&&Array.from(b.matchAll(/\{([^}]*)\}/g)).every(x=>vocabulary.has(x[1]))&&!b.replace(/\{[^}]*\}/g,'').includes('{');
        }))throw new PrintHostError('E_SCRIPT','invalid plain G-code block');
        // Upstream sees owned markers and fixed machine modes only, never custom expressions.
        d.gcodePre=[';FLOE_START','G21','G90','M82','G92 E0'];d.gcodePost=[';FLOE_END'];
        d.gcodeLayer=[';FLOE_LAYER {layer} {z}'];d.gcodeChange=[];
        Object.assign(d.extruders[0],{extNozzle:tool.nozzleDiameter,extFilament:tool.filamentDiameter,extOffsetX:0,extOffsetY:0,extSelect:[],extDeselect:[]});
    }else{
        const r=m.resin;
        if(!r||!Number.isInteger(r.resolutionX)||!Number.isInteger(r.resolutionY)||!number(r.resolutionX,100,8192)||!number(r.resolutionY,100,8192)||r.resolutionX*r.resolutionY>16777216||![0,90,180,270].includes(r.rotationDegrees)||!['awayFromPlatform','towardPlatform'].includes(r.buildDirection))throw new PrintHostError('E_MACHINE','invalid resin configuration');
        for(const k of ['liftDistance','bottomLiftDistance'])if(!number(r[k],0,100))throw new PrintHostError('E_MACHINE','invalid lift distance');
        for(const k of ['liftSpeed','retractSpeed'])if(!number(r[k],.01,100))throw new PrintHostError('E_MACHINE','invalid lift speed');
        if(!Number.isInteger(r.bottomLayers)||!number(r.bottomLayers,0,1000)||!number(r.lightOffSeconds,0,120))throw new PrintHostError('E_MACHINE','invalid resin exposure');
        Object.assign(d,{resolutionX:r.resolutionX,resolutionY:r.resolutionY});
        Object.assign(p,{slaPeelDist:r.liftDistance,slaBasePeelDist:r.bottomLiftDistance,slaPeelLiftRate:r.liftSpeed,slaBasePeelLiftRate:r.liftSpeed,slaPeelDropRate:r.retractSpeed,slaBaseLayers:r.bottomLayers,slaLayerOff:r.lightOffSeconds,slaBaseOff:r.lightOffSeconds});
    }
    settings.floe=m;
}

/** Apply origin/carriage/tool translation once. Firmware owns CoreXY/i3 motor mixing. */
export function machineGCode(text, settings) {
    const m=settings.floe,t=m.tools.find(t=>t.id===m.selectedTool),p=settings.process;
    const offset=[(m.origin==='frontLeft'||m.origin==='rearLeft'?m.bedWidth/2:0)+m.originX+m.headOffsetX-t.offsetX,
        (m.origin==='frontLeft'?m.bedDepth/2:m.origin==='rearLeft'?-m.bedDepth/2:0)+m.originY+m.headOffsetY-t.offsetY,m.originZ+m.headOffsetZ-t.offsetZ];
    const shift=[offset[0]-m.bedWidth/2,offset[1]-m.bedDepth/2,offset[2]];
    let layer=0,z=0,seenLayer=false;
    const render=block=>block.replace(/\{([^}]*)\}/g,(_,key)=>String({nozzle_temperature:p.outputTemp,bed_temperature:p.outputBedTemp,tool:m.selectedTool,layer,layer_z:z,bed_width:m.bedWidth,bed_depth:m.bedDepth}[key]));
    const lines=[`; Floe Cartesian coordinates; kinematics=${m.kinematics}; tool=${m.selectedTool}`];
    for(const raw of text.split(/\r?\n/)){
        if(raw.trim()===';FLOE_START'){lines.push(render(m.scripts.start),render(m.scripts.toolChange));continue;}
        if(raw.trim()===';FLOE_END'){if(seenLayer)lines.push(render(m.scripts.afterLayer));lines.push(render(m.scripts.end));continue;}
        const marker=raw.match(/^;FLOE_LAYER\s+(\d+)\s+([-\d.]+)/);
        if(marker){if(seenLayer)lines.push(render(m.scripts.afterLayer));layer=Number(marker[1]);z=Number(marker[2]);seenLayer=true;lines.push(`;; --- layer ${layer} ---`,render(m.scripts.beforeLayer));if(m.pauseLayers?.includes(layer))lines.push(render(m.scripts.pause));continue;}
        let line=raw;
        if(/^G(?:0?0|0?1|92)\s/.test(line)){
            const parts=line.split(';');parts[0]=parts[0].replace(/\b([XYZ])(-?(?:\d+\.?\d*|\.\d+))/g,(_,axis,value)=>axis+Number((Number(value)+shift['XYZ'.indexOf(axis)]).toFixed(5)));line=parts.join(';');
        }
        lines.push(line);
    }
    return lines.join('\n');
}
