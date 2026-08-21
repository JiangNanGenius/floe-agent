// FloeApp — Privacy & security settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 8: Keychain state (real probe),
// API-key sync explanation, destructive clear operations (double-confirmed
// in-sheet, ClearReport count echo), and the redacted diagnostics export.
// No secret value is ever displayed — only "configured / not configured".

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LocalAuthentication
import FloeCore

struct PrivacySecurityView: View {
    @ObservedObject var center: SettingsCenter
    @AppStorage(DeviceOwnerAuthenticator.preferBiometricsKey)
    private var preferBiometrics = true

    @State private var confirmClearHistory = false
    @State private var confirmClearModels = false
    @State private var clearReport: ClearReport?
    @State private var isWorking = false
    @State private var exportURL: IdentifiableURL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("优先使用 Face ID / Touch ID", isOn: $preferBiometrics)
            } header: {
                Text("身份验证")
            } footer: {
                Text("开启时优先显示生物识别；设备不支持或关闭后才使用设备密码。")
            }

            Section {
                LabeledContent("settings.privacy.keychain.state") {
                    capabilityText(center.keychainState)
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                let configured = center.credentialStatus.values.filter { $0 }.count
                LabeledContent("settings.privacy.apikeys") {
                    Text("settings.privacy.apikeys.count \(configured)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.privacy.keychain")
            } footer: {
                Text("settings.privacy.keychain.footer")
            }

            Section {
                destructiveButton(
                    title: String(localized: "settings.privacy.clear_history"),
                    confirming: $confirmClearHistory
                )
                destructiveButton(
                    title: String(localized: "settings.privacy.clear_models"),
                    confirming: $confirmClearModels
                )
                if let clearReport {
                    Text(reportText(clearReport))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.privacy.data")
            } footer: {
                Text("settings.privacy.clear.footer")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    Label("settings.privacy.export", systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .disabled(isWorking)
            } header: {
                Text("settings.privacy.diagnostics")
            } footer: {
                Text("settings.privacy.export.footer")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(FloeTheme.destructive)
                }
            }
        }
        .navigationTitle("settings.section.privacy")
        .task { await center.load() }
        .confirmationDialog(
            "settings.privacy.clear_history",
            isPresented: $confirmClearHistory,
            titleVisibility: .visible
        ) {
            Button("settings.privacy.clear_history.confirm", role: .destructive) {
                Task { await runClear(history: true) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("settings.privacy.clear_history.message")
        }
        .confirmationDialog(
            "settings.privacy.clear_models",
            isPresented: $confirmClearModels,
            titleVisibility: .visible
        ) {
            Button("settings.privacy.clear_models.confirm", role: .destructive) {
                Task { await runClear(history: false) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("settings.privacy.clear_models.message")
        }
        .sheet(item: $exportURL) { wrapper in
            SettingsShareSheet(items: [wrapper.url])
        }
    }

    // MARK: - Subviews

    private func destructiveButton(title: String, confirming: Binding<Bool>) -> some View {
        Button(role: .destructive) {
            confirming.wrappedValue = true
        } label: {
            Text(title)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .disabled(isWorking)
    }

    @ViewBuilder
    private func capabilityText(_ state: CapabilityState) -> some View {
        switch state {
        case .available(let version):
            Text(version).foregroundStyle(FloeTheme.success)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .unknown:
            Text("settings.capability.unknown").foregroundStyle(FloeTheme.unknown)
        }
    }

    // MARK: - Actions

    private func runClear(history: Bool) async {
        isWorking = true
        defer { isWorking = false }
        clearReport = nil
        errorMessage = nil
        do {
            clearReport = history
                ? try await center.actions.clearLocalHistory()
                : try await center.actions.clearModelConfiguration()
            await center.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            exportURL = IdentifiableURL(url: try await center.exportDiagnostics())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reportText(_ report: ClearReport) -> String {
        var parts: [String] = []
        if report.deletedConversations > 0 {
            parts.append(String(localized: "settings.privacy.report.conversations \(report.deletedConversations)"))
        }
        if report.deletedRuns > 0 {
            parts.append(String(localized: "settings.privacy.report.runs \(report.deletedRuns)"))
        }
        if report.deletedGrants > 0 {
            parts.append(String(localized: "settings.privacy.report.grants \(report.deletedGrants)"))
        }
        if report.deletedKeychainItems > 0 {
            parts.append(String(localized: "settings.privacy.report.keychain \(report.deletedKeychainItems)"))
        }
        return parts.isEmpty
            ? String(localized: "settings.privacy.report.empty")
            : parts.joined(separator: " · ")
    }
}

/// One authentication policy for every sensitive Floe surface. Using
/// `.deviceOwnerAuthentication` directly lets iOS choose the passcode sheet
/// even when Face ID is available, which made otherwise identical actions
/// behave inconsistently across settings screens.
enum DeviceOwnerAuthenticator {
    static let preferBiometricsKey = "floe.security.preferBiometrics"

    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "action.cancel")
        let preferBiometrics = UserDefaults.standard.object(forKey: preferBiometricsKey)
            .map { ($0 as? Bool) ?? true } ?? true
        var evaluationError: NSError?
        if preferBiometrics,
           context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        }
        evaluationError = nil
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            throw evaluationError ?? NSError(
                domain: LAError.errorDomain,
                code: LAError.authenticationFailed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "设备未设置可用的身份验证。"]
            )
        }
        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}

/// URL wrapper for sheet presentation (mirrors the pattern in
/// Files/ImageEditorView without extending URL globally).
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Minimal UIActivityViewController wrapper for the diagnostics export.
/// Named distinctly from the private ShareSheet in Files/ImageEditorView.
private struct SettingsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
