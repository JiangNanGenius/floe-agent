# Android Alpha64 交付

[0.1.0-alpha.64／code90](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.64)已作为Android预发布交付，固定源码`6c82d891180badb25c0f24c2a92a1ba259a89c07`。七份公开附件的完整字节、不可变标签及实际生产更新解析器均已读回，iOS Latest保持独立。以下交付结果为源码冻结后的追加记录，不移动原标签或替换原包。

主安装包：`Floe-Android-0.1.0-alpha.64-full-arm64-v8a.apk`，164,416,111字节；SHA-256：`5156e856687e64c09a94f1d3a175634fbb5aca1168d8cb05fc9d350b4246912a`。

模型任务优先使用所属Linux环境中的命令行；图形桌面主要供用户手动操作专业软件，模型可按请求准备软件、文件并启动交接。普通Full／Play任务按实际工具附加指引，保留临时会话、手记、手机控制和现有授权边界。

公共SkillHub接入签名镜像策略：官方源优先，仅在明确可用性故障时尝试同一固定内容的已编译镜像；取消、权限、证书、大小与内容校验错误不换路。持久保存已验证配置和最高代次，不放宽内容签名、摘要及包身份检查。可变GitHub API的commit解析仍只走官方接口，私有仓库连接器取回仍有独立实现缺口。

Linux桌面全屏弹窗使用自身窗口的系统栏明暗设置，修正白色背景上图标缺少对比度的问题。没有改变键盘布局或将图形桌面用作模型的常规执行前提。

4项执行指引宿主检查、28项真实镜像／传输模块宿主检查、相关Full／Play Kotlin编译、实际Android ARM64对象／链接及58项封装／签名／16KiB检查通过。三星从App公开更新入口下载完整包，经系统安装器完成主应用和运行环境的code89→90联合更新；安装字节与公开主包／内置运行组件匹配，两个UID、原有项目和对话保留，没有使用adb安装本版。系统的未知应用扫描及设备认证是实际安装流程的一部分；没有全局关闭系统保护。

三星真实Ark Plan／`ark-code-latest`任务只请求环境状态与`exec.shell`，在所属项目环境中执行`printf FLOE64_CLI`并取得真实标准输出及退出码0，未请求启动桌面。此前将标记误作命令的提案未获执行；原记录保留，随后独立的明确命令用例完成。一次性测试导出副本及旧提案任务已清理，手机常亮和权限恢复；仅暂留完成用例供下一批直接保存功能验收。

63→64增量已真实重建出目标包，实际生产策略对公开元数据判定可采用。本次三星观察到的是完整包路径，不能据此宣布设备增量执行通过。桌面弹窗系统栏的新代码已编译，新渲染观察仍待完成。索尼Android9组件故障、原VNC断连原因、私有仓库连接器、部分后台／自动解锁及全局界面缺口继续保留；完整任务目前只有分享菜单，直接系统文件保存另在后续代码包接通。整轮N01–N08未结束。

English: Alpha64/code90 is published from immutable source6c82d891 with seven complete public asset read-backs and the actual update parser. Samsung completed the public in-App full-package upgrade of both App and runtime from89 to90, with exact package identities and existing data retained. Four guidance cases,28 real-module mirror/transport cases,Full/Play Kotlin,actual Android ARM64 compilation/linking and58 packaging/signature/16KiB checks pass. A real Ark Plan/ark-code-latest task returned CLI stdout and exit0 without requesting the desktop. The real63-to64 patch reconstructs the exact target and passes production admission; this device run used the full package, so device delta execution is not claimed. New dialog rendering,private connector fetching,Sony Android9,earlier VNC/background/unlock issues and broader UI work remain open. Direct system-document task saving belongs to a subsequent packet; N01–N08 remain active.
