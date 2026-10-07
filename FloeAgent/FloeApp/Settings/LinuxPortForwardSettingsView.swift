// FloeApp — Linux TCP port-forward settings (Build 222).
//
// Lists the persisted per-environment rules, the port each plan really binds
// (or will bind), a copyable LAN URL and a QR code rendered from exactly that
// URL. Adding a rule asks for the guest port and either a fixed host port in
// 49152–65535 or dynamic allocation. Conflicts are shown, never hidden.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FloeCore
import FloeExecution

struct LinuxPortForwardSection: View {
    let environmentID: String
    let environmentTitle: String
    let guestRunning: Bool

    @ObservedObject private var center = LinuxPortForwardCenter.shared
    @State private var showingAdd = false
    @State private var editingID: UUID?
    @State private var localOnly = true
    @State private var previewURL: URL?
    @State private var newLabel = ""
    @State private var newGuestPort = "8080"
    @State private var newHostPort = ""
    @State private var errorMessage: String?
    @State private var copiedRuleID: UUID?
    @State private var expandedRuleID: UUID?

    var body: some View {
        Section {
            Text(String.localizedStringWithFormat(
                String(localized: "portforward.footer"),
                Int64(LinuxPortForwardLimits.maximumRulesPerEnvironment),
                LinuxPortForwardLimits.defaultBindAddress
            ))
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(center.rules(environmentID: environmentID)) { rule in
                ruleRow(rule)
            }

            Button {
                editingID = nil
                localOnly = true
                newLabel = ""
                newGuestPort = "8080"
                newHostPort = ""
                showingAdd = true
            } label: {
                Label("portforward.add_rule", systemImage: "plus.circle")
            }
            .frame(minHeight: FloeTheme.minimumTarget)

            if let planConflict = center.lastConflictNotice {
                Label(planConflict, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.pending)
                    .textSelection(.enabled)
            }
            if let errorMessage = errorMessage ?? center.errorsByEnvironment[environmentID] {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .textSelection(.enabled)
            }
            Text(center.addressSummary(environmentID: environmentID))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("portforward.title")
        }
        .sheet(isPresented: $showingAdd) { addSheet }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL { PortForwardPreview(url: previewURL) }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: LinuxPortForwardRule) -> some View {
        let preview = center.preview(environmentID: environmentID, ruleID: rule.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rule.label.isEmpty
                     ? String.localizedStringWithFormat(String(localized: "portforward.port"), Int64(rule.guestPort))
                     : rule.label)
                    .font(.body)
                Spacer()
                Text(rule.bindAddress == "127.0.0.1" ? IDELanguageRunText.t("仅本机", "This device") : IDELanguageRunText.t("局域网", "LAN"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(rule.isDynamic ? "portforward.dynamic" : "portforward.fixed")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(String.localizedStringWithFormat(
                    String(localized: "portforward.guest_port"), Int64(rule.guestPort)
                ))
                Text("→")
                Text(String.localizedStringWithFormat(
                    String(localized: "portforward.host_port"),
                    preview.map { String($0.plan.hostPort) } ?? rule.requestedHostPortText
                ))
                if preview?.isApplied == true {
                    Label("portforward.applied", systemImage: "checkmark.circle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                } else {
                    Text("portforward.pending")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            .font(FloeTheme.Typography.metadata)

            if let preview {
                if let url = preview.lanURL ?? preview.loopbackURL {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if preview.isApplied, let local = preview.loopbackURL {
                            Button(IDELanguageRunText.t("预览", "Preview"), systemImage: "safari") { previewURL = local }
                                .buttonStyle(.borderless).frame(minHeight: 44)
                        }
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            copiedRuleID = rule.id
                        } label: {
                            Label(copiedRuleID == rule.id ? "portforward.copied" : "portforward.copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                    if preview.lanURL == nil {
                        Text("portforward.loopback_hint")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("portforward.no_local_address")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let payload = preview.qrPayload {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedRuleID == rule.id },
                            set: { expandedRuleID = $0 ? rule.id : nil }
                        )
                    ) {
                        if let image = PortForwardQRCode.image(for: payload) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 160, maxHeight: 160)
                                .accessibilityLabel(Text("portforward.qr_label"))
                        }
                        Text("portforward.qr_hint")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("portforward.show_qr")
                            .font(FloeTheme.Typography.metadata)
                    }
                }
                if preview.wasRemapped, let requested = rule.requestedHostPort {
                    Text(String.localizedStringWithFormat(
                        String(localized: "portforward.remapped"),
                        Int64(requested),
                        Int64(preview.plan.hostPort)
                    ))
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.pending)
                }
            }

            HStack {
                Toggle("portforward.enable", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { enabled in
                        Task {
                            do {
                                try await center.setEnabled(
                                    environmentID: environmentID,
                                    ruleID: rule.id,
                                    isEnabled: enabled
                                )
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)
                Spacer()
                Button(IDELanguageRunText.t("编辑", "Edit"), systemImage: "pencil") {
                    editingID = rule.id
                    newLabel = rule.label
                    newGuestPort = String(rule.guestPort)
                    newHostPort = rule.requestedHostPort.map(String.init) ?? ""
                    localOnly = rule.bindAddress == "127.0.0.1"
                    showingAdd = true
                }.buttonStyle(.borderless).frame(minHeight: 44)
                Button(role: .destructive) {
                    Task { await center.removeRule(environmentID: environmentID, ruleID: rule.id) }
                } label: {
                    Label("portforward.delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: FloeTheme.minimumTarget)
            }
        }
        .padding(.vertical, 2)
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(IDELanguageRunText.t("仅允许本机访问", "Allow this device only"), isOn: $localOnly)
                    TextField("portforward.name_optional", text: $newLabel)
                    TextField("portforward.guest_port_field", text: $newGuestPort)
                        .keyboardType(.numberPad)
                    TextField("portforward.host_port_field", text: $newHostPort)
                        .keyboardType(.numberPad)
                    Text(String.localizedStringWithFormat(
                        String(localized: "portforward.host_port_hint"),
                        Int64(LinuxPortForwardLimits.minimumHostPort),
                        Int64(LinuxPortForwardLimits.maximumHostPort)
                    ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("portforward.new_rule")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
            .navigationTitle("portforward.add_title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { showingAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("保存", "Save")) { submit() }
                }
            }
        }
    }

    private func submit() {
        errorMessage = nil
        guard let guestPort = Int(newGuestPort.trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(guestPort) else {
            errorMessage = String(localized: "portforward.guest_invalid")
            return
        }
        let trimmedHost = newHostPort.trimmingCharacters(in: .whitespaces)
        let hostPort: Int?
        if trimmedHost.isEmpty {
            hostPort = nil
        } else if let parsed = Int(trimmedHost),
                  LinuxPortForwardLimits.isAllowedHostPort(parsed) {
            hostPort = parsed
        } else {
            errorMessage = String.localizedStringWithFormat(
                String(localized: "portforward.host_invalid"),
                Int64(LinuxPortForwardLimits.minimumHostPort),
                Int64(LinuxPortForwardLimits.maximumHostPort)
            )
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        showingAdd = false
        Task {
            do {
                let title = label.isEmpty ? "TCP \(guestPort)" : label
                let address = localOnly ? "127.0.0.1" : "0.0.0.0"
                if let editingID {
                    try await center.updateRule(environmentID: environmentID, ruleID: editingID,
                        guestPort: guestPort, requestedHostPort: hostPort, label: title, bindAddress: address)
                } else {
                    try await center.addRule(environmentID: environmentID, guestPort: guestPort,
                        requestedHostPort: hostPort, label: title, bindAddress: address)
                }
            } catch {
                errorMessage = error.localizedDescription
                if !guestRunning {
                    // Rules apply when the VM runs; the persistence still
                    // succeeded, so only a real validation error is shown.
                }
            }
        }
    }
}

/// Every entry uses the same center and section. With no explicit environment,
/// require the user to select one instead of silently targeting the first VM.
struct LinuxPortManagementView: View {
    var environmentID: String? = nil
    @State private var choices: [(id: String, title: String, running: Bool)] = []
    @State private var selected: String?
    @State private var error: String?
    var body: some View {
        Form {
            if environmentID == nil {
                Picker(IDELanguageRunText.t("环境", "Environment"), selection: $selected) {
                    Text(IDELanguageRunText.t("选择环境", "Choose environment")).tag(String?.none)
                    ForEach(choices, id: \.id) { item in Text(item.title).tag(Optional(item.id)) }
                }
            }
            if let id = environmentID ?? selected {
                LinuxPortForwardSection(environmentID: id,
                    environmentTitle: choices.first(where: { $0.id == id })?.title ?? id,
                    guestRunning: choices.first(where: { $0.id == id })?.running == true)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("portforward.title")
        .task {
            do {
                let reports = try await FloePlatformServices.shared.environmentReports()
                for report in reports where report.record.effectiveExecutionBackend == .linuxVM && report.record.state != .deleting {
                    let status = await FloePlatformServices.shared.linuxGuestStatus(id: report.id)
                    choices.append((report.id, report.record.name ?? report.id, status?.running == true))
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PortForwardPreview: View {
    let url: URL
    @StateObject private var center = BrowserSessionCenter(durableHandoffs: false)
    @State private var owner = UUID()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BrowserView(center: center)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action.close") { dismiss() } } }
        }.task {
            BrowserURLPolicy.authorizeService(url, owner: owner, conversationID: owner)
            center.bind(to: owner); center.addressText = url.absoluteString; center.navigateFromAddressBar()
        }.onDisappear { BrowserURLPolicy.revokeService(owner: owner) }
    }
}

enum PortForwardQRCode {
    /// QR for the exact URL string. Returns nil when rendering is impossible
    /// rather than showing a placeholder that scans to nothing.
    static func image(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
