# Floe language capability routes (WASI catalog)

Updated 2026-09-19. This file describes what is installable today, what is
compilepending, and the exact promotion path. Only entries in the **signed**
`catalog.json` can be installed on a device; syntax highlighting in the IDE is
not a runtime and `CANDIDATES` entries are not installable.

## Device execution route

1. The app loads the signed catalog with the pinned public key and verifies the
   Ed25519 signature over `FLOE-CAPABILITY-CATALOG-V1\n` + payload.
2. `apt install floe/<name>` stages the artifact, checks the signed SHA-256,
   requires the WASM magic and then atomically activates a receipt.
3. The shell registers the canonical `floe-<name>` command, plus the bare alias
   when the catalog entry exists (`lua`, `ruby`, `php`).
4. `WasmKitCommandRuntime` executes the module with the token interpreter, a
   workspace preopen jail, borrowed host stdio, a cooperative budget and the
   limits carried by the signed entry (`moduleMaxBytes`, `memoryMaxBytes`,
   `defaultTimeoutSeconds`).

Small utilities keep the historical 4 MiB / 64 MiB / 30 s defaults. Interpreter
entries may raise them within reviewed ceilings (module ≤ 64 MiB, memory ≤
1 GiB, timeout ≤ 600 s); the app rejects a catalog entry outside those ranges at
signature-verification time. A signed entry whose `minimumAppVersion` is newer
than the running app is skipped on its own; it never invalidates the rest of
the signed catalog. Interpreter startup can exceed the shell tool's default
timeout; use a longer `timeout` or a background job.

## Status

| Capability | Route | Status |
| --- | --- | --- |
| `floe/wasm-text` 1.0.0, `floe/lua` 5.4.8 | committed signed WASI modules | **ready**; install with `apt install floe/lua` |
| `floe/ruby` 3.4.1 | pinned [ruby/ruby.wasm](https://github.com/ruby/ruby.wasm) release asset, fetched and verified by `language-runtimes.yml` | **compilepending**; candidate metadata in `build.py`, lock in `FloeAgent/ThirdParty/RubyWASI/runtime.lock.json` |
| `floe/php` 8.2.33 | pinned php-src 8.2.33 security release + vendored Apache-2.0 VMware Labs patch series replayed onto it + wasi-sdk 20.0, built by `language-runtimes.yml` | **compilepending**; promotion waits for the passing cloud build, interpreter qualification and staged digest (8.2 security support runs until 2026-12-31) |
| Rust / C / C++ / Go / Swift sources | `.github/workflows/cloud-language-compile.yml` compiles one bounded source file to wasm32-wasip1, requires WASI-only imports, smoke-runs with wasmtime and stages under `capability-hub/cloud-staging/` | **prepared, not run**; no artifact is presented as ready |
| Native ELF/Mach-O binaries, WASIX packages, Emscripten modules with JS glue | none | **not supported**; the import check in the workflow rejects non-WASI imports |

## Cloud compile to local WASI (no device compiler)

```bash
gh workflow run cloud-language-compile.yml \
  -f language=rust \
  -f name=floe/hello-rust \
  -f command=floe-hello-rust \
  -f version=1.0.0 \
  -f source_base64="$(base64 < hello.rs)" \
  -f smoke_args=""
```

The workflow pins Rust 1.98.1 (`wasm32-wasip1`), wasi-sdk 20.0 for C/C++, Go
1.26.0, and the official Swift 6.4.0 WASM SDK (swift.org artifact bundle with
its published checksum). It emits an `artifact.json` with the module digest,
size, source digest, toolchain language and run id, and only stages an artifact
after `wasm-validate`, the WASI-only import check and the wasmtime smoke run all
pass. Staging never signs and never edits `MANIFEST`; `capability-hub.yml` is
the only signer.

Sources that need unsupported OS features, native extensions or non-WASI
syscalls stay on the remote host / cloud workspace route; they are not
advertised as locally executable.

## Promotion procedure (reviewed)

```bash
# 1. Qualify on cloud (dispatch only, after source freeze)
gh workflow run language-runtimes.yml -f runtimes=both
# 2. Stage a verified artifact immutably (CI does this in the stage job; it can
#    also be run locally against a verified file)
python3 capability-hub/stage_artifact.py --id floe/ruby --artifact ruby.wasm --evidence evidence/
# 3. Reviewed change: move the entry from CANDIDATES to MANIFEST in build.py
#    with the staged digest/size/limits, then verify and sign
python3 capability-hub/build.py --check
python3 capability-hub/build.py   # requires FLOE_SKILL_HUB_SIGNING_KEY
```

Promotion rules:

* a candidate must stay `status: compilepending` and must never collide with a
  released id or command;
* `check()` fails if a candidate id appears in the signed catalog;
* staged bytes are immutable: a different digest at the same path is refused;
* the signed catalog may add limits only within `LIMIT_RANGES` in `build.py`
  and `WasmPackageLimits` in FloeExecution;
* the bundled copy under `FloeAgent/FloeApp/Resources/Capabilities` is written
  only by the signing step in `capability-hub.yml`.

## Provenance and licenses

* `FloeAgent/ThirdParty/LuaWASI` — Lua 5.4.8 (MIT), wasi-sdk 34.
* `FloeAgent/ThirdParty/RubyWASI` — ruby.wasm 2.10.1 (tooling MIT); Ruby
  interpreter Ruby license / BSD-2-Clause.
* `FloeAgent/ThirdParty/PHPWASI` — PHP 8.2.33 (PHP-3.01, current 8.2 security
  release); VMware Labs webassembly-language-runtimes port patches (Apache-2.0)
  replayed onto 8.2.33 and vendored with NOTICE and license text, each digest
  pinned in `runtime.lock.json`.
* Every workflow verifies digests before compiling or executing; no artifact
  hash is hand-written.
