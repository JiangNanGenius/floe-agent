# Android 0.1.0-alpha.46

## Known issues / 已知问题

这是持续修复的中间版本。CAD 新组件的安装、取消、离线打开及升级衔接仍需本版实际设备记录确认；编译或下载成功不代表预览已通过。旧版 CAD 缓存保留为恢复资料，不能充当新组件的安装回执。完整包升级会替换可选预览组件，Office／CAD 需要安装与新版匹配的组件；原文档保留。手机多步控制、条件计划、跨项目隔离和全局界面仍在继续收口，旧付费测试任务不恢复或重试。

## 本批更新

- CAD 首次打开接入签名可选组件：提供下载进度、取消、系统安装确认、失败后重试和安装结果读回。已安装组件从本机加载，保留只读预览及视口截图。
- 预览器资源仍使用固定版本与文件摘要；完整校验后才交给查看器。CAD 不增加建模或重型编辑器。
- Office 与 CAD 复用组件安装生命周期。补齐设置页的系统确认、切回前台恢复、真正停止下载后再结束取消，以及组件安装和应用升级的互斥。
- 存储设置显示组件与下载缓存；旧 CAD 缓存单独保留并可显式清理。用户文档不属于组件缓存。
- 提供完整 APK；已知问题在 GitHub 版更新确认前显示。实际增量与安装回执在交付记录中单独说明。

## English

This is an intermediate prerelease. Installation, cancellation, offline CAD rendering and update continuity require this version's actual device evidence; compilation or a successful download alone is not preview acceptance. The legacy CAD cache remains recoverable and is not treated as an installed signed component. Full-package updates replace optional preview components, so Office/CAD need matching components afterward; source documents remain intact. Multi-step phone control, conditional scheduling, cross-project isolation and further UI refinement remain in progress. Previous paid test runs are not resumed or retried.

CAD first use now uses a signed optional component with download progress, cancellation, system confirmation, explicit retry and installed-module read-back. Locally installed viewer resources retain fixed revisions and file digests, and are verified before rendering. Preview and viewport capture remain read-only; no modeling editor is added.

Office and CAD share the installation lifecycle, including settings confirmation, foreground recovery, cancellation that waits for the old download to stop, and mutual exclusion with application updates. Storage settings expose installed components, staged downloads and the separately retained legacy CAD cache. Component cleanup does not remove user documents.

A full APK is provided. Known issues appear before GitHub-channel update confirmation. Delta reconstruction and real installation receipts are recorded separately at delivery.
