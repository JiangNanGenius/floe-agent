import Foundation

/// Product-only bilingual copy. The prototype L10n table remains for the
/// retained diagnostic code paths, but the shipping Bridge surfaces use these
/// concise owner-facing strings.
enum BridgeProductCopy {
    private static func t(_ english: String, _ chinese: String) -> String {
        BridgeL10n.t(english, chinese)
    }

    // MARK: - Shell

    static var appTitle: String { t("Floe iOS Bridge", "Floe iOS 桥接") }
    static var run: String { t("Run", "运行") }
    static var clients: String { t("Clients", "客户端") }
    static var diagnostics: String { t("Diagnostics", "诊断") }
    static var settings: String { t("Settings", "设置") }
    static var setup: String { t("Setup", "设置向导") }
    static var done: String { t("Done", "完成") }
    static var cancel: String { t("Cancel", "取消") }
    static var close: String { t("Close", "关闭") }
    static var open: String { t("Open", "打开") }
    static var copy: String { t("Copy", "复制") }
    static var copied: String { t("Copied.", "已复制。") }
    static var retry: String { t("Try again", "重试") }
    static var learnMore: String { t("Learn more", "了解更多") }

    // MARK: - Run

    static var needsSetup: String { t("Needs setup", "需要完成设置") }
    static var readyToStart: String { t("Ready to start", "可以启动") }
    static var preparing: String { t("Preparing", "正在准备") }
    static var running: String { t("Running", "运行中") }
    static var stopped: String { t("Stopped", "已停止") }
    static var needsAttention: String { t("Needs attention", "需要处理") }
    static var reopenRequired: String { t("Reopen required", "需要重新打开") }

    static var startBridge: String { t("Start Bridge", "启动桥接") }
    static var stopBridge: String { t("Stop Bridge", "停止桥接") }
    static var setUpBridge: String { t("Set up Bridge", "设置桥接") }
    static var reopenApp: String { t("Reopen the app", "重新打开应用") }

    static var statusNeedsSetupDetail: String {
        t("Finish the one-time setup before starting Bridge.",
          "请先完成一次性设置，再启动桥接。")
    }
    static var statusReadyDetail: String {
        t("Start the engine, then open the local address in a browser on this device.",
          "启动引擎后，在本机浏览器中打开本地地址。")
    }
    static var statusPreparingDetail: String {
        t("Keep this app open and the device unlocked while Bridge prepares.",
          "准备期间请保持此应用打开并解锁设备。")
    }
    static var statusRunningDetail: String {
        t("This device is ready for an approved browser client.",
          "此设备已可供已批准的浏览器客户端使用。")
    }
    static var statusStoppedDetail: String {
        t("The engine is stopped. Start again when you need remote control.",
          "引擎已停止。需要遥控时请重新启动。")
    }
    static var failureHint: String {
        t("Bridge could not continue. Open Diagnostics for the exact issue, then try again.",
          "桥接无法继续。请打开诊断查看具体问题，然后重试。")
    }
    static var statusAttentionDetail: String {
        t("Open Diagnostics for the current issue, then try again.",
          "请打开诊断查看当前问题，然后重试。")
    }
    static var statusReopenDetail: String {
        t("This session can no longer restart the engine. Quit Bridge and open it again.",
          "本次会话已无法重新启动引擎。请退出桥接后重新打开。")
    }

    static var checkingDevice: String { t("Checking this device…", "正在检查此设备…") }
    static var downloadingImage: String { t("Downloading the developer image…", "正在下载开发者镜像…") }
    static var connectingLocally: String { t("Starting the local connection…", "正在启动本地连接…") }
    static var preparingImage: String { t("Preparing the developer image…", "正在准备开发者镜像…") }
    static var startingEngine: String { t("Starting the control engine…", "正在启动控制引擎…") }
    static var waitingForEngine: String {
        t("Waiting for the engine. Keep the device unlocked.",
          "正在等待引擎。请保持设备解锁。")
    }
    static var readyForBrowser: String {
        t("Ready. Open the address below on this device.",
          "已就绪。请在本机打开下方地址。")
    }
    static var initializedStopped: String {
        t("The engine is initialized but stopped. Start reuses it.",
          "引擎已初始化但已停止。启动会复用它。")
    }
    static var idleDetail: String {
        t("Start Bridge to create a local remote-control session.",
          "启动桥接以创建本地遥控会话。")
    }
    static var setupNeededDetail: String {
        t("Import a pairing record and prepare the developer image first.",
          "请先导入配对记录并准备开发者镜像。")
    }
    static var setupCalloutTitle: String { t("Finish setup to run Bridge", "完成设置后即可运行桥接") }
    static var setupCalloutAction: String { t("Open setup", "打开设置向导") }

