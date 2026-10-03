# Floe 1.7.0 (223) — TinyEMU Runtime v2 与专项修复 / TinyEMU Runtime v2 and focused repairs

Status: release recovery candidate. This document describes the Build 223 source candidate.
Cloud build, TestFlight upload, Apple processing, Floe QA availability,
GitHub prerelease publication and physical-device acceptance are recorded only
after each result is obtained.

## 简体中文

Build 223 将本地 Linux 从“会话拥有一份完整运行盘”升级为持久 Environment 与
临时 VM 分离的 Runtime v2：基础镜像按内容寻址并全局共享；每个 Environment 只
保存 64 KiB 块级 CoW 差异、独立数据、服务和端口状态；Workspace、缓存、下载、
恢复点和 VM 临时目录分别归属。旧镜像和旧环境通过 staging、摘要校验和原子引用
切换迁移，同 ID 不同摘要不会覆盖。启动前会创建缺失的 9P 宿主目录，安装状态由
已验证镜像、差异层和启动探针共同判断。

运行时最多并行四台 TinyEMU VM；同一 Environment 只允许一个可写租约，第五个
环境进入可取消队列。动态内存池在 12 GiB 及以上设备使用 2 GiB，否则使用
1.5 GiB；单 VM 采用 256/512/768/1024 MiB 档位。当前 TinyEMU 不安全支持在线
balloon 时，内存档位通过安全停止、flush 和重启生效。Linux 与 MLX 本地模型通过
同一重型资源仲裁器互斥，本地模型空闲两分钟自动卸载，工具续轮期间保持驻留。

本轮同时修复本地模型工具调用闪退与第二、第三轮工具续接；Linux 下载、后台 PiP、
端口转发和任务系统通知沿用统一服务。PPT/PPTX 的打开流程增加真实的有界状态：
宿主没有回报可见首帧时不再永久转圈，保留已挂载引擎和编辑副本，显示可重试、可
恢复、可关闭的提示；手记草稿准备失败也会明确提示并可重试。DOCX/XLSX 产品流程
未重构。

源码验证包括 `FloeExecution` 的 Swift 6 对象编译，以及 PPT 打开策略的 7 项定向
测试。真实 iPad 上的 PPT 首帧、PiP、后台存活、端口访问、旧镜像迁移和多 VM 压力
仍由 TestFlight 真机验收。

## English

Build 223 separates persistent Linux environments from temporary TinyEMU VM
instances. A content-addressed base image is stored once; each environment owns
only its 64 KiB block CoW delta, data, service and port state. Workspaces,
shared download caches, recovery data and disposable VM directories have
separate ownership. Legacy images and environments migrate through staging,
digest verification and an atomic registry switch; an image with the same ID
but a different digest is never overwritten. Missing 9P host directories are
created before boot, and install state is derived from the verified image,
delta and boot probe.

The pool runs at most four VMs and grants one writable lease per environment;
a fifth environment waits in a cancellable queue. Devices with at least 12 GiB
of physical memory use a 2 GiB pool, other devices use 1.5 GiB, with
256/512/768/1024 MiB VM tiers. Where safe online ballooning is unavailable, a
tier change uses stop, flush and restart. Linux and the MLX local model share
one heavy-runtime arbiter; an idle model unloads after two minutes while tool
continuations retain it.

The release also repairs local-model tool crashes and multi-turn tool
continuations, and keeps Linux download, background PiP, port forwarding and
system task notifications on their shared services. PPT/PPTX opening now has a
bounded, recoverable outcome: if the native host does not report a visible
first frame, the app no longer spins forever; it retains the mounted engine and
working copy and offers retry, recovery and dismissal. Notes staging failures
are visible and retryable. DOCX/XLSX product flows are unchanged.

Source validation includes Swift 6 object compilation of `FloeExecution` and
seven focused PPT opening-policy tests. Real-iPad PPT paint, PiP/background
behavior, port reachability, legacy migration and multi-VM pressure remain
TestFlight device acceptance items.


## Build 222 recovery note

Build 222 stopped during the accepted-SDK App compile before packaging or upload because `LinuxPortForwardCenter` did not initialize four new observable state properties. Build 223 initializes that state explicitly and is the first distribution candidate for this source line. The immutable Build 222 failure tag and diagnostics remain retained.
