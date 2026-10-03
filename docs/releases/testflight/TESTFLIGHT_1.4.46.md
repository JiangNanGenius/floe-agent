# Floe Agent 1.4.46（Build 77）TestFlight 测试说明

本构建是首个公开 Beta 前的功能收口候选。源码、标签和 GitHub Release 不是 Apple 处理回执；只有 App Store Connect 显示构建处理完成且目标测试组能看到该构建，才算分发完成。

## 重点验证

1. **任务连续性与 Harness**：运行包含并行或批量工具的长任务，在工具完成、审批、切后台和强制结束等边界恢复。已经成功的工具不得重做；同一工具、相同参数和相同错误仅在没有新进展的阶段内触发循环防护。工具请求、执行中状态、审批原因、结果、后续思考和最终回复必须按顺序显示。
2. **VNC 与浏览器操作**：在主机编辑器中同时保存普通 VNC 与 SSH 隧道 VNC，重新进入后确认密码状态仍为“已安全保存”。VNC 和浏览器均应优先使用结构化或 OCR 文字引用，只有缺少合适引用时才使用绑定到新鲜截图摘要的坐标；输入已发送不能被误报为任务成功。
3. **远程主机与工作区**：保存 SSH、VNC、Telnet、普通 TCP 或 BLE 串口配置，验证模型可在授权范围内更新连接元数据。私有工作区应自动挂载，远程工作区应展开真实远端目录与文件；默认执行目标可选择已启用的远端执行环境。
4. **无限画布与创意模式**：侧边栏应出现“创意模式”。每个工作区的画布可移动、绘制、平移、缩放并恢复；受限画布助手只获得 `web.search`、`web.fetch` 和用户明确开放的 MCP 工具，不获得浏览器控制、终端、SSH、Git 或任意文件访问。
5. **标准 MCP**：在“技能”中添加可信的 Streamable HTTP MCP 服务，验证连接、工具发现、逐工具启停和普通 Agent 调用。凭据只显示配置状态，不得出现在聊天、日志或导出中；画布默认不开放 MCP。
6. **Office 与工作区编辑**：让 Agent 创建 DOCX、XLSX 和 PPTX，使用系统预览检查，再进入 Floe 基础编辑器手工修改 Word 段落、表格单元格/公式、幻灯片文字和演讲者备注。保存后重新打开，并确认未编辑的主题、样式、图片和关系仍保留。
7. **模型与供应商设置**：分别启停供应商和模型；打开“从首页模型列表隐藏”后，模型不再出现在新任务主模型选择器，但仍可作为辅助模型或供已有任务继续使用。添加供应商时不应出现“本地模型”协议选项。
8. **本地模型与 Apple Foundation Model**：只在真机加载 MLX 模型。下载式本地模型按文字模型运行，附件图片先由本机 OCR 写入工作区；Apple Foundation Model 仅承诺聊天及系统实际开放的 Apple 能力。验证多轮第二次发送、工具结果后的自然语言回复、真实上下文用量和准备状态及时结束。
9. **技能与 Python**：带纯 Python 脚本或锁定版本纯 Python 包的技能只在创建或安装时审计一次；未改变的指纹可复用，改变脚本、依赖、原生代码或安装钩子必须重新拦截。二进制科学包继续走明确标注的 Pyodide/WASM 路线。
10. **聊天、画中画与设置**：向上查看长对话后，右下角向下箭头应返回最新消息。任务画中画只在离开 Floe 后出现，阶段变化不能令其提前消失，也不能在前台遮挡输入按钮。归档或删除任务后侧边栏应立即更新。

## 反馈要求

请注明 Build 77、设备型号、iOS/iPadOS 版本、模型与供应商、连接方式、准确操作、结果和时间。崩溃、卡停、VNC 失败或画中画异常时，只上传时间匹配的脱敏 Floe 诊断、Xcode Organizer、TestFlight crash 或设备日志。不要发送 API Key、Token、密码、SSH 私钥、证书或描述文件。

## English summary

Build 77 closes the first-public-beta feature set: durable harness settlement and recovery, evidence-bound browser/VNC control, editable VNC profiles, standard MCP, bounded canvas research, native infinite canvas, per-provider and per-model visibility controls, audited Python-backed skills, and native DOCX/XLSX/PPTX creation plus basic manual Office editing. Local MLX models, Apple Foundation Model multi-turn behavior, PiP, Keychain persistence and real remote connections still require physical-device validation.
