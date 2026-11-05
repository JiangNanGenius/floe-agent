# Floe 1.7.71（312）交付状态

更新日期：2026-11-05。安装包来源为 `1e1d875c99fc39d16b1d10e7420ad4148116976a`，不可变标签 `v1.7.71`。本记录的后续提交不改变安装包来源。

## 修复与证据

| 范围 | 本版结果与实际验证 |
| --- | --- |
| 3D 打开时崩溃 | 已采集并符号化 311 的两份物理 M4 iPad 日志，定位到工作台深层 SwiftUI 视图类型元数据递归；拆分视图构造，保留原交互顺序和几何路径。指定 iPad 模拟器两次冷开、真实齿轮修改、保存和冷重开通过 |
| 下一次发送被检查点阻断 | 在同一数据库事务中核对会话与运行归属并保存已有环境绑定；不可用后端不再导致原生聊天丢失恢复绑定。保留代次、所有权和命令执行检查 |
| 首次发送准备与设置加载 | 启动时先恢复已保存配置；可选本地模型发现由服务异步持有，发送使用已完成加载的偏好，不必再次保存设置 |
| 运行中调整核心 | 支持最多四核在线调整；真实 ARM64 客体执行 1→4→1→3→4→2→1，同一启动身份、任务文件和依赖保留，两个项目的隔离及非法请求检查通过，共 30 项 |
| 音频与画中画 | 后台音频独立管理；关闭画中画不停止 Linux，运行状态与音频所有权的竞态有针对性回归 |
| 文件和右侧面板 | 恢复直接文件入口与收起按钮；窄 iPad 同时打开检查器时合理收起左栏，避免挤压聊天和输入区域。实际界面测试通过 |
| 输入框 | 最终 App 在指定 iPad 模拟器重新执行软换行、完整三行、光标可见、展开编辑及完整草稿回收，两项通过；测试草稿不覆盖普通未发送草稿 |

双语更新说明：[Release notes](../notes/RELEASE_NOTES_1.7.71_BUILD_312.md)。桥程序单独交付：[Bridge 1.1.2](FLOE_BRIDGE_1.1.2_DELIVERY.md)。

## 验证范围

- Xcode 27.1（27A9275）、SDK 27.1，Swift 6 实际对象编译、链接及最终 Release 归档成功；App 和全部扩展身份一致。
- 相关完整 App 测试分批为 86 项、侧栏 1 项、最终输入框 2 项，全部通过。原首次失败保留，实际修复后执行对应回归；不是无修改重试。
- 原生组件范围为 141 项 XCTest 和 11 项 Swift Testing；这些不替代完整 App 验证。
- 较早 App 测试与最终提交的对应模块逐文件核对；后续根布局改动由最终侧栏和输入框阶段单独覆盖。未将较早整个 App 阶段标成最终源码测试。
- ARM64 Skill 安装、跨任务依赖复用、客体网页服务、回环转发及 WebKit 行为复用本轮 311 已有的实际证据；未改变的链路不重复运行。
- 没有使用用户手机。用户带走 iPad 后未阻塞发布，也未把模拟器结果称为 iPadOS 27.2 真机复测。
- CPU 在线切换检查不等同于物理 iPad 性能或加速比结论；后台功能不承诺无限系统执行时间。

## 渠道状态

| 渠道 | 状态 |
| --- | --- |
| 内部 TestFlight | 上传及 Apple 处理完成；独立 GET 确认 VALID、未过期、Floe QA 内测可用，中英文说明一致 |
| 公开 TestFlight | Safari 提交现有 publictest1 成功；独立 GET 读回唯一 pending_review、WAITING_FOR_BETA_REVIEW、群组关联和双语说明一致，尚不可公开安装 |
| GitHub／Feather | stable、latest、非 draft、非 prerelease；公开 IPA 实际下载，来源、摘要、大小、arm64 iPhoneOS 可执行文件和 awaited Feather 更新源均已独立核验 |
| 正式 App Store | 按用户新指令撤回等待审核的 311，替换为 1.7.71（312）重新提交；审核详情再次读回等待审核，保留手动发布 |

正式审核提交：`12da1f0a-b7d1-44bb-bcbb-f833cd4c6638`。审核附带录像继续保留，并明确注明为 308 物理 iPad 后台音频录像，不将其称为 312 真机录制。

公开安装包：[GitHub v1.7.71](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.71)。

```text
Floe-Agent-1.7.71-build312-unsigned.ipa
bytes: 821312196
SHA-256: 5e9286da2835eb21f5f1e59e85a9fbcf25491dd23e9b817bfdc9243950eb3fc2
```

[Apple 上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/41960990196)、[独立内测读回](https://github.com/JiangNanGenius/floe-agent/actions/runs/41963193865)及 [GitHub／Feather 发布](https://github.com/JiangNanGenius/floe-agent/actions/runs/41963033375)完成。Feather 首次因并发 main 更新而推送失败，保留失败记录后仅重跑失败下游，同一安装包及不可变来源保持不变。

[公开测试独立读回](https://github.com/JiangNanGenius/floe-agent/actions/runs/41964230457)通过。正式与公开 Beta 审核分别提交，等待审核不表示已经公开可安装。

## 留存与清理

本轮截图 13 张已追加到主仓长期素材索引。输入框与侧栏截图保留作候选，CAD 横屏附件存在裁切／方向问题，仅作诊断，未列为可直接发布的宣传图。

Bridge 临时配对已撤销，本机测试应用已卸载，没有运行中的 Bridge；用户原有工作文件、配对及钥匙串保留。公开 DMG、公证和下载／更新签名证据保留。指定模拟器已关闭，未删除其用户数据。

归档后移除 312 的一次性 DerivedData，内置盘实测增加约 4.11 GB；完成行为测试后移除两个自有构建目录，本次内置盘实测增加约 16.52 GB。另一批旧镜像、暂存包和重复 Bridge App 清理时，外置盘实测增加约 339 MB。APFS 克隆、并发磁盘活动及不同批次的测量分别记录，不将逻辑文件大小相加作为实际回收量。

当前归档、恢复包、符号、原始失败、必要 311 回滚和其他线程未完成内容保留。独立性能预研已交接原线程，不作为本版新增验收门槛。Skill Hub 自动发布锚点维护由原线程完成，现网只读检查通过，未更改 312 标签、工具权限或已发布 Skill。

## English

Build 312 is available in internal Floe QA. The stable/latest GitHub IPA and awaited Feather update were independently verified. Public TestFlight and formal App Store review were submitted and read back as waiting for review; production release remains manual. Focused App, native component and actual ARM64 guest checks cover the changed paths; physical iPadOS 27.2 post-fix behavior is not claimed. Bridge 1.1.2 was separately published, its temporary pairing revoked, and its local test applications removed.

## 送审后新反馈

任务停止后文字仍继续生成、会话文件浏览无法打开 `.floecad` 包，以及模型调用 `environment.repairLinux` 无效，作为后续 build 的阻断修复继续处理。312 的标签和安装包保持不变，这三项不算作本版已修复。
