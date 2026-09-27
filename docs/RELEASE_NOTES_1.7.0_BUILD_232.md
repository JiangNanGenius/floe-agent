# Floe 1.7.0 Build 232 — internal beta candidate

## 简体中文

- 本地模型前台恢复受阻时返回可恢复状态，避免任务静默停留；保留用户取消与工具续轮状态。
- 修正 iPhone 用量详情弹出层的展示生命周期，并加强低内存 VM 准入、排队恢复及分配前检查。这些改动尚不代表设备崩溃已全部解决。
- 输入框超过行内高度上限后才显示展开按钮。
- 诊断上传按部分保留 Office、本地推理和任务记录，避免关键阶段日志被大型指标内容截掉。
- 默认 Linux 下载切换到经过验证的 SMP 固件／内核镜像，逻辑系统盘 16 GiB，采用稀疏解包。正常启动和硬重启工具可显式请求双核；无参数启动仍为单核，实际配额受设备内存与租约检查约束。
- 已有环境保留原镜像和私有盘，不把旧差异盘直接套到新基底。旧单核基底不会因目录更新自动变成双核；新 SMP 环境才能使用双核。软重启仍返回不支持。
- GitHub 为新 SMP 镜像的已验证下载源；该镜像的 Gitee 同步尚未完成，不使用未经核验的备用地址。

### 验证与已知限制

本地执行模块和稀疏导入检查通过；云端真实模型权重完成两轮文件工具调用，平台为 macOS，不是 iPad。SMP 正确性分项通过，但等量工作性能测试为 0.76 倍，未达到加速阈值。

PPT 进入编辑器后静置闪退仍未取得当前完整堆栈，不能宣称修复。Office 编辑绘制、字体、保存写回、本地模型设备行为及低内存 iPhone 仍需真机验收。完整 App 构建、上传、Apple 处理和测试组可安装状态由交付记录分别核实。

## English

- Recoverable local-model foreground deferral now ends silent waiting while preserving cancellation and tool-continuation state.
- Stabilized the iPhone usage-details presenter and strengthened VM low-memory admission, queue recovery and pre-allocation checks. Device crash resolution remains unverified.
- The composer expansion control appears only after inline text exceeds its height cap.
- Diagnostic uploads retain bounded Office, local-inference and task sections instead of losing them behind large metric payloads.
- The default Linux download now points to the verified SMP firmware/kernel image with a 16 GiB logical disk and sparse extraction. Normal start and hard-restart tools accept an explicit two-core request; an argument-free cold start remains single-core. Device memory and writable-lease constraints still apply.
- Existing environments retain their original base and private disk. Their deltas are never rebased onto the new image. Existing single-core environments do not become dual-core through a catalog update; a new SMP environment is required. Soft restart remains unsupported.
- GitHub is the verified source for the new SMP image. Its Gitee mirror remains pending; no unverified fallback URL is supplied.

### Verification and known limits

Host execution-module and sparse-import checks passed. Real-weight model qualification completed two file-tool turns on macOS, not iPad. SMP correctness checks passed, but equal-work performance was 0.76x and did not meet the speedup threshold.

The reported PPT crash after entering the editor and waiting remains unresolved without a current complete device stack. Office editable rendering, fonts, saving/writeback, local-model device behavior and low-memory iPhone behavior still require device acceptance. Full-App build, upload, Apple processing and beta-group availability are verified separately in the delivery record.
