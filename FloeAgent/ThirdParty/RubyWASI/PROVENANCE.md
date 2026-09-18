# Floe Ruby WASI runtime — provenance and status

Status: **compilepending** (not signed, not in `catalog.json`, not installable by
any shipped build yet). This directory is the pinned, reviewable route; the
promotion gates are listed at the end.

## What is pinned

| Item | Value |
| --- | --- |
| Upstream project | [ruby/ruby.wasm](https://github.com/ruby/ruby.wasm) release `2.10.1` |
| Asset | `ruby-3.4-wasm32-unknown-wasip1-full.tar.gz` (25,134,606 bytes) |
| Asset SHA-256 | `440f9a48a3bae258c70de610f7a78cfc56b536bdb9b81ef750f8d3918382515e` |
| Module member | `ruby-3.4-wasm32-unknown-wasip1-full/usr/local/bin/ruby` |
| Module SHA-256 | `348305ee0b4e4cdb84ec169223e33721899548577a42a421725b71e481afff11` (34,719,962 bytes) |
| License | ruby.wasm tooling MIT (Yuta Saito); Ruby interpreter Ruby license / BSD-2-Clause |
| Target | `wasm32-unknown-wasip1` (WASI preview 1), single-threaded |
| Runtime engine | vendored WasmKit 0.3.1 + Floe patches (`FloeAgent/ThirdParty/WasmKit`) |
| Package limits | module 64 MiB, memory 256 MiB, default timeout 120 s |

`fetch_runtime.sh` downloads the asset, verifies the asset digest, extracts
only the `ruby` member, verifies its digest and size, checks the WASM magic and
writes evidence (lock, digests, licenses) into `<scratch>/evidence`.

## Compatibility evidence actually observed (2026-09-19, host macOS 27 arm64)

The private harness
(`Local/Private/build191-feedback/languages/tools/floe-wasm-harness.swift`)
links the WasmKit/WasmKitWASI objects the App repository already built from
`ThirdParty/WasmKit` and mirrors `WasmKitCommandRuntime`'s instantiation
(token engine, preopen jail, borrowed stdio, resource limiter, cooperative
budget). It is a diagnostic harness, not the compiled `FloeExecution` module.

| Check | Result |
| --- | --- |
| `--disable-gems -e 'puts "hello from ruby"; puts RUBY_VERSION; puts 2+40'` | exit 0, `hello from ruby / 3.4.1 / 42`, ~18.9 s |
| file IO in the `/workspace` preopen | exit 0, written file read back (`sum=42`) |
| `ARGV` | exit 0, `alpha,beta` |
| stdin (UTF-8) | exit 0, `echo:来自stdin` |
| `raise "boom"` | exit 1, `-e:1:in '<main>': boom (RuntimeError)` — recovered, no trap |
| cancellation flag set after 5 s on `loop { i += 1 }` | status `cancelled` at 5.2 s (patched token-loop budget) |
| memory growth caps 32/64/128 MiB | interpreter starts in all three; growth cap is not a startup limit |

Timings come from **Debug** WasmKit objects in the local module cache; the App
Release build interprets faster. Device (iPad) timing is not measured here and
is part of the App acceptance gate.

## Why the limits

34.7 MiB exceeds the 4 MiB utility default, so the signed catalog entry must
carry `moduleMaxBytes` (64 MiB ceiling) and the store/download path must honour
it. That support is implemented in `FloeExecution`
(`WasmPackageLimits.swift`, `SignedWasmCapabilityStore.swift`,
`WasmKitCommandRuntime.swift`) and in the capability catalog payload
(`capability-hub/build.py`).

## Promotion gates

1. Run the `language-runtimes.yml` ruby job: it fetches and verifies the asset,
   runs the Ruby interpreter tests through the production runtime on the
   qualification host, and uploads artifact + evidence.
2. `python3 capability-hub/stage_artifact.py --id floe/ruby --artifact <ruby.wasm> --evidence <dir>`
   stages the module immutably and writes the promotion record.
3. Move the entry from `CANDIDATES` into `MANIFEST` in `capability-hub/build.py`
   (reviewed change) with the staged digest, then `capability-hub.yml` signs.
   No App or catalog change happens before that review.

Known limitations: `gem`/`irb`/`rake` wrappers are not shipped; native
extensions and threads are unavailable; the interpreter is an interpreted
runtime and startup is seconds, not milliseconds.
