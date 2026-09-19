# Build 199 — Office 编辑状态与 IDE 内嵌修复记录 / Office editing-state and IDE embedding repair record

日期 / Date: 2026-09-20 · 分支 / Branch: `codex/build199-office-ide-repair` · 范围 / Scope: Office 交互状态机、Notes 默认编辑、IDE 内嵌、文件管理器全屏路由（无引擎重写、无 App 重构建）

## 交互状态根因 / Interaction-state root causes

1. **“正在关闭…”转圈 / read-only 卡死** — 预览控制器经 `loadViewIfNeeded` 强制加载视图但从未挂载时（Notes `open`→`requestEditing` 竞速、快速点编辑），引擎侧没有任何 kit 会话可以应答 `bye`，Swift 侧关闭等待 8 秒后超时报错。宿主现在跟踪 `openRequested`（viewWillAppear）/`openSettled`/`documentOpened`；从未真正打开的会话在 `closeWorkingCopyWithCompletion` 立即结算，不再出现关闭转圈。
2. **首次编辑可成功、后续失败** — (a) `executeEdit` 失败路径遗留 `readOnly == false`：失败界面（只读才显示重试）、IDE 操作栏与关闭对话框都把死会话当成“可编辑”，用户被困在只读态。现在失败即恢复 `readOnly = true` 并保留真实原因。(b) 编辑权限确认窗口仅 ~3s，冷启动/二次挂载的引擎页面来不及经 observer 回报真实后端权限，被误判为“只读打开”并退回预览；窗口延长到 ~9s。(c) 只读预览挂载此前要等 0–4s 引擎权限探测才上报就绪；预览权限被挂载授权与锁定脚本强制只读，探测无意义，现在 UIDocument 打开后立即上报。
3. **第二个窗口 / 内部关闭冲突** — IDE 的 Office “全屏”按钮曾把同一控制器重挂到第二个全屏编辑器（自带返回/关闭铬件，与宿主标签关闭冲突）；文件预览还有另一条复用内嵌会话的 cover 编辑器，而检查器展开按钮打开的是新会话的专用编辑器——同一原文件可能同时存在两个工作副本，保存互相冲突。

## 行为规则（修复后）/ Behavior after repair

- **Notes**：既有/导入 Office 文档第一次进入为只读预览，页首始终给出清晰的宿主级“编辑”操作（含 iPhone compact）；首次成功打开后，之后默认直接进入编辑（`OfficeDocumentModeMemory` 规则不变）；本运行新建文档首次即直编。
- **IDE**：Word/Excel/PPT 在各自 IDE 标签内嵌预览与编辑，打开绝不产生第二个 App 标签/窗口；标签操作栏保留 编辑/保存/放弃/分享（compact 下为纯图标，远端快照提示保持文字）；保存/放弃后内嵌只读预览自动恢复；标签关闭仍走 保存/放弃/取消 对话框。
- **文件管理器**：预览的“编辑”与检查器的展开动作都进入同一个专用全屏 `OfficeFullscreenEditorView`；打开前先释放内嵌预览会话，同一原文件任意时刻只有一个活会话；关闭编辑器后预览按已提交字节重载。
- **页面内部控件**：引擎自带关闭按钮（`closeButtonEnabled=false` + CSS）与浮动移动编辑入口继续在脚本层移除；只读挂载的权限锁定脚本不变。
- **Pencil 批注**：笔画设置仍按文档身份持久化（本地=物理 URL，Notes/远端=稳定逻辑身份），批注走引擎矢量自由画笔并随保存/导出提交；状态机修复保证编辑—保存—再编辑循环不再丢批注会话。

## 变更文件 / Changed files

- `FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm` — 打开生命周期标志、从未打开会话的关闭快速结算、只读预览免权限探测。
- `FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift` — 编辑失败恢复只读、权限确认窗口延长、预览“编辑”操作全尺寸类可见、移除菜单重复入口。
- `FloeAgent/FloeApp/Workspace/WorkspaceIDEView.swift` — 删除 Office 全屏 cover/占位/“全屏”动作，操作栏 compact 图标化。
- `FloeAgent/FloeApp/Workspace/IDEWorkspaceTabs.swift` — 注释对齐（无行为变更）。
- `FloeAgent/FloeApp/Workspace/FilePreviewView.swift` — 预览编辑路由到专用全屏编辑器，先释放内嵌会话。
- `FloeAgent/project.yml` + `FloeAgent/FloeAgent.xcodeproj/project.pbxproj` — 注册 `OfficeBridgeStateTests.swift`（FloeAppTests；本机缺 Vendor/Office 预置输入，xcodegen 无法重生成，pbxproj 按生成器模式手工同步并经 plutil 校验）。
- 测试：`FloeAgent/Tests/FloeAgentUITests/OfficeBridgeStateTests.swift`（新增）、`FloeAgent/scripts/tests/run_office_embedded_controls_fixture.py`（新增）、`FloeAgent/scripts/tests/office_ide_repair_invariants.py`（新增）、`FloeAgent/scripts/tests/ide_review/review_invariants.py`（更新为内嵌设计）。

## 聚焦测试与结果 / Focused tests and results

| 检查 | 结果 |
| --- | --- |
| `office_ide_repair_invariants.py`（22 项静态不变量） | 22/22 通过 |
| `ide_review/review_invariants.py`（Git/Office/IDE 22 项） | 22/22 通过 |
| `run_office_embedded_controls_fixture.py`（node，真实抽取脚本：关闭/编辑铬件隐藏、ModifiedStatus 锁存、字体下拉、幂等、只读锁定） | 6/6 通过 |
| `run_readonly_permission_fixture.py`（node，权限脚本既有夹具） | 6/6 通过（无回归） |
| `OfficeEditIntentQueue` 逻辑探针（swiftc 直连真实源码，队列语义 15 项） | 15/15 通过 |
| `OfficeDocumentModeMemory` 模块探针（对真实构建产物：首进预览/次进编辑/快照回读/键派生 8 项） | 8/8 通过 |
| `swift build --target FloeDocuments` | 通过 |
| 变更 Swift 文件 `swiftc -parse` | 全部通过 |
| `plutil -lint project.pbxproj` | OK |

未跑：`swift test` 全矩阵在本机因 `FloeLocalModelsTests` 既有的 macOS 15.4 可用性错误而无法整体构建（与本修复无关，保持原样）；App/设备构建按仓库约定留在云 CI。

## 仍需真机核对 / Remaining device-only checks

1. iPhone + iPad：Notes 首进预览（页首“编辑”清晰可见）→ 编辑 → 保存 → 再次进入默认直编；反复多次编辑/保存不再出现“正在关闭…”长转圈或只读卡死。
2. IDE 内打开 docx/xlsx/pptx：始终停留在同一标签，无第二窗口；保存/放弃后预览自动恢复；标签关闭对话框三路行为正确。
3. 文件管理器：预览“编辑”与展开按钮都进入同一专用全屏编辑器；编辑器关闭后预览刷新为新字节；连续打开不同 Office 文件无串会话。
4. Apple Pencil：批注后保存、重开、再编辑，笔画与颜色/线宽设置保持；受保护文档/需编辑密码文档仍给出真实原因而非伪造可编辑。
5. 远端（云/网络）Office 快照：无编辑入口、提示文案完整（compact 下不被图标化吞掉）。
