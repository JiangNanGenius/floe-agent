// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import FloeMacNetwork
import FloeToolboxCore

/// Each run is started by the person using this window. It owns no Agent task
/// and cannot grant an Agent or a background caller access to the network.
struct MacNetworkToolView: View {
    let tool: ToolboxTool
    let owner: MacManualNetworkOwner
    @Environment(\.locale) private var locale
    @State private var target = ""
    @State private var dnsType: MacManualDNSRecordType = .a
    @State private var ports = "80,443"
    @State private var inputError = false
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tool.title(in: locale)).font(.title2.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
            if needsHost {
                TextField(MacToolboxText.t("主机名或 IP 地址", "Host name or IP address", locale), text: $target)
                    .textFieldStyle(.roundedBorder)
                    .disabled(owner.running)
            }
            if tool == .port {
                TextField(MacToolboxText.t("端口，用逗号分隔", "Ports, separated by commas", locale), text: $ports)
                    .textFieldStyle(.roundedBorder).disabled(owner.running)
            }
            if tool == .dns {
                Picker(MacToolboxText.t("记录类型", "Record type", locale), selection: $dnsType) {
                    ForEach(MacManualDNSRecordType.allCases, id: \.rawValue) { type in
                        Text(String(describing: type).uppercased()).tag(type)
                    }
                }
                .disabled(owner.running)
            }
            HStack {
                Button(MacToolboxText.t("开始", "Start", locale)) { start() }
                    .buttonStyle(.borderedProminent).disabled(owner.running)
                if owner.running {
                    ProgressView().controlSize(.small)
                    Button(MacToolboxText.t("停止", "Stop", locale)) { owner.cancel() }
                }
            }
            if inputError {
                Text(MacToolboxText.t("请检查主机名或端口。端口须为 1 至 65535，最多 64 个，且不能重复。",
                                     "Check the host or ports. Use up to 64 distinct ports from 1 to 65535.", locale))
                    .foregroundStyle(.red)
            }
            if didStart, owner.failure {
                Text(MacToolboxText.t("未能完成。请检查目标、网络连接及系统权限后重试。",
                                     "Could not complete. Check the target, network and system permissions, then try again.", locale))
                    .foregroundStyle(.orange)
            }
            if didStart, let output = owner.result {
                ScrollView {
                    Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NetworkWindowCloseObserver { owner.cancel() }.frame(width: 0, height: 0))
        .onDisappear { owner.cancel() }
    }

    private var description: String {
        switch tool {
        case .ping, .traceroute:
            MacToolboxText.t("使用 IPv4；超时不一定表示目标离线。", "Uses IPv4. A timeout does not necessarily mean the host is offline.", locale)
        case .dns:
            dnsType == .ptr
                ? MacToolboxText.t("请输入 in-addr.arpa 或 ip6.arpa 反向域名。", "Enter an in-addr.arpa or ip6.arpa reverse name.", locale)
                : MacToolboxText.t("查询当前 DNS 服务器。", "Query the configured DNS servers.", locale)
        case .port:
            MacToolboxText.t("只检查你填写的 TCP 端口。", "Check only the TCP ports you enter.", locale)
        case .lan:
            MacToolboxText.t("查找本地网络中广播的服务。系统可能要求本地网络权限。", "Find services advertised on the local network. macOS may request local network access.", locale)
        case .roaming:
            MacToolboxText.t("约 10 秒内观察当前 Wi-Fi 接入点和信号。接入点信息可能需要定位权限。",
                             "Observe the current Wi-Fi access point and signal for about 10 seconds. Access point details may require Location Services permission.", locale)
        default:
            MacToolboxText.t("读取当前 Wi-Fi 状态。网络名称可能需要系统定位权限。", "Read current Wi-Fi status. Network names may require Location Services permission.", locale)
        }
    }

    private var needsHost: Bool { tool != .lan && tool != .wifi && tool != .roaming }

    private func start() {
        inputError = false
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: MacManualNetworkRequest
        switch tool {
        case .ping: request = .ping(host)
        case .traceroute: request = .traceroute(host)
        case .dns: request = .dns(host, dnsType)
        case .port:
            let parts = ports.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard values.count == parts.count, !values.isEmpty, values.count <= 64,
                  !values.contains(0), Set(values).count == values.count else { inputError = true; return }
            request = .ports(host, values)
        case .lan: request = .lan
        case .roaming: request = .roaming
        default: request = .wifi
        }
        guard !needsHost || !host.isEmpty else { inputError = true; return }
        didStart = owner.start(request, locale: locale)
    }
}

private struct NetworkWindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(onClose: onClose) }
    func updateNSView(_ view: TrackingView, context: Context) { view.onClose = onClose }

    final class TrackingView: NSView {
        var onClose: @MainActor () -> Void
        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(closed),
                name: NSWindow.willCloseNotification, object: window)
        }
        @objc private func closed() { onClose() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
