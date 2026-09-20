# TinyEMU (pinned 2019-12-21) — Floe embeddable RISC-V engine

English | [中文](#中文说明)

## What this is

TinyEMU is Fabrice Bellard's small, MIT-licensed RISC-V full-system
emulator (pure interpreter, no JIT). Floe uses it as the candidate engine
for a complete local Linux environment: standard virtio console, virtio-blk
disk, virtio-9p host shares, and slirp user-mode networking. This directory
contains Floe's integration assets only — the upstream source itself is
fetched and hash-verified by `fetch_source.sh` (see `PROVENANCE.json`).

- Engine license: MIT core + 2-clause BSD slirp (+ public-domain hashing
  files on the disabled path). **No GPL/LGPL**; not derived from QEMU or
  iSH. Full per-file inventory: `LICENSE-INVENTORY.md`.
- Host GPL gate: `license_check.sh` (runs in qualification CI).
- Guest images (Linux kernel, Debian userland) are separate works with
  their own licenses — see the "Guest-side GPL separation" section of
  `LICENSE-INVENTORY.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `PROVENANCE.json` | pinned URLs + SHA256 + trim list |
| `fetch_source.sh` | pinned download + hash verify (`--check` is read-only) |
| `LICENSE-INVENTORY.md` | per-file license inventory |
| `license_check.sh` | GPL gate over the exact build sources |
| `patches/0001-htif-poweroff-callback.patch` | guest poweroff becomes an observable flag instead of `exit(0)` |
| `adapter/floe_vm.h` / `floe_vm.c` | embeddable C API: VM create / run slice / console bytes in+out / disk / 9p / slirp net / stop+destroy |
| `adapter/Makefile` | builds `libfloevm.a` (+ `floe_vm_host` when `HOST_DIR` is set); `MACOS=1` adds local shim headers |
| `adapter/macos/` | macOS-only build shims (byteswap/statfs/if_tun); Linux needs none |

## Embeddable C API (stable surface for the app integration)

```c
FloeVM *floe_vm_create(const FloeVMConfig *, FloeVMConsoleOutFn, void *);
int     floe_vm_console_input(FloeVM *, const uint8_t *, int); /* guest stdin */
int     floe_vm_run_slice(FloeVM *, int timeout_ms);           /* 0 / 1=poweroff / <0 error */
int     floe_vm_poweroff_requested(const FloeVM *);
void    floe_vm_destroy(FloeVM *);
```

Config covers: RAM, BIOS (bbl) + kernel + initrd paths, kernel cmdline,
one virtio-blk raw image (snapshot or write-through), up to 4 virtio-9p
shares (tag → host dir), slirp networking on/off. Console output arrives
via callback inside `run_slice`; console input is queued thread-safely.

The qualification host + scripts + measured results live in
`FloeAgent/Qualification/TinyEMULinux/`.

## 中文说明

TinyEMU 是 Fabrice Bellard 的 MIT 许可 RISC-V 全系统模拟器（纯解释执行，
无 JIT）。Floe 将其作为“完整本地 Linux 运行环境”的候选引擎：标准
virtio 控制台、virtio-blk 磁盘、virtio-9p 宿主共享目录与 slirp 用户态
网络。本目录只包含 Floe 的集成资产，上游源码由 `fetch_source.sh`
按固定 URL+SHA256 拉取校验（见 `PROVENANCE.json`）。

- 引擎许可证：核心 MIT + slirp 二条款 BSD（已禁用路径上另有公有领域
  散列文件）。**不含 GPL/LGPL**，不源自 QEMU 或 iSH。逐文件清单见
  `LICENSE-INVENTORY.md`。
- 宿主 GPL 门禁：`license_check.sh`（资格 CI 中执行）。
- 客户机镜像（Linux 内核、Debian 用户态）是独立作品，适用其自身许可
  与源码提供义务，不由引擎的 MIT 覆盖。
- 嵌入 API：`floe_vm_create / floe_vm_run_slice / floe_vm_console_input /
  floe_vm_poweroff_requested / floe_vm_destroy`；配置含内存、BIOS/内核/
  initrd、cmdline、virtio-blk 磁盘（快照或写透）、至多 4 个 9p 共享、
  slirp 网络开关。控制台输出经回调返回，输入线程安全排队。
- 资格宿主与实测结果见 `FloeAgent/Qualification/TinyEMULinux/`。
