# Phase 2 — TinyEMU migration: execution routing and grant contract

Status: **migration worker contract, published before implementation completes.**
Date: 2026-09-21. Base: `46422286` (post Build211). Worktree: `codex/tinyemu-phase2-migration`.

This page is the cross-worker contract for removing the bundled native
CPython/Node runtimes and routing every execution caller to the TinyEMU Linux
guest. It records the routing table, the isolation/grant rules the migration
preserves, and the interfaces this worker consumes from the engine worker
(job-d629b6b710b448c5, branch `tinyemu-phase2-engine`) and the Notes/assistant
worker (job-fe5e238cb87140e8). Dated build evidence and the final SHA list land
in the report section at the bottom when the implementation commits.

中文摘要见文末。

## 1. What leaves the IPA

The next IPA contains **no** native Python/Node payload:

- `Vendor/Python.xcframework`, `Vendor/PythonExtensions/*.xcframework`
  (stdlib + pandas/numpy/lxml/Pillow wheels), `Vendor/NodeMobile/NodeMobile.xcframework`
  — all embed/link entries removed from `FloeAgent/project.yml`.
- `FloeApp/Resources/python`, `FloeApp/Resources/NodeTools`,
  `FloeApp/Resources/PythonServiceBootstrap.py` — removed from resources.
- `FloeCPythonBridge.{h,m}` / `FloeNodeBridge.{h,mm}` and their Swift owners
  (`CPythonLocalRuntime`, `IOSSystemNodeRuntime`) — removed from the app target.
- `managed_package_install.py` / `managed_package_remove.py` — removed from the
  `FloeExecution` SwiftPM resources (they ran only inside the bundled
  interpreter). `deb_extract.py` stays: it serves the reviewed host-side
  data-only `dpkg-deb` path, which is unchanged.

Source/build recipes (bootstrap scripts, ios-wheelhouse, Node tools pins,
bridges) are **archived recoverably** under
`FloeAgent/ThirdParty/NativeRuntimeArchive/` with a README; nothing is deleted
from history. Old on-device installs (`usr/lib/node_modules`,
`usr/lib/floe-python/site-packages` inside existing environment layers) are
user data and are **not erased**; the Node prefix is the same path the guest
exports as `/floe/env/usr`, so those modules are visible again once the
environment runs on Linux. Legacy Python installs are **not** placed on the
guest `PYTHONPATH` (see §3.2): they stay on disk untouched, and the recorded
layer manifest is the reinstall source for guest-compatible packages.

## 2. Routing table (final state)

| Caller | Before | After |
| --- | --- | --- |
| `exec.localPython` (name kept) | bundled CPython in-process | guest shared venv `python3 -c` via `TinyEMULinuxCommandService`; non-Linux environment → honest failure naming the Linux backend switch |
| `exec.shell` one-shot + `shell.*` sessions | ios_system dash | unchanged for `native` environments; `linuxVM` environments already route through `RoutingLocalShellBackend` → `LinuxGuestShellBackend` |
| `exec.localService` (name kept) | NodeMobile/CPython in-process workers | guest detached process + 9p log + slirp loopback forward (`LinuxGuestLocalServiceControlling`); native branch removed |
| shell `python3`/`python` | Floe replacement command → bundled CPython | same command names → the task environment's guest interpreter (same venv/cwd/files as `exec.localPython`); native environment → truthful "requires the Linux backend" exit 127 |
| shell `pip`/`pip3` | managed native installer | `LinuxGuestLanguagePackages.pythonInstall/Uninstall/Inspect` (real venv pip, riscv64 wheels allowed); native → truthful failure |
| shell `node`/`npm`/`npx`/`pnpm`/`pnpx`/`yarn` | NodeMobile + bundled npm/pnpm/yarn JS | guest `node`/`npm` via `LinuxGuestNodeProvisioner` (environment prefix `/floe/env/usr`); native → truthful failure |
| `python.packages` / package UI | managed native installer + layer scan | guest pip/npm for Linux environments; native environments keep read-only inventory of preserved installs and report that mutation requires the Linux backend |
| `apt`/`apt-get`/`dpkg` family | guest forwarding (already) + host data-only dpkg | unchanged: apt family = standard Linux installer inside the guest only; reviewed host data-only `dpkg-deb` stays for native environments; WASM/pip/npm never resolve through apt |
| workspace.archive compressed formats | bundled CPython script | guest Python through the same fixed audited script, routed with the task's environment |
| skills (`scriptRuntime: localPython`) | bundled CPython | same guest route as `exec.localPython`; skill pre-approval digests unchanged |
| WASM (`wasm.*`, `floe-lua`…) | WasmKit signed catalog | unchanged; separate compatibility path, not Python/Node |

