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
            if let errorMessage {
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
                    Button("portforward.add") { submit() }
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
                try await center.addRule(
                    environmentID: environmentID,
                    guestPort: guestPort,
                    requestedHostPort: hostPort,
                    label: label.isEmpty
                        ? String.localizedStringWithFormat(
                            String(localized: "portforward.port"), Int64(guestPort)
                        )
                        : label
                )
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
