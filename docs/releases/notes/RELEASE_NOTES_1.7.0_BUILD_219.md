# Floe 1.7.0 (219) — Linux lifecycle, MLX, IDE and Office repair / Linux 生命周期、MLX、IDE 与 Office 修复

Status: candidate for the existing private internal Floe QA TestFlight group,
the matching unsigned-only GitHub prerelease and Feather source entry. Build,
upload, Apple processing and group availability are recorded separately after
they occur.

## 简体中文

Build 219 把 TinyEMU/Linux 收敛为主要本地运行环境。首次使用 Shell、Linux
Python、Node、APT/DPKG 或后台服务时，会共用同一套受控的准备、下载、校验、安装和
启动流程；设置与终端也提供明确入口。客体首次启动会配置网卡、默认路由、可用 DNS
和 Git 安全目录，并把网络状态返回给 App。已安装磁盘与软件包继续保留，新组件只升级
经校验的 runner。

Linux runner 组件补充完整对应源码与 LGPL 重链接材料，包含本轮新增的网络源码；9p
对扩展属性探测返回兼容结果，避免 `ls -l` 等命令因 524 错误失败。后台服务继续保留
持久任务定义、状态、日志、停止与显式重启路径；iOS 终止 App 后不会虚假声称原进程仍
存活。

本地 MLX 模型现在在加载前检查快照完整性，并把正在运行的 Linux 内存计入设备预算，
分别提示损坏快照和内存不足。当前设备上不合适的最大模型从推荐下载列表移除；已有下载
仍可由用户明确删除。

IDE 的源码管理会在初始化仓库、Git 变更和回到前台后立即刷新。工作区 Office 预览的
编辑入口直接打开独立全屏 Office；只有 IDE 文件树继续使用内嵌标签。DOCX、XLSX 和
PPTX 共用有界保存与退出确认，PPTX 编辑增加加载超时，避免空白页和无限保存。README
中的 Feather 与 AltStore 按钮改为 GitHub 能保留的官网 HTTPS 下载入口。

本轮按要求仅做定向代码、脚本、组件客体启动与云端 App 构建验证。首次网络、持久磁盘、
PPTX/DOCX/XLSX 保存退出、Git 侧栏、MLX 内存提示和真实设备体验仍由用户安装后验收。

## English

Build 219 consolidates TinyEMU/Linux as the primary local runtime. First use of
Shell, guest Python, Node, APT/DPKG or background services shares one controlled
prepare, download, verify, install and start flow, with explicit entries in
Settings and Terminal. The guest configures its interface, default route,
working DNS resolvers and Git safe directories before reporting network state to
the app. Existing persistent disks and installed packages remain in place while
the verified runner is upgraded.

The Linux runner component now carries complete corresponding source and LGPL
relink material, including the new networking source. Compatible 9p extended
attribute responses prevent commands such as `ls -l` from failing with error
524. Background services retain durable definitions, status, bounded logs,
stop and explicit restart paths; the app does not claim that a raw process
survives iOS termination.

Local MLX loading now validates snapshots before initialization and subtracts
active Linux guest memory from the device budget, separating corrupt-snapshot
errors from memory pressure. The largest nonviable model is removed from the
recommended download list while existing downloads remain available for
explicit removal.

The IDE refreshes source control immediately after repository initialization,
Git mutations and foreground return. Editing from a workspace Office preview
opens the standalone full-screen editor; only the IDE file tree keeps embedded
tabs. DOCX, XLSX and PPTX share bounded save and close confirmation, and PPTX
editing has a load watchdog to prevent an indefinite blank or saving state.
README Feather and AltStore buttons now use the GitHub-safe official HTTPS
download entry.

Validation is intentionally focused: source, script, component guest boot and
cloud App build gates. First-boot networking, persistent disks, Office save on
exit, the Git sidebar, MLX memory diagnostics and physical-device behavior remain
for device acceptance.
