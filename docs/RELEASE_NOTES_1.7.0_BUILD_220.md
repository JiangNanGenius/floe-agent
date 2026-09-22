# Floe 1.7.0 (220) — Linux 持久磁盘与后台模式、完成通知、PPTX 宿主修复 / Linux disks and background mode, completion notifications, PPTX host repair

Status: version and release metadata prepared for the authorized expedited
private internal Floe QA TestFlight, the matching unsigned-only GitHub
prerelease and the Feather source entry. This document describes the source
state of the integrated `main` HEAD `9e83fcfa` plus the metadata commit on
`codex/build220-release-metadata`. Build, upload, Apple processing and group
availability have **not** happened for build 220 and are recorded separately
after they occur. Simulator/UI qualification is expected to be waived by the
user's expedited request; physical-device acceptance remains with the user.

## 简体中文

Build 220 修复 Linux 环境的持久化与安装状态，补齐显式后台模式与如实指标，
统一任务完成通知，并修复 PPTX 可用渲染与编辑入口。

Linux 客体现在为每个环境维护独立的 ext4 磁盘：可用时通过 APFS clonefile
快速复制，容量按需稀疏增长到 8 GiB，启动后由客体幂等执行 resize2fs 完成扩容。
旧版 v1 sidecar 会原地迁移并保留 schema／容量来源信息；扩容或调整失败会如实
报告，不会删除用户已安装的软件包。TMPDIR／TMP／TEMP 以及 pip、XDG、npm 缓存
统一指向可写的 `/floe/env` 路径（runner 与 Swift 两侧一致），因此从源码构建
（例如 Pillow sdist）不再可能写满内存支撑的根分区。安装状态由已验证镜像、磁盘
迁移结果与实时运行状态共同推导：已安装或正在运行的客体不会再显示“下载”卡片，
下载、进度、取消、启动、停止、修复、更新各阶段有明确状态；所有 Linux 入口共用
可取消的准备流程，并合并并发安装请求，避免重复下载。TinyEMU 补丁 0009 修正
unlinkat 标志传递（AT_SYMLINK_NOFOLLOW 类型检查、空目录可删除、非空目录返回
ENOTEMPTY、不触碰符号链接目标），并把伪造的 524 xattrwalk 改为空列表／ENODATA，
因此 GNU `ls -l` 不再打印 “Unknown error 524”。

Linux 环境新增显式“在后台保持运行”开关：只有用户自己的操作可以请求系统持续
处理任务，且不依赖聊天画中画的偏好设置；偏好未加载或后台唤醒时会安全失败。
指标只在注册了前台消费者时采样，只上报实测值，并且不会声称客体有 GPU 直通
（TinyEMU 没有）。重新启动后会如实报告客体已中断，而不是假装进程仍存活；不存在
静默音频保活路径。状态画中画改为默认关闭的显式开关。会话运行与 Linux 会话共用
同一套后台工作模型与完成停留／代次策略：成功状态短暂停留后仅在代次仍为当前时拆除，
失败与检查点保持可操作并给出真实原因与恢复提示，过期定时器的拆除不会关闭更新的运行。

任务完成通知由“按会话策略 + 真实授权状态 + 真实前台状态”三者共同决定：前台时只显示
一条应用内横幅，不再同时弹出系统通知；后台提醒需要实际已授权，未授权状态会被如实
记录；通知携带稳定身份，并分别路由回对应会话或 Linux 执行环境界面。

PPTX 修复了“显示可编辑但引擎仍停留在浏览界面”的问题：应用跟随引擎自身受保护的移动端
编辑入口（演示文稿与绘图的有界延迟判断），不会把只读回退权限、受保护文件或只读文件式
文档提升为可写；同时加入有界渲染探针，轮询编辑器自身的图块管线与降采样画布指纹，
演示文稿必须真正解码出文档图块才算就绪，超时会显示可重试／可恢复的明确失败并保留编辑
副本，编辑校验也改为要求引擎的 UI 模式而不只是回退权限。重建后的原生宿主已在
`office-native-host` 运行 35668651442（源码 `c4ff0dde`）编译链接，并在 `f0ca71a7`
重新固定；`engine.lock.json` 的四项设备能力回执仍全部为 false，模拟器编译守卫
`67a37db3` 只有定向检查。README 与使用指南保留 GitHub 安全的官网下载按钮，并记录
官网实际使用的 `feather://source/<url>` 与 `altstore://source?url=<encoded>` 深链；
已退役的原生载荷措辞改为 Linux 客体与受信 SSH 主机说明。

