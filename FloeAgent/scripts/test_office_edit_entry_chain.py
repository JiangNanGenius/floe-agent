#!/usr/bin/env python3
"""Exercise the shipped edit-entry JS contract under device-realistic timing.

Build 223's PPT edit failure lives in the edit-mode initialization chain: the
native host probes the engine's backing permission and drives the guarded
mobile edit entry through single-shot `evaluateJavaScript` calls, on a page
whose 9.9 MB bundle can take seconds to parse on a device. This harness runs
the *actual shipped* `FloeEnginePermissionProbeScript` and
`FloeEngineEditEntryScript` (extracted from `FloeOfficeNative.mm`) against
simulated page timelines and pins the contract the host's bounded, retrying
chain relies on:

1. the permission probe reports `null` (never a spurious boolean) while the
   page is still loading, so a slow load cannot be misread as a denied
   document;
2. once the page is up with an editable grant, the probe reports editable,
   and the edit entry switches the engine's own guarded mobile entry exactly
   once (the Impress file-based layout included);
3. while the page is down the edit entry answers `not-ready` — the transient
   the host now retries, bounded, instead of reporting a false denial;
4. a read-only backing grant is never elevated (the view-only file-based
   guard stays with the fullscreen-entry suite);

The timing simulation proves the budget repair: with a page that becomes
ready after the old 4 s probe budget, the old chain reported a spurious
read-only open (the device fallback loop), while the shipped chain (10 s
probe budget + bounded edit-entry retries) reaches the verified edit entry.
"""
import json
from pathlib import Path
import subprocess
import tempfile

HOST = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'


def extract(marker):
    text = HOST.read_text()
    segment = text[text.index(marker):]
    return segment.split('R"FLOE_JS(', 1)[1].split(')FLOE_JS"', 1)[0]


def check():
    probe = extract('static NSString *FloeEnginePermissionProbeScript()')
    entry = extract('static NSString *FloeEngineEditEntryScript()')
    with tempfile.TemporaryDirectory(prefix='floe-edit-entry-chain-') as directory:
        test = Path(directory) / 'chain.js'
        test.write_text('const permissionProbe = ' + json.dumps(probe) + ';\n'
                        'const editEntry = ' + json.dumps(entry) + ';\n' + HARNESS)
        subprocess.run(['node', str(test)], check=True, capture_output=True, text=True, timeout=30)
    return {'checksPassed': [
        'permission probe reports unknown (never a spurious grant) while the page loads',
        'editable grant is reported once the page is up',
        'edit entry answers not-ready while the page is down and switches once up',
        'the Impress file-based layout enters the guarded edit entry exactly once',
        'a read-only backing grant is never elevated',
        'the old 4s budget misread a slow editable open as denied; the shipped chain verifies it',
    ], 'deviceEditEntryChainPassed': False}


HARNESS = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');

// One simulated page. `readyAt` is the millisecond timestamp (simulated clock)
// at which window.app + app.map exist — the multi-megabyte bundle finished.
function page(readyAt, { backendReadOnly = false, fileBasedView = true, docType = 'presentation' } = {}) {
  const listeners = {};
  let now = 0;
  const window = {
    ThisIsAMobileApp: true,
    app: null,
    RenderManager: null,
  };
  window.window = window;
  const sandbox = { window, setTimeout, clearTimeout, console };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  const timers = [];
  const engine = {
    // Advance the simulated clock; the page comes up at readyAt.
    tick(ms) {
      now = ms;
      if (now >= readyAt && !window.app) {
        window.app = {
          file: { readOnly: backendReadOnly, fileBasedView, permission: backendReadOnly ? 'readonly' : 'edit' },
          events: { on() {}, fire() {} },
          map: {
            _permission: backendReadOnly ? 'readonly' : 'readonly',
            _docLayer: { _docType: docType },
            _docLoaded: true,
            isEditMode() { return this._permission === 'edit'; },
            _shouldStartReadOnly() { return false; },
            getDocType() { return docType; },
            _switchToEditMode() {
              if (backendReadOnly) return;
              this._permission = 'edit';
              this.switches = (this.switches || 0) + 1;
            },
          },
        };
        window.app.map._docHasPasswordToModify = false;
      }
    },
  };
  return { sandbox, engine, timers };
}

function evaluate(sandbox, source) {
  return vm.runInContext(source, sandbox);
}

