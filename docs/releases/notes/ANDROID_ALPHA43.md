# Android 0.1.0-alpha.43

本次中间版本修复手机接管等待与首次任务权限保存，并改善手机设置的长内容排版：

- 手机观察、操作和截屏经过审批后，继续读取当前任务的真实接管确认，避免批准工具后一直等待却看不到确认入口。确认仍由用户提交；任务切换、终止和工具返回会停止对应等待。
- 空任务已准备过工作区时，首次发送前选定的审批模式与启动事务一起保存；保留原有工具和文件权限，启动失败整笔回滚。已有任务继续使用原策略版本校验。
- 手机设置中的长模型名称与左侧标题共享宽度，减少大字体下标题被挤成多行的情况，保留系统字体缩放与完整无障碍文案。
- 提供 Alpha42 到 Alpha43 的增量包，以及跨版本安装所需的完整 APK。

## Known issues / 已知问题

这是仍在迭代的预发布，不保证整轮功能均已完成。Alpha42 三星实测曾在手机观察获准后长时间等待，本版针对已定位的等待发现缺口修复；编译、实际设备结果与剩余限制分别记录在交付说明。多步跨 App、条件触发、项目隔离和其余 N01–N08 场景继续修复。既有 CAD 实机证据仅覆盖一份 STL，不代表所有格式均通过。

## English

This intermediate prerelease keeps discovering a real phone handover question after tool approval, scoped to the owning task and run. It persists an explicit first-send approval mode even when an empty task already owns a workspace, within the same launch transaction and without widening other permissions. Phone settings share width between long values and labels while retaining system font scaling and accessibility text.

An Alpha42-to-Alpha43 delta and a full cross-version APK are provided. Alpha42 previously waited without a usable handover prompt after phone observation was approved; this iteration repairs the identified discovery gap. Compilation, physical-device results and remaining limits are reported separately. The full N01–N08 round remains in progress, including multi-step phone control, conditional schedules and project isolation. Previous physical CAD evidence covers one STL only.
