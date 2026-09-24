# Floe 1.7.0 (227) — candidate / 候选说明

**Status / 状态：尚未发布。** This document records the candidate scope. Build, IPA, upload, Apple processing, Floe QA availability, and physical-device behavior must be recorded separately after they occur. / 本页先记录候选范围；构建、IPA、上传、Apple 处理、Floe QA 可安装及真机行为须取得各自证据后分别补记。

## 简体中文

Build 226 的云端编译在文件树压缩入口缺少 `FloeTools` 导入处失败，没有生成 IPA 或上传 TestFlight。本构建补齐该导入并重新从不可变源码编译；其余候选功能范围沿用下文。


本候选延续 Runtime v2：Linux 基础镜像与软件模板可复用，各 Environment 保留独立系统修改和工作区引用；设置与执行入口共用镜像准备状态。新增常用开发与文档软件模板的构建流程，以及环境内真实包清单和安装范围。**预装模板只有在云端镜像完成安装、校验并由 TinyEMU 客体再次启动验证后才启用；尚未通过的镜像不会固定到 App。**

镜像资格现状：早期云端运行在 TinyEMU 内解包超时，现改为云端宿主辅助安装，并保留签名 APT、实际安装脚本、包数据库与 TinyEMU 两次启动验证。基础模板 [run 35928017233](https://github.com/JiangNanGenius/floe-agent/actions/runs/35928017233) 通过资格检查，已在 [Linux 基础模板 prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-basic-20260923.1) 发布镜像与对应源码，分发工作流 [run 35935814778](https://github.com/JiangNanGenius/floe-agent/actions/runs/35935814778) 成功，发布资产摘要已固定到 App 源码。开发文档模板 [run 35928029851](https://github.com/JiangNanGenius/floe-agent/actions/runs/35928029851) 通过镜像资格检查；其 Debian 对应源码 [run 35930774915](https://github.com/JiangNanGenius/floe-agent/actions/runs/35930774915) 及包含 `pypdfium2` 的 PyPI 对应源码 [run 35939078878](https://github.com/JiangNanGenius/floe-agent/actions/runs/35939078878) 均已收集并通过缺口检查。开发文档模板已在 [组件 prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-dev-document-20260924.1) 发布镜像及对应源码；[分发 run 35941775534](https://github.com/JiangNanGenius/floe-agent/actions/runs/35941775534) 成功，资产摘要已固定到 App 源码。两种模板仍须通过本版 App 构建与安装路径检查，才算用户可下载。

TinyEMU 已加入无 JIT 双 hart 的源码实现、设备 CPU/内存池与资源准入；发布默认仍受单核安全门控制。只有真实双核 Guest 的并行、I/O、停止落盘和恢复检查通过，才开放双核配置。Linux 与 MLX 使用统一的资源仲裁；本地模型新增分阶段加载错误和工具续轮处理。源码及云端宿主检查不等于用户设备上的 MLX 加载、测速或多轮工具成功。

模板环境选择外部工作区时，现在先保存原始文件选择器 URL 的安全作用域书签，再登记环境；Linux 的 9P 共享在 VM 运行期间持有授权，确认停机后释放。旧环境的外部目录若没有有效书签，将明确要求重新授权，而不会启动一个不可读的共享目录。书签与租约的组件测试已通过；iPad 文件提供者的实际授权仍待设备验证。

IDE 候选改用 iPad 原生 SwiftUI 工作台布局：左侧活动栏切换文件、搜索与源码管理；保留多标签编辑区、底部终端和状态栏。Git 面板显示变更目录树并沿用仓库操作服务。文本与代码仅使用原生编辑器，不提供 Web 文本编辑切换；Markdown 使用同一编辑缓冲区提供大纲、格式操作与原生预览，代码字体可缩放。Office 继续使用现有 WebKit 宿主及打开方式；PPT 编辑入口改为先取得演示文稿绘制证据，再进入编辑布局，并要求编辑后的新首帧。**PPT 可编辑、保存和重开仍需在 iPad 真机验收。**

原生 IDE 的[定向云端 App 与界面运行 35947162133](https://github.com/JiangNanGenius/floe-agent/actions/runs/35947162133) 整体通过：iPad mini 的四项用例通过；iPhone 的 DXF 预览断言首次失败、自动重试通过，最终结果仍保留该次失败记录。原生保存与冷启动重开已有模拟器证据，真机键盘、输入法和触控体验尚未验收。

本候选还包括多行输入与完整提示词编辑、按会话保存草稿、原生归档操作、环境运行状态与 PiP/通知修复，以及统一的第三方许可证入口。GitHub 是主要发布源；Gitee 的源码与可容纳资产以独立流程同步，镜像状态不会阻塞 GitHub 和 TestFlight 交付。

发布记录待填：不可变源码 SHA、标签、云端构建运行、IPA 摘要与 Bundle 版本、签名上传、Apple `VALID` 状态、Floe QA 分组与可安装状态。真机 MLX、PPT、PiP、通知和输入体验证据须逐项记录；未取得时维持“待验收”。

## English

Build 226 failed cloud compilation because the file-tree compression entry lacked the `FloeTools` import. No IPA was produced or uploaded. This build adds the import and recompiles from a new immutable source; the candidate feature scope below is unchanged.


This candidate continues Runtime v2: reusable Linux base images and software templates, with private system changes and workspace references per Environment. Settings and execution use the same image preparation state. It adds a build path for common development and document packages and a real package inventory with installation scope. **A preinstalled template is enabled only after cloud installation, verification, and a second boot and package check inside TinyEMU; an unqualified image is never pinned into the App.**

Earlier cloud runs timed out while unpacking packages in TinyEMU. Cloud-host-assisted installation now retains signed APT, real maintainer scripts and the package database, followed by two TinyEMU boot checks. The [basic-template run 35928017233](https://github.com/JiangNanGenius/floe-agent/actions/runs/35928017233) passed image qualification; its image and corresponding sources are published in the [Linux basic-template prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-basic-20260923.1), with successful [distribution run 35935814778](https://github.com/JiangNanGenius/floe-agent/actions/runs/35935814778) and exact asset hashes pinned into the App source. The [dev-document run 35928029851](https://github.com/JiangNanGenius/floe-agent/actions/runs/35928029851) passed image qualification; its [Debian source run 35930774915](https://github.com/JiangNanGenius/floe-agent/actions/runs/35930774915) and [PyPI source run 35939078878](https://github.com/JiangNanGenius/floe-agent/actions/runs/35939078878), including `pypdfium2`, report no source gaps. The image and corresponding sources are now public in the [dev-document template prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-dev-document-20260924.1); [distribution run 35941775534](https://github.com/JiangNanGenius/floe-agent/actions/runs/35941775534) succeeded and exact asset hashes are pinned into the App source. Both templates still need this App build and install-path verification before either is described as user-downloadable.

The source now includes a no-JIT dual-hart TinyEMU implementation, device CPU and memory pools, and admission control. The shipping default remains behind the single-core safety gate until a real dual-core Guest passes concurrency, I/O, shutdown, disk flush, and recovery checks. Linux and MLX use shared resource arbitration; local-model work adds staged load diagnostics and tool continuation handling. Source checks and cloud hosts do not establish successful MLX load, benchmark, or multi-turn tool use on the user's iPad.

When an external workspace is selected for a template environment, the App now saves a security-scoped bookmark from the original picker URL before registering the environment. The Linux 9P share holds that grant while the VM runs and releases it after confirmed stop. A legacy external folder without a valid bookmark now asks for reauthorization instead of booting an unreadable share. Bookmark and lease component tests passed; actual iPad Files-provider authorization remains unverified.

The IDE candidate adopts a native SwiftUI iPad workbench: an activity bar for files, search, and source control, with editor tabs, a bottom terminal panel, and a status bar. The Git pane shows a directory tree of changes and uses the existing repository service. Text and code use the native editor exclusively, with no Web text-editor switch. Markdown adds an outline, formatting actions, and native preview over the same edit buffer; code text can be zoomed. Office retains its existing WebKit host and opening flow. The PPT edit entry now waits for presentation paint evidence before changing to the edit layout and requires a fresh post-entry frame. **Editable PPT content, save, and reopen still require physical iPad acceptance.**

The [targeted cloud App/UI run 35947162133](https://github.com/JiangNanGenius/floe-agent/actions/runs/35947162133) succeeded overall: all four iPad mini cases passed; an iPhone DXF preview assertion failed on its first attempt and passed on automatic retry, with the initial failure retained in the result. Native save and cold reopen have simulator evidence. Physical-device keyboard, IME, and touch behavior remain unverified.

The candidate also contains a multiline composer and full prompt editor, per-conversation drafts, native archive operations, runtime/PiP/notification repairs, and a single third-party license entry. GitHub remains the primary release source. Gitee source and eligible asset synchronization run separately and do not block GitHub or TestFlight delivery.

Delivery evidence to add: immutable source SHA, tag, cloud build run, IPA hash and bundle version, signed upload, Apple `VALID` processing, and Floe QA group/installability. Physical-device MLX, PPT, PiP, notification, and input behavior must be recorded individually and remain pending without evidence.
