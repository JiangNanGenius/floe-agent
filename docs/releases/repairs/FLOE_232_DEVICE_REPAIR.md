# Build 232 candidate — device feedback repair / 设备反馈修复

Status: candidate under verification; not a delivered TestFlight build. / 状态：候选版本验证中，尚未交付 TestFlight。

## Confirmed evidence / 已确认的证据

- Build 231 iPhone crash feedback reaches UIKit zoom-transition dismissal and SwiftUI `UIKitPopoverBridge.dismissAndReset`. This identifies the presentation failure class, not a confirmed VM out-of-memory event or the exact originating control. / iPhone 崩溃堆栈指向 UIKit 缩放转场关闭及 SwiftUI 弹窗更新；不能据此认定为虚拟机内存不足，也尚不能唯一确定原始控件。
- The previous feedback upload could remove the middle Office stage trace when MetricKit payloads were large. The candidate uses bounded named sections, retaining Office, local-inference and durable task summaries while separately bounding raw MetricKit payloads. / 旧上传逻辑可能在 MetricKit 内容过大时截掉中间的 Office 阶段记录；候选版本改为分节限额，保留关键诊断。
- Persisted logs and MetricKit reports can belong to an older build than the app exporting them. Report identity alone must not reassign old crashes to the current version. / 持久日志和 MetricKit 记录可能来自旧版本，不能用导出 App 的版本号替代原始记录版本。

## Implemented changes / 已实施改动

- The composer expansion control appears only when the inline text field exceeds its height cap and scrolls internally. Short drafts retain the compact layout. / 输入框超过最大高度、开始内部滚动时才显示展开按钮，短文本不占用该按钮空间。
- Normal Linux lifecycle requests accept one or two vCPUs; ordinary requests without a CPU count still start one. Two cores require a verified SMP kernel/firmware image. Explicit two-core requests cannot silently become one core. Resource, writable-lease and safe-stop checks remain. / 正常生命周期工具支持单核或双核，无参数仍默认单核；双核必须使用经过验证的 SMP 启动镜像，不允许静默降为单核，保留资源、单写租约及安全停止检查。
- Dual-core performance is not an internal-test availability gate. Previous equal-work performance was slower than single-core; no speedup is promised. / 双核性能阈值不再单独阻止内测开放；已有等量工作测试较单核慢，不宣称性能提升。

## Verification boundary / 验证边界

- Execution module qualification: 370 XCTest cases passed, with separate Swift Testing and native engine checks recorded by the implementation task. These are component results. / 执行模块 370 项 XCTest 通过，另有 Swift Testing 与引擎组件检查；它们不是 App 真机验收。
- [MLX host qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/36326672449) passed the constrained batch-8 profile and, separately, two real file-tool turns using the host-selected profile on macOS. Its long synthetic context had 4,215 input tokens; first token took approximately 158 seconds. It is not an exact replay of the device prompt or iPad acceptance. / macOS 实际权重测试通过 batch=8，另以宿主选择的配置通过两轮真实文件工具调用；长上下文首字约 158 秒，不等于 iPad 实测通过。
- Composer verification includes focused iOS object compilation and a small coalescing/state harness; touch layout remains device verification. / 输入框进行了局部 iOS 对象编译与状态合并检查，触屏显示仍待设备验证。
- Current PPT idle-after-open crash, editable rendering/save, iPhone presentation repair and full App compilation remain open until corresponding evidence is obtained. / PPT 打开后闲置闪退、编辑绘制与保存、iPhone 弹窗修复效果和完整 App 编译仍须分别验证。
- The new SMP image must be built, verified, published and pinned in the download catalog before dual-core delivery is complete. / 新 SMP 镜像须完成构建、验证、发布并固定到下载目录，双核交付才算完成。

## Candidate repair checks / 候选修复检查