验证边界：上述行为已在对应实现提交中完成源码级实现与定向本地检查（Linux 磁盘／后台／
Office 各自的 Swift 与宿主测试，见交付记录）；本次 Build 220 的版本与发布元数据准备
另行执行了项目生成一致性、版本契约、TestFlight 说明 JSON 与文档检查。Build 220
尚未进行云端验收 SDK App 编译、签名、上传或 Apple 处理，也没有模拟器 UI 与真机验收；
首次下载、磁盘持久化、`ls -l`、后台停止／重启、完成通知与 PPTX 保存退出仍由用户在
真机上验收。

## English

Build 220 repairs Linux persistence and install state, adds an explicit
background mode with truthful metrics, unifies task-completion notifications,
and repairs PPTX visible rendering and the edit entry.

Each Linux environment now owns its own ext4 disk: an APFS clonefile copy when
available, sparse grow-only capacity up to 8 GiB, and an in-guest idempotent
`resize2fs` after boot. v1 sidecars migrate in place with their schema and
capacity provenance, and a failed grow or resize is reported honestly without
touching installed user packages. `TMPDIR`/`TMP`/`TEMP` and the pip, XDG and npm
caches now route to writable `/floe/env` paths in both the runner and Swift, so
a source build such as the Pillow sdist can no longer fill the compact
RAM-backed root partition. Install state is derived from the verified image,
the disk migration result and the live runtime: an installed or running guest
can never render the download card, the download, progress, cancel, start,
stop, repair and update phases are explicit, and every Linux entry point shares
one cancellable preparation that coalesces concurrent installs instead of
downloading twice. TinyEMU patch 0009 propagates `unlinkat` flags with
`AT_SYMLINK_NOFOLLOW` type checks (empty directories removable, non-empty
`ENOTEMPTY`, symlink targets untouched) and replaces the bogus 524 `xattrwalk`
with an empty list/`ENODATA`, so GNU `ls -l` no longer prints "Unknown error
524".

Linux environments gain an explicit **keep running in the background** switch:
only the user's own action may request the system continued-processing task,
independent of the chat picture-in-picture preference, and the lifecycle fails
closed on an unloaded preference or a background wake. Metrics are sampled only
while a foreground consumer is registered, report only measured values, and
never claim a guest GPU (TinyEMU has no passthrough). A relaunch reports the
guest as interrupted instead of pretending it survived, and no silent-audio
keepalive path exists. Status picture-in-picture is now an explicit opt-in.
Conversation runs and Linux sessions share one background-work model with a
completion-dwell/generation policy: a success stays briefly and tears down only
while its generation is current, failures and checkpoints stay actionable with
the real reason and a recovery hint, and teardown of a stale timer cannot close
a newer run's surface.

Task-completion notifications resolve from a per-conversation policy plus the
real authorization and real foreground state: in the foreground a single in-app
banner replaces the duplicated system alert, background alerts require actual
authorization, a blocked state is recorded truthfully, and each notification
carries a stable identity that routes back to its conversation or to the Linux
execution-environment surface.

The PPTX repair fixes a presentation that could report itself editable while
the engine stayed in the viewing UI: Floe follows the engine's own guarded
mobile entry for presentation/drawing file-based layouts and never elevates a
read-only backing permission, a protected file or a view-only file-based
document. A bounded render probe polls the editor's own tile pipeline and a
downsampled document-canvas fingerprint, so a presentation is ready only after a
real decoded document tile; the deadline shows an actionable retry/recovery
failure and retains the editing copy, and edit verification now requires the
engine's UI mode rather than only the backing permission. The rebuilt native
host was compiled and linked in `office-native-host` run 35668651442 (source
`c4ff0dde`) and re-pinned at `f0ca71a7`; the four device-capability receipts in
`engine.lock.json` all remain false, and the simulator compile guard
`67a37db3` has focused coverage only. The README and user guide keep the
GitHub-safe official download-page buttons and now publish the exact
`feather://source/<url>` and `altstore://source?url=<encoded>` routes the
official site fires; retired native-payload wording now describes the Linux
guest and audited SSH hosts.

Validation boundary: the behavior above was implemented at source level and
checked by the focused local tests recorded with each implementing commit
(Linux disk/background Swift and host tests, and the Office render/host gates),
while this build 220 version and release-metadata preparation ran the
project-generation consistency, version-contract, TestFlight notes JSON and
documentation checks. Build 220 has **not** been compiled by the cloud
accepted-SDK App build, signed, uploaded or processed by Apple, and it has no
simulator/UI or physical-device acceptance; first-download, disk persistence,
`ls -l`, background stop/restart, completion notifications and PPTX
save-on-close remain for the user to accept on a device.
