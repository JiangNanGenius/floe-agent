# ARM64 runtime performance — current evidence / 当前证据

Reviewed / 核对日期: **2026-11-10**, main
`b0722808df5e006b5f035d4a2f43e2a8c1f3490e`.

This is the entry point for interpreting the dated ARM64 performance reports.
Keep the original measurements in those reports; a newer source revision is
not a new performance measurement. Release permissions are defined by the
current repository instructions, not historical report introductions.

本文是 ARM64 性能记录的当前入口。历史报告保留原始数据；源码更新不等于
获得新的性能实测。发布范围按现行仓库约定执行，不沿用历史报告的轮次授权。

## Measurement scopes / 指标口径

| Evidence / 证据 | Measurement / 测量 | Result / 结果 | Scope / 适用范围 |
| --- | --- | --- | --- |
| Build 317, physical M4 iPad | sysbench, 4 threads versus 1 | **1.46×** | Historical App result, before CPU-state separation; not the current multicore baseline |
| Build 319, physical M4 iPad | Same fixed sysbench fixture, 4 threads versus 1 | **2.31×** | Latest retained matched physical-iPad measurement in these reports |
| CPU-state separation, M5 Pro host | Fixed register workload, 4 workers versus 1 | **3.79×** | Native component workload; not Node.js, HTTP or physical iPad |
| Historical TinyEMU, Mac host | Fixed `dd` workload, 3 harts versus 1 | **2.689×** | Different emulator and workload; not comparable with iPad sysbench |

The threefold-or-better component scaling and the physical-iPad results are
different measurements. The earlier **1.46× must not be presented as the
current runtime's multicore performance**. The matched Build 319 iPad medians
are **127.49 / 232.76 / 294.24 events/s** at one/two/four threads;
`294.24 / 127.49 = 2.3079457`.

“三倍以上”的组件多核结果与 iPad 实测属于不同口径。**不能继续用旧的
1.46×概括当前运行时**；也不能把宿主组件的 3.79×写成 M1 iPad 网页或
Node.js 的提速。Build 319 的物理设备为 M4，尚无本轮 M1 网页访问实测。

## Retained implementation / 当前保留的实现

At the reviewed source, CPU-state cache-line separation is still present in
`FloeAgent/ThirdParty/ARM64EMU/Source/src/cpu.h`. The engine diff from frozen
Build 319 source `c0aea38a8beda63bb6dcca32f6b4a84fe5dc7663` changes only
`virtio_9p.c` and `PROVENANCE.json`; it does not remove or reimplement the
measured CPU-state separation. This source check establishes retention of the
optimization, not a fresh timing result for current main.

当前主线仍保留 CPU 状态缓存行隔离。相对冻结 319 来源的引擎改动仅在 9p
与来源清单；这证明该优化仍在，不能据此声称当前整个 App 已重新测得相同倍数。

Existing accepted work also includes optimized C compilation, operand
predecode/threaded dispatch, bound per-hart MMU banks, aligned-stack fast
paths, bounded 16K tickets and worker QoS inheritance. Do not propose enabling
these again as new gains. Rejected experiments include ThinLTO, the measured
forced-inline/hot-cold fetch variant, and the SHA-helper variant that regressed
the real Linux workloads. General hart padding rejected in an earlier
experiment is distinct from the later accepted CPU-state separation.

Earlier `platform.c` instruction-count I/O throttling is not evidence of a
fixed wait in the App: `floe_ae_run_slice` uses the parallel runtime for every
CPU count, and its coordinator clears `io_poll_due` before ticking devices.
Network readiness already wakes the runtime.

## Evidence / 原始报告

- [CPU-state separation, component and delivered Build 319 measurements](ARM64_CPU_STATE_ISOLATION_20261106.md)
- [Builds 315–317 interpreter and scheduler history](ARM64_PARALLEL_PERFORMANCE_20261106.md)
- [Earlier bounded scheduler qualification](ARM64_PARALLEL_PERFORMANCE_20261105.md)