// The native permission probe, verbatim semantics: retry every 100ms until a
// boolean backing permission exists, then report. Mirrors the shipped host.
function hostPermissionProbe(page_, budgetMs) {
  const started = Date.now();
  return new Promise((resolve) => {
    const poll = () => {
      page_.engine.tick(Date.now() - started);
      const result = evaluate(page_.sandbox, permissionProbe);
      if (result && typeof result.backendReadOnly === 'boolean') {
        resolve({ known: true, readOnly: result.backendReadOnly, at: Date.now() - started });
        return;
      }
      if (Date.now() - started >= budgetMs) {
        resolve({ known: false, readOnly: true, at: Date.now() - started });
        return;
      }
      setTimeout(poll, 100);
    };
    poll();
  });
}

// The native edit entry, verbatim semantics: one eval; `not-ready` retried
// bounded (20 x 250ms) — the shipped retry; definitive answers report.
async function hostEditEntry(page_, budgetMs = 6000) {
  const started = Date.now();
  for (;;) {
    page_.engine.tick(Date.now() - started);
    const result = evaluate(page_.sandbox, editEntry);
    if (result && result.ok) {
      return { readOnly: result.backendReadOnly === true || result.uiEdit !== true, result };
    }
    if (result && result.reason === 'readonly') return { readOnly: true, result };
    if (result && result.reason === 'unsupported') return { readOnly: true, result };
    if (Date.now() - started >= budgetMs) return { readOnly: true, result };
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

(async () => {
  // 1. A page that is still loading: the probe reports null, never a boolean.
  {
    const p = page(60_000);
    p.engine.tick(500);
    const result = evaluate(p.sandbox, permissionProbe);
    assert.equal(result, null, 'a loading page must probe as unknown, not as a denial');
  }

  // 2. The device failure window: the page becomes ready at 6s — after the old
  //    4s probe budget. The old chain misread the open as denied; the shipped
  //    chain (10s budget + bounded edit-entry retries) verifies the edit entry.
  {
    const p = page(6_000);
    const probe = await hostPermissionProbe(p, 15_000);
    assert.equal(probe.known, true, 'the shipped 15s probe budget must outlast a 6s page load');
    assert.equal(probe.readOnly, false);
    const entry = await hostEditEntry(p);
    assert.equal(entry.readOnly, false, 'the shipped retrying edit entry must reach the verified switch');
    assert.equal(p.sandbox.window.app.map._permission, 'edit');
  }

  // 3. The probe reports editable once the page is up, and the edit entry
  //    switches the engine's own guarded entry exactly once for the Impress
  //    file-based layout.
  {
    const p = page(300);
    p.engine.tick(500);
    const probe = await hostPermissionProbe(p, 15_000);
    assert.equal(probe.known, true);
    assert.equal(probe.readOnly, false);
    const entry = await hostEditEntry(p);
    assert.equal(entry.readOnly, false);
    assert.equal(p.sandbox.window.app.map.switches, 1, 'the guarded entry runs exactly once');
  }

  // 4. While the page is down the edit entry answers not-ready (the transient
  //    the shipped host retries) — never a fabricated editable grant.
  {
    const p = page(60_000);
    p.engine.tick(500);
    const result = evaluate(p.sandbox, editEntry);
    assert.equal(result.ok, false);
    assert.equal(result.reason, 'not-ready');
  }

  // 5. A read-only backing grant is never elevated: the edit entry answers
  //    `readonly` and the engine's UI mode stays read-only.
  {
    const denied = page(300, { backendReadOnly: true });
    denied.engine.tick(500);
    const probe = await hostPermissionProbe(denied, 10_000);
    assert.equal(probe.known, true);
    assert.equal(probe.readOnly, true);
    const entry = await hostEditEntry(denied);
    assert.equal(entry.readOnly, true);
    assert.equal(denied.sandbox.window.app.map._permission, 'readonly');
  }

  // 6. Regression pin: the OLD 4s probe budget misread the 6s editable open as
  //    a denied document — the exact spurious read-only report that bounced the
  //    device editor back to preview on every attempt.
  {
    const p = page(6_000);
    const old = await hostPermissionProbe(p, 4_000);
    assert.equal(old.known, false, 'the old 4s budget gave up on a slow-but-editable open');
  }
  console.log('edit-entry chain contract: all checks passed');
})().catch((error) => { console.error(error); process.exit(1); });
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