There is **no silent native fallback**: when the selected environment is not a
running Linux guest, every Python/Node entry point fails with the explicit
reason (install the Linux component / start the environment / switch backend).

## 3. Backend migration (existing installs included)

**3.1 Metadata migration.** Linux is the main execution path for the next
version, including existing chats. On first launch (registry `prepare`), every
environment record whose backend was never explicitly chosen
(`executionBackend == nil`, the legacy default) is migrated to `.linuxVM` in
place: the record ID, ownership, layer data, packages and manifests are
untouched — only the backend field changes. The registry file is backed up to
`registry.json.pre-linux-migration` before the first write, so the change is
recoverable. A record whose backend was **explicitly** set to `.native`
(`floe-env backend <id> native` or the settings picker) is an intentional
compatibility choice and stays native; `native` remains selectable afterwards
and keeps the ios_system shell plus the reviewed host-side data-only package
operations, with Python/Node truthfully unavailable there. New records default
to `.linuxVM`.

**3.2 Legacy language packages.** A migrated environment keeps its layer bytes.
Guest Node resolves the same `usr/lib/node_modules` prefix, so preserved Node
modules work. Legacy Python installs were pure-Python-only by construction,
but the guest must **not** put the whole legacy `site-packages` on
`PYTHONPATH`: version/shadowing and any stray extension module would silently
override Linux wheels. Instead the layer manifest's recorded Python
distributions are reinstalled into the guest venv (`name==version`, guest pip,
recoverable, failure surfaces honestly and never deletes the legacy copy).

## 3.3 Confinement honesty

The host side declares each environment's 9p share list and maps paths through
`LinuxGuestPathMap`; that alone is **not** the containment proof. Actual
filesystem confinement is enforced by the engine's guest 9p server, which must
reject `..` walks and symlink escapes outside the exported roots (tracked as
an engine integration dependency in §7). The migration layer additionally
never hands the guest an unmapped host path: values that do not resolve
through the path map are dropped, not forwarded verbatim.

## 4. Grant and isolation contract (coordinator boundary requirement)

Auto-approval must not let an arbitrary guest script reach other tasks' files.
The migration keeps and makes explicit these confinement rules:

1. **Mount confinement is the isolation boundary.** A guest only ever sees the
   declared virtio-9p shares of its own environment descriptor: the
   environment layer (`floe-env` → `/floe/env`) and that environment's
   workspace root (`workspace` → `/workspace`). Session environments are owned
   by one conversation; project environments by one workspace. A task's
   Python/Node/shell/service code therefore cannot name another task's files:
   no host path outside the declared shares is exported or mapped, and the
   guest runner receives guest paths only. Task IDs/path conventions are *not*
   the isolation mechanism — the share list plus the engine's 9p server
   walk/symlink checks are (§3.3, §7).
2. **Constrained context, not blanket grants.** Every execution entry point
   carries the task's explicit `ToolContext` (run ID, conversation, workspace
   root, environment ID). `EnvironmentExecutionCoordinator` rejects an
   environment that belongs to another conversation/workspace. The Notes
   assistant worker consumes this same contract: guest work for a Notes task
   runs in that task's own session environment and workspace share, never in a
   shared " Notes-wide" interpreter.
3. **Approval policy unchanged in shape.** `exec.localPython` non-install
   scripts stay auto-approvable *because* the script is confined to the task's
   own guest mounts (same authority as `exec.shell` today). Package installs
   (`packages`/`pipCommand`, `pip install` in the shell, npm/pnpm changes)
   keep the existing review path (`isSoftwareInstallRequest`, managed-package
   purpose review). Removing the in-process interpreter does **not** widen any
   grant, and this migration adds no new auto-approved capability.
4. **Services.** `exec.localService` binds loopback only; the guest port is
   published through slirp host forwarding on `127.0.0.1` with the job-scoped
   ownership loop (cancel → real guest KILL, never a fake kill thread). The
   native worker/service code paths are removed, so no in-process service can
   outlive its gate.
5. **Downloads.** The Linux guest image is an explicit, user-visible
   downloadable component: pinned catalog entry, SHA-512 verified artifacts,
   resumable/cancellable download with persisted state
   (`LinuxGuestImageInstallationService`), truthful unavailable state in
   Settings and in every execution error message until installed.

## 5. Cross-worker interfaces