    static var localAddress: String { t("Local address", "本地地址") }
    static var localAddressUnavailable: String {
        t("The address appears here only after the engine and local service are both ready.",
          "只有在引擎与本地服务都就绪后，这里才会显示地址。")
    }
    static var localServiceListening: String {
        t("The local service is listening. The address becomes usable when the engine is ready.",
          "本地服务正在监听。引擎就绪后地址才可使用。")
    }
    static var openRemotePage: String { t("Open remote page", "打开遥控页面") }
    static var lanAddresses: String { t("On your local network", "本地网络地址") }
    static var lanSameNetworkOnly: String {
        t("Only approved computers on the same local network can connect.",
          "仅同一本地网络中的已批准电脑可以连接。")
    }
    static var lanNotReady: String {
        t("Local network access is on; waiting for a usable network address.",
          "本地网络访问已开启；正在等待可用网络地址。")
    }
    static var copyAddress: String { t("Copy address", "复制地址") }
    static var addressCopied: String { t("Address copied.", "地址已复制。") }
    static var currentStep: String { t("Current step", "当前步骤") }

    static func listenerStartFailed(_ detail: String) -> String {
        t("The local service could not start: \(detail)",
          "本地服务无法启动：\(detail)")
    }
    static func listenerPartialFailure(_ detail: String) -> String {
        t("The local service is running, but local network access could not start: \(detail)",
          "本地服务已运行，但本地网络访问无法启动：\(detail)")
    }
    static var remoteStopped: String {
        t("An approved client stopped Bridge. Start again when you need it.",
          "已批准的客户端停止了桥接。需要时请重新启动。")
    }
    static var storageWriteFailed: String {
        t("The secure store could not save that change. Nothing was reported as changed.",
          "安全存储无法保存此更改，因此没有报告为已更改。")
    }

    // MARK: - Setup

    static var setupIntro: String {
        t("Set up Bridge once on this device. You do not need an Apple ID, a signing certificate, or an extra helper app here.",
          "在此设备上完成一次桥接设置。此处不需要 Apple ID、签名证书或额外辅助应用。")
    }
    static var setupPairingTitle: String { t("1. Developer pairing record", "1. 开发者配对记录") }
    static var setupPairingDetail: String {
        t("Import the RemotePairing record your development Mac saved for this device. It is stored in the Keychain and used only to prepare the developer image.",
          "导入开发 Mac 为此设备保存的 RemotePairing 记录。它将存储在钥匙串中，仅用于准备开发者镜像。")
    }
    static var setupPairingImported: String { t("Imported", "已导入") }
    static var setupPairingMissing: String { t("Not imported", "未导入") }
    static var importPairing: String { t("Import pairing record", "导入配对记录") }
    static var replacePairing: String { t("Replace pairing record", "替换配对记录") }
    static var removePairing: String { t("Remove pairing record", "移除配对记录") }
    static var setupPairingImportedBanner: String { t("Pairing record imported.", "配对记录已导入。") }
    static var setupPairingRemovedBanner: String { t("Pairing record removed.", "配对记录已移除。") }

    static var setupVPNTitle: String { t("2. Local connection", "2. 本地连接") }
    static var setupVPNDetail: String {
        t("Bridge uses its own local VPN configuration to reach the developer service. iOS may ask you to allow it; no third-party VPN profile is needed.",
          "桥接使用自带的本地 VPN 配置访问开发者服务。iOS 可能会请求你的允许；无需第三方 VPN 配置。")
    }
    static var setupVPNStart: String { t("Set up local connection", "设置本地连接") }
    static var setupVPNStop: String { t("Stop local connection", "停止本地连接") }
    static var setupVPNStarting: String { t("Waiting for system approval…", "正在等待系统批准…") }
    static var setupVPNConnected: String { t("Local connection ready", "本地连接已就绪") }
    static var setupVPNDisconnected: String { t("Not connected", "未连接") }
    static var setupVPNNeedsPermission: String {
        t("If iOS denied the connection, allow Bridge in Settings → General → VPN & Device Management, then try again.",
          "如果 iOS 拒绝了连接，请在“设置”→“通用”→“VPN 与设备管理”中允许桥接，然后重试。")
    }
    static var setupVPNConflict: String {
        t("Another VPN or device management profile may be using the same connection. Stop it and try again.",
          "其他 VPN 或设备管理配置可能占用了同一连接。请先停止它，然后重试。")
    }

