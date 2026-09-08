# 本轮升级验证记录

这是 `codex/office-workflow-upgrade` 工作分支的阶段证据，**不是整轮验收或发布声明**。素材与任务均为合成测试数据。

## 已验证

- 46 项工具/数据层回归通过：多查询搜索、目录分页、内置升级来源策略、跟随状态、历史事件分页、HTTP 下载失败不覆盖目的文件。
- 53 项应用逻辑回归通过：Skill 生命周期、文档转换、长文本流与时间线、素材导入。包含新增的历史工具链折叠及旧版内置升级保留禁用用例。
- iPad mini (A17 Pro)、iOS 27 模拟器三项 UI 流程通过：插件市场/长按多选，PDF 内嵌/全屏/返回，素材缩略图列表/海报墙。实际截图如下。

| 流程 | 截图 |
| --- | --- |
| 插件市场 | [查看](ipad-plugin-marketplace.png) |
| 长按后选择任务 | [查看](ipad-batch-long-press.png) |
| 设置进入所有工作区 | [查看](ipad-all-workspaces.png) |
| PDF 内嵌阅读 | [查看](ipad-pdf-inline.png) |
| PDF 全屏阅读 | [查看](ipad-pdf-fullscreen.png) |
| 素材缩略图列表 | [查看](ipad-materials-list.png) |
| 素材缩略图海报墙 | [查看](ipad-materials-wall.png) |

首次素材测试对缩略图宽度的断言失败：SwiftUI 暴露的是父按钮边界。已查看截图和录屏，改为验证列表行/海报卡高度差，重测通过。

## 验证边界

这些 UI 测试复核已有流程与本轮回归，不能证明 Word/Excel/PPT 已有完整可编辑前端。Office 原生构建、引擎接入、真机编辑、原格式重开仍未验收。跟随滚动和分页的代码/逻辑验证不能替代 100 轮绘画的真机性能记录。

原始结果包保留在开发机 `/tmp/floe-workflow-app-regression-20260909.xcresult` 与 `/tmp/floe-workflow-ui-20260909.xcresult`；同目录的摘要是这些实际测试输出的摘录。

最终应用及素材回归结果包：`/tmp/floe-workflow-final-regression-20260909.xcresult`。