- Foreground deferral now produces a recoverable local-inference outcome instead of silently leaving the task in `streamingModel`; user cancellation remains cancellation. 174 model tests pass, and a pre-fix mutation caused six new regression tests to fail. / 前台恢复受阻不再静默留下未完成任务；用户停止仍按取消处理。174 项模型测试通过，回退旧逻辑后六项新回归测试失败。
- Usage details retain a stable presenter and content snapshot; availability loss or run selection clears presentation state. Compact width uses default system adaptation. Focused iOS object compilation and 11 state checks pass; reporting-device reproduction remains open. / 用量详情保留稳定展示宿主与内容快照，数据不可用或切换运行时清理展示状态，窄屏采用系统适配。局部 iOS 对象编译及 11 项状态检查通过，报告设备上的复测仍待完成。
- Two approval regression tests pass. An incidental full runtime module run reported 13 failures; that broad run is not recorded as passing and was not used as proof of this UI repair. / 两项审批回归检查通过；附带执行的完整运行时模块测试出现 13 项失败，不能记作全量通过，也不作为 UI 修复成功的证据。
- [Current SMP qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/36328718565): S0–S4 passed; S5 failed its performance threshold (0.76× speed ratio). Stop evidence was retained. Performance failure is not represented as a correctness pass or hidden. / 最新 SMP 检查 S0–S4 通过，S5 性能阈值未通过（速度比 0.76）；停止证据保留，不掩盖性能失败。
- [Post-repair MLX qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/36329617087) passed on source `e08344ca`: constrained batch-8 and historical profiles, plus two successive real file-tool turns with distinct call IDs and verified result receipts under the host-selected profile. The platform remains macOS, not iPad; it does not validate device foreground transitions. / 修复后的云端实权重复测通过 batch=8 及历史配置，并以宿主选择的配置完成连续两轮真实文件工具调用与结果回传；仍为 macOS 组件证据，不代表 iPad 前后台切换验收。
- SMP image help/probe checks passed 16 focused cases, including truncated help, nonzero exit, missing capability and SIGPIPE reproduction. The next image build is separate from these script checks. / SMP 镜像帮助与能力探针通过 16 项针对性检查，涵盖截断、错误退出、能力缺失及 SIGPIPE；脚本检查不等于镜像构建成功。
- Low-memory VM admission preserves a real zero-byte allowance instead of treating it as an unavailable probe. Queued starts recheck recovery every five seconds only while waiting; authorized memory reductions respect their floor, and strict requests never silently shrink. The VM rechecks allowance immediately before allocation, including the legacy path. 41 focused tests and real Swift 6 object/SIL compilation passed. This reduces risk; it is not proof of the reported iPhone crash cause or protection against every system termination. / 低内存准入不再跳过零余量，等待队列每五秒复查恢复且空闲不轮询；允许的降档遵守下限，明确请求不静默缩水，分配前再次检查余量并覆盖旧路径。41 项针对性测试及 Swift 6 对象/SIL 编译通过；尚不能据此归因本次 iPhone 闪退。
- [SMP image build](https://github.com/JiangNanGenius/floe-agent/actions/runs/36330566148) succeeded: the assembled bytes match the rebuilt firmware/kernel, with `CONFIG_SMP=y`, `CONFIG_NR_CPUS=2` and `smp_capable=true`. The corresponding-source component is now published; App catalog integration is complete. / SMP 镜像构建成功且启动文件摘要一致，对应源码组件已公开发布，App 下载目录已接入。

## Component distribution / 组件分发

- [SMP component release](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-smp-20260928.1) contains the image, corresponding sources, source index and digest evidence. [Distribution run](https://github.com/JiangNanGenius/floe-agent/actions/runs/36341082109) succeeded; all 17 assets were retained and uploaded. Firmware, kernel and root disk bytes remain those from the original qualified image; only distribution provenance changed. / SMP 组件已发布，包含镜像、对应源码、索引和摘要证明。分发成功并上传 17 个资产；固件、内核和根盘内容保持原资格镜像不变，仅更新分发来源记录。
- The download is 587,162,397 bytes; the system disk has 16 GiB logical capacity. Download size, logical capacity and allocated disk space are different measures. / 下载包为 587,162,397 字节，系统盘逻辑容量为 16 GiB；下载大小、逻辑容量和实际占用不能混为一谈。
- Sparse import changes passed six targeted tests; the retained module run passed 384 XCTest cases and 222 Swift Testing cases. The final changes passed 203 related XCTest cases and 6 Swift Testing cases, including the six sparse-import tests; the mutable test catalog is excluded from Release. These checks are host/component evidence, not an iPad installation test. / 稀疏导入改动通过六项针对性检查，保留的模块测试通过 384 项 XCTest 和 222 项 Swift Testing。最终改动通过 203 项相关 XCTest 和 6 项 Swift Testing（含六项稀疏导入检查），正式版本排除可变测试目录；这些不是 iPad 安装验收。
- Existing environments retain their original base and private disk; a new catalog default does not upgrade or rebase their system state. Soft restart remains explicitly unsupported. / 旧环境保留原基底和私有盘，更新默认目录不会自动升级或重置旧环境；软重启仍明确不支持。
