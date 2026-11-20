# Floe Agent 1.8.55（376）

App Store Connect 已确认构建有效、未过期，内部 Floe QA 可以安装。构建已加入现有公开测试组 `publictest1`，本版只有一条外部审核提交记录。正在等待 Apple 的外部 Beta 审核（`WAITING_FOR_BETA_REVIEW`）。源码标签 `v1.8.55` 固定于 `a586ecf51f804916f56ae1ef9bd70d0067f1dbd2`。[签名与上传回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44698148927)

- **游戏运行**　iPad 模拟器上从同一个 Phaser 工程的主页和 IDE 各运行一次，停止后均返回发起页面。更新中断的工程删除可在容器路径改变后恢复，已对受影响的旧工程实际重试。
- **任务与助手**　验证了子任务停止与隔离、审批继承和 Studio 本地编辑共 17 项。文件与助手生命周期另有 17 项通过，包含保留仍在使用的工程和对应助手，并让普通任务继续在聊天列表可见。
- **文件与入口**　聊天回复中的文件差异可原地展开。游戏文件进入所属工作区 IDE。普通文件在同级 Studio 工程移动后仍可打开。iPhone 的入口已按源码盘点，实机、第三方游戏样本和实际云服务的覆盖范围见[功能盘点](../../FLOE_IOS_FEATURE_CLOSURE_20261120.zh-CN.md)。
