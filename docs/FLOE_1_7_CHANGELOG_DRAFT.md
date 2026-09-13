# Floe 1.7 变更草稿 / Unreleased changes

这是整合分支的变更草稿，不是已发布版本说明。正式发布另行安排；build 156 固定源码的双 SDK 自动检查已通过，TestFlight 分发恢复仍在进行，真机验收由用户安装后完成。精确测试范围见[实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md)。

## 运行环境与执行

环境类型统一到 FloeEnvironments，工具与后台任务逐步携带环境归属。登记恢复、基础版本重建标记、路径检查、CAS 引用保护与删除等待已有定向测试。原生 shell 在 Debug/Release 最小 App 中通过 9 项命令和交互输入/关闭，包含取消、超时和工作线程退出。Node 改用一次初始化宿主和串行 worker，加入 stdin、环境、输出上限、运行中取消与超时后的资源归属保护，并锁定框架及 npm/pnpm/yarn 来源与摘要。

旧依赖迁移、模板/晋升、配额、Python/WASM 安装与各类后台任务的完整环境链路仍待验收。

## 软件包

发布器与客户端使用真实 OpenPGP 签名仓库样本。安装增加依赖版本检查、文件归属、摘要、升级/卸载与恢复日志；维护脚本及不支持的载荷明确失败。修复 Debian ar 头缺失和 Release 日期解析。保留已修改文件与失败恢复现场，避免静默覆盖。

15 项候选包尚未全部制作和实测，不能作为完整官方可用目录发布。

## 媒体与模型

转码和音频转换实际应用支持的参数组合，使用有界处理和验证后提交。音频编辑改为分块处理，真实应用剪辑、淡入淡出和两路混音增益；JPEG 抽帧实际编码为 JPEG，批量产物验证前暂存，代理视频保留宽高比。基础视频编辑接入剪辑、同步变速、音量与淡入淡出；未接通操作拒绝执行，取消不会把未验证输出当作完成产物。

模型服务接入签名目录地址及正确的签名文件路径，待制作条目不作为可安装能力。安装增加路径、大小、摘要与登记检查。33 项模型的最终资格评估、15 类能力的推理样本和真机性能证据仍未完成。

## 轻量工作台与说明

工作区本地视频预览新增媒体工作台入口，带入素材并提供单素材区间、速度/音量、编码设置、预览、导出、取消/重试和参数保存重开。完整 App 界面验收、共享任务队列和聊天附件回接仍未完成。

项目介绍、双语指南、架构、构建、迁移恢复、兼容性矩阵、贡献/支持/安全说明同步更新。floe-video 1.0.1 已通过云端签名和本地校验，只声明已接通路径。

## 分发与完整验收

TestFlight 分发需要固定源码的开发/发布 SDK 构建、自动化回归、Apple 处理和内部测试组可安装确认。用户在安装后检查 iPad/iPhone 真机、Office 保存重开及中文文档、聊天/工具、工作区、Canvas 和 PiP 的完整交互。真机检查不再作为上传前置条件，其结果仍独立保留。

### Interface and container management

- General settings now includes visual Automatic/Light/Dark choices with immediate app-wide updates and inherited Canvas appearance.
- Added project/conversation container management with exact-environment package actions, inherited dependency inspection, lifecycle controls, measured capacity and recoverable task feedback. Production apt source/package provisioning remains pending.
- Refined reasoning and tool frames, concise batch summaries, persistent manual folding and reduced-motion-aware insertion animations. Running tools, failed calls and approvals remain visible in folded batches.

## 手记、动态导图、Office 与语音

新增高于创意模式的独立“手记”入口，支持笔记本、最近打开、收藏、搜索、回收站与确认后永久删除。手写默认仅 Apple Pencil，手指书写单独开启；支持 PDF/图片背景、选区和套索提问、保存 AI 回答与来源。关联导图可单独编辑或以 PDF 小窗打开，主题支持图片和文件附件，内容变化动态排版。导图编辑与 Canvas 撤销分离。

手记复用 Office 编辑入口，提供可编辑归档及 PDF/大纲导出。语音入口统一使用按需 Whisper Small、失败回退 Apple；视频自动字幕与 Agent 文件转录复用同一服务。完整交互和真机验收尚未完成。

修复图片加载后的导图连线更新、Agent 布局方向未应用、iPhone 旋转阅读位置偏移，以及 Word/Workbook 工具发现缺项。脚本型 Skill 的依赖不再误识别 Python 属性或退役工具名。
