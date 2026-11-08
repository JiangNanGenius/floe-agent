#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeExecution

struct NativeExternalOAuthConnectionView: View {
    @Bindable var center: NativeExternalOAuthConnectionCenter
    @ObservedObject private var session: SystemOAuthAuthenticationSession

    init(center: NativeExternalOAuthConnectionCenter) {
        self.center = center; session = center.session
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(NativeExternalOAuthCopy.text("Status", "状态"), value: status)
                if let error = center.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section(NativeExternalOAuthCopy.text("Client profile", "客户端配置")) {
                TextField(NativeExternalOAuthCopy.text("Client ID", "客户端 ID"), text: $center.draft.clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if center.draft.provider == .microsoft {
                    TextField(NativeExternalOAuthCopy.text("Tenant", "租户"), text: $center.draft.tenant)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField(NativeExternalOAuthCopy.text("Client secret (optional)", "客户端密钥（可选）"), text: $center.draft.clientSecret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(NativeExternalOAuthCopy.text("Permissions (scopes)", "权限范围（scopes）"), text: $center.draft.scopes, axis: .vertical)
                    .lineLimit(2...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle(NativeExternalOAuthCopy.text("Keep signed in", "保持登录"), isOn: $center.draft.keepSignedIn)
                DisclosureGroup(NativeExternalOAuthCopy.text("More options", "更多选项")) {
                    Picker(NativeExternalOAuthCopy.text("Sign-in method", "登录方式"), selection: $center.draft.grant) {
                        Text(NativeExternalOAuthCopy.text("Browser sign-in", "浏览器登录")).tag(ExternalOAuthClientProfile.Grant.authorizationCode)
                        Text(NativeExternalOAuthCopy.text("Device code", "设备码")).tag(ExternalOAuthClientProfile.Grant.device)
                    }
                    TextField(NativeExternalOAuthCopy.text("Resources (optional)", "资源（可选）"), text: $center.draft.resources, axis: .vertical)
                        .lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .disabled(center.isBusy || center.isCancelling || center.stopUnconfirmed)
            Section {
                Picker(NativeExternalOAuthCopy.text("Environment", "环境"), selection: $center.draft.environmentID) {
                    Text(NativeExternalOAuthCopy.text("Choose an environment", "选择环境")).tag("")
                    ForEach(center.environments) { choice in Text(choice.title).tag(choice.id) }
                    if !center.draft.environmentID.isEmpty,
                       !center.environments.contains(where: { $0.id == center.draft.environmentID }) {
                        Text(NativeExternalOAuthCopy.text("Saved environment unavailable", "已保存的环境不可用")).tag(center.draft.environmentID)
                    }
                }
                .disabled(center.isBusy || center.isCancelling || center.stopUnconfirmed)
            } footer: {
                Text(NativeExternalOAuthCopy.text("Use your configured client profile. Sign-in opens the system authentication page.", "使用你配置的客户端，登录将在系统认证页中完成。"))
            }
            Section {
                if session.state == .waitingForCodeCopy, let code = session.userCode {
                    LabeledContent(NativeExternalOAuthCopy.text("Verification code", "验证码"), value: code)
                        .textSelection(.enabled)
                    Button(NativeExternalOAuthCopy.text("Copy code and continue", "复制验证码并继续")) { session.copyDeviceCodeAndContinue() }
                }
                Button(center.saved == nil ? NativeExternalOAuthCopy.text("Connect", "连接") : NativeExternalOAuthCopy.text("Reconnect", "重新连接")) {
                    center.connect()
                }.disabled(!center.canConnect)
                if center.saved != nil {
                    Button(NativeExternalOAuthCopy.text("Refresh connection", "刷新连接")) { center.refresh() }
                        .disabled(!center.canRefresh)
                    Button(NativeExternalOAuthCopy.text("Disconnect", "断开连接"), role: .destructive) { center.disconnect() }
                        .disabled(center.isBusy || center.isCancelling)
                }
                if center.isBusy || center.isCancelling || center.stopUnconfirmed {
                    Button(NativeExternalOAuthCopy.text("Cancel", "取消"), role: .cancel) {
                        center.requestCancel()
                    }
                    .disabled(center.isCancelling)
                }
            }
        }
        .navigationTitle(center.draft.provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(NativeOAuthWindowReader { [weak center] window in center?.setAnchor(window) }.frame(width: 0, height: 0))
        .task { await center.reload() }
        .onDisappear { center.requestCancel() }
    }

    private var status: String {
        if center.stopUnconfirmed || center.isCancelling { return NativeExternalOAuthCopy.text("Stopping", "正在停止") }
        if center.isBusy {
            return center.isRefreshing ? NativeExternalOAuthCopy.text("Refreshing", "正在刷新")
                : NativeExternalOAuthCopy.text("Connecting", "正在连接")
        }
        guard let saved = center.saved else { return NativeExternalOAuthCopy.text("Not connected", "未连接") }
        return saved.status == .available ? NativeExternalOAuthCopy.text("Connected", "已连接")
            : NativeExternalOAuthCopy.text("Refresh needed", "需要刷新")
    }
}

private struct NativeOAuthWindowReader: UIViewRepresentable {
    let update: @MainActor (UIWindow?) -> Void
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.update = update; return view }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.update = update }
    final class Probe: UIView {
        var update: (@MainActor (UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let value = window
            Task { @MainActor [weak self] in self?.update?(value) }
        }
    }
}
#endif
