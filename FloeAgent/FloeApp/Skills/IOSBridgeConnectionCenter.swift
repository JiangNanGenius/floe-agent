// FloeIOSAutomation — native App connection-center adapter.
//
// This file is the App-facing glue for the generic Skill detail page. It owns
// no persistence and no approval store: the AppEnvironment injects the native
// client, which is backed by the generic Skill secret store and the existing
// task authority. Mac/iOS-on-Mac/Simulator entry points must stay hidden via
// LocalBridgePlatform.current.supportsIOSAutomation.

#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import FloeCore
import FloeIOSAutomation
import SwiftUI
import UIKit

@MainActor
final class IOSBridgeConnectionCenter: ObservableObject {
    enum PrimaryAction: Equatable {
        case none
        case getBridge
        case openBridge
        case pair
        case rePair
        case check
        case useInChat
    }

    static var isSupported: Bool {
        LocalBridgePlatform.current.supportsIOSAutomation
    }

    static var downloadURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "FloeIOSBridgeDownloadURL") as? String,
              let url = URL(string: text),
              url.scheme == "https",
              url.host == "www.floe-agent.com",
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }

    /// Optional, additive open/return handoff supplied by the Bridge companion
    /// patch. The released Bridge 1.0 has no URL scheme, so nil means the user
    /// opens Bridge manually. Never place a pairing key or other secret here.
    static var companionOpenURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "FloeIOSBridgeOpenURL") as? String,
              let url = URL(string: text),
              url.scheme?.lowercased() == "floe-ios-bridge",
              url.user == nil,
              url.password == nil,
              (url.query?.utf8.count ?? 0) <= 128,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    static var defaultClientName: String {
        let model = UIDevice.current.model
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        return String(format: chinese ? "Floe（%@）" : "Floe on %@", model)
    }

    @Published private(set) var snapshot: IOSBridgeConnectionSnapshot?
    @Published private(set) var status: IOSBridgeConnectionStatus = .unknown
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPairing = false
    @Published private(set) var pairingProgress: IOSBridgePairingProgress?
    @Published private(set) var lastPairingResult: IOSBridgePairingResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var forgetNotice: String?
    @Published var showingForgetConfirmation = false
    @Published var showingRePairConfirmation = false

    private let client: IOSBridgeClient
    private var pairingTask: Task<Void, Never>?

    init(client: IOSBridgeClient) {
        self.client = client
    }

    var supported: Bool { Self.isSupported }

    var statusTitle: String {
        IOSBridgeConnectionCopy.text(Self.statusCopy(for: status).title)
    }

    var statusDetail: String {
        IOSBridgeConnectionCopy.text(Self.statusCopy(for: status).detail)
    }

    var statusSymbol: String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .unsupportedPlatform: return "iphone.slash"
        case .companionMissing: return "square.and.arrow.down"
        case .companionPresenceUnknown, .serviceOff, .serviceUnavailable:
            return "bolt.horizontal.circle"
        case .incompatibleBridge: return "exclamationmark.triangle"
        case .needsPairing: return "link.badge.plus"
        case .pairingInProgress, .waitingForOwnerApproval: return "hourglass"
        case .lockedCredentials: return "lock"
        case .credentialsUnavailable, .pairingRecordInvalid: return "exclamationmark.triangle"
        case .expired, .revoked: return "link.badge.minus"
        case .engineNotReady: return "gearshape.2"
        case .unknown: return "questionmark.circle"
        }
    }

    var primaryAction: PrimaryAction {
        switch status {
        case .ready:
            return .useInChat
        case .unsupportedPlatform:
            return .none
        case .companionMissing:
            return Self.downloadURL == nil ? .none : .getBridge
        case .companionPresenceUnknown, .serviceOff, .serviceUnavailable, .engineNotReady:
            if Self.companionOpenURL != nil { return .openBridge }
            return .check
        case .incompatibleBridge:
            return Self.downloadURL == nil ? .check : .getBridge
        case .needsPairing:
            return .pair
        case .pairingInProgress, .waitingForOwnerApproval:
            return .none
        case .lockedCredentials:
            return .check
        case .credentialsUnavailable:
            return .check
        case .pairingRecordInvalid, .expired, .revoked:
            return .rePair
        case .unknown:
            return .check
        }
    }

    var pairingProgressText: String {
        guard let pairingProgress else {
            return IOSBridgeConnectionCopy.text("ios.bridge.state.pairing")
        }
        switch pairingProgress {
        case .contactingCompanion:
            return IOSBridgeConnectionCopy.text("ios.bridge.progress.contacting")
        case .waitingForOwnerApproval:
            return IOSBridgeConnectionCopy.text("ios.bridge.progress.waiting")
        case .savingCredential:
            return IOSBridgeConnectionCopy.text("ios.bridge.progress.saving")
        case .verifyingCredential:
            return IOSBridgeConnectionCopy.text("ios.bridge.progress.verifying")
        case .paired:
            return IOSBridgeConnectionCopy.text("ios.bridge.progress.paired")
        }
    }

    var diagnosticsStatus: String {
        statusKey(status)
    }

    var diagnosticsProtocol: String {
        guard let version = snapshot?.info?.protocolVersion else { return "—" }
        return "v\(version)"
    }

    var diagnosticsEngine: String {
        guard let engine = snapshot?.configuration?.engineState else { return "—" }
        switch engine {
        case .unknown: return IOSBridgeConnectionCopy.text("ios.bridge.diag.unknown")
        case .notRegistered: return IOSBridgeConnectionCopy.text("ios.bridge.diag.not_registered")
        case .notReady(let reason):
            return reason.isEmpty
                ? IOSBridgeConnectionCopy.text("ios.bridge.diag.not_ready")
                : reason
        case .ready: return IOSBridgeConnectionCopy.text("ios.bridge.diag.ready")
        }
    }

    var diagnosticsMethodCount: Int {
        snapshot?.configuration?.supportedMethods.count ?? 0
    }

    var diagnosticsExpiry: String {
        guard let date = snapshot?.clientExpiresAt else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var diagnosticsSensitiveInput: String {
        guard let value = snapshot?.sensitiveInputGranted else { return "—" }
        return IOSBridgeConnectionCopy.text(
            value ? "ios.bridge.diag.granted" : "ios.bridge.diag.not_granted"
        )
    }

    var diagnosticsDetail: String? {
        snapshot?.detail
    }

    var shouldShowInstallation: Bool {
        switch status {
        case .companionMissing, .companionPresenceUnknown, .serviceUnavailable,
             .incompatibleBridge:
            return true
        default:
            return false
        }
    }

    var needsBridgeAttention: Bool {
        switch status {
        case .companionPresenceUnknown, .serviceOff, .serviceUnavailable,
             .engineNotReady, .incompatibleBridge:
            return true
        default:
            return false
        }
    }

    func refresh() async {
        guard Self.isSupported else {
            status = .unsupportedPlatform
            return
        }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let next = await client.status()
        snapshot = next
        status = next.status
        if next.status == .unsupportedPlatform {
            errorMessage = IOSBridgeConnectionCopy.text("ios.bridge.error.unsupported")
        }
    }

    func beginPairing(replaceExisting: Bool = false) {
        guard Self.isSupported, !isPairing else { return }
        forgetNotice = nil
        errorMessage = nil
        isPairing = true
        pairingProgress = .contactingCompanion
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isPairing = false
                self.pairingProgress = nil
                self.pairingTask = nil
            }
            do {
                let result = try await self.client.pair(
                    clientName: Self.defaultClientName,
                    replaceExisting: replaceExisting
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.pairingProgress = progress
                    }
                }
                self.lastPairingResult = result
                self.errorMessage = nil
                await self.refresh()
            } catch let error as IOSBridgeError {
                if error != .cancelled {
                    self.errorMessage = IOSBridgeConnectionCopy.errorText(error)
                }
                await self.refresh()
            } catch {
                self.errorMessage = IOSBridgeConnectionCopy.text("ios.bridge.error.generic")
                await self.refresh()
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        Task { await client.cancelPairing() }
    }

    func forgetLocalPairing() async {
        do {
            let result = try await client.forgetLocalPairing()
            forgetNotice = result.handleWasPresent
                ? IOSBridgeConnectionCopy.text("ios.bridge.forget.done")
                : IOSBridgeConnectionCopy.text("ios.bridge.forget.nothing")
            errorMessage = nil
            await refresh()
        } catch let error as IOSBridgeError {
            errorMessage = IOSBridgeConnectionCopy.errorText(error)
        } catch {
            errorMessage = IOSBridgeConnectionCopy.text("ios.bridge.error.generic")
        }
    }

    func openCompanion() {
        guard let url = Self.companionOpenURL else { return }
        UIApplication.shared.open(url)
    }

    func openDownload() {
        guard let url = Self.downloadURL else { return }
        UIApplication.shared.open(url)
    }

    private func statusKey(_ status: IOSBridgeConnectionStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .unsupportedPlatform: return "unsupported"
        case .companionMissing: return "companion_missing"
        case .companionPresenceUnknown: return "companion_unknown"
        case .serviceOff: return "service_off"
        case .serviceUnavailable: return "service_unavailable"
        case .incompatibleBridge(let version): return "incompatible:\(version)"
        case .needsPairing: return "needs_pairing"
        case .pairingInProgress: return "pairing"
        case .waitingForOwnerApproval: return "waiting_approval"
        case .lockedCredentials: return "locked"
        case .credentialsUnavailable: return "credentials_unavailable"
        case .pairingRecordInvalid: return "pairing_invalid"
        case .expired: return "expired"
        case .revoked: return "revoked"
        case .engineNotReady: return "engine_not_ready"
        case .ready: return "ready"
        }
    }

    private static func statusCopy(
        for status: IOSBridgeConnectionStatus
    ) -> (title: String, detail: String) {
        switch status {
        case .unknown:
            return ("ios.bridge.state.checking", "ios.bridge.state.checking_detail")
        case .unsupportedPlatform:
            return ("ios.bridge.state.unsupported", "ios.bridge.state.unsupported_detail")
        case .companionMissing:
            return ("ios.bridge.state.companion_missing", "ios.bridge.state.companion_missing_detail")
        case .companionPresenceUnknown, .serviceUnavailable:
            return ("ios.bridge.state.service_unavailable", "ios.bridge.state.service_unavailable_detail")
        case .serviceOff:
            return ("ios.bridge.state.service_off", "ios.bridge.state.service_off_detail")
        case .incompatibleBridge:
            return ("ios.bridge.state.incompatible", "ios.bridge.state.incompatible_detail")
        case .needsPairing:
            return ("ios.bridge.state.needs_pairing", "ios.bridge.state.needs_pairing_detail")
        case .pairingInProgress:
            return ("ios.bridge.state.pairing", "ios.bridge.state.pairing_detail")
        case .waitingForOwnerApproval:
            return ("ios.bridge.state.waiting_approval", "ios.bridge.state.waiting_approval_detail")
        case .lockedCredentials:
            return ("ios.bridge.state.locked", "ios.bridge.state.locked_detail")
        case .credentialsUnavailable:
            return ("ios.bridge.state.credentials_unavailable", "ios.bridge.state.credentials_unavailable_detail")
        case .pairingRecordInvalid:
            return ("ios.bridge.state.pairing_invalid", "ios.bridge.state.pairing_invalid_detail")
        case .expired:
            return ("ios.bridge.state.expired", "ios.bridge.state.expired_detail")
        case .revoked:
            return ("ios.bridge.state.revoked", "ios.bridge.state.revoked_detail")
        case .engineNotReady:
            return ("ios.bridge.state.engine_not_ready", "ios.bridge.state.engine_not_ready_detail")
        case .ready:
            return ("ios.bridge.state.ready", "ios.bridge.state.ready_detail")
        }
    }
}

