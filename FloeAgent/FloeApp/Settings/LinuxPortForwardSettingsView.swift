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
        Section("TCP 端口转发") {
            Text("每条规则把客户机的一个 TCP 端口发布到本机；主机端口可固定或动态分配（49152–65535），每台 VM 最多 \(LinuxPortForwardLimits.maximumRulesPerEnvironment) 条。默认绑定 \(LinuxPortForwardLimits.defaultBindAddress)（局域网可访问）。应用不会做 UPnP/NAT 映射，也不会展示公网地址。")
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
                Label("添加端口转发规则", systemImage: "plus.circle")
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
        }
        .sheet(isPresented: $showingAdd) { addSheet }
    }

    @ViewBuilder
    private func ruleRow(_ rule: LinuxPortForwardRule) -> some View {
        let preview = center.preview(environmentID: environmentID, ruleID: rule.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rule.label.isEmpty ? "端口 \(rule.guestPort)" : rule.label)
                    .font(.body)
                Spacer()
                Text(rule.isDynamic ? "动态" : "固定")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("客户机 \(rule.guestPort)")
                Text("→")
                Text("主机 \(preview.map { String($0.plan.hostPort) } ?? rule.requestedHostPortText)")
                if preview?.isApplied == true {
                    Label("已生效", systemImage: "checkmark.circle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                } else {
                    Text("待应用")
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
                            Label(copiedRuleID == rule.id ? "已复制" : "复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                    if preview.lanURL == nil {
                        Text("尚未检测到本机局域网地址；显示的是仅本机可用的回环地址。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("当前没有可用的本地地址")
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
                                .accessibilityLabel("端口转发地址二维码")
                        }
                        Text("二维码内容为该地址本身，不包含任何公网映射。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("显示二维码")
                            .font(FloeTheme.Typography.metadata)
                    }
                }
                if preview.wasRemapped, let requested = rule.requestedHostPort {
                    Text("固定端口 \(requested) 已被占用，已改用 \(preview.plan.hostPort)。")
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.pending)
                }
            }

            HStack {
                Toggle("启用", isOn: Binding(
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
                    Label("删除", systemImage: "trash")
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
                Section("新规则") {
                    TextField("名称（可选）", text: $newLabel)
                    TextField("客户机端口", text: $newGuestPort)
                        .keyboardType(.numberPad)
                    TextField("固定主机端口（留空为动态分配）", text: $newHostPort)
                        .keyboardType(.numberPad)
                    Text("主机端口必须在 \(LinuxPortForwardLimits.minimumHostPort)–\(LinuxPortForwardLimits.maximumHostPort) 之间；留空时自动从该范围分配最小空闲端口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
            .navigationTitle("添加端口转发")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { submit() }
                }
            }
        }
    }

    private func submit() {
        errorMessage = nil
        guard let guestPort = Int(newGuestPort.trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(guestPort) else {
            errorMessage = "客户机端口必须是 1–65535 的整数。"
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
            errorMessage = "固定主机端口必须在 \(LinuxPortForwardLimits.minimumHostPort)–\(LinuxPortForwardLimits.maximumHostPort) 之间，或留空使用动态分配。"
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
                    label: label.isEmpty ? "端口 \(guestPort)" : label
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
