# Floe Agent 1.8.53（374）

App Store Connect 已确认构建有效、未过期，Floe QA 可安装。构建已加入现有公开测试组 `publictest1`，已提交一次外部 Beta 审核。独立查询返回 `WAITING_FOR_BETA_REVIEW`。源码标签为 `v1.8.53`，提交为 `2ec59eb4b2d3b115984ac7ce2c9b5191bb2daef1`。[签名与上传回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44541683256)

已在旧版序列化的聊天请求中重现图表定义经分面子图引用自身的循环。新版在首次请求中提供有限的图表字段定义，完整格式仍由图表工具按需返回。修复后的实际请求结构通过循环检查，40 种图表示例通过原生解码，13 项图表核心测试通过。此轮未使用真实 Kimi 账户执行对话。

本版同时包含游戏加载与虚拟键盘布局修复。iPad 模拟器已验证连续移动两个键、保存后重开和按键响应。1,445 个文件、约 204 MB 的样本上，试玩文件准备及校验阶段的三次测试中位数从 1.37 秒降至 0.78 秒。完整设备 Release 构建通过。

Apple confirmed internal availability and received the external beta submission for the existing public group. The recorded external state is awaiting Beta App Review. The build includes the Kimi chart schema, game loading and touch layout fixes.
