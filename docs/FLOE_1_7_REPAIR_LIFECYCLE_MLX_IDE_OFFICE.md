# Floe 1.7 repair slice — Linux lifecycle, MLX fit, IDE Git, Office routes

Status: **implementation commit in review. No release, tag, upload or TestFlight
change is part of this slice.** Physical-device acceptance remains with the user.
The evidence base is the build-218 device task log
(`1-floe-task-31E70E65-…jsonl`, 2026-09-21), which installed and exercised the
TinyEMU Linux guest and recorded the failures this slice repairs.

## 1. TinyEMU Linux is the primary local runtime

| Repair | Implementation | Evidence |
| --- | --- | --- |
| First use prepares Linux without model awareness | Every Linux-required entry point now runs the same background preparation as the model tool: `FloePlatformServices.activateLinuxGuestWithPreparation` is used by `exec.shell` routing, guest Python, `exec.localService`, apt/dpkg command routing, `node`/`npm` and the language-package service. An `imageNotQualified` failure triggers the shared, cancellable download job once and resumes the original command. | `FloeApp/Execution/FloePlatformServices.swift` (activate/WithPreparation), `LinuxGuestBackend.activateWithPreparation`, `LocalServiceTool`, `EnvironmentLanguagePackageService` |
| Explicit download/update/start entry | Settings → Execution Environments gained a Linux runtime section that reuses the shared `LinuxImageInstallModel`/`LinuxImageInstallCard` job (one job per pinned image id), shows image/verification/update state, starts the first Linux environment, stops it, and reports the runner's network state. The per-environment screen keeps its existing controls. | `FloeApp/Settings/ExecutionEnvironmentView.swift`, `FloeApp/Terminal/LinuxImageInstallCard.swift`, `environment.backend.*` strings |
| Guest network, route and DNS on first boot | The guest runner (PID 1) configures `eth0` with the slirp address/route through ioctls, writes `/etc/resolv.conf` (slirp's own `10.0.2.3` alias first — the engine rewrites it to the host resolver, see [the network repair record](FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md) — then public fallbacks), writes `/etc/network/interfaces.d/eth0`, and runs a bounded DNS probe over that ordered list before answering capability negotiation. The answer carries `net=up|partial|down`; the host parses and surfaces it and never treats a missing field as ready. The qualification boot only reaches that state when the host attaches a network device (`floe_vm_host --net` / `FloeVMConfig.net_enable`), which the component workflow now asserts. | `FloeAgent/LinuxGuest/runner/floe_net.h`, `floe_exec.c` (`guest_bring_up_network`), `LinuxGuestService.swift` (`LinuxGuestNetworkStatus`), `LinuxGuestRegistry`/`LinuxGuestCommandChannel`, `docs/FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md` |
| 9p `ls -l` "Unknown error 524" | Root cause: the engine's 9p server answered the kernel's `xattrwalk` probe with `P9_ENOTSUP` (524); `ls -l` probes ACLs per file and printed one error per path while `stat`/`find`/`cat` worked. The server now answers a list request with an empty attribute list and a named attribute request with `ENODATA`. | `FloeAgent/ThirdParty/TinyEMU/Sources/FloeTinyEMU/engine/virtio.c` case 30 |
| Host UID ownership / git `dubious ownership` | The guest start writes a system `/etc/gitconfig` marking `/workspace`, `/workspace/*`, `/floe/env` and `/floe/env/*` safe, so an apt-installed guest git accepts the 9p-mounted host workspace whose files report the host user's uid. | `floe_net.h` (`floe_net_render_gitconfig`) |
| Disk/package persistence | Unchanged and confirmed: the per-environment disk clone persists apt/dpkg state; `/floe/env` is the persistent 9p layer. The guest start still records the network/safe-directory configuration there each boot. | `LinuxGuestRuntimeImagePreparer`, device log §9 |
| Service lifecycle honesty | Local services keep their durable job row (payload = the exact request), environment/task ownership, bounded log tail, stop/restart controls and restart replay. App relaunch marks them interrupted (`reconcileInterruptedOnLaunch`); the guest restart path reports the real process state instead of claiming liveness. | `BackgroundJobService`, `LocalServiceTool`, `Sources/FloeExecution/Linux/LinuxGuestLocalService.swift` |

Focused, network-free checks:

```bash
make -C FloeAgent/LinuxGuest/runner check-net     # rendered resolver/interfaces/git config + status vocabulary
make -C FloeAgent/LinuxGuest/runner host          # runner still builds for the developer host
bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
```

## 2. Native payloads stay out of the App

`python3 FloeAgent/scripts/audit_native_runtime_free.py --project` passes. The
audit now also fails on a `*.whl`/`wheelhouse` manifest reference, a bundled
precompiled wheel, and native Ruby or Rust runtime libraries in a built bundle.
WASM stays a separate compatibility route: the signed capability catalog and
`ThirdParty/PHPWASI`/WasmKit packages are untouched and are not App-bundled
language runtimes.

## 3. MLX fit and diagnostics

| Repair | Implementation |
| --- | --- |
| Distinguish corrupt snapshot from insufficient memory | `LocalModelSnapshotIntegrity` validates installed files before a load (pinned sizes, safetensors header, tensor extents, `config.json` model type). A deterministic problem raises `LocalInferenceError.corruptModelSnapshot` with the re-download instruction; a load that fails for allocation reasons raises `insufficientMemory`. `LocalModelLoadFailure.classify` is a pure, tested classifier. |
| Realistic memory budget including a running Linux guest | The Linux registry publishes its admitted guest RAM to `ResidentMemoryReservations` (FloeCore); `LocalInferenceResourcePolicy.canLoad`/`profile` subtract that reservation, so a model is refused instead of started on top of a guest whose pages the OS has not charged yet. The refusal message states the reserved bytes. |
| Largest nonviable default model removed | `gemma4-e4b-mlx4` (5.15 GB safetensors) moved from the selectable catalog to `retiredEntries`: it is no longer offered as a default/recommended download, but an existing download is still discovered and can be deleted explicitly — no user file is removed silently. The two Qwen 4-bit entries remain selectable. |
| No retry/crash loops | The runtime keeps one bounded recreate per load; the deterministic snapshot check now stops a damaged snapshot before any engine retry, and the preflight settle window still ends in a truthful refusal. |

## 4. IDE source control

`LocalGitService` posts `floeGitRepositoryDidChange` after every successful
mutation (init/stage/unstage/discard/commit/branch/merge/pull/fetch/push/abort),
and `SourceControlCenter` observes it, refreshing only when the changed tree
affects the active workspace. A repository created by the agent's `git.*` tool
(or by any host-side writer) therefore appears immediately with
status/stage/diff/commit support. Returning to the app re-reads the repository
so guest git changes made through 9p are picked up as well. Init failures keep
their existing visible error path.

## 5. Office routes and save behavior

- A workspace Office preview's header no longer routes into the IDE: the
  preview's primary action is the standalone full-screen editor
  (`file.preview.office.edit`), while only IDE file-tree opens use IDE embedded
  tabs. PDF keeps its IDE expansion entry.
- A tap on Edit that beats the standalone host's open no longer drops the
  intent: `executeEdit` opens the requested document and continues into edit.
- The editable open watchdog has a larger, documented budget (45 s) than the
  preview budget (30 s), because entering edit is a mode switch that a
  chart-heavy PPTX cold start can outlast.
- The standalone editor's back action now offers save / discard / cancel when
  the shared engine-modified check reports unsaved edits, instead of an implicit
  save; DOCX, XLSX and PPTX all go through the same bounded save service,
  Command-S shortcut and close decision.

## Remaining physical-device checks

1. Boot TinyEMU Linux on the iPad (fresh and upgraded disk) and confirm
   `ip -brief addr show eth0`, `ip route`, `cat /etc/resolv.conf`, then
   `apt-get update`, `pip install`, `npm install` without any manual network
   step; check the reported `net=` state in Settings.
2. Run `ls -l /workspace` and `git init`/`status` inside the guest against a
   host workspace, confirming no error 524 and no dubious-ownership refusal.
3. Start a local Node service, dismiss the UI, background/foreground the app,
   stop and restart the guest, then restart the service from Settings and
   confirm the reported state never claims a dead process is alive.
4. Open a PPTX from the workspace preview → Edit, save with Command-S and via
   the back save/discard/cancel prompt; repeat for DOCX/XLSX; verify the IDE
   file-tree open still embeds in an IDE tab.
5. Confirm a `git.init` from the agent appears immediately in an open
   source-control pane, and that the MLX refusal/corruption messages differ as
   designed on a real device memory profile.
