# Floe Agent 1.8.27（348）内部测试交付

冻结源 `35f28586df617de376df1631be22efd713a7d57f`，标签 `v1.8.27`。Xcode 27.2（27B52）完成 iPhoneOS 27.2 Release 构建。已保存 App 与 19 份 dSYM。签名 IPA 的主程序 UUID 与本地成品匹配，SHA-256 为 `1503d86fdc05b673e392f913bd6f2b17667215e85941f77cead0c71b2eb3d910`。

Apple 返回 `VALID`、未过期，内部 Floe QA 为 `IN_BETA_TESTING`。独立读回确认中英文测试说明与冻结源码一致，外部测试组和审核提交均为空。[签名上传记录](https://github.com/JiangNanGenius/floe-agent/actions/runs/43594237798)

数据管理清理任务现在可复用已创建的共享 Linux 工作目录。容量整理可接收启动恢复期间的一次点按，随后自动进入清点。单盘已安全释放、仍需保留时，其他候选盘可独立接受检查。多条恢复记录结束后会刷新容量。

定向 macOS 宿主验证覆盖目录复用、并发创建、迁移、拒绝符号链接，以及队列、回执和批次继续条件。7 项提取生产源码的 XCTest 均通过。完整 App 已编译。真机在读取上一版日志后已交还，本版尚无 iPad 客户机清理结果或物理空闲容量前后读数。[上一版真机记录](FLOE_1.8.26_BUILD347_DELIVERY.md)
