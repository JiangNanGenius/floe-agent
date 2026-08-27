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
import UIKit
import FloeCore

struct DiagnosticsAboutView: View {
    @ObservedObject var center: SettingsCenter
    @State private var logText: String = ""
    @State private var exportURL: IdentifiableDiagnosticsURL?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var presentsFeedback = false
    @AppStorage("diagnostics.includeDeviceInfo") private var includeDeviceInfo = false
    @State private var presentsFullLog = false

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
                Link(destination: projectURL) {
                    Label("settings.diagnostics.github_project", systemImage: "arrow.up.right.square")
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                LabeledContent("settings.diagnostics.db_version") {
                    Text("\(center.databaseUserVersion)")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                if includeDeviceInfo {
                    LabeledContent("settings.diagnostics.device") {
                        Text(deviceInfo).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
                Toggle("settings.diagnostics.include_device_info", isOn: $includeDeviceInfo)
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
                HStack {
                    Button {
                        logText = FloeLogger.buffer.renderedText()
                    } label: {
                        Label("settings.diagnostics.logs", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = logText
                    } label: {
                        Label("action.copy", systemImage: "doc.on.doc")
                    }
                    .disabled(logText.isEmpty)
                    Button {
                        presentsFullLog = true
                    } label: {
                        Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(logText.isEmpty)
                }
            } header: {
                Text("settings.diagnostics.logs")
            } footer: {
                Text("settings.diagnostics.logs.footer")
            }

            Section {
                Button {
                    presentsFeedback = true
                } label: {
                    Label("feedback.open", systemImage: "ladybug")
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("diagnostics.feedback")

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
                Text("feedback.entry.footer")
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
        .sheet(isPresented: $presentsFeedback) {
            NavigationStack {
                FeedbackReportView(center: center)
            }
            .presentationSizing(.page)
        }
        .fullScreenCover(isPresented: $presentsFullLog) {
            NavigationStack {
                DiagnosticLogTextView(text: logText)
                    .ignoresSafeArea(edges: .bottom)
                .navigationTitle("诊断日志")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { presentsFullLog = false }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            logText = FloeLogger.buffer.renderedText()
                        }
                        Button("复制", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = logText
                        }
                    }
                }
            }
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

    private var projectURL: URL {
        URL(string: "https://github.com/JiangNanGenius/floe-agent")!
    }

    /// Device info for diagnostics (optional, off by default).
    private var deviceInfo: String {
        let device = UIDevice.current
        return "\(device.model) (\(device.systemName) \(device.systemVersion))"
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

/// UIKit's text system virtualizes very large logs and always wraps them to
/// the available width. A two-axis SwiftUI ScrollView around one huge Text can
/// resolve to an unbounded size and render an entirely blank page on iPad.
private struct DiagnosticLogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = false
        view.textContainer.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.accessibilityIdentifier = "diagnostics.full_log"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let offset = view.contentOffset
        view.text = text
        view.setContentOffset(offset, animated: false)
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
