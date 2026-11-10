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