    static var setupImageTitle: String { t("3. Developer image", "3. 开发者镜像") }
    static var setupImageDetail: String {
        t("Bridge needs the matching developer disk image at runtime. It is never bundled in the app.",
          "桥接在运行时需要匹配的开发者磁盘镜像。它不会打包进应用。")
    }
    static var setupImageReady: String { t("Files ready", "文件已就绪") }
    static var setupImageMounted: String { t("Mounted on this device", "已在此设备挂载") }
    static var setupImageMissing: String { t("Not ready", "未就绪") }
    static var downloadImage: String { t("Download image files", "下载镜像文件") }
    static var importImage: String { t("Import image folder", "导入镜像文件夹") }
    static var cancelDownload: String { t("Cancel download", "取消下载") }
    static var setupGuideTitle: String { t("Setup guide", "设置指南") }
    static var setupGuideHint: String {
        t("See the short guide for the browser steps and common recovery actions.",
          "查看简短指南，了解浏览器步骤与常见恢复操作。")
    }
    static var setupOpenGuide: String { t("Open guide", "打开指南") }
    static var noPairingSelected: String { t("No pairing record selected.", "未选择配对记录。") }
    static var noImageSelected: String { t("No image folder selected.", "未选择镜像文件夹。") }

    // MARK: - Clients

    static func clientCount(_ count: Int) -> String {
        t("\(count) clients", "\(count) 个客户端")
    }
    static var noClientsTitle: String { t("No paired clients", "尚无已配对客户端") }
    static var noClientsDetail: String {
        t("Open the local address in a browser on this device, then approve its pairing request here.",
          "在本机浏览器中打开本地地址，然后在此处批准其配对请求。")
    }
    static var clientsNeedService: String {
        t("Start Bridge before pairing a client.",
          "请先启动桥接，再配对客户端。")
    }
    static var clientSourceDevice: String { t("This device", "此设备") }
    static var clientSourceLAN: String { t("Local network", "本地网络") }
    static var clientSourceUnknown: String { t("Unknown source", "未知来源") }
    static var lastActive: String { t("Last active", "最近活动") }
    static var justNow: String { t("Just now", "刚刚") }
    static var sensitiveInput: String { t("Sensitive app input", "敏感应用输入") }
    static var sensitiveInputDetail: String {
        t("Allows this client to operate password fields in third-party apps. System passcode and authentication prompts are never available. Ordinary text input does not need this.",
          "允许此客户端操作第三方应用中的密码栏。系统密码与认证提示永远不可用。普通文本输入无需此权限。")
    }
    static var revoke: String { t("Revoke", "撤销") }
    static var revokeAll: String { t("Revoke all clients", "撤销所有客户端") }
    static var revokeClientTitle: String { t("Revoke this client?", "撤销此客户端？") }
    static var revokeClientMessage: String {
        t("The client is disconnected immediately and must pair again.",
          "此客户端会立即断开，并需要重新配对。")
    }
    static var revokeAllTitle: String { t("Revoke every client?", "撤销所有客户端？") }
    static var revokeAllMessage: String {
        t("All browser clients are disconnected immediately and must pair again.",
          "所有浏览器客户端都会立即断开，并需要重新配对。")
    }
    static var clientApproved: String { t("Approved", "已批准") }
    static var storageUnavailable: String {
        t("Secure client storage is unavailable. Existing clients cannot be verified and new pairings will be refused.",
          "安全客户端存储不可用。无法验证现有客户端，新的配对请求也会被拒绝。")
    }

    // MARK: - Pairing approval

