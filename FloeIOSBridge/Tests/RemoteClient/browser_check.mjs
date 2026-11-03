#!/usr/bin/env node
/*
 * Focused real-browser check for Resources/BridgeRemote/REMOTE.html.
 *
 * Runs against the synthetic mock_bridge.py. It drives Edge through the
 * DevTools protocol, performs real pointer/text input, and asserts observed
 * DOM + mock-service state. This is not a regex/HTML inspection.
 */
const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const cdpPort = Number(args.get('--cdp'));
const base = args.get('--base');
const mockBase = args.get('--mock') || base;
const label = args.get('--label') || 'browser';
if (!cdpPort || !base) {
  console.error('usage: browser_check.mjs --cdp PORT --base URL [--label NAME]');
  process.exit(2);
}

let ws;
let seq = 0;
const pending = new Map();
const consoleEvents = [];
const networkEvents = [];
const failures = [];
const notes = [];

function check(condition, message) {
  if (!condition) {
    failures.push(message);
    console.error('FAIL ' + message);
  } else {
    console.log('PASS ' + message);
  }
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function connect() {
  const targets = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  if (!page) throw new Error('no page target');
  ws = new WebSocket(page.webSocketDebuggerUrl);
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    } else if (message.method === 'Runtime.consoleAPICalled' || message.method === 'Log.entryAdded' ||
               message.method === 'Runtime.exceptionThrown') {
      consoleEvents.push(message);
    } else if (message.method === 'Network.requestWillBeSent') {
      networkEvents.push(message.params.request.url);
    }
  };
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  await send('Runtime.enable');
  await send('Log.enable');
  await send('Page.enable');
  await send('Network.enable');
}
function send(method, params = {}) {
  return new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true
  });
  if (result.result && result.result.exceptionDetails) {
    throw new Error('evaluate exception: ' + JSON.stringify(result.result.exceptionDetails).slice(0, 800));
  }
  if (!result.result || !result.result.result) return undefined;
  return result.result.result.value;
}
async function waitFor(expression, timeout = 12000, interval = 100) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      if (await evaluate(expression)) return true;
    } catch (_) {}
    await sleep(interval);
  }
  return false;
}
async function navigate(url) {
  await send('Page.navigate', { url });
  const ready = await waitFor('document.readyState === "complete"', 15000);
  check(ready, 'page loaded: ' + url);
  await sleep(600);
}
async function click(selector) {
  const ok = await evaluate(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return false; e.click(); return true; })()`);
  check(ok, 'click ' + selector);
  return ok;
}
async function rect(selector) {
  return await evaluate(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return null; const r = e.getBoundingClientRect(); return {left:r.left,top:r.top,width:r.width,height:r.height}; })()`);
}
async function mouseTap(x, y) {
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
}
async function mouseDrag(x1, y1, x2, y2) {
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x1, y: y1, button: 'none', buttons: 0 });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: x1, y: y1, button: 'left', buttons: 1, clickCount: 1 });
  for (let i = 1; i <= 8; i++) {
    const x = x1 + (x2 - x1) * i / 8;
    const y = y1 + (y2 - y1) * i / 8;
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'left', buttons: 1 });
    await sleep(12);
  }
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x2, y: y2, button: 'left', buttons: 0, clickCount: 1 });
}
async function mockState() {
  return await (await fetch(mockBase + '/__test/state')).json();
}
async function setMode(value) {
  const response = await fetch(mockBase + '/__test/mode', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(value)
  });
  if (!response.ok) throw new Error('mock mode failed: ' + response.status);
}
async function resetMock() {
  await fetch(mockBase + '/__test/reset', { method: 'POST' });
}
function calls(state, method) {
  return (state.calls || []).filter((c) => c.method === method);
}
function near(a, b, tolerance) { return Math.abs(a - b) <= tolerance; }

