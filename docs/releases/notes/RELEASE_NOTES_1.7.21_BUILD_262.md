# Floe Agent 1.7.21 · Build 262

## 简体中文

改进 IDE 运行窗口与终端全屏，修复本地终端输出顺序和工作目录。增加作为网页服务运行入口，支持 Python、Node 和 Shell，提供托管日志、预览与停止操作。请重点复测脚本启动、持续输出、方向键、换行，以及关闭窗口后的网页服务访问。

## English

Improves IDE run presentation and full-screen terminals, fixes local terminal output ordering and workspace directory selection. Adds managed Python, Node and Shell web services with logs, preview and stop controls. Please test script startup, continuous output, arrow keys, line breaks and service access after closing the window.

## 验证与发布 / Verification and delivery

本地 Xcode 27 Release 构建、27 项相关服务/终端测试及 iPad 运行窗口与终端全屏 UI 验证已通过。使用同一份不可变源码产物签名上传；未将完整云端矩阵作为本次快速发布门槛。Apple 已确认 VALID、未过期且现有 Floe QA 内部可安装；publictest1 尚未送审或批准。

Local Xcode 27 Release building, 27 focused service/terminal tests and iPad run-sheet/full-screen terminal UI verification passed. Signing reuses the immutable-source artifact; the full cloud matrix was not a gate for this expedited release. Apple confirmed VALID, unexpired and available for internal Floe QA testing. publictest1 was submitted on 2026-10-07 and is waiting for Apple review; approval remains pending.

[本地验证记录 / Local evidence](../testflight/BUILD_262_LOCAL_VERIFICATION.md) · [发布状态 / Delivery status](../../CURRENT_STATUS.md)