    static var approvalTitle: String { t("Allow this client?", "允许此客户端？") }
    static var approvalDetail: String {
        t("Only approve a browser you opened and recognize. The request expires automatically.",
          "请仅批准你亲自打开并确认的浏览器。请求会自动过期。")
    }
    static var approvalAllow: String { t("Allow", "允许") }
    static var approvalDeny: String { t("Don't allow", "不允许") }
    static var approvalFromDevice: String { t("From this device", "来自此设备") }
    static var approvalFromLAN: String { t("From the local network", "来自本地网络") }
    static var approvalFingerprint: String { t("Key fingerprint", "密钥指纹") }
    static var approvalUnknownClient: String { t("Unnamed client", "未命名客户端") }
    static var approvalExpired: String { t("Request expired", "请求已过期") }
    static func approvalExpiresIn(_ seconds: Int) -> String {
        t("Expires in \(max(0, seconds))s", "\(max(0, seconds)) 秒后过期")
    }

    // MARK: - Diagnostics

    static var now: String { t("Now", "当前状态") }
    static var status: String { t("Status", "状态") }
    static var phase: String { t("Phase", "阶段") }
    static var stage: String { t("Stage", "阶段详情") }
    static var engine: String { t("Engine", "引擎") }
    static var localService: String { t("Local service", "本地服务") }
    static var localNetwork: String { t("Local network", "本地网络") }
    static var bonjour: String { t("Bonjour discovery", "Bonjour 发现") }
    static var storage: String { t("Secure storage", "安全存储") }
    static var timing: String { t("Timing", "时间") }
    static var started: String { t("Started", "已开始") }
    static var ready: String { t("Ready", "已就绪") }
    static var stoppedAt: String { t("Stopped", "已停止") }
    static var updated: String { t("Updated", "已更新") }
    static var lastIssue: String { t("Last issue", "最近问题") }
    static var noIssue: String { t("No issue recorded.", "未记录问题。") }
    static var connectionDetails: String { t("Connection details", "连接详情") }
    static var port: String { t("Port", "端口") }
    static var connectedClients: String { t("Paired clients", "已配对客户端") }
    static var methods: String { t("Engine methods", "引擎方法") }
    static var capabilities: String { t("Capabilities", "能力") }
    static var exportSafeDiagnostics: String { t("Export safe diagnostics", "导出安全诊断") }
    static var copySafeDiagnostics: String { t("Copy safe diagnostics", "复制安全诊断") }
    static var safeDiagnosticsCopied: String { t("Safe diagnostics copied.", "安全诊断已复制。") }
    static var diagnosticsPrivacy: String {
        t("The export contains state, timings, ports, bounded status-log metadata and redacted errors. It excludes file paths, client names, ids and addresses, keys, typed text, screenshots and log bodies.",
          "导出内容包含状态、时间、端口、有界状态日志元数据与已脱敏的错误信息；不包含文件路径、客户端名称、ID 与地址、密钥、输入文本、截图和日志正文。")
    }
    static var diagnosticsUnavailable: String {
        t("Diagnostics are not available yet.", "诊断尚不可用。")
    }
    static var showSafeExport: String { t("Show safe export", "显示安全导出") }
    static var hideSafeExport: String { t("Hide safe export", "隐藏安全导出") }
    static var recentStatusEvents: String { t("Recent status events", "最近状态事件") }
    static var statusEventsPrivacy: String {
        t("Fixed status fields only: lifecycle states, readiness, counts, generations and timings. No input, client details, keys or log bodies.",
          "仅包含固定状态字段：生命周期状态、就绪情况、计数、代数与时间；不含输入、客户端信息、密钥或日志正文。")
    }
    static var noRecentStatusEvents: String {
        t("No status events yet.", "尚无状态事件。")
    }
    static var statusLogStored: String { t("Stored on this device", "已存储在此设备") }
    static var statusLogMemoryOnly: String { t("This session only", "仅本次会话") }
    static var statusLog: String { t("Status log", "状态日志") }

    // MARK: - Settings

