# LÖVE / love.js persistence — actual behavior and repair source

## What the current runtime actually does

Evidence source: prepared `love.js@11.4.1` compatibility runtime.

- `EmscriptenPersistence.js` (LÖVE fork `a79ab87...`) mounts **IDBFS** at
  `/home/web_user/love` and calls `FS.syncfs(true)` before the game starts.
- It calls `FS.syncfs(false)` only from a `window.beforeunload` listener.
- It does not expose `FS`, `syncfs`, or a flush method on the `Love` object.
- It has no `saveFS` symbol and no per-write sync.
- LÖVE's save identity (`floe-tidepool` for the starter) is a subdirectory of
  `/home/web_user/love`, so the mount covers engine saves.
- A persistent WKWebsiteDataStore/stable origin is necessary but not
  sufficient: the IDBFS reconciliation still has to run before teardown.

The first Root actual lifecycle test (S/write -> stop -> **new**
GameWebPlayer -> L/read) failed: `Could not open file floe-save.txt. Does not
exist.` This confirmed the beforeunload-only gap. A synthetic `beforeunload`
dispatch timing pass is not evidence of durability.

Root's focused actual native WebKit follow-up now **PASSES**:
`web-storage-final/native-close-1/record.json` (SHA-256 `c6066331...`) has
`crossPlayerBuiltInSavePersistenceVerified: true`. The original Lua game saved
x=641.04, stopped with `.saved`, a new GameWebPlayer started at x=480, and L
read x=641.04 from the original file. The candidate receipt
`mpl-compat/love-close-candidate-1-receipt.json` (SHA-256 `e6d98d33...`)
records the patched loader `a9fec128...`, unchanged `love.wasm`
(`ecc9e098...`) and unchanged `game.data` (`51fcbc69...`). Do not repeat the
test.

## Repair source

Root prepared the authoritative focused patch after the real failure:
`Scripts/Distribution/patches/love/EmscriptenPersistence.js.patch`
(SHA-256 `e678aa5191f9ed39591c27fedd11e7e3242e638dfa2afbb519653e6cd78ef2ef`)
and `LOVE-PERSISTENCE-SOURCE-PATCH.json` (SHA-256
`32f50673919173a951a7b86439cd4f8313c9c1c133b37a137cd1759abb55454b`).
Its guards are the exact npm loader hashes `12db012a...` (compat) and
`eb20a4d9...` (release); it adds `Module.floePrepareToStop`, queues
`FS.syncfs(false)`, pauses the main loop, changes no WASM or user content, and
retains the upstream MIT/NCSA notices. The modified loader SHA-256 is
`a9fec12804500c6dcfc524c0c40ef06fc3b772afc23eaa36f4c3aff2ae3da955`.
Root owns those two files; do not overwrite them during integration. This
document does not duplicate that implementation.

The alternative source-level patch below is retained as a reference/fallback
for a rebuild from the pinned LÖVE source. It is **not** the authoritative
integration path. Apply `EmscriptenPersistence.js.patch` to
`src/scripts/EmscriptenPersistence.js` in the pinned LÖVE source and rebuild
the compatibility/release runtime with emsdk 2.0.0 (see
`source-packages/love/RELINK.md`). The alternative patch adds:

- `Module["flushSave"](callback)` exposing an explicit `FS.syncfs(false)`;
  because `Module` is the `Love` object, it is `Love.flushSave`.
- `pagehide` and `visibilitychange` flushes.
- A wrapper on `FS.close` that syncs after a file under
  `/home/web_user/love/` is closed, covering `love.filesystem.write` before an
  app stop.
- A 2-second backstop sync.

Original file SHA-256:
`2176225739b95988edef11554233e6d6eb7a2a4ff78375b9021c5a482f4227de`.
Patched file SHA-256:
`aa76c4655dbf3848158e0a4738c37fc5eb5733519a70b3606bb571cdce9c96be`.

This is not a claim that the unpatched current private artifact is fixed.
Root's patched candidate is the persistence-qualified runtime; the unpatched
artifact remains preserved research. Root's six WebKit lifecycle fixtures and
the actual new-player/read test passed and were not repeated by this task.

## Optional tree overlay (no rebuild)

`floe-persist.js` can be injected into a built artifact's `index.html`. It
calls `Love.flushSave` when the patched runtime provides it; otherwise it
dispatches a synthetic `beforeunload` and waits a bounded time. It is a
stopgap, not proof. Do not use it as acceptance evidence for cross-player
persistence.

## Ownership

The Core WebKit persistence owner owns the durable data store, stable origin
and player lifecycle. This document only records the engine-side requirement
and supplies the LÖVE source patch; it does not change Core storage or the
App.
