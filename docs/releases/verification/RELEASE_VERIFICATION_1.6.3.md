# Floe Agent 1.6.3 (139) 发布核验 / Release Verification

> 日期：2026-09-11（UTC）。结论：**TestFlight 已上架且可见性核验通过**。

## 源码与门禁

| 项 | 值 |
|---|---|
| 标签 | `v1.6.3`（annotated，重打至修复后提交） |
| 源码 SHA | `57111d5`（main；regex 框架 minOS 一致性修复 + build 139） |
| 主 CI | run [34541861585](https://github.com/JiangNanGenius/floe-agent/actions/runs/34541861585) — build-test / appstore-sdk-compatibility / spm-linux-build 三 job 全绿 |
| 发布流 | run [34545690562](https://github.com/JiangNanGenius/floe-agent/actions/runs/34545690562) — 三 job 全绿 |

## Apple 侧核验

| 项 | 值 |
|---|---|
| ASC build ID | `f863ed91-2f95-42c5-a9a0-8d326ac7de89` |
| 版本/构建号 | 1.6.3 / 139 |
| processingState | **VALID** |
| buildAudienceType | APP_STORE_ELIGIBLE |
| Beta 组 | 恰好一个 `Floe QA`（internal=true，无公开链接），意外组 0 |
| 核验 run | discover [34555450572](https://github.com/JiangNanGenius/floe-agent/actions/runs/34555450572)；verify-testflight [34557460726](https://github.com/JiangNanGenius/floe-agent/actions/runs/34557460726) |

## 过程事件（如实记录）

1. **build 138 被 Apple 拒绝于处理阶段**（未出现在 builds API）：error 90208 —— 新 pin 的 regex 框架二进制为 minOS 17.0 而框架 Info.plist 写 13.0（wheel 文件名 tag 是 cibuildwheel 的 13.0 下限假象）。修复：该 pin 的 minimum_ios 改为 17.0，重打 tag 为 139 重发。
2. **GitHub 资产发布首跑失败**：RELEASE_NOTES 缺 workflow 校验的 `### 简体中文`/`### English` 标记；已修 main 并手动以工作流同等资产集补齐 v1.6.3 GitHub Release，第二次发布流（139）publish job 绿色通过。

## 内容摘要

任务清单生命周期（完结自动闭合/终态退役/CAS 可选/精确报错）、失败熔断 + 计划保鲜提醒（Reminder 服务 + `<system-reminder>`）、云端语义压缩（确定性回落）、提示词全面重写（交付验证/沟通纪律/注入元协议/denial 纪律）、类型化并行子代理（explore/research + 交接契约）、PiP 三项（真图标/decode 口径速度/详细工具状态）、jobs 提交即校验、createFile overwrite、工作区 AGENTS.md/FLOE.md 发现注入、workspace 顶层列表进提示词。

## Wheelhouse 进展

- **已转正入包**：regex 2026.9.10（原生双 slice）、PyYAML 6.0.3、MarkupSafe 3.0.3（纯 Python）。
- **下一版接入（已 pin 入 main）**：zstandard 0.25.0、Brotli 1.2.0、greenlet 3.5.5、frozenlist 1.8.0、multidict 6.8.0——全部 CI 构建 + iOS testbed 冒烟通过，不可变 Release 已发，install 表已 pin。
- 管线加固：sdist 自带 [tool.cibuildwheel] 表剥离、`stripBuildRequires` 机制（zstandard 的 cffi 构建期依赖）、-Werror 包的 CFLAGS 豁免（multidict）。
- 仍 parked：orjson/pydantic-core（Rust/maturin 交叉链）。

## 遗留跟踪

- 五包 pin 的端到端验证随下一版（1.6.4）发布流的 LocalPythonRuntimeTests 进行（import + 功能断言已就位）。
- Tier-3 设计（快照回滚/模型 failover/hooks iOS 形态）见 docs/HARNESS_TIER3_DESIGN.md。
