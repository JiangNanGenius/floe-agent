# Android 0.1.0-alpha.48

## 已知问题 / Known issues

这是中间测试版。手机多步操作仍有间歇性观察失效，旧失败记录保留。Office 关闭后可能保留待确认副本；完整升级后 Office／CAD 组件需重新安装，原文件保留。其余既定功能和界面精修继续推进。

This is an intermediate release. Multi-step phone control can still encounter stale observations; prior failures are retained. Office may retain an unconfirmed working copy. Optional Office/CAD components need reinstalling after a full upgrade; original documents remain. Other planned features and UI refinement remain in progress.

## 更新

- 修复系统进程查询先截取500条再筛选，漏掉真实运行应用的问题；筛选后的回复仍有数量上限。
- 无线调试重新开启后，启动服务优先发现当前端口，避免旧缓存端口阻塞连接；已有配对保留。
- ADB 启动失败在对应区域显示，并提供开启无线调试和查看详情的指引；已配对时仍可打开开发者选项。
- 区分无障碍界面操作与 ADB 系统查询的可用状态，补充不含界面内容的手机观察失效诊断。

三星已在匹配修复实现的私有候选上完成真实配对、UID2000服务启停和模型进程查询；最终发行包的升级与重连结果在交付记录补充。

## English

- Filter the complete bounded process table before limiting returned matches, so running apps beyond the first500 rows remain discoverable.
- Discover the current local wireless-debugging port before using a cached endpoint; retain existing pairing trust.
- Show ADB startup failures beside their controls, with recovery guidance and access to Developer options after pairing.
- Distinguish accessibility readiness from ADB system-query readiness and add phone-observation diagnostics without screen content.

Samsung verified genuine pairing, UID2000 service lifecycle and a real model process query on a matching private repair implementation. Final release-package upgrade and reconnection results are added to the delivery evidence separately.
