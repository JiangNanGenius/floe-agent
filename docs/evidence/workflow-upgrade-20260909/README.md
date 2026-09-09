# 本轮升级验证记录

这是 `codex/office-workflow-upgrade` 工作分支的阶段证据，**不是整轮验收或发布声明**。素材与任务均为合成测试数据。

## 当前 Office 证据摘要

- **Word 真实附件局部闭环通过**：宿主 34313654241 编译/链接/Swift 导入成功，独立 Mac 应用 11 实际插入附件并完成两轮单次撤销/重做，保存关闭后只读重开。最终 [18 项结构检查](office-word-attachment-owned-undo-structure.json)通过，中文/表情文件名、Package 类型、图标及原附件字节保留。见 [运行回执](office-word-attachment-owned-undo-runtime.json)、[单次撤销](office-word-attachment-owned-single-undo-mac.jpg)、[重复重做](office-word-attachment-owned-double-cycle-redo-mac.jpg)、[只读重开](office-word-attachment-owned-undo-reopened-mac.jpg)。完整 Floe 选择/写回、附件查看/导出/替换、Excel/PPT 附件和真机仍未完成。
- **真实编辑往返新增结果**：Word 在独立原生界面编辑、保存 DOCX 并关闭重开成功，[15 项结构检查](office-word-roundtrip-structure.json)通过；见[编辑前后保存画面](office-word-edit-before-save-mac.jpg)、[重开画面](office-word-reopened-mac.jpg)和[原生事件](office-word-native-events.json)。这不是全部 Word 功能或原用户文件写回验收。
- **Excel 数字格式已修复，整体仍未通过**：宿主 34309184148 在原系统 zh-Hans-TW 下匹配已打包语言，原样保存及 B2=36 编辑保存均保留 General，重开 C2=72，见 [修复运行回执](office-editor-language-fixed-runtime.json)。编辑样本 22/23 项通过，A 列宽 22→21.21 仍失败。先前 [五项格式失败](office-excel-roundtrip-structure-failure.json)和[英语对照](office-excel-english-control.json)保留为定位证据，不再代表最新修复状态。
- Mac 辅助功能操作分别触发 Excel/PPT 的 WebContent 数组越界，见[失败摘要](office-editor-accessibility-failures.json)。坐标交互完成 Excel 修改不代表崩溃修复。PPT 原生对象编辑往返、两种图表首点显示仍待验证。
- [只读修复宿主 34306039335](https://github.com/JiangNanGenius/floe-agent/actions/runs/34306039335) 完整编译、链接和 Swift 导入成功；取回后校验 4,785 个文件与 178 个目录。运行使用的源码/补丁和产物均已锁定。
- 独立签名应用在 Mac Designed for iPad 中显示真实 Word 页面。预览不再出现编辑入口，菜单保留只读操作；全选后输入不修改内容，显式保存被拒绝，工作文件和引擎副本均与合成源文件逐字节一致。见 [运行回执](office-readonly-runtime-check.json) 和 [截图](office-native-readonly-save-rejected-mac.jpg)。粘贴自动化超时，未据此声称粘贴完整验收。
- 完整 Floe 应用较早的构建 34301236609 和 34302444252 已成功，前者取回并复核加载链及资源；它们使用旧框架，不证明当前只读修复已在完整 Floe 中运行。
- 全屏真实编辑/原文件写回/重开保真、强制后端修改命令、物理设备及 TestFlight 仍待验证。下面保留的是历次阶段证据，不能将不同版本的检查拼成整轮完成。

## 早期 Office 原生宿主进度

[宿主构建 34292622779](https://github.com/JiangNanGenius/floe-agent/actions/runs/34292622779)
已成功编译、链接并通过 Swift 导入。取回的未签名框架、公开头文件、
4,780 个资源文件和 174 个目录已逐项验证，见
[宿主产物回执](office-native-host-qualification.json)。首次宿主构建 34292156866
因缺少显式 Apple framework 链接失败，后续已补齐。

[7 项原生打开片段检查](office-native-copy-open-tests.json)、
[8 项保存/关闭片段检查](office-native-host-lifecycle.json)和
[11 项文件会话回归](office-native-session-retention-tests-summary.txt)已通过。
这些记录不证明 Floe UI 已接通、原文件已安全写回、真机可编辑或 Office 排版保真。
右侧只读、全屏编辑、保存关联、恢复和发布验收继续保留为未完成。

取回框架还通过了本地 iphoneos Swift API 类型检查：实际调用运行时准备、
带错误处理的文档初始化与打开/保存/关闭回调，使用
[API 探针](../../../FloeAgent/scripts/fixtures/office_native_host_api.swift)。
它没有执行引擎或打开真实 UI。

[11 项安装与主应用复制检查](office-host-bootstrap-embed-tests-summary.txt)通过；
[本地安装产物校验](office-host-installed-verification.json)覆盖 4,785 个文件和
178 个目录（包含框架、清单及全部资源）。主应用工程和云端设备版构建入口已接线，
实际应用编译、运行与 Office UI 验收仍需分别取得证据。

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

补齐任务 [34286492116](https://github.com/JiangNanGenius/floe-agent/actions/runs/34286492116) 已启动；同一提交的常规打包/补丁及预检任务 [34286492003](https://github.com/JiangNanGenius/floe-agent/actions/runs/34286492003) 成功，后者不执行完整引擎重建。原始库抽样对象确认为 iOS、最低 26.0、SDK 27.0；仅是单对象平台检查，不代替全部链接和真机验证。

## 2026-09-09 原生 Excel 语言回归与完整编辑边界

宿主 [34309184148](https://github.com/JiangNanGenius/floe-agent/actions/runs/34309184148) 编译、链接和 Swift 导入通过；[实际取回清单验证](office-language-host-installed.json) 与 [18 项 Foundation 语言匹配检查](office-editor-language-tests.json)通过。系统原 zh-Hans-TW 不变，编辑器匹配 zh-CN；[运行回执](office-editor-language-fixed-runtime.json)记录原样保存及 B2=36 编辑保存重开，General 和公式保留。

对照：[旧未匹配语言的无编辑保存](office-excel-unmatched-language-control.json) 仍产生乱码；[简体中文旧宿主对照](office-excel-zhcn-controls.json) 保持 General。[修复后无编辑截图](office-excel-language-fixed-control-mac.jpg) 和 [编辑重开截图](office-excel-language-fixed-edited-mac.jpg)已保存。编辑样本 [23 项结构检查](office-excel-language-fixed-edited-structure.json)通过 22 项；列 A 宽度 22→21.21 仍失败，图表首点显示异常也未解决。

这些只证明局部 Excel 回归。完整编辑功能仍未完成，尤其通用附件导入/嵌入通道缺失。用户要求的真实操作与断点见 [Office 前端逐项验收](../../OFFICE_FRONTEND_ACCEPTANCE.md)。不以原生界面或简单文字/数字编辑成功代替完整 Word/Excel/PPT，也不代表 Floe 原文件写回、真机、Microsoft Office 重开或新版本发布通过。
