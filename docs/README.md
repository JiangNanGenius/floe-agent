# Floe Agent Documentation / 文档中心

[Official website](https://www.floe-agent.com/) · [English README](../README.md) · [简体中文 README](../README.zh-CN.md)

## Start here / 从这里开始

| Topic | English | 简体中文 |
| --- | --- | --- |
| Install and use | [User guide](USER_GUIDE.md) | [使用指南](USER_GUIDE.zh-CN.md) |
| Current architecture | [Architecture overview](ARCHITECTURE_OVERVIEW.md) | 同一文档提供双语术语 |
| Product definition | [Product](../PRODUCT.md) | 关键定位包含双语说明 |
| Design direction | [Design](../DESIGN.md) | 当前工作台与交互原则 |
| Contribute | [Contributing](../CONTRIBUTING.md) | [贡献指南](../CONTRIBUTING.zh-CN.md) |
| Security | [Security](../SECURITY.md) | [安全策略](../SECURITY.zh-CN.md) |
| Support | [Support](../SUPPORT.md) | [支持](../SUPPORT.zh-CN.md) |

## Protocols and active engineering references

- [Floe Browser Protocol](FLOE_BROWSER_PROTOCOL.md): visible WebKit automation protocol, validation, stale references, and takeover.
- [Development plan](DEVELOPMENT_PLAN.md): milestone history and release gates. Some milestone language is historical; use the architecture overview for current 1.2.x structure.
- [Alpha daily plan](ALPHA_DAILY_PLAN.md): short-cycle implementation record.
- [Agent workspace architecture](../FloeAgent/docs/ARCHITECTURE_AGENT_WORKSPACE.md): detailed runtime/workbench design.
- [Execution architecture](../FloeAgent/docs/ARCHITECTURE_EXECUTION.md): remote and local execution boundaries.
- [Settings architecture](../FloeAgent/docs/ARCHITECTURE_SETTINGS.md): provider, model, data, and diagnostic settings.

## Historical evidence

Files whose names contain `AUDIT`, `VALIDATION_REPORT`, `IMPLEMENTATION_REPORT`, `HANDOFF`, or `DELIVERY` capture a specific review or handoff. They are retained for traceability, not as current release documentation. When a historical statement conflicts with the README, user guide, current source, or latest release evidence, the current source and release evidence win.

Reference mockups in [`design/reference`](design/reference/README.md) are historical visual explorations. The App screenshot and bilingual architecture diagrams in [`images`](images/) reflect the current workbench and security model more closely.