struct IOSBridgeConnectionView: View {
    @ObservedObject var center: IOSBridgeConnectionCenter
    var onUseInChat: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(center.statusTitle)
                        Text(center.statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: center.statusSymbol)
                }
                if center.isPairing {
                    HStack {
                        ProgressView()
                        Text(center.pairingProgressText)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        center.cancelPairing()
                    } label: {
                        t("ios.bridge.action.cancel_pairing")
                    }
                } else {
                    primaryButton
                }
                if let error = center.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if let notice = center.forgetNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }

            if center.shouldShowInstallation {
                Section {
                    t("ios.bridge.install.body")
                    if IOSBridgeConnectionCenter.downloadURL != nil {
                        Button {
                            center.openDownload()
                        } label: {
                            t("ios.bridge.action.get_bridge")
                        }
                    }
                    Text(IOSBridgeConnectionCopy.text("ios.bridge.note.local_only"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    t("ios.bridge.section.installation")
                }
            }

            if center.needsBridgeAttention {
                Section {
                    Text(IOSBridgeConnectionCopy.text("ios.bridge.open_bridge_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup {
                    LabeledContent {
                        Text(center.diagnosticsStatus)
                    } label: {
                        t("ios.bridge.diag.status")
                    }
                    LabeledContent {
                        Text(center.diagnosticsProtocol)
                    } label: {
                        t("ios.bridge.diag.protocol")
                    }
                    LabeledContent {
                        Text(center.diagnosticsEngine)
                    } label: {
                        t("ios.bridge.diag.engine")
                    }
                    LabeledContent {
                        Text("\(center.diagnosticsMethodCount)")
                    } label: {
                        t("ios.bridge.diag.methods")
                    }
                    LabeledContent {
                        Text(center.diagnosticsExpiry)
                    } label: {
                        t("ios.bridge.diag.expires")
                    }
                    LabeledContent {
                        Text(center.diagnosticsSensitiveInput)
                    } label: {
                        t("ios.bridge.diag.sensitive_input")
                    }
                    if let detail = center.diagnosticsDetail {
                        LabeledContent {
                            Text(detail)
                        } label: {
                            t("ios.bridge.diag.detail")
                        }
                    }
                } label: {
                    t("ios.bridge.section.diagnostics")
                }
                Button {
                    center.showingRePairConfirmation = true
                } label: {
                    t("ios.bridge.action.repair")
                }
                .disabled(center.isPairing || center.isRefreshing)
                Button(role: .destructive) {
                    center.showingForgetConfirmation = true
                } label: {
                    t("ios.bridge.action.forget")
                }
                .disabled(center.isPairing || center.isRefreshing)
                Text(IOSBridgeConnectionCopy.text("ios.bridge.note.permissions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                t("ios.bridge.section.advanced")
            }
        }
        .navigationTitle(Text(IOSBridgeConnectionCopy.text("ios.bridge.title")))
        .task { await center.refresh() }
        .confirmationDialog(
            Text(IOSBridgeConnectionCopy.text("ios.bridge.forget.title")),
            isPresented: $center.showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await center.forgetLocalPairing() }
            } label: {
                t("ios.bridge.action.forget")
            }
            Button(role: .cancel) {} label: {
                Text("action.cancel")
            }
        } message: {
            Text(IOSBridgeConnectionCopy.text("ios.bridge.forget.message"))
        }
        .confirmationDialog(
            Text(IOSBridgeConnectionCopy.text("ios.bridge.repair.title")),
            isPresented: $center.showingRePairConfirmation,
            titleVisibility: .visible
        ) {
            Button {
                center.beginPairing(replaceExisting: true)
            } label: {
                t("ios.bridge.action.repair")
            }
            Button(role: .cancel) {} label: {
                Text("action.cancel")
            }
        } message: {
            Text(IOSBridgeConnectionCopy.text("ios.bridge.repair.message"))
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch center.primaryAction {
        case .none:
            EmptyView()
        case .getBridge:
            Button {
                center.openDownload()
            } label: {
                t("ios.bridge.action.get_bridge")
            }
        case .openBridge:
            Button {
                center.openCompanion()
            } label: {
                t("ios.bridge.action.open_bridge")
            }
        case .pair:
            Button {
                center.beginPairing()
            } label: {
                t("ios.bridge.action.pair")
            }
        case .rePair:
            Button {
                center.showingRePairConfirmation = true
            } label: {
                t("ios.bridge.action.repair")
            }
        case .check:
            Button {
                Task { await center.refresh() }
            } label: {
                t("ios.bridge.action.check")
            }
            .disabled(center.isRefreshing)
        case .useInChat:
            Button {
                if let onUseInChat {
                    onUseInChat()
                } else {
                    dismiss()
                }
            } label: {
                t("ios.bridge.action.use_in_chat")
            }
        }
    }

    private func t(_ key: String) -> Text {
        Text(IOSBridgeConnectionCopy.text(key))
    }
}

enum IOSBridgeConnectionCopy {
    private static let fallback: [String: (en: String, zh: String)] = [
        "ios.bridge.title": ("Local automation", "本机自动化"),
        "ios.bridge.state.checking": ("Checking Bridge…", "正在检查 Bridge…"),
        "ios.bridge.state.checking_detail": ("Floe is checking the connection on this device.", "Floe 正在检查本机连接。"),
        "ios.bridge.state.unsupported": ("Not available on this device", "此设备不可用"),
        "ios.bridge.state.unsupported_detail": ("Local automation is available only in Floe on a supported iPhone or iPad. It is unavailable on Mac, in the Simulator and in Mac Catalyst.", "本机自动化仅适用于受支持的 iPhone 或 iPad 上的 Floe；Mac、模拟器和 Mac Catalyst 不可用。"),
        "ios.bridge.state.companion_missing": ("Bridge isn't installed", "尚未安装 Bridge"),
        "ios.bridge.state.companion_missing_detail": ("Install the local Bridge companion on this iPhone or iPad, then return here.", "请先在此 iPhone 或 iPad 上安装本机 Bridge 配套应用，然后返回。"),
        "ios.bridge.state.service_off": ("Bridge is not running", "Bridge 未运行"),
        "ios.bridge.state.service_off_detail": ("Open Bridge on this device and keep it available while Floe uses local automation.", "请在此设备上打开 Bridge，并在 Floe 使用本机自动化期间保持可用。"),
        "ios.bridge.state.service_unavailable": ("Bridge isn't reachable", "无法连接 Bridge"),
        "ios.bridge.state.service_unavailable_detail": ("Open Bridge on this device, check that it is running, then check the connection again. If Bridge isn't installed, get it first.", "请在此设备上打开 Bridge，确认其正在运行，然后重新检查连接。如果尚未安装 Bridge，请先获取。"),
        "ios.bridge.state.incompatible": ("Bridge needs an update", "Bridge 需要更新"),
        "ios.bridge.state.incompatible_detail": ("This Bridge version uses an unsupported protocol. Update Bridge on this device.", "此 Bridge 版本使用不支持的协议，请更新此设备上的 Bridge。"),
        "ios.bridge.state.needs_pairing": ("Not paired", "尚未配对"),
        "ios.bridge.state.needs_pairing_detail": ("Pair Floe with Bridge on this device. Bridge will ask you to approve.", "请在此设备上配对 Floe 与 Bridge，Bridge 会请求你批准。"),
        "ios.bridge.state.pairing": ("Pairing…", "正在配对…"),
        "ios.bridge.state.pairing_detail": ("Keep Bridge open while the pairing is completed.", "配对完成前请保持 Bridge 打开。"),
        "ios.bridge.state.waiting_approval": ("Approve in Bridge", "请在 Bridge 中批准"),
        "ios.bridge.state.waiting_approval_detail": ("Open Bridge on this device and approve Floe's pairing request.", "请在此设备上打开 Bridge，并批准 Floe 的配对请求。"),
        "ios.bridge.state.locked": ("Unlock this device", "请解锁此设备"),
        "ios.bridge.state.locked_detail": ("Saved Bridge credentials are locked. Unlock the device and try again; nothing was deleted.", "已保存的 Bridge 凭据已锁定。请解锁设备后重试；凭据未被删除。"),
        "ios.bridge.state.credentials_unavailable": ("Saved connection unavailable", "已保存的连接暂不可用"),
        "ios.bridge.state.credentials_unavailable_detail": ("Floe can't read the saved Bridge connection right now. Try again; it was not deleted.", "Floe 暂时无法读取已保存的 Bridge 连接。请重试；该连接未被删除。"),
        "ios.bridge.state.pairing_invalid": ("Pairing needs repair", "配对需要修复"),
        "ios.bridge.state.pairing_invalid_detail": ("The saved pairing is invalid. Pair again; the old record stays until a new one is saved.", "已保存的配对无效。请重新配对；旧记录会在新配对保存成功后才替换。"),
        "ios.bridge.state.expired": ("Pairing expired", "配对已过期"),
        "ios.bridge.state.expired_detail": ("Bridge expires an unused pairing after 30 days. Pair again and approve in Bridge.", "Bridge 会在 30 天未使用后使配对失效。请重新配对并在 Bridge 中批准。"),
        "ios.bridge.state.revoked": ("Pairing no longer authorized", "配对已失效"),
        "ios.bridge.state.revoked_detail": ("Bridge no longer recognizes this pairing. Pair again; the old local record is replaced only after the new one is saved.", "Bridge 已不再识别此配对。请重新配对；旧的本机记录会在新配对保存成功后才替换。"),
        "ios.bridge.state.engine_not_ready": ("Bridge is starting", "Bridge 正在准备"),
        "ios.bridge.state.engine_not_ready_detail": ("Bridge is reachable and paired, but its automation engine isn't ready. Open Bridge and check its setup.", "Bridge 已连接并完成配对，但自动化引擎尚未就绪。请打开 Bridge 检查准备状态。"),
        "ios.bridge.state.ready": ("Ready", "已就绪"),
        "ios.bridge.state.ready_detail": ("Floe can use the built-in local automation commands on this device.", "Floe 可以使用此设备上的内置本机自动化命令。"),
        "ios.bridge.action.check": ("Check connection", "检查连接"),
        "ios.bridge.action.pair": ("Pair with Bridge", "与 Bridge 配对"),
        "ios.bridge.action.repair": ("Pair again", "重新配对"),
        "ios.bridge.action.cancel_pairing": ("Cancel pairing", "取消配对"),
        "ios.bridge.action.open_bridge": ("Open Bridge", "打开 Bridge"),
        "ios.bridge.action.get_bridge": ("Get Bridge", "获取 Bridge"),
        "ios.bridge.action.use_in_chat": ("Use in chat", "在对话中使用"),
        "ios.bridge.action.forget": ("Forget this connection", "忘掉此连接"),
        "ios.bridge.forget.title": ("Forget the saved pairing?", "忘掉已保存的配对？"),
        "ios.bridge.forget.message": ("This removes the saved connection from Floe only. It does not revoke Floe in Bridge; remove this client in Bridge if you want to revoke it there.", "此操作只会从 Floe 中移除已保存的连接，不会在 Bridge 中撤销 Floe。如需撤销，请在 Bridge 中移除此客户端。"),
        "ios.bridge.forget.done": ("The saved connection was removed from Floe. It may still be listed in Bridge.", "已从 Floe 中移除保存的连接；Bridge 中可能仍保留该客户端。"),
        "ios.bridge.forget.nothing": ("There was no saved connection to remove.", "没有可移除的已保存连接。"),
        "ios.bridge.repair.title": ("Pair again?", "重新配对？"),
        "ios.bridge.repair.message": ("The existing local pairing stays until the new pairing is saved and verified. Bridge will ask you to approve.", "现有本机配对会保留到新配对保存并验证成功；Bridge 会请求你批准。"),
        "ios.bridge.section.installation": ("Install Bridge", "安装 Bridge"),
        "ios.bridge.install.body": ("Local automation uses the separate Bridge companion on this iPhone or iPad. Installing the skill does not install Bridge, pair it or grant control.", "本机自动化使用此 iPhone 或 iPad 上独立的 Bridge 配套应用。安装技能不会安装 Bridge、完成配对或授予控制权限。"),
        "ios.bridge.open_bridge_hint": ("Released Bridge 1.0 has no automatic open link. Open the Bridge app manually on this device, then check the connection again.", "已发布的 Bridge 1.0 暂无自动打开链接。请在此设备上手动打开 Bridge，然后重新检查连接。"),
        "ios.bridge.section.advanced": ("Advanced", "高级"),
        "ios.bridge.section.diagnostics": ("Connection details", "连接详情"),
        "ios.bridge.diag.status": ("Status", "状态"),
        "ios.bridge.diag.protocol": ("Protocol", "协议"),
        "ios.bridge.diag.engine": ("Automation engine", "自动化引擎"),
        "ios.bridge.diag.methods": ("Available commands", "可用命令"),
        "ios.bridge.diag.expires": ("Pairing expires", "配对到期"),
        "ios.bridge.diag.sensitive_input": ("Secure-field input", "安全输入框输入"),
        "ios.bridge.diag.detail": ("Detail", "详情"),
        "ios.bridge.diag.unknown": ("Unknown", "未知"),
        "ios.bridge.diag.not_registered": ("Not registered", "未注册"),
        "ios.bridge.diag.not_ready": ("Not ready", "未就绪"),
        "ios.bridge.diag.ready": ("Ready", "已就绪"),
        "ios.bridge.diag.granted": ("Granted", "已授予"),
        "ios.bridge.diag.not_granted": ("Not granted", "未授予"),
        "ios.bridge.progress.contacting": ("Contacting Bridge…", "正在联系 Bridge…"),
        "ios.bridge.progress.waiting": ("Approve in Bridge", "请在 Bridge 中批准"),
        "ios.bridge.progress.saving": ("Saving pairing…", "正在保存配对…"),
        "ios.bridge.progress.verifying": ("Verifying pairing…", "正在验证配对…"),
        "ios.bridge.progress.paired": ("Paired", "已配对"),
        "ios.bridge.note.local_only": ("This connection stays on this device. It does not control another phone, iPad or Mac.", "此连接仅限本机，不会控制其他手机、iPad 或 Mac。"),
        "ios.bridge.note.permissions": ("Installing the skill does not grant automation permissions. Floe still uses the task's existing authority.", "安装技能不会授予自动化权限；Floe 仍使用任务已有的授权。"),
        "ios.bridge.error.unsupported": ("Local automation is not available on this device.", "此设备不支持本机自动化。"),
        "ios.bridge.error.generic": ("The Bridge operation could not be completed.", "无法完成 Bridge 操作。"),
        "ios.bridge.error.denied": ("Bridge's owner declined the pairing request.", "Bridge 所有者拒绝了配对请求。"),
        "ios.bridge.error.busy": ("Another pairing request is waiting for the owner.", "另一个配对请求正在等待所有者批准。"),
        "ios.bridge.error.cooldown": ("A pairing request was just refused. Try again shortly.", "配对请求刚刚被拒绝，请稍后再试。"),
        "ios.bridge.error.timeout": ("The pairing request timed out. Check Bridge on this device before trying again.", "配对请求超时。请先在此设备上检查 Bridge，然后重试。"),
        "ios.bridge.error.device_busy": ("Finish the current device action before changing the Bridge connection.", "请先结束当前设备操作，再更改 Bridge 连接。"),
        "ios.bridge.error.locked": ("Saved Bridge credentials are locked. Unlock this device and try again.", "已保存的 Bridge 凭据已锁定。请解锁设备后重试。"),
        "ios.bridge.error.verification": ("The pairing could not be saved and read back reliably. Nothing was claimed as paired.", "配对无法可靠保存并读回，未将连接标记为已配对。"),
        "ios.bridge.error.transport": ("Bridge isn't reachable on this device.", "无法连接此设备上的 Bridge。"),
    ]

    static func text(_ key: String) -> String {
        let localized = String(localized: String.LocalizationValue(key))
        if localized != key { return localized }
        guard let pair = fallback[key] else { return key }
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        return chinese ? pair.zh : pair.en
    }

    static func errorText(_ error: IOSBridgeError) -> String {
        switch error {
        case .pairingDenied:
            return text("ios.bridge.error.denied")
        case .pairingBusy:
            return text("ios.bridge.error.busy")
        case .pairingCooldown:
            return text("ios.bridge.error.cooldown")
        case .pairingTimedOut:
            return text("ios.bridge.error.timeout")
        case .deviceBusy:
            return text("ios.bridge.error.device_busy")
        case .credentialStoreLocked, .credentialStoreUnavailable:
            return text("ios.bridge.error.locked")
        case .credentialStoreVerificationFailed:
            return text("ios.bridge.error.verification")
        case .unsupportedPlatform:
            return text("ios.bridge.error.unsupported")
        case .transportUnavailable, .transportNotPermitted, .transportDenied:
            return text("ios.bridge.error.transport")
        case .authorityDenied(let reason):
            return reason.isEmpty ? text("ios.bridge.error.generic") : reason
        default:
            return text("ios.bridge.error.generic")
        }
    }
}
#endif