**Consumed from the engine worker (this commit, `Sources/FloeExecution/Linux`
+ `ThirdParty/TinyEMU` + `LinuxGuest/` are engine-owned; this worker does not
edit them):**

- `TinyEMULinuxCommandService` (`LinuxCommandRunning`, `LinuxGuestControlling`,
  `LinuxGuestLocalServiceControlling`, `LinuxGuestPathMapping`).
- `LinuxGuestPythonProvisioner` / `LinuxGuestNodeProvisioner`,
  `LinuxGuestLanguagePackages`, `LinuxGuestLocalServiceSupervisor` models,
  `LinuxGuestImageInstallationService`, `LinuxGuestImageDistributionCatalog`.
- Integration requests raised to the engine worker (tracked in §7): engine-side
  confirmation that the guest 9p server rejects `..`/symlink escapes outside
  the exported share roots (the containment proof behind §4.1). No guest
  `PYTHONPATH` change is requested: legacy Python reinstalls go through guest
  pip from the layer manifest instead (§3.2).

**Provided to the app/Notes workers:**

- `LocalPythonService` keeps its name and `ScriptExecutionService` surface;
  its runner is always the guest router (no environment → honest
  unavailable). `LocalPythonCapabilityProbe` reports the Linux-backed
  capability honestly (image installed + backend present), and
  `runtimeManifest()` live-probes a running guest when one exists, otherwise
  returns the static "runs inside the per-environment Linux guest" statement.
- `ManagedPythonInstallService` keeps `install/uninstall/inspect/recover/
  installedDistributions/isLinuxGuestEnvironment`; all mutation paths require
  a Linux-owned environment.
- `exec.localPython`, `exec.localService`, `exec.shell`, `pip`, `node`, `npm`
  names and schemas are unchanged for skills and saved content.

## 6. IPA audit (anti-regression)

`FloeAgent/scripts/audit_native_runtime_free.py` is a lean post-build audit:
given a `.app` or `.ipa`, it fails if any native Python/Node marker is present
(Python/NodeMobile frameworks, `*.cpython-*` extension frameworks, Python
stdlib trees, `NodeTools`, `PythonServiceBootstrap.py`), and a `--project`
mode lints `project.yml`/`Package.swift` so a reintroduction fails in CI
without a device build. It is wired into `release_preflight.sh` and the
release workflows' verification steps (no release is started by this worker).

## 7. Open integration dependencies

- Engine worker: 9p server walk/symlink escape enforcement proof (§3.3/§4.1);
  single-guest-at-a-time and PTY resize semantics stay as documented in
  `LinuxGuestService.swift`.
- Notes/assistant worker: consume the §4 contract (per-task session
  environment + workspace share) for Notes guest work; no shared interpreter
  across documents.
- Release coordinator: cloud compile + archive of this branch, then the
  `audit_native_runtime_free.py` gate on the produced IPA. Swift 6 concurrency
  changes here are verified by that cloud build (local `-typecheck` alone is
  not accepted as proof).

---

## 中文摘要

本次迁移把 App 内的本地 Python/Node 全部改为在 TinyEMU Linux 客体中运行：
IPA 不再包含 Python.xcframework、PythonExtensions、NodeMobile、Python 标准库
或 NodeTools 资源；原生构建配方归档在 `ThirdParty/NativeRuntimeArchive/` 可恢复。
`exec.localPython`、`exec.localService`、`exec.shell` 及 `pip`/`node`/`npm`
等名称保持不变，按任务环境路由到该环境的 Linux 客体；未安装组件或客体未
运行时给出真实不可用原因，不做静默原生回退。现有环境在首次启动时做可恢复
的元数据迁移（仅改 backend 字段，保留环境 ID 与全部数据；显式选择 native
兼容后端的记录除外），新环境默认 Linux。隔离边界是每个环境显式声明的 9p
共享（环境层 + 当前任务工作区）加上引擎侧 9p 服务器对越界/符号链接的拒绝，
不是任务 ID 或路径约定：自动批准的客体脚本无法访问其他任务的文件；软件包
安装仍走原有审核。旧 Python 安装不进入客体 PYTHONPATH（避免版本遮蔽与
ABI 不兼容），数据保留在原地，按层清单用客体 pip 重装兼容版本。Linux 镜像
是用户可见的可下载组件，带 SHA-512 校验、可取消续传和真实状态展示。新增
`audit_native_runtime_free.py` 在 IPA 与 project.yml 两个层面阻止原生
Python/Node 重新引入。
