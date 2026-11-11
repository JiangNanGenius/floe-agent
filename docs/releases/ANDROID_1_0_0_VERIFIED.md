# Android 1.0.0 / code108 — verified delivery

2026-11-12。自行分发 Full ARM64 [1.0.0 已可下载](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.0)，GitHub 标记为预发布，保留 iOS Latest。冻结候选记录见 [交付准备](ANDROID_1_0_0_DELIVERY.md)；本记录追加实际发行与设备结果，不改写标签或旧故障。

| 项目 | 实际结果 |
| --- | --- |
| 不可变源码 | `9230fc6485aabfb8542058121d43bd7da2efc3d6`，标签 `android/v1.0.0` |
| 安装包 | `Floe-Android-1.0.0-full-arm64-v8a.apk`，165,619,051 字节 |
| APK SHA-256 | `7f50350bcc5a89dd67d59372e94041d714c0769f8810d337482f7b8dd9cac044` |
| 公开附件 | 一个 Full APK、两项按需预览组件、对应源码包及 `SHA256SUMS`；五个附件均完成匿名完整字节读取与摘要核对 |
| 更新发现 | 实际编译的当前与保留旧客户端发现 1.0.0 完整包；当前 1.0.0 不提示更新；已知问题与摘要可读 |
| 三星升级 | App 内 GH-Proxy 下载完整包，经正常系统安装器和 Play Protect 检查完成工程107→公开108；未用 ADB 覆盖安装 |
| 安装与数据 | 主包及运行组件均为108，实际安装字节匹配发行产物，原 UID、5条任务、2个项目及原文件保持 |
| 升级后 Linux | 真实终端执行、工作区定位及原报告读取成功，进程退出码0；无新的云端调用 |

## 本批功能与验证

手机和平板统一使用 `device.observe`、`device.act`、`device.screenshot`，覆盖目录、派发、审批、等待恢复、敏感输入脱敏及指南。三个旧名称只供历史记录精确兼容，不在新工具目录重复展示。

后台任务以原生运行归属判断存活，不要求先打开对话。独立三星 S2 在一次定时触发前从未打开生成的对话，实际完成锁屏→解锁→计算器9→任务结束→自然重锁；49条原记录含4项成功的规范工具调用。独立 G4 首次返回保留的干净编辑标签即读取 Linux 新内容；删除的自建文件在原生与新 Linux 会话中均未回流。旧失败与这些新用例分别保留。

复用未改组件证据，本批135项相关 Swift／JVM检查、Full实际编译及 ARM64 原生对象／链接通过；实际产物的58项封装、原生绑定和16 KiB检查、API28／29签名校验及对应源码／许可核对通过。工程功能验证与最后108的安装／发行核对分别记录，没有重新执行未改组件的全套矩阵。

跨版本按用户要求直接下载完整包，本次不制作 Alpha→1.0 增量；同系列增量及失败回退代码保留，未改部分复用此前80→81重建证据。完整安装会移除可选预览拆分，安装前已有明确提示；需要时重新下载对应组件，用户文档仍保留。

## 恢复、清理与边界

测试任务／计划／文件／设备导出及结束的终端标签已清理，原有用户数据保持。临时解锁凭据已删除，无障碍、控制范围、自动化及电源设置恢复；最后升级用例未再次保存凭据。设备自然锁屏后释放给独立录制任务，后者的临时设置不属于本轮验收遗留。

完成的宿主测试暂存、重复组件与源码打包暂存按生产回执退役；保留当前包、必要回退、原失败、原生符号、源码、SDK／AVD及有明确后续用途的共用缓存。停止维护的 Play 线未重新构建。

验收以三星实机为主。API28／29签名检查不代替索尼新包实机验收；真实笔、射频、USB配件、厂商 Root 和不同锁屏方式保持具体未验记录。新 iOS 重型编辑器、双端实时同步及新增的 Android 原生文档目录页属于独立后续范围，未包含于这个不可变 APK。

English: Full ARM64 1.0.0/code108 is publicly downloadable as a GitHub prerelease from immutable source9230fc648. All five canonical assets pass complete anonymous byte verification. Samsung completed the actual in-App mirror/full-package107→108 joint update through normal system installation and scanning, retaining package UIDs, five tasks, two projects and files; the upgraded Linux terminal executed successfully and read the original report with exit0. Actual compiled current and retained clients discover the full update. Cross-version delivery deliberately uses the complete package; unchanged same-family delta evidence is reused. Focused functional, native, package, signature and source checks remain distinct from real-device acceptance. Temporary test state and owned outputs were restored/retired; original failures and required recovery remain. Hardware differences and the independent next documentation-page package are not claimed as accepted in this APK.
