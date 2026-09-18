# Floe language capability routes (WASI catalog)

Updated 2026-09-19. Signed bundle source: capability-hub.yml run 35399070312
at commit 96be231e978354e7c15cdb909cf118ad7b415c23 (prepare=true, no publish);
final main publication is coordinated by the primary. This file describes what is installable today, what is
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
| `floe/ruby` 3.4.1 | pinned [ruby/ruby.wasm](https://github.com/ruby/ruby.wasm) release asset, fetched and verified by `language-runtimes.yml`; 34,719,962 B, sha256 `348305ee…afff11` | **qualified and promoted**; run 35396385874 passed the interpreter, limit and capability suites through the production runtime; staged at `packages/floe-ruby/3.4.1/` and signed by the catalog signing run |
| `floe/php` 8.2.33 | pinned php-src 8.2.33 security release + 21 vendored Apache-2.0 VMware Labs patches replayed onto it + wasi-sdk 20.0; CLI SAPI 4,077,894 B, sha256 `c76afbda…c73f` | **qualified and promoted**; run 35397034902 built the CLI SAPI and 18 interpreter/limit/capability tests passed (the retried commit carries the stream-agnostic error assertion); 8.2 security support runs until 2026-12-31 |
| Rust / C / C++ / Go / Swift sources | `.github/workflows/cloud-language-compile.yml` compiles one bounded source file to wasm32-wasip1, requires WASI-only imports, smoke-runs with pinned wasmtime and qualifies through the production runtime | **qualified** (runs 35395954508 / 35395961045 / 35395966796 / 35395972559 / 35397154942); hello/fileIO/args/error fixtures staged-unpromoted under `cloud-staging/`, not signed |
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
#    with the staged digest/size/limits, then sign and verify
gh workflow run capability-hub.yml -f prepare=true       # signs at the fixed commit
python3 capability-hub/build.py --check                  # verifies the signed catalog
```

Promotion rules:

* a candidate must stay `status: compilepending` and must never collide with a
  released id or command;
* `check()` fails if a candidate id appears in the signed catalog;
* staged bytes are immutable: a different digest at the same path is refused;
* the signed catalog may add limits only within `LIMIT_RANGES` in `build.py`
  and `WasmPackageLimits` in FloeExecution;
* the bundled copy under `FloeAgent/FloeApp/Resources/Capabilities` is written
  by the signing step in `capability-hub.yml`; the build 192 source imports the
  prepare-signed copies from run 35399070312 (revision `96be231e`) verbatim so
  the device ships the Ruby/PHP entries, and the main-only publish job re-runs
  the signing step and verifies the same bytes.

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
