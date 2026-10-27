# Floe Agent 1.7.60（301）交付 / Delivery

2026-10-27

## 源码与内容 / Source and changes

- App 固定于不可变 `v1.7.60` → `f1307f0dabec5d4b30b01d5024bf411eacc770be`，标签对象 `b57cea1a3d98f2d6468368017f2d6c39698085f5`。本地单次归档立即保存，后续签名与发布复用同一产物。The annotated tag and App source remain unchanged; signing and publication reused the saved local archive.
- Skill Hub 精选滚动卡、分类、自然比例操作与行内多选；技能更新、预置保护、依赖声明和版本管理；按用途的模型表单、长输入、Kimi 调用命名、工具准备状态和终端尺寸处理；后台工作／下载收尾、远端 Skill 入口及图片保存到照片已整合。[双语改动](../notes/RELEASE_NOTES_1.7.60_BUILD_301.md)。基础镜像未变更，依赖按需准备。
- 审核说明在独立文档提交 `33dbbc131d67ad1c6880eac1eb56e14c0e05b2c4` 修正“long draft”的措辞；App、版本和标签未改动。Reviewer copy was corrected separately without moving the release tag or rebuilding the App.

## 验证 / Qualification

Xcode 27.1（27A9275），SDK 27.1；完整 Swift 6 App／测试宿主对象编译和 arm64 iOS Release 归档通过。使用既有 iPad 模拟器（iOS 27.0）并串行运行；紧凑布局在同一模拟器内检查。

| 范围 / Scope | 通过 / Passed |
| --- | ---: |
| 功能与状态单元检查 / Feature and state tests | 312 |
| Shell／MCP 契约 / Shell and MCP contracts | 68 |
| 下载与恢复 / Downloads and recovery | 32 |
| 两条实际冷启动入口 / Actual cold entry points | 2 |
| 原生界面 / Native UI | 8 |
| 真实 riscv64 Python 依赖、离线 wheel 与哈希正反例 / Real guest Python, offline wheel and hash checks | 1 |
| 真实 apt 精确安装／执行及中文字体绘制 / Real apt exact installation, execution and CJK glyph rendering | 1 |
| **合计；0 失败、0 跳过 / Total; zero failed or skipped** | **424** |

另有真实宿主 C 后端检查：修复前 4 项失败保留，修复后文件句柄 35/35、目录隔离 73/73；远端后端本地契约检查 17/17。未改动的 MCP 实际客体证据按源文件摘要复用。本轮验证范围是模拟器、实际 RISC-V 客体及宿主组件；真机交互、在用远端部署和长期系统后台时长另行判断。

Additional host checks passed 35 file-handle and 73 containment assertions, with the original four failures retained; 17 local remote-backend contract tests passed. Physical-device behavior, production remote deployment and long-duration OS background execution are separate boundaries.

## 渠道 / Channels

| 渠道 / Channel | 已核验状态 / Verified state |
| --- | --- |
| Floe QA | `VALID`、未过期、`IN_BETA_TESTING`；[签名上传及 Apple 确认](https://github.com/JiangNanGenius/floe-agent/actions/runs/40439148055) / Available internally |
| publictest1 | Safari 提交一次；[独立 GET-only 读回](https://github.com/JiangNanGenius/floe-agent/actions/runs/40442489267)确认群组关联、说明匹配、恰一条 `pending_review`，`WAITING_FOR_BETA_REVIEW` / Submitted, awaiting Apple review |
| [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.60) | stable、latest；实际 arm64 iOS IPA、摘要、标签及源码绑定通过 / Verified stable/latest unsigned IPA |
| [Feather](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json) | [同次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/40441083199)等待下游完成，实时文件的版本、地址、源码、大小及摘要一致 / Awaited downstream and live feed verified |

公开测试等待审核批准；无签名 IPA 需自行签名。本轮未发布正式 App Store 版本。External TestFlight installation awaits approval; the unsigned IPA requires signing. No formal App Store publication was performed.

`Floe-Agent-1.7.60-build301-unsigned.ipa`：815,710,468 bytes；SHA-256：

```text
2863cc9613598327ea139e21d3ebe131cc2bea42b4832bac590fad4c483edb30
```

原始说明预检失败和两处 API 403 均保留；后续经已有 Safari 会话完成说明与送审，没有重复创建审核申请。The initial copy-preflight failure and both API 403 failures are retained; the existing Safari session completed the submission, independently read back as one pending record.

## 清理与后续 / Cleanup and follow-up

本轮各次清理前后实测净可用空间变化合计：内盘 **14.39 GiB**，仓库卷 **2.17 GiB**。目录占用与卷净变化分别记录。已移除完成的编译目录、重复 App／归档、原始中转 ZIP、临时展开目录及私有传输草稿；保留当前 IPA、精简来源、恢复 ZIP、14 份匹配符号、完整验证／失败记录和原有回滚材料。既有模拟器已关闭，App 和用户数据保留。

Measured free-space changes across the cleanup operations total **14.39 GiB internally** and **2.17 GiB on the repository volume**. Current delivery, recovery, matching symbols and evidence are retained; Simulator user data remains intact.

单独诊断仍发现：共享目录中，Python 对已重命名或删除的开放文件句柄查询状态可能返回 `ENOENT`，同时仍可读取该句柄。此兼容性项留待后续定向处理；本轮 apt 安装及中文绘制实测已通过，不据此宣称完整 POSIX 支持。A separate Python metadata-route limitation after rename/unlink remains recorded for follow-up; the real apt and font-render acceptance passed.
