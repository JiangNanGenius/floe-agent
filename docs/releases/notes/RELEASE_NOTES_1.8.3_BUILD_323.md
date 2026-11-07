# Floe 1.8.3 (323)

## 简体中文

本构建继续整批预研接入的内部测试，集中补齐 322 测试中发现的入口、操作和保存链路。

- 空间恢复置顶作品、实际使用记录和传统文件夹；文件默认列表，可切换缩略图。作品和文件夹增加删除与最近删除恢复；任务文件树、搜索结果和预览补齐删除及返回入口，并保护正在编辑的文件。
- 工具箱采用顶部横向展示与完整工具列表。漫游默认使用当前网关；Wi-Fi 名称与 BSSID 按系统授权读取。修复诊断结果、文件校验选择和导出；AI 分析增加进度、停止与超时反馈。普通聊天接入 WebSocket／匿名 MQTT 与本会话通信记录工具。
- 加工和 3D 打印从 CAD 的加工入口进入。加工先选择机床，再设置毛坯、坐标和工序；预览沿刀路逐步去料并显示已实现的碰撞检查。切片完成自动进入“预览”，参数与保存结果保持对应。
- 创意模式画布复用原有编辑框架，保留正文、资产、历史和撤销；补齐源文件、编辑器及流程操作，并回收不再引用的旧快照副本。
- 补齐 CAD 当前对象读取、改名和保存，二维 DXF 导入接线，以及建筑工作台的墙体、矩形房间工具。导入网格可准备后进入雕刻；精确实体转换需要明确确认。
- 补齐音视频素材导入、字幕样式、音乐和化学工具的实际结果回流，并修复会议开页和全局资料检索。
- AI 可读取音频的分声道波形区间、峰值、RMS、静音统计和对应采样范围；结果可继续传给模型，音乐渲染回执关联实际生成文件的音频观察。

请重点检查菜单、开页、按钮及此前确认的布局。本轮没有重跑完整功能和稳定性验证；USB 原生驱动包尚未纳入，实际硬件打印、机床安全、物理音频、AP 切换及外部服务仍按各自真实能力和授权使用。音频波形统计不代表听音或语义识别，制造预览也不代表完整机床防撞认证。315 正式审核和自动发布设置保持不变，本构建仅内部 TestFlight。

## English

This internal build continues the predevelopment integration and closes entry, operation and persistence gaps reported during Build 322 testing.

- Space restores pinned works, actual recent use and ordinary folders, with a default list and optional thumbnails. Works and folders gain deletion and recovery through Recently Deleted. Task file trees, search results and previews gain guarded deletion and return to their owning file view, protecting active editors.
- The toolbox combines a horizontal showcase with the complete tool list. Roaming defaults to the current gateway; Wi-Fi names and BSSIDs use system authorization. Diagnostics, checksum file selection and export are corrected. AI analysis gains progress, Stop and timeout feedback. Ordinary chat gains WebSocket, anonymous MQTT and session traffic capture tools.
- Manufacturing and 3D printing open through CAD's Manufacturing entry. Machining starts with machine selection before stock, coordinates and operations. Its preview removes material along the toolpath and shows implemented collision checks. Completed slicing opens Preview automatically, with parameters bound to the saved result.
- Creative mode uses the original canvas editor, preserving content, assets, history and undo while exposing source, editor and flow operations. Superseded stored snapshots are collected while complete undo history is retained.
- Adds current CAD object inspection, rename/save, native 2D DXF import wiring, and Building tools for walls and rectangular rooms. Imported meshes can be prepared for sculpting; conversion of exact solids requires explicit consent.
- Completes media import, caption styling and result handoffs for music and chemistry, and repairs meeting opening and global source search.
- AI can inspect per-channel audio waveform bins, peaks, RMS, silence statistics and sample ranges. Complete results reach subsequent model calls; music render receipts inspect the actual rendered file.

Please focus on menus, pages opening, controls and the agreed layouts. This round does not repeat comprehensive functional or stability qualification. The native USB driver package is not yet included. Physical printing, machine safety, audio behavior, AP roaming and external services retain their actual capability and authorization requirements. Waveform statistics do not imply listening or semantic recognition; manufacturing previews do not certify complete machine collision safety. Build 315's formal review and automatic release settings remain unchanged. Internal TestFlight only.