For the reported M1 Node.js page delay, compare already-running guest-local
HTTP requests with forwarded requests, recording first-byte and full-body
times for a small fixed response, a large uncompressed file and the real page.
Separate request work, compression/file access and transport before attributing
the delay to multicore scaling. The M5 Pro native-component candidate has now
been measured with real Linux/Node after the fairness/tail repairs: 8 MiB
median 1.800 s → 0.815 s and guest instructions per MiB 15.124 M → 7.238 M.
Small requests are broadly unchanged; 9/10 concurrent small requests completed
while bulk was active, and a second IPv6 run passed with 7/8. Queue/reset and
protocol component checks pass. Full network App integration remains pending;
the independent SDK privacy resource has been read back from the main App. See the [network plan and current
measurements](FLOE_VIRTUAL_NETWORK_ENHANCEMENT_PLAN_20261110.zh-CN.md).
Physical M1 page timing and its reported one-minute delay remain unverified.

## 2026-11-22 稳定性复查 / Stability pass

基线为 `5911ee356`。Xcode 27.2（27B52）在同一台 M5 Pro Mac 上编译
ARM64 解释引擎，两边启动同一份 Debian 资格镜像。虚拟盘保留原有的同步
和完成语义，把分散的客体 RAM 数据合成最多 64 KiB 的宿主 I/O。一次 128
KiB、32 个离散页的真实 virtio 请求中，`pread` 和 `pwrite` 均从 32 次降为
2 次。写入完成、`fsync`、客体直接回读和字节比对均通过。

9P 描述符改为一次读取 16 字节，并校核队列游标、描述符方向和消息容量。
取指快路径直接核对当前缓存槽的物理页、写入版本和清除代数。写入 D-TLB
命中时，内存锁和写入通知复用同一个物理地址。原有的中断、快照失效和
指令权限检查仍在同一路径。CPU/IRQ 组件测试与带 ASan/UBSan 的 9P 协议
测试通过。此次修改沿用现有的无 JIT 解释器和 ABI。

| 双 vCPU Debian 负载 | 首轮基线 → 候选 | 交换顺序后基线 → 候选 |
| --- | ---: | ---: |
| 虚拟盘直接读 64 MiB | 3.117 → 0.155 s | 0.209 → 0.203 s |
| 9P 共享读 64 MiB | 6.153 → 5.135 s | 5.795 → 5.885 s |
| Python 整数循环 | 5.343 → 5.361 s | 5.370 → 5.321 s |
| zlib 解压工作负载 | 4.542 → 4.413 s | 4.521 → 4.534 s |

每格为三次中位数。直接读的单次结果随运行轮次明显变化。只替换 9P 实现的
单 vCPU 对照中，800 个小文件的中位数为 3.385 → 3.342 秒（五次），
共享读 64 MiB 为 3.404 → 3.364 秒（三次）。小文件合并摘要一致。
关闭联网，用同一份
14,010,719 字节的 NumPy 2.2.6 ARM64 wheel 安装到客体临时目录，一次对照为
32.887 → 31.154 秒，两侧均成功导入并计算出 `49995000`。安装计时覆盖本地
wheel 与客体安装阶段。下载、索引查询、首次环境准备和真实 iPad 底层盘的结果
需各自测量。

单次从 9P 读入再写盘同步的对照为 0.558 → 0.828 秒。将相同的 8 MiB
输入先放进客体内存，再隔离做五次直接写入和 `fsync`，中位数为
0.144 → 0.138 秒。全部回读摘要一致。

iPhoneOS 的四个受影响编译单元通过对象编译。完整 App 在已有 iPad 模拟器
编译并通过 CAD 跟踪点缩放和户型画墙平移两项回归。上传元数据、原生运行时
排除检查、依赖固定和双语目录通过源码校核。
