# Android Alpha48 交付记录

2026-11-07，[Android 0.1.0-alpha.48](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.48) 已公开，code67，固定源码 `281e06acbf5ec326e75b0b32550448da0f3d6b5e`。主 APK 为164018895字节，SHA-256：`51ae6a44bdb031ba21b1a6c80052b3027e5568642064682c1b86d89952ea86db`。整轮N01–N08继续，未标记全应用验收完成。

## 本包修复与编译

- 系统进程表先按筛选条件查找，再限制回复数量，修复前500项之外的真实应用被漏报。读取字节上限、权限及回复上限保留。
- 无线调试重开时优先发现当前本机端口，避免旧缓存端口阻塞启动；不重放启动命令，不自动删除配对。
- ADB启动失败就近显示明确说明；已配对时也能打开开发者选项。无障碍界面操作与ADB系统查询分别报告状态。
- Full实际生产及Play Kotlin编译通过，约130.5秒。18项现有界面策略与4项进程查询测试在匹配代码上实际运行通过，最终包复用相同输入。原生3096份输入不变，复用native13；实际58行封装、签名、ARM64/JNI与16KiB检查通过。

## 三星实际升级与ADB

三星从字节相符的公开47，经App默认更新入口使用47→48补丁，实际显示“已由较小的增量补丁准备好”。随后完成主程序和运行环境的系统确认及安全扫描。两包均为67，安装摘要与目标一致，原UID、可见项目及聊天记录保留，App显示“更新已安装”；没有通过ADB安装67。

补丁42377090字节，约为完整APK的25.84%，生产端也已真实重建到目标摘要。七附件的匿名完整下载、标签→源码及版本发现已读回；iOS Latest保留 `v1.7.74`。

首次通知内配对及首次服务生命周期证据来自47。48实际保留了这份配对信任：无线调试关闭时给出就近说明，开发者选项入口可用；开启后以UID2000启动，停止后旧PID消失。再关闭并重开无线调试，系统端口实际变化，同一App进程一次启动成功，产生新服务PID，无需新配对码。Root和无障碍保持关闭。

修复进程查询的真实模型证据首先来自私有code66候选：Ark Plan／`ark-code-latest` 经App查到第500项之后的计算器PID／UID，与系统读数一致。发行包67换端口重连后，又以新Ark任务仅调用一次进程查询，返回相同实机PID／UID，30行完整回执已保存。此时手机自动化关闭、选中应用0、无障碍及Root关闭，系统查询仍真实可用。

最终查询结束后，已通过App停止测试服务并确认进程消失，恢复无线调试、USB常亮及临时审批模型；设备回到无项目首页并息屏。配对信任保留在原有凭据存储和系统授权中，没有导出密钥。

## 手机操作与剩余事项

匹配手机实现的私有code66诊断候选完成了一次新Ark Plan计算器任务：真实启动、清除、输入1＋2并确认3，共6次界面动作，87行完整任务回执和物理界面一致。此前两次观察失效仍保留；本次未复现，未把新增诊断宣称为行为修复。临时无障碍和计算器范围已恢复，没有配置App解锁密码。

Office原生关闭缺明确回执、来源授权释放、间歇手机观察失效、跨项目图形隔离、专业编辑器保存、系统条件任务及全局UI精修仍继续。未将单次计算器通过扩大为所有跨App流程通过。本轮没有启动平板模拟器或进行Root验收。

## 清理

48收尾实测释放3129905152字节，约3.13GB：19处构建输出、7个完成的源码／组件暂存目录，以及3处相同不可变产物副本归并。生产回执先导出，旧暂存路径已退役；当前48、回退47／46、本轮候选、原始故障、符号、SDK／AVD及下一轮有明确用途的缓存保留。其他任务的iOS修改未吸收或清理。

English: Alpha48 fixes late process matches, discovers current wireless-debugging ports before cached ones, and makes startup recovery visible. Samsung installed the public 47→48 delta through the App; both code67 packages, exact bytes, UIDs and visible history were verified. Existing pairing survived; a changed-port restart succeeded in the same App process as UID2000, followed by one real final-package model query matching the physical PID/UID. A matching private implementation completed a six-action Calculator run, while earlier intermittent failures remain open. Relevant compilation, 22 focused tests, package checks and all seven anonymous downloads pass. Test settings were restored and the owned service stopped. Cleanup measured about3.13GB; iOS Latest is unchanged.