    static var restoreOnOpen: String { t("Restore when Bridge opens", "打开桥接时恢复") }
    static var restoreOnOpenDetail: String {
        t("Opening Bridge resumes a session you last started. Stop keeps it stopped until you start again; turning this off never changes a running session.",
          "打开桥接会恢复你上次启动的会话。停止后会保持停止，直到你再次启动；关闭此选项不会改变正在运行的会话。")
    }
    static var lanAccess: String { t("Allow local network access", "允许本地网络访问") }
    static var lanAccessDetail: String {
        t("Off by default. Lets approved computers on the same network reach Bridge. No peer-to-peer, AWDL or internet relay is used.",
          "默认关闭。允许同一网络中的已批准电脑访问桥接。不使用点对点、AWDL 或互联网中继。")
    }
    static var bonjourDiscovery: String { t("Advertise with Bonjour", "使用 Bonjour 广播") }
    static var bonjourDetail: String {
        t("Off by default. Requires local network access. Advertises only on the same local network.",
          "默认关闭。需要先开启本地网络访问。仅在同一本地网络中广播。")
    }
    static var bonjourRequiresLAN: String {
        t("Turn on local network access first.", "请先开启本地网络访问。")
    }
    static var portDetail: String { t("Local port 8200", "本地端口 8200") }
    static var language: String { t("Language", "语言") }
    static var languageSystem: String {
        t("Follows the system: English or Simplified Chinese",
          "跟随系统：英文或简体中文")
    }
    static var about: String { t("About", "关于") }
    static var version: String { t("Version", "版本") }
    static var notices: String { t("Notices and licenses", "声明与许可") }
    static var help: String { t("Help", "帮助") }
    static var openSetup: String { t("Open setup", "打开设置向导") }
    static var networkError: String { t("Local network error", "本地网络错误") }
    static var bonjourError: String { t("Bonjour could not start.", "Bonjour 无法启动。") }

    // MARK: - Guide

    static var guideTitle: String { t("Bridge setup guide", "桥接设置指南") }
    static var guideIntro: String {
        t("Bridge keeps the browser client and this device on the same local connection. A computer is only needed for the first preparation steps.",
          "桥接会让浏览器客户端与此设备保持在同一本地连接中。仅首次准备步骤需要电脑。")
    }
    static var guideStepPairing: String {
        t("Import the RemotePairing record from your development Mac.",
          "从开发 Mac 导入 RemotePairing 记录。")
    }
    static var guideStepVPN: String {
        t("Set up the local connection and allow it when iOS asks.",
          "设置本地连接，并在 iOS 询问时允许。")
    }
    static var guideStepImage: String {
        t("Download or import the matching developer image files.",
          "下载或导入匹配的开发者镜像文件。")
    }
    static var guideStepBrowser: String {
        t("Start Bridge, open the local address on this device, and approve the pairing request here.",
          "启动桥接，在本机打开本地地址，并在此处批准配对请求。")
    }
    static var guideTroubleshootingTitle: String { t("If something does not work", "如果出现问题") }
    static var guideTroubleshootAddress: String {
        t("No address: start Bridge and wait for both the engine and local service to be ready.",
          "没有地址：启动桥接，等待引擎与本地服务都就绪。")
    }
    static var guideTroubleshootVPN: String {
        t("Connection refused: allow Bridge under Settings → General → VPN & Device Management.",
          "连接被拒绝：在“设置”→“通用”→“VPN 与设备管理”中允许桥接。")
    }
    static var guideTroubleshootReopen: String {
        t("Reopen required: quit Bridge completely and open it again. A latched engine fault cannot be retried in the same session.",
          "需要重新打开：完全退出桥接后重新打开。已锁定的引擎故障无法在同一会话中重试。")
    }
    static var guideTroubleshootPairing: String {
        t("Pairing denied or expired: open the address again and approve the fresh request.",
          "配对被拒绝或已过期：重新打开地址并批准新的请求。")
    }
    static var guideTroubleshootSensitive: String {
        t("Password field unavailable: enable sensitive app input for that client in Clients. System authentication remains unavailable.",
          "密码栏不可用：在“客户端”中为该客户端开启敏感应用输入。系统认证仍不可用。")
    }

    // MARK: - Notices

    static var noticesIntro: String {
        t("Bridge includes adapted open-source code and Apple system frameworks. No advertising or behavioural analytics SDK is included.",
          "桥接包含改编的开源代码与 Apple 系统框架。不包含广告或行为分析 SDK。")
    }
    static var noticeICTRL: String {
        t("Remote-control protocol and browser client adapted from OpenMinis/iCTRL, Apache License 2.0.",
          "遥控协议与浏览器客户端改编自 OpenMinis/iCTRL，Apache License 2.0。")
    }
    static var noticeApple: String {
        t("System controls, networking, Keychain, video encoding and browser rendering use Apple platform frameworks.",
          "系统控件、网络、钥匙串、视频编码与浏览器渲染使用 Apple 平台框架。")
    }
    static var noticeNoAccount: String {
        t("Bridge does not create an account, upload device data to Floe, or use an internet relay.",
          "桥接不会创建账户、将设备数据上传至 Floe，或使用互联网中继。")
    }
}
