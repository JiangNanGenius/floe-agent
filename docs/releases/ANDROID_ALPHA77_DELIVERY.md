# Android Alpha77 / code103

日期 / Date: 2026-11-10

本源码检查点准备下一份GitHub中间预发布，构建、设备验收和公开下载需分别记录；不是已发布声明。实质代码检查点为 `a130e52c5ac5d557dec1f078deadab9dfa47f6c4`，最终安装包以生产记录中的不可变源码为准。

This source checkpoint prepares the next GitHub intermediate prerelease. Build, device acceptance and public availability are separate results; this document does not claim publication. The reviewed implementation checkpoint is `a130e52c5ac5d557dec1f078deadab9dfa47f6c4`; the APK producer records its exact immutable source.

- Linux启动页采用紧凑的应用选择区，保留单应用／桌面模式、安装选项和明确停止确认；不改变查看器或鼠标协议。
- 新任务环境复制使用有界流水线，保留旧内核逐文件／目录落盘，清理和发布前等待工作线程退出；事务快照继续使用原串行路径。
- 定时运行历史可以打开所属任务，复用现有导航，不重新执行计划；不承诺自动选中某一历史运行。
- 包含此前已编译的原生确认与升级完成状态布局修复；新包行为仍需实机确认。

- The Linux launcher uses compact wrapping application choices while retaining session modes, installation options and confirmed stopping. Viewer and pointer protocols are unchanged.
- A bounded rootfs copy pipeline retains legacy file/directory durability and joins workers before cleanup or publication. Transaction snapshots keep the existing serial path.
- Schedule history can open its recorded task through existing navigation without relaunching it. Exact-run positioning remains separate.
- The build includes the previously compiled native confirmation and update-completion layout changes; new-package device behavior remains to be checked.

源码验证：56项根环境／运行层定向检查和Full实际消费端编译通过；此前18项原生确认检查按未改输入保留。UI和组件代码并行完成，再合并验证；不重复未改模块的整套检查。

Source qualification:56 focused rootfs/runtime cases and actual Full consumer compilation passed. Prior18 native-submit cases are retained for unchanged inputs. UI and runtime work were authored concurrently and validated together.

已知边界：这是首批启动页／选择控件精修，整体UI尚未全部完成；三星的旧76用例在原生确认失败，不能冒充新包解锁／重锁通过。索尼Android9的具体启动、专业图形编辑保存、部分恢复／定时组合及首次下载计量仍需实际反馈或验收。没有设备加速幅度或全功能通过声明。

Known limits: this is the first launcher/control refinement, not whole-App visual completion. The original Samsung76 native-confirmation failure remains retained; no new unlock/relock pass is inferred. Sony Android9 startup, professional graphical saves, remaining recovery/scheduling combinations and fresh-download metering still need actual feedback or acceptance. No measured acceleration or complete feature acceptance is claimed.

发行保持一个Full ARM64安装包及必要校验、更新、对应源码和许可文件；保留iOS Latest，不更改已有公开版本的标签或安装包。

Distribution keeps one Full ARM64 installer and required integrity/update/source/license files. Preserve iOS Latest and existing immutable release tags and bytes.

## 公开交付与三星补记 / Publication and Samsung read-back

[Alpha77/code103](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.77) 已从不可变源码 `5fa8272714d955fdb895e8f70ff3a5ffdcd3a17d` 公开。Full APK 为164,744,855字节，SHA-256：`604b1eef2c1113dd5c36c045396376047d129643739ea5a8732ee7d711a43426`。Full／Play编译、未改native34输入绑定、58项封装校验、API28／29签名、76→77增量重建以及七个公开附件的匿名实际下载字节核对通过；当前及保留的Alpha65更新解析器可发现本版，iOS Latest保持。

Alpha77/code103 is public from the immutable source above. The Full APK is164,744,855 bytes with the recorded SHA-256. Full/Play compilation, unchanged native34 input binding,58 package checks, API28/29 signatures,76→77 delta reconstruction and anonymous download verification of all seven assets passed. Current and retained Alpha65 clients discover this version; iOS Latest remains unchanged.

三星通过App内保存的镜像源完成真实76→77增量更新，正常确认主包／运行组件安装；未使用ADB安装或降级。实际安装的两包字节、原UID、原5任务和2项目保持。新建Ark Plan／ark-code-latest任务真实执行终端命令，生成的文本成果已在内置轻量IDE全屏打开，内容正确。一次含20秒主动等待的命令总用时34.811秒，上一版对应观察为65.887秒；这是单个用例的工具总时长对比，不是分阶段性能基准或全机提速结论。

Samsung completed the actual in-App76→77 mirrored delta update and ordinary coupled installation. Both installed package bytes, original UIDs, five tasks and two projects were retained. A fresh Ark Plan/ark-code-latest task executed the terminal command and its generated text opened correctly in the full-screen native lightweight IDE. One command including an intentional20-second sleep took34.811 seconds versus65.887 seconds in the preceding observation; this is a single end-to-end tool comparison, not a phase-isolated benchmark.

本版新自动解锁用例仍失败：系统接受填写和确认手势后仍保持锁屏，进入人工接续；没有计算器或结束重锁通过声明。首故障及41条完整原记录已保留，未恢复失败任务。临时凭据、权限／自动化开关、目标范围、任务和设备导出均已清理，常亮恢复后休眠；原5任务保留。后续修复使用新的源码和新用例，不能回写本版通过。

The fresh automatic-unlock case still failed: accepted text and confirmation gestures did not release keyguard, and manual continuation was requested. Calculator execution and relocking did not pass. The first failure and41 original export records remain retained; the failed task was not resumed. Temporary credentials, permissions, automation settings, target scope, task and device export were removed, stay-awake restored and the device put to sleep, preserving the original five tasks. A later source fix requires a new case and cannot change this version's outcome.
