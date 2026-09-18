# Floe PHP WASI runtime — provenance and status

Status: **compilepending** (not signed, not in `catalog.json`, not installable by
any shipped build yet). PHP has no upstream WASI target: the vendored patch set
below is the reviewed, pinned port, replayed onto the current PHP 8.2 security
release. Promotion gates are listed at the end.

## What is pinned

| Item | Value |
| --- | --- |
| PHP source | `https://www.php.net/distributions/php-8.2.33.tar.gz`, SHA-256 `9a525d4db1237ede408e454b46f5a93b9e45d83d71753592e3f921903d917e07` (19,264,838 bytes), released 2026-07-30 |
| WASI port | VMware Labs [webassembly-language-runtimes](https://github.com/vmware-labs/webassembly-language-runtimes) revision `dd26cd52f0cf5e15ba058d5e8c0c4354386570ca`, `php/v8.2.6/patches` (Apache-2.0), replayed onto php-8.2.33 and vendored in `./patches` with per-file SHA-256 in `runtime.lock.json` |
| Toolchain | wasi-sdk 20.0, `wasi-sdk-20.0-linux.tar.gz`, SHA-256 `7030139d495a19fbeccb9449150c2b1531e15d8fb74419872a719a7580aad0f9` (79,570,956 bytes) |
| License | PHP-3.01 (interpreter); Apache-2.0 (port patches, `NOTICE` and license text included) |
| Target | `wasm32-wasi` (WASI preview 1) |
| Runtime engine | vendored WasmKit 0.3.1 + Floe patches (`FloeAgent/ThirdParty/WasmKit`) |
| Package limits | module 32 MiB, memory 256 MiB, default timeout 120 s |

`build_wasi.sh` fetches and verifies the source, toolchain and every patch
digest, applies the series, configures with the upstream VMware flags, builds
the CLI SAPI (preferred) and CGI (fallback), optionally runs `wasm-opt -O3`,
and writes digests, patches, toolchain version and license text into
`<scratch>/evidence`. It never signs or edits the catalog.

## PHP support status (verified 2026-09-19)

php.net `supported-versions.php` on 2026-09-18: PHP 8.2 active support ended
2024-12-31, **security support runs until 2026-12-31**; 8.3/8.4/8.5 are the
other supported branches. PHP 8.2 is therefore not end-of-life yet, but only
critical security fixes are issued and only as needed. The previous pin,
8.2.6 (2023-05-11), predates more than three years of security releases, so the
pin was moved to **8.2.33** (2026-07-30), the current security release, via the
`php-8.2` release metadata endpoint (`https://www.php.net/releases/index.php?json&version=8.2`).

There is no maintained upstream WASI patch set for 8.3/8.4/8.5 (the VMware Labs
repository stops at `php/v8.2.6`), so the supported-branch choice is 8.2.33.

## Patch series rebase (8.2.6 → 8.2.33)

The 19 VMware Labs patches were replayed hunk-by-hunk onto the 8.2.33 tree with
`Local/Private/build191-feedback/language-delivery/tools/rebase_php_patches.sh`
(+ `apply_patch_robust.py`), regenerated with `git diff`, and verified to apply
with plain `git apply` in order on a clean php-8.2.33 tree (19/19, only
inherited whitespace warnings). Two deliberate deviations, recorded in
`runtime.lock.json`:

* `0001` `main/network.c` hunk 15 dropped: 8.2.33 zero-initializes the local
  sockaddr (`local_address = {0}`), which makes the WASM_WASI `memset` guard
  obsolete. Dropping it preserves the 8.2.6 behavior (in 8.2.6 the memory was
  cleared explicitly; in 8.2.33 it is cleared by initialization).
* `0018` `ext/random/random.c` context updated for the 8.2.33
  `(defined(__sun) && defined(HAVE_GETRANDOM))` condition; the added
  `|| defined(__wasi__)` branch is preserved.

No other patch behavior was changed. The historical 8.2.6 patch files remain
available in git history at the previous commit of this directory.

## Cloud build history (this pin)

* 2026-09-19, `language-runtimes.yml` run 35394211461 (commit 9641c0fa): the
  php-8.2.33 build configured with the full extension set and failed in
  `ext/libxml/libxml.lo` because configure used the runner's host libxml2
  (`-I/usr/include/libxml2`), whose headers need ICU (`unicode/ucnv.h`), not
  present in wasi-sdk 20. The uploaded `build.log` records the exact error
  (`php-wasm-<sha>` artifact).
* Fix in the recipe: build the reviewed **slim** extension set
  (`--disable-all --without-libxml --disable-dom/-simplexml/-xml/-xmlreader/-xmlwriter
  --without-sqlite3 --disable-pdo --without-pdo-sqlite`) that does not depend on
  the VMware prebuilt WASI libraries. Core PHP, the CLI SAPI, file IO, JSON,
  PCRE, date, SPL and standard stay available; XML/DOM, mbstring, sqlite and
  gd stay on the remote route and are listed as limitations below.

* 2026-09-19, `language-runtimes.yml` run 35394556662 (commit c47ecb3c): with the
  slim set the build reached `main/streams/xp_socket.c:591` and failed because
  8.2.33 moved the Unix-socket length check before the WASM_WASI guard while
  wasi-sdk 20's `struct sockaddr_un` has no `sun_path`. Fixed by patch `0020`,
  which extends the guard to cover the `max_length` computation; the object
  compiles locally with the macOS wasi-sdk 20 (`make main/streams/xp_socket.lo`).

## Compatibility evidence actually observed

**2026-09-19, host macOS 27 arm64, PHP 8.2.6 published module (historical
probe, not the 8.2.33 build):**

* Source pin 8.2.6 tarball downloaded from php.net and digested (matched the
  published `.sha256`); wasi-sdk 20.0 (linux) downloaded and digested.
* All 19 original patches applied cleanly to php-8.2.6 (`git apply`, no rejects).
* The published VMware Labs PHP 8.2.6 CGI module (`@antonz/php-wasi` 8.2.6 npm
  tarball SHA-256 `56f781b0eecf51c35749d303308468ca5509ec240b11c9af2c1ba5f428ac9bc9`,
  `dist/php-cgi.wasm` 13,164,411 bytes, SHA-256
  `edb29de7cd80597292670499846db56929af1166459c4a776ef606aef357c93b`) ran
  through the vendored WasmKit 0.3.1 objects: `--version` → `PHP 8.2.6
  (cgi-fcgi)`; script with file IO + `$argv` → exit 0 with the `/workspace`
  jail file written; thrown `RuntimeException` → exit 255 with the fatal text,
  recovered; cancellation at 5.2 s on `while (true) {}`.

**2026-09-19, php-8.2.33 rebase check (this pin):**

* `php-8.2.33.tar.gz` downloaded from php.net; SHA-256 verified against the
  release metadata (`9a525d4d…e07`).
* Rebased series applies with plain `git apply` on a clean 8.2.33 tree: 19/19
  patches, zero rejects; per-patch change sets match the 8.2.6 originals except
  the two documented deviations.
* The 8.2.33 compile itself is **not** run locally; it is the
  `language-runtimes.yml` php job (cloud, wasi-sdk 20.0) that must produce and
  validate the module. Until that run passes, no PHP compatibility claim for
  8.2.33 is made.

CGI SAPI limits are real and are the reason the build prefers the **CLI** SAPI:
`php-cgi` does not support `-r`, and reading stdin needs CGI request variables
(`REQUEST_METHOD`/`CONTENT_LENGTH`), which turns the invocation into an HTTP
CGI request, so the qualification test records the SAPI difference instead of
hiding it.

## Security gate

8.2.33 is the current security release of a still-supported branch, so shipping
it is materially different from shipping 8.2.6. Promotion still requires the
cloud build and the interpreter qualification tests to pass, plus the staged
artifact digest recorded by `stage_artifact.py`. The catalog entry stays
`compilepending` until then.

## Promotion gates

1. Run the `language-runtimes.yml` php job; it must produce `php.wasm` (CLI) or
   `php-cgi.wasm`, run the PHP interpreter qualification tests, and upload
   artifact + evidence.
2. `python3 capability-hub/stage_artifact.py --id floe/php --artifact <php.wasm> --evidence <dir>`.
3. Move the entry from `CANDIDATES` into `MANIFEST` with the staged digest
   (reviewed change) and let `capability-hub.yml` sign.

Known limitations: slim extension set (no libxml/DOM/XML, mbstring, sqlite,
pdo, gd, sockets, `iconv`/`openssl`/`phar`), fibers disabled, `wasmedge`
flavors are not used (the WASM_RUNTIME_WASMEDGE code paths stay inert), and the
module is an interpreter — startup is seconds, not milliseconds. Native PHP
extensions and non-WASI syscalls stay on the remote host route.
