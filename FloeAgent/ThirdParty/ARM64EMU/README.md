# Floe ARM64 Linux engine

Pinned upstream: [`sylirre/arm64emu-system`](https://github.com/sylirre/arm64emu-system) at `55c8128cb02d8ba3809f6579f7c6d316537e0546`.

This stages Floe's A6 embedded checkpoint with the qualified A9 five-file slot optimization for the ARM64 transition. It interprets ARM64 guest code without native JIT or downloaded host code. Upstream source retains Apache-2.0 notices; Floe's embedding and translation-unit wrappers retain MPL-2.0 notices. `PROVENANCE.json` records the source digest and exact compiled units. `Source/NOTICE` also describes the device-tree data attribution.

The embedded ABI supports one live machine, a possible topology of 1–5 virtual CPUs, bounded console bytes, a caller-owned writable disk, stop/join/destruction and event-based parking. The host owns the worker lifetime. A successful create is not a Linux readiness receipt.

The version-2 ABI exposes contained live 9P share slots with synthetic guest ownership, NAT networking, loopback forwards and independent console geometry. Nine virtio consoles carry one supervisor and eight project channels. Each console applies bounded backpressure independently; CPU/RPC progress, host controls and socket readiness wake the event loop.

The combined source's 30 translation units and 21 exported operations compile and link on iOS device, iOS Simulator and macOS. Guest boot and component checks do not prove the complete App path. Production remains on the previous backend until resident-project storage and App acceptance finish; the completed ARM64 release will not retain a compatibility fallback. No general performance claim is made from component or prior research measurements.

## 简体中文

此目录固定导入已经核对摘要的 A6 嵌入式源码，为 ARM64 切换准备。保留上游 Apache-2.0、自有桥接 MPL-2.0 和设备树数据的许可边界，不包含运行时宿主 JIT。

当前完成 C 组件的集成与三套 Apple 目标的对象编译、完整链接，主 App 尚未切换。固定共享槽位、动态挂接、网络事件等待和独立终端背压已接入；真实客体已启动至 supervisor，项目隔离、存储及完整 App 仍待验收。完成后的新版本只使用 ARM64，不保留 TinyEMU 兼容执行层；不以组件结果宣称整机性能。

The immutable CRC tables can be independently checked without modifying the header: `python3 Tools/generate_crc32_tables.py --check`. The generator is source tooling, not part of the App target.

可用 `python3 Tools/generate_crc32_tables.py --check` 独立只读核对 CRC 表；生成工具不进入 App 编译目标。
