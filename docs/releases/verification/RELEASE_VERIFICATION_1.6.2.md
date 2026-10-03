# Floe Agent 1.6.2 (137) 发布核验 / Release Verification

> 日期：2026-09-10（UTC）。结论：**TestFlight 已上架且可见性核验通过**。

## 源码与门禁

| 项 | 值 |
|---|---|
| 标签 | `v1.6.2`（annotated，release_preflight 通过） |
| 源码 SHA | `a02354d9`（main，含 PR #5 + #6） |
| 主 CI | run [34454591378](https://github.com/JiangNanGenius/floe-agent/actions/runs/34454591378) — build-test / appstore-sdk-compatibility / spm-linux-build 三 job 全绿 |
| 发布流 | run [34458842784](https://github.com/JiangNanGenius/floe-agent/actions/runs/34458842784) — build-verify-release → TestFlight 上传 → GitHub 资产发布，三 job 全绿（TestFlight job 首跑因模拟器 WebKit 截图瞬时故障失败，重跑通过） |

## Apple 侧核验

| 项 | 值 |
|---|---|
| ASC build ID | `e3f16a72-d457-494d-b372-d6b375928040` |
| 版本/构建号 | 1.6.2 / 137 |
| processingState | **VALID** |
| buildAudienceType | APP_STORE_ELIGIBLE |
| Beta 组 | 恰好一个 `Floe QA`（internal=true，无公开链接），意外组 0 |
| 核验 run | discover [34474560479](https://github.com/JiangNanGenius/floe-agent/actions/runs/34474560479)；verify-testflight [34474735431](https://github.com/JiangNanGenius/floe-agent/actions/runs/34474735431) |

## 内容摘要

工具结果随对话回放 + schema 跨任务持久化（根治反复枚举）、jobs.* 后台任务（下载/清洗不阻塞对话）、28 族字体管线落地为 9 族精选字重（约 340MB，中文方框修复）、Office 自闭合元素修复、引擎预热、提示词分层 + Anthropic 缓存断点、100 步迭代软预算、ios-wheelhouse 产线（regex/pyyaml/markupsafe 已产候选 wheel；orjson/pydantic-core Rust 链路为二期实验）。

## 遗留跟踪

- Rust 系 wheel（orjson/pydantic-core）：maturin 交叉链路继续调试，见 ios-wheelhouse/README.md。
- wheel 候选核验后写回 install pin 并入后续版本。
- 模型摘要压缩、harness 文案统一为 follow-up。
