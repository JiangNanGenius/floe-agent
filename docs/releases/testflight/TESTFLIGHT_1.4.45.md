# Floe Agent 1.4.45（Build 76）TestFlight 测试说明

本构建面向首个公开 Beta 前的可靠性与工作区体验回归。源码版本、标签和 GitHub Release 不是 Apple 处理回执；只有 App Store Connect 显示构建为 `VALID` 且测试组能看到该构建，才算分发完成。

## 重点验证

1. **任务连续性与 Harness**：在含多个工具的任务中切后台、强制结束后恢复，以及在审批、远程任务和工具批次之间恢复。已经成功的工具不得重复执行；结果不确定的外部操作必须明确提示核验。下一步思考、工具请求、审批原因、工具结果和最终回复应按顺序归入对应步骤。
2. **VNC 与远程主机**：从主机列表进入编辑，分别保存普通 VNC 与 SSH 隧道 VNC 的地址、端口和密码；重新进入后密码状态应仍为已配置。验证连接、截图、结构化目标、坐标回退、点击和文字输入。不要在反馈中附带密码。
3. **浏览器操作**：优先用新鲜的结构化元素引用点击；Canvas 或图片型页面使用截图后的坐标回退。导航或页面变化后旧引用必须返回过期，而不能继续猜测点击。
4. **标准 MCP**：添加一个可信的 Streamable HTTP 服务器，验证连接、工具发现、逐工具启停和普通 Agent 调用。凭据只应显示“已配置”，不得出现在日志、聊天或导出中。画布默认不获得 MCP 工具。
5. **工作区与画布**：私有工作区创建后应立即挂载；远程工作区目录应能展开并读取文件。文件检查器可打开原生画布，创建多张画布、移动文本、手绘、平移、缩放、重新进入并恢复内容。
6. **审批与远程执行**：在运行中切换权限，验证普通环境准备、软件包、换源和守护程序更新不会逐条重复询问；删除、凭据、上传和灾难性命令仍应拦截。审批结果和原因只显示在对应工具展开区。
7. **本地模型与 Apple Foundation Model**：本地大模型只在真机测试。验证多轮聊天、工具调用后继续回复、上下文用量与内存诊断。下载式本地模型不加载视觉组件；附图应由 OCR 写入工作区。Apple Foundation Model 应能连续完成第二轮，不应停在“准备中”。
8. **画中画与长任务**：离开 Floe 后进度画中画应稳定创建、持续到任务终态且不黑屏；前台不应出现遮挡输入区的伪画中画。任务阶段变化不能提前结束系统画中画。

## 反馈要求

请注明 Build 76、设备型号、iOS/iPadOS 版本、所选模型/服务商、连接方式、准确操作、结果与时间。进程退出、任务卡停、VNC 失败或画中画异常时，只上传本次最新的脱敏 Floe 诊断，以及时间匹配的 Xcode Organizer、TestFlight crash 或设备日志。不要发送 API Key、Token、密码、SSH 私钥、证书或描述文件。

## English summary

Build 76 focuses on durable tool-batch settlement and recovery, VNC profile/password editing, structured and screenshot-based computer control, standard Streamable HTTP MCP, native workspace canvas, live permission changes, and first-public-beta regression coverage. Test local MLX models, Apple Foundation Model multi-turn behavior, Picture in Picture, Keychain persistence, local-network access, and real remote connections on physical devices. Report only redacted, time-matched evidence.
