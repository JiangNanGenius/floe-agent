# Floe ARM64 Linux engine

Pinned upstream: [`sylirre/arm64emu-system`](https://github.com/sylirre/arm64emu-system) at `55c8128cb02d8ba3809f6579f7c6d316537e0546`.

This stages Floe's A6 embedded checkpoint for the ARM64 transition. It interprets ARM64 guest code without native JIT or downloaded host code. Upstream source retains Apache-2.0 notices; Floe's embedding and translation-unit wrappers retain MPL-2.0 notices. `PROVENANCE.json` records the source digest and exact compiled units. `Source/NOTICE` also describes the device-tree data attribution.

The embedded ABI supports one live machine, a possible topology of 1–5 virtual CPUs, bounded console bytes, a caller-owned writable disk, stop/join/destruction and event-based parking. The host owns the worker lifetime. A successful create is not a Linux readiness receipt.

The version-2 ABI now exposes contained 9P shares, NAT networking, loopback forwards and independent console geometry. Its 30 translation units and 18 exported operations compile and link on iOS device, iOS Simulator and macOS. Four focused native components pass. Live-share mutation, socket-ready parking and saturated-console flow control remain integration work; real Linux I/O and production App acceptance are still pending. The previous backend remains selected during integration; no compatibility fallback is intended in the completed ARM64 release.

The same A6 source passed Mac component, concurrency and real Linux checks in the research stage. Its host-parallel heavy-workload measurements remained slower than the serial ARM64 reference. These are not iOS App, physical iPad, general performance or package-compatibility claims. iOS compilation and actual guest-service acceptance are separate integration steps.

## 简体中文

此目录固定导入已经核对摘要的 A6 嵌入式源码，为 ARM64 切换准备。保留上游 Apache-2.0、自有桥接 MPL-2.0 和设备树数据的许可边界，不包含运行时宿主 JIT。

当前仅接入组件，尚未切换主 App。网络、受限文件共享和终端尺寸已接入 C ABI，并通过三套 Apple 目标的对象编译和完整链接。动态共享、网络事件等待、独立终端背压及生产项目隔离仍在集成；尚未完成真实客体 I/O、App 或真机验收。完成后新版本只使用 ARM64，不保留 TinyEMU 兼容执行层。
