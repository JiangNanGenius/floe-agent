# Floe 1.7.0 (216) — release-path stability / 发布链路稳定性

Status: candidate for the existing private internal Floe QA TestFlight group and
the matching GitHub prerelease. Signed upload, Apple processing and group
availability are verified separately after they occur.

## 简体中文

Build 216 保留 Build 215 根据真机反馈完成的全部修复：本地模型精选工具与第二轮续写、跨任务检索闭环、按任务隔离且可取消的并行终端、Git 初始化、IDE 内 PDF/Office 标签、中文字体与保存流程，以及思维导图自由拖动。

本版进一步修正发布链路：Office 源码在没有原生宿主模块的资格检查环境中也能正确编译；HTTP 工作流通过真实 SwiftPM 模块依赖进行验证；App 回归门禁只要求仍在产品中的 TinyEMU/Linux 与 Shell 套件，不再引用已封存的原生 Python 和旧本地服务测试。实际云端 App 回归产物已重放为 234/234 通过。

TinyEMU 继续作为主要本地 Linux 环境。原生 Python、Node、Ruby 等语言载荷不会重新打进应用；语言和软件包仍在 Linux 客体中安装运行，WASM 保留为独立兼容路径。Git、Office 中文渲染、本地模型内存行为、终端并行度和 Linux 性能仍由用户在真机安装后验收。

## English

Build 216 retains all Build 215 device-feedback repairs: capability-selected
local-model tools and second-turn continuation, complete cross-task lookup,
task-isolated concurrent terminals with cancellation, Git initialization,
IDE-owned PDF and Office tabs, Chinese font/save handling, and free-position
mind-map dragging.

This build also stabilizes the release path. Office sources compile correctly in
qualification configurations that omit the native host module; the HTTP workflow
uses the real SwiftPM module graph; and the focused App gate now requires the
current TinyEMU/Linux and Shell suites instead of retired native-Python and legacy
local-service suites. The retained cloud App result replays as 234/234 passing.

TinyEMU remains the primary local Linux environment. Native Python, Node, Ruby
and other language payloads remain outside the App; languages and packages are
installed in the Linux guest, while WASM stays an independent compatibility path.
Git, Office Chinese rendering, local-model memory behavior, terminal concurrency
and Linux performance remain for physical-device acceptance after installation.
