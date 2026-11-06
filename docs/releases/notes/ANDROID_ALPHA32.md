# Android 0.1.0-alpha.32 · code51

GitHub Full 中间预发布；保留 iOS Latest，整轮功能收口继续推进。

## 本次更新

- 图形环境启动脚本提前退出时立即返回失败，不再只等待超时。区分组件安装、会话服务、图形工具、认证、显示和桌面阶段；退出码可在详情中查看。
- Linux 图形环境和软件设置增加可复制的会话详情，显示真实任务、工作区、环境及运行会话信息，便于排查“准备失败”或软件出现在不同环境的问题。详情不包含路径、命令、原始输出或凭据，也不会自动上传。
- 阻止旧停止请求关闭后来启动的新图形会话；保留原有编辑回传、冲突和恢复流程。
- 修正充电／网络条件计划的状态标签，以及复用项目工作区时的说明。未改动全局字号、间距和控件样式。

## 已知问题与验证范围

- 相关 Full/Play 编译及 4 项启动协议测试通过；本安装包的图形环境、手机控制和实际条件触发仍继续三星实测，不能将编译结果当作全功能验收。
- 提供 Alpha31→32 增量与完整 APK。增量生产会核对重建的精确字节；设备增量行为仍须实际确认。不匹配的基包或失败的补丁可使用完整包。
- 旧 Alpha30 若已卡在安装确认，请取消该次安装并用系统文件管理器打开完整 APK 过渡。修复后的安装器已在三星完成过主 App／运行组件联合在线更新。
- 四张大图反馈仍保留测试网络超时记录，TIFF 预览尚未实现；普通任务／工具／供应商异常不自动上报。自动解锁需要单独同意与配置。全局 UI 优化在功能接通后集中进行。

---

Intermediate GitHub Full prerelease; iOS Latest is preserved and the whole feature goal remains active.

Graphical startup now reports early script failures immediately, with bounded stage/exit-code details. Linux graphical and software settings expose copyable task/workspace/environment/session diagnostics without paths, commands, raw output, credentials or automatic upload. A queued stop from an older request cannot close a later graphical session. Corrected condition-trigger badges and reused-project wording; global styling remains unchanged.

Full/Play compilation and four startup-protocol checks passed; device graphics, phone control and real condition execution remain under Samsung validation. Includes an Alpha31→32 reconstruction-verified delta and a full APK; device delta behavior is not claimed from host checks. An already affected old Alpha30 installer may still require the documented manual transition. The fixed installer previously completed a Samsung coordinated main/runtime online update. Large-image report timeout evidence and the missing TIFF preview remain recorded. Ordinary task/tool/provider failures are excluded from automatic reporting. Automatic unlocking requires separate consent/configuration; the global UI pass stays deferred.