async function main() {
  await connect();
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await navigate(base + '/remote');
  await evaluate('window.scrollTo(0, 0)');
  if (await evaluate('document.documentElement.lang === "zh-CN"')) {
    await click('#langBtn');
    await sleep(250);
  }
  check(await evaluate('document.documentElement.lang === "en"'), 'language is English for the deterministic UI checks');
  check(await evaluate('document.title === "Floe Bridge Remote"'), 'title is Floe Bridge Remote');
  await click('#langBtn');
  await sleep(200);
  check(await evaluate('document.documentElement.lang === "zh-CN" && document.getElementById("stageTitle").textContent === "设备屏幕"'), 'Simplified Chinese labels are applied');
  await click('#langBtn');
  await sleep(200);
  check(await evaluate('document.documentElement.lang === "en" && document.getElementById("stageTitle").textContent === "Device screen"'), 'English labels are restored');
  check(await evaluate('document.documentElement.lang === "en" || document.documentElement.lang === "zh-CN"'), 'language is declared');
  check(await evaluate('!!document.querySelector(".brand-icon") && document.querySelector(".brand-icon").src.startsWith("data:image/png;base64,")'), 'retained Floe icon is embedded as data URI');
  check(await evaluate('document.styleSheets.length === 1'), 'one inline stylesheet is active under CSP');
  check(await evaluate('document.scripts.length === 2'), 'two inline scripts are active under CSP');
  const secure = await evaluate('window.isSecureContext');
  const subtle = await evaluate('!!(window.crypto && window.crypto.subtle)');
  notes.push('secureContext=' + secure + ' subtle=' + subtle);
  if (!secure) check(subtle === false, 'non-secure origin really exercises the JS crypto fallback (crypto.subtle absent)');

  // Service/schema loaded without authentication.
  const serviceReady = await waitFor('document.getElementById("statusText").textContent.length > 0 && !document.getElementById("statusText").textContent.includes("Starting")', 8000);
  check(serviceReady, 'service status replaced the starting state');
  check(await evaluate('document.getElementById("serviceLine").textContent.includes("Floe Bridge")'), 'service line names Floe Bridge');
  check(await evaluate('!document.getElementById("pairBtn").hidden'), 'pair action is visible before pairing');

  // Pair with explicit Remember, owner approval is simulated by the fixture.
  await evaluate('document.getElementById("rememberKey").checked = true');
  await click('#pairBtn');
  const paired = await waitFor('document.getElementById("statusText").textContent.includes("Connected") || document.getElementById("connectNotice").textContent.includes("Connected")', 15000);
  check(paired, 'pair + connect reached a connected state');
  const stateAfterPair = await mockState();
  check((stateAfterPair.pair_requests || []).length >= 1, 'mock owner saw the pairing request');
  check(await evaluate('document.getElementById("keyInput").value === ""'), 'pairing key is not left in the DOM input');
  check(await evaluate('localStorage.getItem("floe.bridge.v1.key") && /^[0-9a-f]{64}$/.test(localStorage.getItem("floe.bridge.v1.key"))'), 'explicit Remember stores the key under this origin');
  check(await evaluate('!document.getElementById("deviceCard").hidden && document.getElementById("deviceKv").textContent.includes("Floe Test iPhone")'), 'real device_info fields are rendered');
  check(await evaluate('document.getElementById("deviceKv").textContent.includes("390×844")'), 'point geometry is rendered');

  // Saved-key reconnect: reload, then connect without a new pairing.
  const pairRequestsBeforeReload = (await mockState()).pair_requests.length;
  await send('Page.reload', { ignoreCache: true });
  await waitFor('document.readyState === "complete"', 15000);
  await sleep(800);
  const reconnectReady = await waitFor('!document.getElementById("connectBtn").hidden && !document.getElementById("connectBtn").disabled', 10000);
  check(reconnectReady, 'saved key enables Connect after reload');
  await click('#connectBtn');
  const reconnected = await waitFor('document.getElementById("statusText").textContent.includes("Connected") || document.getElementById("connectNotice").textContent.includes("Connected")', 15000);
  check(reconnected, 'saved key reconnects without a new owner prompt');
  check((await mockState()).pair_requests.length === pairRequestsBeforeReload, 'reload did not create another pairing request');
  check(await evaluate('document.getElementById("keyInput").value === ""'), 'saved key is not exposed in the input after reload');

  // Screenshot display.
  const shotReady = await waitFor('!document.getElementById("shot").hidden && document.getElementById("shot").naturalWidth === 780', 25000);
  check(shotReady, 'real screenshot bitmap is displayed');
  check(await evaluate('getComputedStyle(document.getElementById("shot")).objectFit === "contain"'), 'screenshot uses contained geometry');

  // Tap at 50%/50% of the visible image.
  const shotRect = await rect('#shot');
  const tapX = shotRect.left + shotRect.width / 2;
  const tapY = shotRect.top + shotRect.height / 2;
  const beforeTap = (await mockState()).calls.length;
  await mouseTap(tapX, tapY);
  await sleep(900);
  const afterTap = await mockState();
  await sleep(900);
  const tapCalls = calls(afterTap, 'tap');
  check(tapCalls.length === 1, 'one pointer tap produced exactly one tap RPC');
  if (tapCalls.length) {
    notes.push('tap=' + JSON.stringify(tapCalls[0].params));
    check(near(tapCalls[0].params.x, 195, 3) && near(tapCalls[0].params.y, 422, 3),
      'tap coordinates map through the real 390x844 point space');
    check(!!tapCalls[0].operation_id, 'tap carries a single-intent operation id');
  }

  // Drag from 25% to 75% horizontally.
  // Use the displayed image box, not the element box: object-fit: contain
  // letterboxes when the stage's max-height wins. The page must map through
  // that box; the test drags inside it so it exercises real mapping.
  const imageBox = await evaluate('(() => { const img=document.getElementById("shot"); const r=img.getBoundingClientRect(); const s=Math.min(r.width/img.naturalWidth, r.height/img.naturalHeight); const w=img.naturalWidth*s, h=img.naturalHeight*s; return {left:r.left+(r.width-w)/2, top:r.top+(r.height-h)/2, width:w, height:h}; })()');
  notes.push('imageBox=' + JSON.stringify(imageBox));
  const beforeDrag = (await mockState()).calls.length;
  await mouseDrag(imageBox.left + imageBox.width * 0.25, imageBox.top + imageBox.height * 0.55,
                  imageBox.left + imageBox.width * 0.75, imageBox.top + imageBox.height * 0.55);
  await sleep(1200);
  const afterDrag = await mockState();
  const dragCalls = calls(afterDrag, 'drag');
  check(dragCalls.length === 1, 'one pointer drag produced exactly one drag RPC');
  if (dragCalls.length) {
    const p = dragCalls[0].params;
    notes.push('drag=' + JSON.stringify(p));
    check(near(p.from_x, 97.5, 8) && near(p.to_x, 292.5, 8) && near(p.from_y, 464, 12) && near(p.to_y, 464, 12),
      'drag endpoints map through the real image geometry');
  } else {
    notes.push('dragCalls=' + JSON.stringify(afterDrag.calls.map(c => c.method)));
  }

  // OCR labels are rendered as text, never HTML.
  await click('#ocrBtn');
  const ocrReady = await waitFor('document.querySelectorAll("#ocrList .list-row").length >= 3', 15000);
  check(ocrReady, 'OCR items are rendered from the device response');
  check(await evaluate('document.querySelectorAll("#ocrList script, #ocrList img").length === 0'), 'OCR labels are not injected as HTML');
  check(await evaluate('document.getElementById("ocrList").textContent.includes("<script>alert(1)</script>")'), 'untrusted OCR label remains literal text');
  const beforeOcrTap = (await mockState()).calls.length;
  await click('#ocrList .list-row');
  await sleep(900);
  check((await mockState()).calls.filter((c) => c.method === 'tap').length >= 2, 'OCR row tap sends an explicit tap RPC');

  // Text is UTF-8, dispatched once, then cleared from the DOM.
  const text = 'Hello 世界 & <b>not html</b>';
  await evaluate('document.getElementById("textInput").focus()');
  await send('Input.insertText', { text });
  check(await evaluate('document.getElementById("textInput").value === ' + JSON.stringify(text)), 'textarea received the UTF-8 text');
  const beforeType = (await mockState()).calls.length;
  await click('#sendTextBtn');
  await sleep(1200);
  const typeCalls = calls(await mockState(), 'type');
  check(typeCalls.length === 1, 'one send produced exactly one type RPC');
  if (typeCalls.length) check(typeCalls[0].params.text === text, 'type preserved the exact UTF-8 text');
  check(await evaluate('document.getElementById("textInput").value === ""'), 'textarea is cleared after dispatch');
  check(await evaluate('!Object.values(localStorage).some((v) => String(v).includes("世界"))'), 'typed text was not written to localStorage');

  // Live view: mint a new single-use ticket, stop, then mint a different one.
  const canLive = await evaluate('!document.getElementById("liveBtn").hidden');
  check(canLive, 'live view action is advertised');
  if (canLive) {
    await click('#liveBtn');
    const liveReady = await waitFor('!document.getElementById("video").hidden && document.getElementById("video").videoWidth > 0', 25000);
    check(liveReady, 'live fMP4 view decoded in the browser');
    let state = await mockState();
    check((state.tickets || []).length === 1, 'first live view minted exactly one ticket');
    check((state.stream_requests || []).length === 1, 'first live view consumed one stream request');
    const firstTicket = state.tickets[0] && state.tickets[0].ticket;
    await click('#liveBtn');
    await sleep(700);
    check(await evaluate('document.getElementById("video").hidden'), 'stop hides the live video');
    await click('#liveBtn');
    const liveAgain = await waitFor('!document.getElementById("video").hidden && document.getElementById("video").videoWidth > 0', 25000);
    check(liveAgain, 'second live view decodes after a fresh start');
    state = await mockState();
    check((state.tickets || []).length === 2, 'second live view minted a new ticket');
    const tickets = state.tickets || [];
    check(tickets.length === 2 && tickets[0].ticket !== tickets[1].ticket, 'tickets are distinct and never reused');
    check(tickets.every((t) => t.used === true), 'both consumed tickets are marked used');
    await click('#liveBtn');
    await sleep(500);
  }

  // Unknown outcome: exactly one dispatch, no automatic replay.
  await setMode({ unknown_methods: ['tap'] });
  const beforeUnknown = (await mockState()).calls.filter((c) => c.method === 'tap').length;
  await sleep(900);
  const shotRect2 = await rect('#shot');
  await mouseTap(shotRect2.left + shotRect2.width / 2, shotRect2.top + shotRect2.height / 2);
  await sleep(1200);
  const unknownState = await mockState();
  const unknownTaps = unknownState.calls.filter((c) => c.method === 'tap').length;
  check(unknownTaps === beforeUnknown + 1, 'unknown tap was dispatched exactly once');
  check(await evaluate('document.getElementById("actionNotice").textContent.includes("Outcome unknown") || document.getElementById("statusText").textContent.includes("unknown")'), 'unknown outcome is shown honestly');
  await setMode({ unknown_methods: [] });

  // Engine-not-ready is distinct from an auth failure.
  await setMode({ engine: 'not_ready' });
  await click('#refreshBtn');
  await sleep(1200);
  check(await evaluate('document.getElementById("engineNotice").textContent.toLowerCase().includes("engine") || document.getElementById("statusText").textContent.toLowerCase().includes("engine")'), 'engine_not_ready is reported separately');
  check(await evaluate('!document.getElementById("statusText").textContent.toLowerCase().includes("pair")'), 'engine_not_ready does not claim the key was rejected');
  await setMode({ engine: 'ready' });

  // Responsive layouts: one column on a phone, two columns on desktop.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
  await sleep(400);
  const mobile = await evaluate('(() => { const s=document.querySelector(".stage-panel").getBoundingClientRect(); const r=document.querySelector(".rail").getBoundingClientRect(); return {stageW:s.width, railTop:r.top, stageBottom:s.bottom, scrollW:document.documentElement.scrollWidth, innerW:window.innerWidth}; })()');
  check(mobile.stageW <= mobile.innerW + 1, 'phone layout keeps the stage within the viewport');
  check(mobile.railTop >= mobile.stageBottom - 1, 'phone layout stacks the rail below the stage');
  check(mobile.scrollW <= mobile.innerW + 1, 'phone layout has no horizontal overflow');
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await sleep(400);
  const desktop = await evaluate('(() => { const s=document.querySelector(".stage-panel").getBoundingClientRect(); const r=document.querySelector(".rail").getBoundingClientRect(); return {stageRight:s.right, railLeft:r.left}; })()');
  check(desktop.railLeft >= desktop.stageRight - 1, 'desktop layout places the rail beside the stage');

  // No external requests and no CSP/security errors.
  const badRequests = networkEvents.filter((url) => {
    if (url.startsWith('data:') || url.startsWith('blob:')) return false;
    try { return new URL(url).origin !== new URL(base).origin; } catch (_) { return true; }
  });
  check(badRequests.length === 0, 'no external network origin was requested');
  const securityErrors = consoleEvents.filter((entry) => {
    const text = JSON.stringify(entry);
    return /Content Security Policy|Refused to load|violates the following/i.test(text);
  });
  check(securityErrors.length === 0, 'no CSP/security errors were logged');

  // Auth failure after a real 401: local key removed and pair offered.
  await setMode({ auth_fail: true });
  await click('#refreshBtn');
  await sleep(1200);
  check(await evaluate('!document.getElementById("pairBtn").hidden'), 'auth_failed brings back the pair action');
  check(await evaluate('document.getElementById("statusText").textContent.toLowerCase().includes("pair") || document.getElementById("connectNotice").textContent.toLowerCase().includes("pair")'), 'auth_failed shows re-pair guidance');
  check(await evaluate('localStorage.getItem("floe.bridge.v1.key") === null'), 'auth_failed removes the saved local key');
  await setMode({ auth_fail: false });

  console.log('NOTES ' + JSON.stringify(notes));
  if (failures.length) {
    console.error('FAILURES ' + failures.length);
    process.exit(1);
  }
  console.log('BROWSER CHECKS OK');
}

try {
  await main();
} catch (error) {
  console.error('BROWSER CHECK ERROR: ' + (error && error.stack || error));
  process.exit(2);
} finally {
  try { if (ws) ws.close(); } catch (_) {}
}
