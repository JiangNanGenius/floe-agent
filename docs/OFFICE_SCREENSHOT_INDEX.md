# Office 截图与文案素材索引

本轮保留真实运行原图，按操作阶段和验证结果索引。截图能说明界面及当时可见结果；保存成功、内容完整和位置准确还需配套运行/文件检查。当前全部为 Mac 上运行 iOS 应用的合成测试数据，不标作 iPhone/iPad 真机效果。

## 已有素材

| 功能与阶段 | 原图 | 版本与证据 | 文案使用边界 |
| --- | --- | --- | --- |
| Word：完整应用右侧只读预览 | [预览](evidence/workflow-upgrade-20260909/office-drain-fullbuild-preview-mac.jpg) | 完整构建 34333115646 / 415dad3；[运行记录](evidence/workflow-upgrade-20260909/office-native-drain-fullbuild-runtime.json) | 可用于说明右侧阅读入口；发布前用最终版复拍 |
| Word：进入全屏原生编辑 | [编辑工具栏与文档](evidence/workflow-upgrade-20260909/office-drain-fullbuild-edit-mac.jpg) | 同上 | 展示真实文档和工具栏，不据此宣称所有工具均已验收 |
| Word：插入通用附件 | [插入后](evidence/workflow-upgrade-20260909/office-drain-fullbuild-insert-mac.jpg) | 同上；该样本原文件附件 18 项检查通过 | 可作为附件操作说明素材；仍需最终版完整步骤图 |
| Word：保存及关闭后新会话重开 | [保存返回](evidence/workflow-upgrade-20260909/office-drain-fullbuild-saved-mac.jpg)、[重开](evidence/workflow-upgrade-20260909/office-drain-fullbuild-reopened-mac.jpg) | 同上；原文件及新会话副本哈希一致 | 仅证明该样本保存闭环 |
| Excel：固定页面附件与两次文字保存 | [只读重开](evidence/workflow-upgrade-20260909/office-xlsx-precise-page-reopened-mac.jpg) | 独立测试应用 23；宿主 34350509488；[三模式记录](evidence/workflow-upgrade-20260909/office-xlsx-precise-ole-runtime.json) | 回归证据；独立应用外壳不作为最终产品宣传图 |
| Excel：随单元格移动的附件 | [只读重开](evidence/workflow-upgrade-20260909/office-xlsx-precise-move-reopened-mac.jpg) | 同上；原尺寸、位置和列宽在文字修改保存中保持 | 未验收实际调整行列后的移动行为 |
| Excel：随单元格缩放的附件 | [只读重开](evidence/workflow-upgrade-20260909/office-xlsx-precise-resize-reopened-mac.jpg) | 同上；保存后尺寸仍偏差 0.05 / 0.01 mm | **失败记录**；不可描述为精确保真通过 |
| Excel：最新组件的检查中断 | [编辑页关闭](evidence/workflow-upgrade-20260909/office-modern-ole-unexpected-close.png) | 独立测试应用 24 / 宿主 34354533462；[运行记录](evidence/workflow-upgrade-20260909/office-modern-ole-interrupted-runtime.json) | **失败现场**：AX/键盘输入阶段 WebContent 崩溃；未完成保存重开，不作产品宣传或尺寸通过证据 |
| PPT：对象位置/尺寸编辑与重开 | [保存前](evidence/workflow-upgrade-20260909/office-ppt-position-size-before-commit-mac.jpg)、[重开](evidence/workflow-upgrade-20260909/office-ppt-position-size-reopened-mac.jpg) | 宿主 34320630546；[运行记录](evidence/workflow-upgrade-20260909/office-ppt-position-size-runtime.json) | 对象指定位置/尺寸通过；图表首柱缺失、内嵌数据丢失，**整体失败记录** |

## 后续每项操作的留图方式

1. 保留操作前、操作中、保存返回、关闭后重开四个阶段；涉及附件/图表时补选择文件、编辑数据、导出或重开数据的画面。
2. 每组记录应用构建、原生组件版本、设备与方向、测试文件、操作步骤、预期与实际结果，并链接文件检查回执。
3. 成功和失败原图同时保留；新版本复拍新增文件，不覆盖旧回归证据。
4. 最终文案素材使用完整 Floe 正式候选版本，补齐 iPhone/iPad 横竖屏；独立测试应用、失败画面和旧版本只用于技术记录。

## 最终版待补画面

- Word：文字/段落、表格、图片环绕、图表、附件、页眉页脚及页面布局。
- Excel：公式栏、区域/行列/工作表、格式、排序筛选、图表数据、附件三种定位行为。
- PPT：幻灯片排序、布局主题、文本/图片/表格、图表数据、附件/媒体、位置尺寸旋转组合、备注与放映。
- 通用：右侧阅读到全屏编辑、保存/另存、撤销重做、冲突和恢复；iPhone/iPad 键盘与横竖屏。

最终通过后，用这些素材同步更新使用指南、GitHub 介绍和发布说明；以 [Office 前端验收表](OFFICE_FRONTEND_ACCEPTANCE.md) 的实际通过范围为准。
