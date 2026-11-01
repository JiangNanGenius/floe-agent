import Foundation

struct BridgeL10n {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    static func t(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    static var title: String { t("Floe Bridge", "Floe 桥接") }
    static var subtitle: String {
        t("One app: internal reflector, on-device DDI and embedded test engine.",
          "单应用：内部反射隧道、本机 DDI 与内嵌测试引擎。")
    }
    static var status: String { t("Status", "状态") }
    static var engine: String { t("Engine", "引擎") }
    static var tunnel: String { t("Reflector", "反射隧道") }
    static var ddi: String { t("Developer image", "开发者镜像") }
    static var pairing: String { t("Pairing", "配对") }
    static var pairingImported: String { t("Imported", "已导入") }
    static var pairingMissing: String { t("Not imported", "未导入") }
    static var setup: String { t("Setup", "设置") }
    static var importPairing: String { t("Import RemotePairing file", "导入 RemotePairing 文件") }
    static var replacePairing: String { t("Replace pairing file", "替换配对文件") }
    static var removePairing: String { t("Remove pairing file", "移除配对文件") }
    static var downloadDDI: String { t("Download DDI files", "下载 DDI 文件") }
    static var cancelDownload: String { t("Cancel download", "取消下载") }
    static var importDDI: String { t("Import DDI folder", "导入 DDI 文件夹") }
    static var ddiHint: String {
        t("Files are downloaded or imported at runtime and never bundled in the IPA.",
          "文件在运行时下载或导入，绝不会打包进 IPA。")
    }
    static var run: String { t("Run", "运行") }
    static var start: String { t("Start engine", "启动引擎") }
    static var stop: String { t("Stop engine", "停止引擎") }
    static var resume: String { t("Resume engine", "恢复引擎") }
    static var mountOnly: String { t("Mount DDI only", "仅挂载 DDI") }
    static var autoStart: String { t("Auto-recover when opened", "打开应用时自动恢复") }
    static var autoStartHint: String {
        t("After a successful first run, opening the app retries tunnel, mount and engine without a computer.",
          "首次成功后，重新打开应用会在无需电脑的情况下重试隧道、挂载与引擎。")
    }
    static var connectTunnel: String { t("Start reflector", "启动反射隧道") }
    static var disconnectTunnel: String { t("Stop reflector", "停止反射隧道") }
    static var diagnostics: String { t("Prototype diagnostics", "原型诊断") }
    static var removeDDI: String { t("Remove DDI (prototype)", "移除 DDI（原型）") }
    static var removeDDIHint: String {
        t("Debug-only action. Requires Auto-recover off, the engine stopped and an idle test process. Xcode and test services stop working until the DDI is reinstalled.",
          "仅供调试。需要关闭自动恢复、停止引擎且测试进程空闲。在重新安装 DDI 前，Xcode 与测试服务将不可用。")
    }
    static var removeDDIConfirmTitle: String { t("Remove the developer image?", "移除开发者镜像？") }
    static var removeDDIConfirmMessage: String {
        t("This removes the on-device developer disk image. Xcode and test services will stop working until it is reinstalled. Continue?",
          "这将从设备移除开发者磁盘映像。在重新安装前，Xcode 与测试服务将不可用。继续？")
    }
    static var removeDDIConfirmAction: String { t("Remove DDI", "移除 DDI") }
    static var startAndCheck: String { t("Start and check", "启动并自检") }
    static var startAndCheckHint: String {
        t("Starts the engine, waits for its real entry, then checks Settings with local commands. No computer or file copy is used; keep the device unlocked.",
          "启动引擎并等待真实入口，然后用本机命令检查设置。无需电脑或复制文件；请保持设备解锁。")
    }
    static var stageProbe: String { t("Check DDI stages (prototype)", "检查 DDI 阶段（原型）") }
    static var stageProbeHint: String {
        t("Read-only: cached files, cryptexd queries, Apple TSS reachability and tunnel packet counters. No install, mount or pairing change.",
          "只读：缓存文件、cryptexd 查询、Apple TSS 可达性与隧道包计数。不会安装、挂载或更改配对。")
    }
    static var cancel: String { t("Cancel", "取消") }
    static var lan: String { t("Read-only LAN endpoint", "只读局域网端点") }
    static var lanHint: String {
        t("Off by default. Requires a random per-install token; no command endpoint exists.",
          "默认关闭。需要每次安装生成的随机令牌；不提供命令端点。")
    }
    static var lanControl: String { t("LAN control (prototype)", "局域网控制（原型）") }
    static var lanControlHint: String {
        t("Allow an authorized computer to control this device over the local network. Off by default.",
          "允许已授权的电脑通过局域网控制此设备。默认关闭。")
    }
    static var controllerKey: String { t("Authorization ID", "授权标识") }
    static var controllerKeyMissing: String {
        t("Complete the initial remote control setup on your computer first.",
          "首次使用请先在电脑上完成遥控设置。")
    }
    static var revokeControllerKey: String { t("Revoke remote access", "撤销遥控授权") }
    static var revokeControllerConfirmTitle: String {
        t("Revoke remote access?", "撤销遥控授权？")
    }
    static var revokeControllerConfirmMessage: String {
        t("This stops remote control and revokes access. Set it up again to reconnect.",
          "这将停止遥控并撤销授权。再次连接需重新设置。")
    }
    static var revokeControllerConfirmAction: String { t("Revoke", "撤销") }
    static var controlNoAddress: String {
        t("Connect to a local network to continue.", "请连接局域网后再试。")
    }
    static var controlURL: String { t("Control URL", "控制地址") }
    static var controlWaiting: String {
        t("Starting remote control…", "正在开启遥控…")
    }
    static var token: String { t("Token", "令牌") }
    static var show: String { t("Show", "显示") }
    static var hide: String { t("Hide", "隐藏") }
    static var copy: String { t("Copy", "复制") }
    static var copyDiagnostics: String { t("Copy diagnostics", "复制诊断") }
    static var details: String { t("Details", "详细信息") }
    static var logs: String { t("Logs", "日志") }
    static var build: String { t("Build", "构建") }
    static var refresh: String { t("Refresh", "刷新") }
    static var close: String { t("Close", "关闭") }
    static var openSettings: String { t("Open Settings", "打开设置") }
    static var ddiDownloaded: String { t("DDI files validated", "DDI 文件已校验") }
    static var ddiMissing: String { t("DDI files not ready", "DDI 文件未就绪") }
    static var rebootSetupIncomplete: String {
        t("Reboot recovery is unproven until an on-device mount succeeds.",
          "在本机挂载成功前，重启恢复尚未验证。")
    }
    static var controlTestTitle: String { t("Control test surface", "控制测试界面") }
    static var controlTestHint: String {
        t("Prototype-only local controls for verifying tap, text input and swipe. Nothing here is saved.",
          "仅用于原型验证点按、文本输入与滑动的本地控件。此处不会保存任何内容。")
    }
    static var controlTestTextField: String { t("Test text field", "测试文本框") }
    static var controlTestCounter: String { t("Tap counter", "点按计数器") }
    static var controlTestScroll: String { t("Scrollable test items", "可滚动测试项目") }
    static func controlTestScrollItem(_ index: Int) -> String {
        t("Item \(index)", "项目 \(index)")
    }
}
