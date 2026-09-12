# Local shell substrate — plan and implementation record

This file records what landed for the local shell/terminal/apt upgrade, what
remains, and the decisions behind it. Architecture details live in
`docs/ARCHITECTURE_LOCAL_SHELL.md`.

## Landed in this change

- **Shell core (FloeExecution)**: `LocalShellBackend` protocol, `LocalShellService`,
  `ShellCommandPolicy` (catastrophic gate + shell patterns), `ShellOperationJournal`,
  `ShellOutputSanitizer`, `ShellSessionCenter`, `exec.shell`, `shell.open/exchange/
  close/signal`, `ShellToolRegistration`.
- **App bridge**: `FloeApp/Execution/FloeShellBridge.{h,mm}` (thread-local stdio,
  mini-root, one-shot runner with watchdog, interactive pipe sessions,
  replacement-command registration), `IOSSystemShellBackend`,
  `FloeShellCommands` (python3, sha256sum, ping, traceroute, dig/nslookup/host,
  nc, apt/pkg/dpkg, git hint), upstream command dictionaries under
  `FloeApp/Resources/Shell/`.
- **Packages**: `CapabilityCatalog` + JSON manifest (T0/T1/T2 entries),
  `ManagedPythonInstallService` (extracted from `exec.localPython`, adds
  uninstall/distribution listing), `CapabilityInstaller`, `apt` tool,
  `ArArchiveReader`, `DebDataInstaller` (ELF rejected), `PythonEntryPointShims`,
  `WasmRuntime` protocol + guarded `WasmKitCommandRuntime`.
- **Approval**: `ApprovalPolicy.isSoftwareInstallRequest` now covers
  `exec.localPython`, `apt` and `exec.shell` package requests; `exec.shell`
  and `shell.*` are never deterministically exempt.
- **Background**: `jobs.submit` accepts `exec.shell` targets (600 s ceiling).
- **Tool surface R0**: dangling `browser.upload` / `workspace.inspectMetadata`
  / `workspace.moveItem` / `document.pdf.save` references fixed; dead
  `exec.remotePython` tool deleted; `ownerSkillID` removed from the descriptor
  and discovery output (replaced by `aliases`); `document.pdf.render` risk and
  effect corrected; `canvas.generate` effect made explicit; synonyms and
  rename aliases moved to `ToolAliasTable` (FloeTools).
- **Demotion wave 1**: `image.process`, `image.svgDocument`, `crypto.hash`,
  `workspace.appendFile`, `workspace.replaceText` removed and replaced by the
  hidden guides `floe-image-edit`, `floe-svg`, `floe-text-edit` plus an updated
  `floe-crypto`. New hidden `floe-shell` guide documents the shell surface.
  (`document.createMarkdown` demotion is deferred to the signed skill-hub
  publish batch because `floe-office` is a signed official package.)
- **Docs**: this file, `ARCHITECTURE_LOCAL_SHELL.md`, release notes 1.6.7,
  historical banners on `PRODUCT.md` / `DEVELOPMENT_PLAN.md` / `SECURITY.md`.

## Decisions

- ios_system (BSD-3) is the command bus instead of a self-written parser:
  App Store precedent (a-Shell), complete BSD userland, `replaceCommand` seam
  for policy-sensitive commands. Linkage stays in the app target so the Swift
  package (and its macOS tests) never depend on iOS-only binary frameworks.
- WasmKit (pure Swift, interpreter) is the intended WASM runtime; the
  dependency is not yet added, so `pkg` reports unavailability honestly.
  a-Shell's WKWebView+JIT/server approach was rejected (JIT entitlement risk,
  extra attack surface).
- Full-ELF/iSH/UTM emulation stays out (GPLv3/GPLv2 and review risk). Remote
  hosts remain the escape hatch for native Linux binaries.
- Security was relaxed exactly as approved (mini-root read access, coarse
  per-command risk, interactive pagers, signed WASM command packages); the
  hard boundaries in the architecture doc are non-negotiable.

## Original remaining list (superseded by the implementation checkpoint below)

1. **Device pass required**: verify the Obj-C++ bridge semantics on device —
   thread-local stdio inheritance, `ios_setMiniRoot` behavior with workspace
   mounts, SIGINT/kill behavior of the watchdog, session EOF detection, and
   `replaceCommand` resolution for `@_cdecl` symbols (`-force_load` may be
   needed depending on dead-stripping).
