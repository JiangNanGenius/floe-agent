# Floe Android 1.0.8

## 简体中文

- 修复内置浏览器能显示页面、但助手读不到网页文字和按钮的问题。
- 保留真实加载错误、页面身份与权限检查；页面本身为空或仍在加载时不伪造内容。
- 设备操作浮窗默认收起为可拖动的小气泡，执行动作时显示进度圈；点击可展开暂停／继续和接管控制，短暂无操作后自动收起。
- 修复存在多个应用界面实例时，点击历史任务、文件预览或权限入口可能没有反应的问题。
- 打开外部预览时等待系统完成界面切换，减少视频播放器刚启动就被误判为未打开的情况。
- 修复长任务已有真实进展后，仍因整轮累计的目录查询次数而提前终止的问题；保留对实际停滞和重复失败的保护。
- 继续使用完整安装包升级，保留已有设置和数据。

复杂跨应用流程及日历成果仍需分别核验；系统／厂商差异继续按实际反馈修复。此前结果不明的生图任务不会自动重新提交，不能据此判断提供商是否计费。

## English

- Fixes a browser issue where pages could render but the assistant could not read their text or controls.
- Preserves real loading failures, page identity and permission checks. Empty or loading pages do not produce invented content.
- Device controls now start as a small draggable bubble, with a spinner during active operations. Tap to show pause, resume and takeover controls; the panel collapses after a short idle period.
- Fixes history, file preview and permission entry points that could fail to open when more than one app screen instance existed.
- External preview checks wait for the system window transition, reducing false reports that a newly opened video viewer did not appear.
- Productive long tasks no longer stop because of catalog queries accumulated across earlier steps. Actual stagnation and repeated-failure guards remain active.
- Complete-installer updates retain existing settings and data.

Complex cross-app flows and calendar outcomes still require separate verification. Device-specific behavior continues to be refined from actual feedback. Earlier unknown image jobs are not automatically resubmitted; their billing status remains unconfirmed.
