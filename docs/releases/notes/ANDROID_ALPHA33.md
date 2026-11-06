# Android 0.1.0-alpha.33 · code52

GitHub Full 中间预发布；保留 iOS Latest，整轮功能继续收口。

## 本次更新

- 修复从手机控制通知返回任务后，当前审批和工具记录可能消失的问题。返回入口核对实际存储身份，继续使用原会话。
- 修复手机通知“接管”已经停止控制，却未取消 Agent 运行的问题。取消仍核对真实运行状态和修订，不会取消其他任务。
- 移除本机报告或撤回自动上报同意时，立即取消相应上传请求；系统停止上传作业时也释放网络请求。压图过程中取消不会重新生成已移除报告的附件。
- 保留四张截图压缩、上传进度、真实回执、完整包下载和增量回退；普通任务、工具和供应商异常仍不自动上报。

## 已知问题与验证范围

- 三星已完成公开 Alpha31→32 的增量及主包／运行组件联合升级；此候选的设备通知返回、接管取消和上报取消仍需定向实测，不能用源码或编译替代设备效果。
- 四张大图的原网络超时仍保留，尚未完成设备接收验收；旧报告可能因服务端版本策略被拒绝，需在更新后重新提交，不会修改报告原始版本绕过限制。
- 手机跨 App 的完整输入／成果流程、真实条件触发、项目图形复用及其余既定能力继续实测修复。TIFF 本地预览尚未实现。系统／云语音、无 App 本地模型、CAD 只读及轻编辑边界不变。
- 全局字号、密度、控件比例和视觉对齐集中在功能收口后处理。旧 Alpha30 安装器若已卡住，仍可能需要通过系统文件管理器打开完整 APK 过渡。

---

Intermediate GitHub Full prerelease; iOS Latest is preserved.

Notification return now retains the authoritative stored task identity, preserving its pending approvals and tool records. Phone takeover matches the actual run UUID and revision before cancelling the Agent. Removing a local report or revoking automatic reporting now cancels its real network request; worker cancellation also releases that request, and cancelled compression cannot recreate removed attachments. Ordinary task/tool/provider errors remain excluded from automatic reporting.

Samsung acceptance of the previous public Alpha31→32 incremental/coordinated update is retained. This candidate's notification return, takeover and upload-cancellation behavior still require targeted device acceptance. The original four-image timeout, missing TIFF decoder and remaining phone/condition/GUI flows remain recorded. Old report metadata is never rewritten to bypass server version policy. Global visual refinement remains deferred until functional closure; affected old Alpha30 installers may still need the documented manual full-APK transition.
