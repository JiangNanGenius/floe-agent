# Floe Android 1.0.7

## 简体中文

- 修复云端生图返回图片地址后，结果下载仍可能失败的问题，并补充失败阶段诊断。
- 同一轮任务内，生图结果不明时，换提示、模型或供应商也不会自动提交替代请求；继续保留原任务，避免重复生成。
- 网页加载失败后，浏览器工具会保留真实错误，正常重开页面后可恢复。
- 保留计划转执行、进度重置、文件成果预览、轻量文本编辑与通知返回。

本版为自行分发预发布，采用完整安装包升级并保留已有设置和数据。旧版本中结果不明的生图任务不会自动重新提交，也不能据此判断提供商是否计费。完整视频任务仍在实机验证和修复中。

## English

- Fixes a result-download failure after a cloud image provider returns an image URL, and records bounded failure-stage diagnostics.
- An unknown image outcome blocks automatic replacement requests within the same task run, including requests with a changed prompt, model, or provider. The original job is retained to avoid duplicate generation.
- Browser tools preserve real page-loading failures and recover after a successful new navigation.
- Retains plan execution, progress reset, output preview, lightweight text editing, and notification recovery.

Self-distributed prerelease. Complete-installer updates preserve existing settings and data. Unknown image jobs from earlier versions are not automatically resubmitted; their billing status remains unconfirmed. The complete video workflow is still undergoing physical-device validation and repair.
