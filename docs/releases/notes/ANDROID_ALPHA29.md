# Android 0.1.0-alpha.29 · code48

这是持续开发中的 GitHub Full 中间预发布，N01–N08 仍在推进；保留 iOS Latest。

## 本次更新

- 修复 Linux 图形应用的项目会话总线、启动回执及触摸/键盘输入配置；改进软件运行和失败状态。
- 修复外部编辑快照丢失原件关联，以及提供商写回缺少原生校验完成步骤的问题。三星前置候选已验证：Linux 实际修改、关闭后保留恢复副本、覆盖升级后核对保存，再由授权原件实际字节确认写回。
- 修复关闭最后一个终端标签后重新打开面板时隐藏新建入口、误报环境未就绪的问题，前置候选已在三星验证。
- 增加 App 内离线静态 SVG 预览，复用文件快照、缩放与关闭/取消管理。组件固定为 AndroidSVG 1.4；拒绝外部资源、实体、活动内容、滤镜及超出预览预算的文件。TIFF 仍未实现。
- Linux 与 Android 外部编辑菜单使用最近明确选择的文件；结束编辑后清除过期的编辑占用提示。轻量文本/代码继续在 Floe 内，专业编辑优先 Android 默认应用，Linux 桌面版可显式选择。
- GitHub 版可直接下载最新完整 APK，跨版本不依赖逐版安装或补丁基包；同时提供 Alpha28→29 的经过重建验证的增量。

## 已知问题与验证范围

- 本版为中间版本，不保证所有 N01–N08 路径完整可用。新增 SVG 及菜单行为已通过 Full/Play 定向编译和相关策略检查；此公开包的三星渲染、自动写回及完整包在线安装在发布后继续核对，尚未据此宣布通过。
- 三星前置候选的保存恢复证据覆盖实际 SVG 文件及一个系统文件提供商，不代表全部格式、所有提供商或新会话自动同步。
- SVG 只读预览有明确静态/资源预算边界；复杂 SVG 可交给其他应用或 Linux。新加预览不增加 SVG 编辑器。
- 手机控制、自动解锁、Root、真实笔及新系统/厂商差异仍按能力、配置和权限开放；没有伪造未测试的设备结果。现有恢复副本保留，不以任务异常自动上报日志。
- 安装前请保存其他应用中的修改；遇到同步待完成或冲突时保留恢复副本，可核对保存或另存，不要删除项目数据。

---

This is an intermediate GitHub Full prerelease. The complete N01–N08 goal remains active; the iOS Latest release is preserved.

Changes: repaired project-scoped Linux graphical launch/input, original-source identity in editor snapshots, and native verification stages in provider writeback; restored explicit terminal creation after the final tab closes. Added bounded offline static SVG preview with pinned AndroidSVG 1.4, consistent selected-file routing, and clearer editing-session messages. Lightweight text/code stays in Floe; professional editing prefers Android apps, with optional Linux desktop applications and independent Agent execution.

Update choices: download the latest full APK directly from any older supported GitHub version, or use the verified Alpha28→29 delta when its exact base matches. No sequential intermediate installs are required for the full package.

Known limits: SVG filters, external dependencies, active content and files above the preview budget are refused; TIFF remains unimplemented. Full/Play targeted compilation and preview policy checks passed. Samsung evidence from preceding private candidates covers a real Linux-edited SVG, retained recovery across an upgrade, explicit save reconciliation and actual provider bytes. It does not prove every format/provider or fresh-session automatic save. New SVG rendering and online full installation continue on this public intermediate build after publication. Preserve recovery copies when a sync/conflict is unresolved.
