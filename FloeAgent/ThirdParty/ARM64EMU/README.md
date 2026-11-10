# Floe ARM64 Linux engine

Pinned upstream: [`sylirre/arm64emu-system`](https://github.com/sylirre/arm64emu-system) at `55c8128cb02d8ba3809f6579f7c6d316537e0546`.

Floe embeds an ARM64 interpreter without host JIT or downloaded native host code. Upstream source retains Apache-2.0 notices; Floe's bridge and translation-unit wrappers retain MPL-2.0 notices. `PROVENANCE.json` records source digests and the exact 30 compiled units. `Source/NOTICE` includes device-tree attribution. The earlier A6/A9 staging descriptions are historical; ARM64 is the App's existing Linux execution path.

The version-2 public ABI supports one live machine, 1–5 virtual CPUs, bounded console buffers, a caller-owned writable disk, event-based parking and explicit stop/join/destruction. The host owns worker lifetime. Per-CPU state isolation, MMU state and execution tickets remain intact. Successful creation is separate from Linux or service readiness.

Contained live 9P shares retain synthetic guest ownership. Nine virtio consoles provide one supervisor and eight project channels with independent backpressure. Environment/project roots, shared read-only executable caches and cancellation follow the existing runtime ownership rules.

The virtual NIC uses the pinned FloeSlirp static dependency for IPv4/IPv6, TCP/UDP, resolver and loopback forwarding. The device negotiates checksum and TCP segmentation capabilities; RX GSO is disabled in the measured shipping profile. Ethernet delivery, socket interests, deadlines and buffer limits remain coordinator-owned. No TAP, VPN entitlement, host process helper or dynamic networking plugin is required. See `../../Vendor/FloeSlirp/README.md` for licenses, rebuilds and relinking. `PrivacyInfo.xcprivacy` is copied into the source SDK's Swift Package resource bundle.

Actual macOS, iOS device and Simulator object/link checks, protocol/queue tests and real Linux/Node measurements are recorded separately from full App, Simulator and physical-device acceptance. Current evidence and limitations are in [`docs/ARM64_RUNTIME_PERFORMANCE.md`](../../../docs/ARM64_RUNTIME_PERFORMANCE.md) and [`docs/FLOE_VIRTUAL_NETWORK_ENHANCEMENT_PLAN_20261110.zh-CN.md`](../../../docs/FLOE_VIRTUAL_NETWORK_ENHANCEMENT_PLAN_20261110.zh-CN.md). Component results do not prove M1 page latency or Apple review acceptance.

CRC tables can be checked read-only: `python3 Tools/generate_crc32_tables.py --check`. The generator is source tooling and is not compiled into the App.

## 简体中文

本目录是 App 现有 ARM64 Linux 解释执行引擎，不使用宿主 JIT。保留上游 Apache-2.0、自有桥接 MPL-2.0 及设备树归属；`PROVENANCE.json` 固定源码摘要和 30 个编译单元。旧 A6/A9 准备阶段说明不再代表当前接入状态。

公共 ABI 保持版本 2；实例、CPU worker、目录共享、控制台背压和销毁沿用现有生命周期。网络采用固定版本 FloeSlirp 及有界设备队列，按实际协商执行 checksum/TSO，测量选用 RX GSO 关闭配置。SDK 隐私清单由 Swift Package 资源包携带。完整许可、对应源码和重链接方法见依赖 README。

对象编译、组件协议检查、真实 Linux/Node、完整 App/Simulator、物理 M1 与 Apple 审核分别记录。不得以组件结果或历史多核指标推断当前 M1 网页表现。CRC 只读核对命令不会修改源码。