2. **App target build**: add the ios_system package resolution to CI, confirm
   embedded frameworks and plist resources land at the bundle root, and run
   `scripts/gen_project.sh` after any project.yml change.
3. **Preset packaging**: run `scripts/pin_python_bundled_packages.py` once with
   network access to freeze T1 URLs+SHA-256, then wire
   `install_python_bundled_packages.py` into `bootstrap_python_runtime.sh` and CI.
4. **WasmKit dependency** + signed WASM capability packaging pipeline.
5. **M3 UI**: SwiftTerm local terminal owner and the editor `.shell` Run button.
6. **Bounded R1/R2 naming wave** using `ToolAliasTable` (presentation.*,
   task.*, image.qrGenerate/scanBarcode, cloudWorkspace.git.*); the alias
   table is empty until then.
7. **User-facing docs**: sync `docs/USER_GUIDE.md` / `.zh-CN` and
   `docs/ARCHITECTURE_OVERVIEW.md` with the shell/apt surfaces, and extend
   `scripts/license_inventory.sh` / `sbom.sh` with the ios_system frameworks.
8. **Full test matrix** and release flow (tag → TestFlight → verification),
   then remove the demotion/deprecation notes one minor release later.


## Implementation checkpoint — 2026-09-12

**Not release-ready. No 1.6.7 tag or TestFlight upload has been made.**

### Changes in the working tree

- Replaced nonexistent individual upstream SwiftPM products with a local
  `FloeShellEngine` package containing the seven intended pinned binary targets.
  Regenerated the Xcode project; added binary artifacts to SBOM generation.
- Corrected bridge API declarations and C linkage, retained run state through
  worker completion, connected one-shot stdio, and replaced direct terminating
  pthread signals with the engine interrupt API. The bridge compiles as iOS
  arm64 against the v3.0.2 public header. This is not app linking/device evidence.
- Added shared command/cwd/env validation, symlink-aware cwd resolution, bounded
  UTF-8 output, and session cleanup/race fixes. Interactive command policy still
  needs end-to-end validation (fragmented terminal input is not a parsed command).
- Wired the locked Python preset into bootstrap. Added the missing pytz dependency:
  the preset now contains 35 wheels. All 35 local/downloaded wheel hashes and
  archive-content checks passed; device import coverage is still pending.
- Fixed receipt date decoding, distribution-name discovery and uninstall lookup;
  uninstall preserves shared RECORD files and rolls back failed moves. Missing
  bundled Python packages fail instead of silently initiating a download.
- Data-only Debian extraction now stages and validates the whole archive before
  publishing to a new destination. Native payloads, path escape, duplicates,
  excessive entries/expanded bytes and existing destinations are rejected.
- Added the bounded naming wave and old dotted/provider-wire aliases. Updated
  official Office skill source to 1.2.2/minimum app 1.6.7; signing/publication is
  pending and existing signed artifacts are unchanged.
- Python package-payload regression: 7 tests passed. Official skill-hub builder:
  4 tests passed. FloeExecution target build passed; final focused Swift test
  result is recorded in the [implementation checkpoint](LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md).

### Newly established architecture blocker

The v3.0.4 package points at v3.0.2 binaries. In that source, `miniRoot` is a
process-global directory policy, while file commands/redirections still invoke
host file APIs. `ios_setMiniRoot` does **not** establish a complete per-workspace
filesystem sandbox. Per-command cwd and several engine globals also require
isolation work before concurrent terminals can be claimed.

Sources:
- https://github.com/holzschu/ios_system/blob/v3.0.4/Package.swift
- https://github.com/holzschu/ios_system/blob/v3.0.2/ios_system.m
- https://github.com/holzschu/ios_system/blob/v3.0.2/libc_replacement.c

The user deferred app publication and asked to finish functionality first. Keep
strict workspace isolation as an outstanding requirement; do not silently weaken
it. The current implementation and remaining acceptance gates are tracked in
[the implementation checkpoint](LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md).

### Next execution steps

1. Resolve the filesystem boundary, then finish and test the chosen engine path,
   including interruption completion, global-state isolation and retained resources.
2. Complete WASM execution budgets and signed capability installation; no JIT,
   real stdin/output, infinite-loop cancellation and workspace-only WASI preopens.
3. Finish local terminal/editor and old removed-tool adapters, then signed skills.
4. Run final local focused checks, cloud app/full tests and physical iPad tests.
5. Freeze the final SHA, tag, upload and verify Apple VALID + only internal Floe QA.
