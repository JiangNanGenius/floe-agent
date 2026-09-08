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

iPhone 17 Pro / iOS 27 模拟器的长思考展开、更新、全屏与折叠交互测试通过。截图：[折叠](iphone-reasoning-folded.png)、[展开更新](iphone-reasoning-expanded.png)、[全屏](iphone-reasoning-fullscreen.png)。结果包：`/tmp/floe-workflow-iphone-20260909.xcresult`。

## 验证边界

这些 UI 测试复核已有流程与本轮回归，不能证明 Word/Excel/PPT 已有完整可编辑前端。Office 原生构建、引擎接入、真机编辑、原格式重开仍未验收。跟随滚动和分页的代码/逻辑验证不能替代 100 轮绘画的真机性能记录。

原始结果包保留在开发机 `/tmp/floe-workflow-app-regression-20260909.xcresult` 与 `/tmp/floe-workflow-ui-20260909.xcresult`；同目录的摘要是这些实际测试输出的摘录。

最终应用及素材回归结果包：`/tmp/floe-workflow-final-regression-20260909.xcresult`。

## 持久待办与提示词规则

37 项待办/计划/Goal/提示词回归通过，见 [结果摘要](checklist-prompt-tests-summary.txt)。iPad 实际聊天读取持久待办并展开查看步骤/记录的 UI 测试通过（`/tmp/floe-checklist-ui-20260909.xcresult`）。已人工检查 [折叠](ipad-checklist-folded.png) 与 [展开](ipad-checklist-expanded.png) 截图。

此合成任务故意保留未完成步骤；截图中运行栏仍写“已完成”，说明 R04 需要进一步区分本轮结束与整体任务完成。fixture 没有模型最终回复，因此出现相应提示，不代表一次真实模型执行。测试尚未覆盖实时多轮更新、真正 PiP 展示或模型调用效率。

## 执行中修订、轮次状态与保存冲突

- [5 项待办测试](plan-steering-tests-summary.txt)通过，包含同一运行中重排、追加、重新打开已完成项、取消及修订历史。真实用户引导到模型调用的链路仍待验收。
- [8 项文件会话测试](document-session-tests-summary.txt)通过，包含同尺寸外部修改冲突、保留未保存内容、连续保存和明确放弃。这是文件生命周期验证，不是 Office 排版/编辑验收。
- 更新轮次文案的前三次 UI 测试在侧栏任务出现前失败。数据库读回确认任务和清单已保存。提前本地工作区/聊天加载，并为侧栏直接订阅子数据源后，第四次相同测试通过（`/tmp/floe-checklist-round-state-4.xcresult`）；[折叠](ipad-round-ended-folded.png)、[展开](ipad-round-ended-expanded.png)已人工检查。顶部明确显示“本轮已结束”，不会把剩余待办暗示为全部完成。新截图替代上一节同一场景的旧文案；旧图保留作为对比证据。

文件恢复副本现保留在 Application Support；重启恢复索引和完整编辑器的保存/恢复 UI 仍需接入。外部未遵循文件协调协议的并发写入尚需与模型文件锁统一验证。

## Office 构建包完整性

[12 项构建包/接入补丁测试](office-bundle-tests-summary.txt)通过：移位后相对链接和库清单有效、缺失头文件/库拒绝打包、目录外链接拒绝、文件/源码修改拒绝、未完成构建拒绝。最初用系统旧 Python 运行不支持安全提取参数，切到 Python 3.12 后修正了 macOS `/var` 与 `/private/var` 的路径规范化断言；最终通过。测试使用合成输入，未宣称当前云端产物完整或原生编辑器可运行。


## 第二轮提示词审查

见 [107 项 Swift 回归](prompt-audit-tests-summary.txt)、[4 项官方指南元数据检查](guide-metadata-tests-summary.txt) 和 [完整审查台账](../../INTERNAL_PROMPT_AUDIT.md)。目录 `prompt-snapshots` 保存 5 个合成场景在实际 provider 请求边界的系统消息/工具集合；无真实模型调用，不是 token 效率证明。新签名版本生成后，iPad 指南安装/注册测试及 26 项签名包回归再次通过，见 [结果](signed-guide-tests-summary.txt)。该 26 项与前面的 107 项有重叠，不能相加作为唯一测试数量。

Office 接入补丁的 [锁定源码检查](office-native-overlay-check.json) 只证明补丁可作用于锁定源码及公开键盘 API 片段可编译；没有完整原生控制器、真机输入或文档保真结果。

## 原生 Office 保存与关闭边界

后续补丁的 [8 个生命周期片段场景](office-native-lifecycle-check.json) 和 [12 项构建包回归](office-lifecycle-bundle-tests-summary.txt)通过。测试从锁定上游源码应用补丁，编译真实保存/关闭方法片段，以可控文档回调和真实临时文件验证失败保留、完成顺序及重复关闭；同时使用 iphoneos SDK 检查完整公开控制器/文档头文件。该记录对应新的补丁哈希；上一节键盘检查是此前补丁的历史证据。

这不是完整控制器或 LibreOffice 引擎编译，也不是 UIKit 的实际保存/真机 Office 编辑测试。原生回调、持久恢复目录、自动保存与显式保存协调仍须与 Floe 会话接通后验证。云端资格检查新增独立记录入口，生命周期检查失败也保留已经成功构建的引擎；运行中旧任务不受修改影响。

## Skill 介绍与分页发现

[39 项 Skill 回归和 1 项应用安装检查](skill-description-tests-summary.txt)通过。第三方介绍关键词、多查询、禁用状态、旧元数据、正文隔离和 100 项较大目录的完整分页有测试覆盖；应用实际安装后的介绍与精确读取保持一致，PowerPoint 可找到 Office 指南。没有真实模型召回率、token 收益或发布验收结论。

## 本地运行规则、长输入与请求边界

[98 项相关回归和应用构建](local-context-tests-summary.txt)通过，包含本地模型目录/解析、计划/Goal/恢复既有回归及新增当前输入完整性、系统来源和普通/已准备运行链路。新增 [local-normal](prompt-snapshots/local-normal.json) 与 [local-prepared](prompt-snapshots/local-prepared.json) 保存合成场景下运行服务、时钟刷新与本地适配器组装后的请求；没有调用真实模型。云端五份样本也随执行记录措辞更新。所有样本只包含合成任务内容及运行时钟；实际 token、设备性能和长期恢复效果没有由这些测试证明。

## Office 实际原生构建产物

[构建任务 34268468731](https://github.com/JiangNanGenius/floe-agent/actions/runs/34268468731) 的引擎、前端构建和产物上传全部成功。[原始资格报告](office-native-build-qualification.json)明确嵌入和真机仍未通过。[实际归档清单](office-native-build-inventory.json)记录 SHA-256、16,617 项输入、缺少的头文件/原生目录以及 91 个链接对象；278 个链接库齐全。544 是包内所有库文件数量，含重复交付路径及主机构建库，不能把该数当作 iOS 实际链接数。

旧归档与解包保存在外置盘 `/Volumes/TECLAST/FloeOfficeBuilds/34268468731`，避免占满系统盘。新打包器保留 `.a` 与显式 `.o` 的完整顺序，缺失对象拒绝打包。[16 项测试](office-complete-input-tests-summary.txt)覆盖这些边界及复用任务在摘要不符/已有目录时不覆盖。依赖补齐流水线尚需运行成功；此处不声称完整原生编辑器已接入。
