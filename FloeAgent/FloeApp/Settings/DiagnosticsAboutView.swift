// FloeApp — Diagnostics & about settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 9: app version/build, database
// schema version, capability summary (providers / models / catalog tools),
// the in-memory log ring buffer (redacted on write), redacted diagnostics
// export, and the third-party license / privacy notes.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct DiagnosticsAboutView: View {
    @ObservedObject var center: SettingsCenter
    @State private var logText: String = ""
    @State private var exportURL: IdentifiableDiagnosticsURL?
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("settings.diagnostics.about") {
                LabeledContent("settings.diagnostics.version") {
                    Text(appVersion).foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                LabeledContent("settings.diagnostics.build") {
                    Text(appBuild).foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                LabeledContent("settings.diagnostics.db_version") {
                    Text("\(center.databaseUserVersion)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section("settings.diagnostics.capabilities") {
                LabeledContent("settings.diagnostics.providers") {
                    Text("\(center.capabilitySummary.providerCount)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                LabeledContent("settings.diagnostics.models") {
                    Text("\(center.capabilitySummary.modelCount)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                LabeledContent("settings.diagnostics.tools") {
                    Text("\(center.capabilitySummary.toolCount)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                if !center.capabilitySummary.adapterKinds.isEmpty {
                    LabeledContent("settings.diagnostics.adapters") {
                        Text(center.capabilitySummary.adapterKinds.joined(separator: ", "))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            }

            Section {
                if logText.isEmpty {
                    Text("settings.diagnostics.logs.empty")
                        .foregroundStyle(.secondary)
                } else {
                    Text(logText)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                        .lineLimit(20)
                }
            } header: {
                Text("settings.diagnostics.logs")
            } footer: {
                Text("settings.diagnostics.logs.footer")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Label("settings.privacy.export", systemImage: "square.and.arrow.up")
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .disabled(isExporting)
            } header: {
                Text("settings.privacy.diagnostics")
            } footer: {
                Text("settings.privacy.export.footer")
            }

            Section("settings.diagnostics.legal") {
                Link(destination: licenseURL) {
                    Label("settings.diagnostics.licenses", systemImage: "doc.text")
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                Label("settings.diagnostics.privacy.note", systemImage: "hand.raised")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(FloeTheme.destructive)
                }
            }
        }
        .navigationTitle("settings.section.diagnostics")
        .task {
            await center.load()
            logText = FloeLogger.buffer.renderedText()
        }
        .sheet(item: $exportURL) { wrapper in
            DiagnosticsShareSheet(items: [wrapper.url])
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? String(localized: "settings.diagnostics.unknown")
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? String(localized: "settings.diagnostics.unknown")
    }

    /// The third-party license document shipped in the repository. Linked
    /// rather than embedded so the file stays the single source of truth.
    private var licenseURL: URL {
        // Bundle resource when packaged; repository path during development.
        if let bundled = Bundle.main.url(forResource: "LICENSES-THIRD-PARTY", withExtension: "md") {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings/
            .deletingLastPathComponent() // FloeApp/
            .deletingLastPathComponent() // FloeAgent/
            .appendingPathComponent("LICENSES-THIRD-PARTY.md")
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        errorMessage = nil
        do {
            let url = try await DiagnosticsExporter.export(center: center)
            exportURL = IdentifiableDiagnosticsURL(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// URL wrapper for sheet presentation (same pattern as PrivacySecurityView).
private struct IdentifiableDiagnosticsURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Share sheet for the diagnostics export.
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
