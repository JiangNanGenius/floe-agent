# ARM64 scheduling qualification — 2026-11-05

## 简体中文

315 的调度改动限定在 `parallel_runtime.c`：合并已经撤销的重复 IRQ
通知，把每次有界执行批次由 4096 提高到 16384 条指令。所有核心数量
使用同一上限，不通过放慢单核来放大多核比值。小预算仍按可运行核心
分配；逐条指令的停止、IRQ、TLB 检查、同步设备请求及原有内存保护保留。

M5 Pro 上使用同一份既有 public-ABI 客户端对象、固件、Linux 内核、
initrd、512 MiB 内存、两个在线 CPU 和固定 affinity 完成了一组配对。
工作量和结果断言未修改：

| Linux 负载 | 原实现 | 候选实现 | 吞吐比 |
| --- | ---: | ---: | ---: |
| PBKDF2，16 次固定迭代计算 | 20.011 s | 18.519 s | 1.081× |
| 128 次固定数据压缩、解压和校验 | 32.885 s | 29.344 s | 1.121× |

另有每个核心数三次、交错顺序的固定指令计算组件检查。它用于定位
线程交接开销，不代替真实 Linux、App 或物理 iPad 性能结果。
本次 Linux 配对只有一组，不据此作普遍性能承诺或宣称四核达到 3.5×。

正常构建及 ThreadSanitizer 检查覆盖真实 worker、停止/销毁、热插拔、
IRQ/事件、TLB 同步和精确的 100 ms／1024 指令预算边界。原预算、超时
和断言保留。新 IRQ 回归直接检查真实四核 session 的 readiness pipe；
原实现会触发重复空通知断言，修复后通过。新测试入口为
`FloeAgent/Qualification/ARM64Parallel/IRQPublicationTests.c`。

这批记录属于原生组件及实际 Linux 客体证据。集成后的完整 App 编译、
模拟器行为和新构建分发另行记录；不能沿用 314 的真机结果冒充 315。

## English

The bounded scheduling change coalesces already-deasserted IRQ publications
and uses the same 16K instruction-ticket ceiling on all CPU topologies.
Small-budget fairness, instruction-boundary cancellation/interrupt/TLB checks,
synchronous device RPCs and memory synchronization remain intact.

One matched real-Linux pair on the M5 Pro used the same existing public-ABI
client object, boot inputs, memory, two online CPUs, affinity, fixed work and
result assertions. PBKDF2 took 20.011/18.519 seconds; compression, decompression
and verification took 32.885/29.344 seconds, respectively. This is preliminary
component evidence, not an iPad result, a universal speed claim or proof of
3.5× four-core scaling. Normal and ThreadSanitizer regressions passed with the
original concurrency, lifecycle and exact-budget assertions. Full-App and
distribution qualification are recorded separately.

## Integrated App checks / 集成 App 检查

Xcode 27.1 (27A9275), Swift 6 completed the full simulator App and test-host
object compilation and linking at `10f5fc5e88a2ad73a707a6eaede3fab47b7fe077`.
On the existing canonical iPad simulator, the unchanged asymmetric Office
pixel regression failed before the rendering fix and passed afterward,
covering both a whole page and an offset crop. The actual shared-directory
preflight also passed: Python used `/floe/env/tmp` and completed symlink and
nested-directory cleanup without falling back to another temporary directory.
Nineteen native 9P protocol checks cover the corresponding Linux-to-Darwin
directory-removal flag conversion and retained read-only/containment behavior.

完整 EDA 技能回归曾在临时目录清理处失败，原始失败保留。上述实际 App
共享目录预检是修复后的局部验证，不代替完整 EDA 技能资格；本记录不宣称
该技能已通过完整回归。315 的物理 iPad 性能对照与分发状态另行记录。
