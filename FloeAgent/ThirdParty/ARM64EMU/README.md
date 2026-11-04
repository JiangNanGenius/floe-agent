# Floe ARM64 Linux engine

Pinned upstream: [`sylirre/arm64emu-system`](https://github.com/sylirre/arm64emu-system) at `55c8128cb02d8ba3809f6579f7c6d316537e0546`.

This stages Floe's A6 embedded checkpoint with the qualified A9 five-file slot optimization for the ARM64 transition. It interprets ARM64 guest code without native JIT or downloaded host code. Upstream source retains Apache-2.0 notices; Floe's embedding and translation-unit wrappers retain MPL-2.0 notices. `PROVENANCE.json` records the source digest and exact compiled units. `Source/NOTICE` also describes the device-tree data attribution.

The embedded ABI supports one live machine, a possible topology of 1–5 virtual CPUs, bounded console bytes, a caller-owned writable disk, stop/join/destruction and event-based parking. The host owns the worker lifetime. A successful create is not a Linux readiness receipt.

The version-2 ABI exposes contained live 9P share slots with synthetic guest ownership, NAT networking, loopback forwards and independent console geometry. Nine virtio consoles carry one supervisor and eight project channels. Each console applies bounded backpressure independently; CPU/RPC progress, host controls and socket readiness wake the event loop.

The combined source's 30 translation units and 23 exported operations compile and link on iOS device, iOS Simulator and macOS; the Swift 6 execution module also compiles to objects. Real Linux checks cover separate workspace/environment roots, a read-only shared ARM64 executable cache, loopback forwarding, process-tree cancellation, restart and overlay reset. The cache uses one trusted 9P mount with read-only project bind mounts. Full App cutover and acceptance remain pending; the completed ARM64 release will not retain a compatibility fallback. No general performance claim is made from these checks.

## 简体中文

此目录固定导入已经核对摘要的 A6 嵌入式源码，为 ARM64 切换准备。保留上游 Apache-2.0、自有桥接 MPL-2.0 和设备树数据的许可边界，不包含运行时宿主 JIT。

当前完成三套 Apple 目标的 C 对象编译、完整链接，以及 Swift 6 执行模块对象编译。真实 Linux 已检查项目与环境目录分离、只读共享 ARM64 二进制缓存、回环转发、进程树取消、重启和运行层重置；共享缓存由可信 supervisor 挂载一次，再只读接入各项目。主 App 切换及完整验收仍待完成。新版本只使用 ARM64，不保留 TinyEMU 兼容执行层；不以组件结果宣称整机性能。

The immutable CRC tables can be independently checked without modifying the header: `python3 Tools/generate_crc32_tables.py --check`. The generator is source tooling, not part of the App target.

可用 `python3 Tools/generate_crc32_tables.py --check` 独立只读核对 CRC 表；生成工具不进入 App 编译目标。
