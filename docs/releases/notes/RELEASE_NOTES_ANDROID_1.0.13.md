# Floe Android 1.0.13

独立分发 Full 版，版本代码122。

## 简体中文

- 改进助手打开外部查看器后再次读取界面的输入归因。只在同一任务、运行及有效环境内，对刚发起的查看操作作短时关联；真实触摸、接管、锁屏及撤权保持有效。
- 设备服务重新连接不再伪造“刚刚发生人工输入”的时间。
- 需要人工确认时显示设备操作等待状态，并保留现有任务提问和返回入口。
- 补充封闭的输入原因诊断；停止旧运行不能清除新运行的查看关联。

已知限制：原 Full121 记录未捕获具体触发事件，不能宣称已证明其事件来源。纯语义输入在短时关联内仍存在平台区分限制；内置屏幕使用提问的语言一致性继续跟进。完整跨 App 视频、成品自查和日历交付另作实测。全局大目录、Linux 常驻服务及完整环境回收继续保留原有未闭合记录。

## English

Full edition for independent distribution, build code122.

- Improves input attribution when the assistant opens an external viewer and observes it again. A short association remains bound to the exact task, run and live environment; actual touch, takeover, lock and revocation remain authoritative.
- Reconnecting the device service no longer fabricates a recent human-input timestamp.
- Shows a device-operation waiting state when human confirmation is required, using the existing task-question return path.
- Adds bounded input-cause diagnostics and prevents an old run's stop from clearing a newer run's viewer association.

Known limits: the Full121 record lacks the exact triggering input event. Semantic-only input remains ambiguous within the short association window. Builtin screen-question language consistency remains a follow-up. Full cross-app video, output inspection and calendar delivery require separate acceptance. Large global catalogs, managed Linux services and complete container reclamation retain their existing open records.
