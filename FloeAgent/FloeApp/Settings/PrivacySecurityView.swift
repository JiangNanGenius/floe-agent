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
import FloeCore

struct PrivacySecurityView: View {
    @ObservedObject var center: SettingsCenter

    @State private var confirmClearHistory = false
    @State private var confirmClearModels = false
    @State private var clearReport: ClearReport?
    @State private var isWorking = false
    @State private var exportURL: IdentifiableURL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("settings.privacy.keychain") {
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
            } footer: {
                Text("settings.privacy.keychain.footer")
            }

            Section("settings.privacy.data") {
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
            exportURL = IdentifiableURL(url: try center.exportDiagnostics())
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
