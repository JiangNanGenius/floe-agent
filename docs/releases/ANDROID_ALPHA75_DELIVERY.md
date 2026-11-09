# Android Alpha75 / code101 — source preparation

This is the frozen-source preparation record. Packaging, device acceptance and public delivery are recorded separately after their actual completion.

## Changes / 更新

- 自动解锁保留单次凭据输入和真实锁屏结果，补充受信任的默认显示器系统窗口查找、输入前的最新窗口确认，以及不含凭据或节点内容的固定就绪阶段诊断。窗口缺失、过期或歧义时保留人工处理。
- 图形查看器失去连接后，先确认同一项目启动器和图形子进程确实存活，再保留执行上下文；明确重开时复用原连接，不创建新环境／终端或失败重连循环。桌面仍以用户手动使用为主，模型继续优先命令行。
- Resolve a fresh trusted native credential surface using the default-display window set, preserve at-most-once entry and actual keyguard observation, and report closed readiness stages without node or credential content.
- Preserve a project graphical context only when its original launcher and display/desktop children remain alive. Explicit reopen reattaches the same viewer; hidden viewers do not force streaming and failures do not loop-reconnect.

## Qualification / 代码验证

Sixty-seven focused phone surface/unlock/wake/ancestor cases and actual Full/Play Kotlin compilation passed. Ten graphics/protocol cases from the preceding source checkpoint are reused after exact input-hash verification. Initial compiler omissions and one new fixture's backward-clock failure are retained; the fixes preserve every behavior assertion and existing lifecycle test. No new cloud/provider call was made for code qualification.

The unchanged native34 producer may be reused only after matching all actual inputs and the exact packaged bytes. App/runtime/Office/CAD versions and corresponding-source offers advance together. Actual APK signatures, 16 KiB/package binding and74→75 delta reconstruction remain part of candidate production rather than being inferred from Kotlin compilation.

## Known issues / 已知问题

Alpha74的三星公开完整包在线升级、原任务／项目保持、回答后等待提示刷新及真实Linux输出已确认。其独立锁屏用例完成唤醒／滑动，但没有观察到可输入凭据界面，未输入密码或完成计算／重锁；本版针对该边界修复，尚未有新的实机结果。原失败保留。

索尼XZ／Android9下载和解压后的具体启动根因仍未确认。Alpha72已有保留环境的重新检查与分类诊断入口，不能把“已安装”当成终端可执行，也不据截图要求刷机。全新下载计量、其余N03／N05组合和全局UI精修继续，N01–N08总目标保持进行中。

Samsung automatic unlock/action/relock and the new graphical continuity require fresh physical evidence. Sony post-extraction startup, fresh-download metering and the remaining N01–N08 scope remain open. This intermediate build does not claim whole-App completion.

## Delivery policy / 发行边界

Publish one Full ARM64 APK with necessary checksums/update/source/optional-preview files, using one immutable source tag. Preserve iOS Latest, validate exact public bytes and current/retained-client update discovery, then record real Samsung upgrade and changed-flow outcomes. Keep original failures, current/required rollback artifacts and native symbols; retire only completed, unused generated outputs.

## Delivery appendix / 交付补记 — 2026-11-10

[Alpha75/code101](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.75) is public from immutable source `54435f1744e8c61766e6c7d5d2b7062863556cc0`. The source-preparation statements above are retained as historical stage evidence.

- Full ARM64 APK:164,714,299 bytes; SHA-256 `75315736dc2accbdd27f3cf028ae872744b29b7b3491c5f6db82961f8ffeb6da`. Actual native34 input identity/58 package bindings, main/runtime API28/29 signatures and exact74→75 host delta reconstruction passed.
- All seven anonymous public asset bytes, immutable source binding and current/retained65 update discovery passed, preserving iOS Latest.
- Samsung selected the regular Update action in public74 using its saved GH-Proxy source. The first preparing-state placeholder showed the full size; the final verified receipt explicitly confirmed reconstruction from the smaller delta. Normal main/runtime confirmations and Play Protect scanning completed. Both installed code101 packages exactly match the public APK/embedded runtime, and original UIDs10346/10348 remain. No ADB replacement, uninstall or downgrade was used.
- Twenty-three unused packaging/source/delta outputs were retired after eight producer receipts and current artifacts were exported. The deletion window measured3,161,395,200 additional internal free bytes; external space changed by−36,864 bytes during concurrent activity. Earlier unused native scratch/unit HTML cleanup measured another992,399,360 bytes. Current75, rollback74, original72/73 failures, native34 raw symbols, original evidence, SDK/AVD and immediately useful Kotlin/Gradle classes remain.

Automatic unlock/action/relock, graphical continuity and remaining N01–N08 acceptance continue independently. Subsequent source repairs for an installed-state recheck no-op and masked startup refusal have passed59 relevant cases/Full/Play compilation, but are not in this immutable75 package. Sony XZ/Android9 physical recovery is not claimed.

## Samsung case H / 三星后续用例

The original75 case used Ark Plan/ark-code-latest and produced three request/result pairs: the Linux command and schema lookup succeeded; the first phone launch reached wake/reveal, then trusted SystemUI without a credential surface and USER_REQUIRED before credential input. It did not retry or complete calculator/relock. The later discarded phone result was influenced by permission teardown and cancellation of the manual-unlock wait; it does not establish the original driver cause. The final34-record run and earlier28-record streaming snapshot are retained separately.

The case task and two exact device exports were retired, temporary local credentials/app scope/control permissions were cleared, the five baseline tasks/two projects remain and the device is asleep. A source defect allowing a reveal on the400ms wake timeout was found; the successor requires observed display/window readiness and adds closed wake branch diagnostics. This is separate from the concrete, still-unproved physical trigger in case H and does not change75's immutable package.
