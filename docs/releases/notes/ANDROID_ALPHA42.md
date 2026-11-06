# Android 0.1.0-alpha.42

本次中间版本集中改善手机菜单密度与首次任务权限：

- 手机侧栏采用紧凑字号、较小的可见按钮和单行历史标题，保留完整标题的无障碍读取与48dp操作区域；平板布局和系统字体缩放保持。
- CAD窄屏工具栏保留保存入口，环绕和详情放入更多操作；单位未指定时显示本地化文案，精确尺寸仍可在详情读取。
- 新建空对话可在首次发送前明确选择任务权限，选择随真实运行提交；准备失败后保留，旧任务继续使用原策略版本校验。
- CAD重试的组件租约按实际会话代次区分，避免旧清理释放新预览。

## Known issues / 已知问题

这是仍在迭代的预发布，不保证整轮功能均已完成。手机多步操作、条件触发、跨项目隔离及其余既定N01–N08场景继续验收和修复。CAD此前仅一份STL完成三星显示、离线重开和视口导出，不能视作全部格式通过。实际本包构建／设备结果在交付记录中分别说明。

## English

This intermediate prerelease improves compact phone navigation, single-line history rows, consistent settings chrome and reachable CAD actions. Explicit permission choices before a first message travel with the actual launch and survive preparation failure; existing tasks retain their versioned policy path. CAD retries use generation-qualified component leases.

Known limits: the full N01–N08 round remains in progress, including multi-step phone control, conditional schedules and project isolation. The prior physical CAD evidence covers one STL, not every format. Compilation and this build's device results are recorded separately in the delivery record.
