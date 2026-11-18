// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxUI
import FloeToolboxWorkbenches
import FloeMacNetwork

/// Manual communication workbench: the person using this window picks an
/// exact target, admits one session, and disconnects explicitly. It owns no
/// Agent task and cannot grant an Agent or background caller network access.
struct MacCommunicationToolView: View {
    let tool: ToolboxTool
    let owner: MacCommunicationOwner
    @Environment(\.locale) private var locale
    @State private var address = ""
    @State private var port = ""
    @State private var useTLS = false
    @State private var mqttVersion = MQTTVersion.v5
    @State private var username = ""
    @State private var password = ""
    @State private var serial = SerialAssistantConfiguration()
    @State private var usbPorts: [MacUSBSerialPortDescriptor] = []
    @State private var usbPortPath = ""
    @State private var usbBaud: UInt32 = 115200
    @State private var usbDataBits: UInt8 = 8
    @State private var usbStopBits: UInt8 = 1
    @State private var usbParity = USBSerialSettings.Parity.none
    @State private var attempted = false

    var body: some View {
        Group {
            if let session = owner.session, session.tool == tool {
                connectedView(session)
            } else {
                setupForm
            }
        }
        .background(MacToolboxWindowCloseObserver { owner.cancel() }.frame(width: 0, height: 0))
        .id(tool.rawValue)
        .onAppear {
            if tool == .serialAssistant, usbPorts.isEmpty { refreshUSBPorts() }
        }
    }

    // MARK: - Connected

    private func connectedView(_ session: MacCommunicationSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // HTTP is request-oriented: an admitted target is ready,
                    // not "connected", until a response actually arrives.
                    Label(tool == .http
                          ? MacToolboxText.t("已就绪", "Ready", locale)
                          : MacToolboxText.t("已连接", "Connected", locale),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("mac.toolbox.communication.status")
                    Text(session.endpointSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(MacToolboxText.t("断开", "Disconnect", locale), systemImage: "xmark.circle") { owner.cancel() }
                    .accessibilityIdentifier("mac.toolbox.communication.disconnect")
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            workbench(session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func workbench(_ session: MacCommunicationSession) -> some View {
        switch tool {
        case .http:
            if let model = session.httpModel {
                HTTPWorkbenchView(model: model, onSave: revealSaved, onExport: exportCapture)
            }
        case .webSocket:
            if let model = session.webSocketModel {
                WebSocketWorkbenchView(model: model, onSave: revealSaved, onExport: exportCapture)
            }
        case .mqtt:
            if let model = session.mqttModel {
                MQTTWorkbenchView(model: model, onSave: revealSaved, onExport: exportCapture)
            }
        case .serialAssistant:
            if let model = session.serialModel {
                SerialClientPanel(model: model, onSaved: revealSaved, onExport: exportCapture)
            } else if let model = session.modbusModel {
                ModbusWorkbenchView(model: model, onSave: revealSaved, onExport: exportCapture)
            }
        default:
            ContentUnavailableView(MacToolboxText.t("暂不可用", "Not available yet", locale),
                                   systemImage: "network.slash")
        }
    }

    // MARK: - Setup

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tool.title(in: locale)).font(.title2.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
            switch tool {
            case .http, .webSocket:
                TextField(tool == .http ? "https://" : "ws://", text: $address)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .disabled(owner.connecting)
                    .accessibilityIdentifier("mac.toolbox.communication.address")
            case .mqtt:
                TextField(MacToolboxText.t("主机名或 IP 地址", "Host name or IP address", locale), text: $address)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .disabled(owner.connecting)
                    .accessibilityIdentifier("mac.toolbox.communication.address")
                TextField(MacToolboxText.t("端口", "Port", locale), text: $port)
                    .textFieldStyle(.roundedBorder)
                    .disabled(owner.connecting)
                    .accessibilityIdentifier("mac.toolbox.communication.port")
                Picker(MacToolboxText.t("版本", "Version", locale), selection: $mqttVersion) {
                    Text("MQTT 5").tag(MQTTVersion.v5); Text("MQTT 3.1.1").tag(MQTTVersion.v311)
                }
                .disabled(owner.connecting)
                Toggle("TLS", isOn: $useTLS).disabled(owner.connecting)
                TextField(MacToolboxText.t("用户名（可选）", "Username (optional)", locale), text: $username)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .disabled(owner.connecting)
                SecureField(MacToolboxText.t("密码（可选）", "Password (optional)", locale), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(owner.connecting)
            case .serialAssistant:
                serialSetupForm
            default:
                EmptyView()
            }
            issuesView
            HStack {
                Button(MacToolboxText.t("连接", "Connect", locale)) { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(owner.connecting || owner.closing || owner.session != nil)
                    .accessibilityIdentifier("mac.toolbox.communication.connect")
                if owner.connecting {
                    ProgressView().controlSize(.small)
                    Button(MacToolboxText.t("取消", "Cancel", locale)) { owner.cancel() }
                        .accessibilityIdentifier("mac.toolbox.communication.cancelConnect")
                }
            }
            if owner.closing {
                Label(MacToolboxText.t("正在停止当前会话…", "Stopping the current session…", locale),
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac.toolbox.communication.closing")
            }
            if owner.session != nil {
                Label(MacToolboxText.t("另一个通信工具仍在连接。请先断开再连接此工具。",
                                       "Another communication tool is still connected. Disconnect it before connecting this one.", locale),
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let failure = owner.failure {
                Text(failure).foregroundStyle(.orange)
                    .accessibilityIdentifier("mac.toolbox.communication.error")
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var serialSetupForm: some View {
        Picker(MacToolboxText.t("连接方式", "Connection", locale), selection: $serial.connection) {
            Text("TCP").tag(SerialAssistantConnection.tcp)
            Text("UDP").tag(SerialAssistantConnection.udp)
            Text(MacToolboxText.t("USB 串口", "USB serial", locale)).tag(SerialAssistantConnection.usb)
        }.pickerStyle(.segmented).disabled(owner.connecting)
            .accessibilityIdentifier("mac.toolbox.communication.serialTransport")
        Picker(MacToolboxText.t("协议类型", "Protocol", locale), selection: $serial.protocolType) {
            Text(MacToolboxText.t("通用收发", "Raw data", locale)).tag(SerialAssistantProtocol.raw)
            Text("Modbus").tag(SerialAssistantProtocol.modbus)
        }.disabled(owner.connecting)
        if serial.protocolType == .modbus {
            Picker(MacToolboxText.t("数据封装", "Framing", locale), selection: $serial.modbusFraming) {
                Text(MacToolboxText.t("按设备说明选择", "Choose for your device", locale)).tag(Optional<ModbusFraming>.none)
                ForEach(serial.availableModbusFramings, id: \.self) { framing in
                    Text(framingLabel(framing)).tag(Optional(framing))
                }
            }.disabled(owner.connecting)
        }
        if serial.connection == .usb {
            usbSerialForm
        } else {
            TextField(MacToolboxText.t("主机名或 IP 地址", "Host name or IP address", locale), text: $address)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .disabled(owner.connecting)
                .accessibilityIdentifier("mac.toolbox.communication.address")
            TextField(MacToolboxText.t("端口", "Port", locale), text: $port)
                .textFieldStyle(.roundedBorder)
                .disabled(owner.connecting)
                .accessibilityIdentifier("mac.toolbox.communication.port")
            if serial.connection == .tcp { Toggle("TLS", isOn: $useTLS).disabled(owner.connecting) }
        }
    }

    /// Explicitly selected local device: the list shows only the callout
    /// nodes the system already exposes; nothing is scanned. The chosen
    /// path, line settings and USB identity are admitted as one request.
    @ViewBuilder private var usbSerialForm: some View {
        HStack(spacing: 10) {
            Picker(MacToolboxText.t("串口", "Serial port", locale), selection: $usbPortPath) {
                if usbPorts.isEmpty {
                    Text(MacToolboxText.t("未找到串口设备", "No serial ports found", locale)).tag("")
                }
                ForEach(usbPorts, id: \.path) { port in
                    Text(port.fileName).tag(port.path)
                }
            }
            .disabled(owner.connecting)
            .accessibilityIdentifier("mac.toolbox.communication.usbPort")
            Button(MacToolboxText.t("刷新", "Refresh", locale)) { refreshUSBPorts() }
                .disabled(owner.connecting)
                .accessibilityIdentifier("mac.toolbox.communication.usbRefresh")
        }
        HStack(spacing: 10) {
            Picker(MacToolboxText.t("波特率", "Baud", locale), selection: $usbBaud) {
                ForEach([9600, 19200, 38400, 57600, 115200, 230400], id: \.self) { value in
                    Text("\(value)").tag(UInt32(value))
                }
            }
            Picker(MacToolboxText.t("数据位", "Data bits", locale), selection: $usbDataBits) {
                ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag(UInt8($0)) }
            }
            Picker(MacToolboxText.t("停止位", "Stop bits", locale), selection: $usbStopBits) {
                Text("1").tag(UInt8(1)); Text("2").tag(UInt8(2))
            }
            Picker(MacToolboxText.t("校验", "Parity", locale), selection: $usbParity) {
                Text(MacToolboxText.t("无", "None", locale)).tag(USBSerialSettings.Parity.none)
                Text(MacToolboxText.t("奇", "Odd", locale)).tag(USBSerialSettings.Parity.odd)
                Text(MacToolboxText.t("偶", "Even", locale)).tag(USBSerialSettings.Parity.even)
            }
        }
        .disabled(owner.connecting)
        Text(MacToolboxText.t(
            "只连接你选中的串口设备；不会自动扫描或打开其他设备。macOS 不支持高位/标记校验的串口参数时会明确提示。",
            "Only the port you select is opened; nothing else is scanned or opened. Settings macOS serial cannot represent are reported instead of approximated.",
            locale))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func refreshUSBPorts() {
        let catalog = MacUSBSerialPortCatalog()
        usbPorts = catalog.ports()
        if !usbPorts.contains(where: { $0.path == usbPortPath }) {
            usbPortPath = usbPorts.first?.path ?? ""
        }
    }

    private var usbSettings: USBSerialSettings {
        // Picker choices stay inside the shared grammar, so this only falls
        // back if those constraints are ever widened.
        (try? USBSerialSettings(baud: usbBaud, dataBits: usbDataBits, stopBits: usbStopBits, parity: usbParity))
            ?? Self.fallbackUSBSettings
    }

    private static let fallbackUSBSettings: USBSerialSettings = {
        // 115200/8/N/1 is the shared default and always validates.
        try! USBSerialSettings()
    }()

    private func framingLabel(_ framing: ModbusFraming) -> String {
        switch framing {
        case .mbap: "MBAP"
        case .rtu: MacToolboxText.t("RTU（CRC）", "RTU (CRC)", locale)
        case .ascii: MacToolboxText.t("ASCII（LRC）", "ASCII (LRC)", locale)
        }
    }

    private var description: String {
        switch tool {
        case .http:
            MacToolboxText.t("向填写的地址发送 HTTP 请求；同一来源的重定向会自动跟随。",
                             "Send HTTP requests to the address you enter. Same-origin redirects are followed.", locale)
        case .webSocket:
            MacToolboxText.t("连接 ws:// 或 wss:// 地址后可发送与接收消息。",
                             "Connect to a ws:// or wss:// address, then send and receive messages.", locale)
        case .mqtt:
            MacToolboxText.t("连接 MQTT 服务器后可订阅主题并发布消息。",
                             "Connect to an MQTT server, then subscribe to topics and publish messages.", locale)
        case .serialAssistant:
            MacToolboxText.t("通过 TCP、UDP 或你选中的 USB 串口与设备通信；支持通用收发与 Modbus。",
                              "Talk to a device over TCP, UDP, or a USB serial port you select; raw exchange and Modbus are supported.", locale)
        default:
            ""
        }
    }

    @ViewBuilder private var issuesView: some View {
        if attempted {
            ForEach(Array(MacCommunicationValidation.issues(for: request).enumerated()), id: \.offset) { _, issue in
                issueText(issue)
            }
        }
    }

    private func issueText(_ issue: MacCommunicationInputIssue) -> some View {
        let text: String
        switch issue {
        case .addressRequired:
            text = MacToolboxText.t("请输入服务器主机名或 IP 地址。", "Enter the server hostname or IP address.", locale)
        case .invalidHost:
            text = MacToolboxText.t("请输入主机名或 IP 地址。", "Enter a hostname or IP address.", locale)
        case .portRequired:
            text = MacToolboxText.t("请输入端口（1–65535）。", "Enter a port from 1 to 65535.", locale)
        case .invalidPort:
            text = MacToolboxText.t("端口须为 1–65535 的整数。", "The port must be an integer from 1 to 65535.", locale)
        case .webSocketURLRequired:
            text = MacToolboxText.t("请输入 WebSocket 地址（ws:// 或 wss://）。", "Enter a WebSocket address starting with ws:// or wss://.", locale)
        case .invalidWebSocketURL:
            text = MacToolboxText.t("请输入完整的 ws:// 或 wss:// 地址。", "Enter a complete ws:// or wss:// address.", locale)
        case .httpURLRequired:
            text = MacToolboxText.t("请输入地址（http:// 或 https://）。", "Enter an address starting with http:// or https://.", locale)
        case .invalidHTTPURL:
            text = MacToolboxText.t("请输入完整的 http:// 或 https:// 地址。", "Enter a complete http:// or https:// address.", locale)
        case .invalidSerialConfiguration:
            text = MacToolboxText.t("请按设备说明选择 Modbus 数据封装。", "Choose the Modbus framing your device documents.", locale)
        case .serialPortRequired:
            text = MacToolboxText.t("请选择要连接的串口设备。", "Choose the serial port to connect.", locale)
        case .invalidSerialPortPath:
            text = MacToolboxText.t("所选串口无效，请刷新列表后重新选择。", "The selected port is not valid. Refresh the list and choose again.", locale)
        }
        return Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(.red)
            .accessibilityIdentifier("mac.toolbox.communication.issue.\(issue.field.rawValue)")
    }

    private var request: MacCommunicationRequest {
        switch tool {
        case .http:
            .http(URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "invalid")!)
        case .webSocket:
            .webSocket(URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "invalid")!)
        case .mqtt:
            .mqtt(host: address.trimmingCharacters(in: .whitespacesAndNewlines),
                  port: UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                  tls: useTLS, version: mqttVersion,
                  username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password)
        case .serialAssistant:
            if serial.connection == .usb {
                .serialUSB(path: usbPortPath.trimmingCharacters(in: .whitespacesAndNewlines),
                           settings: usbSettings, vendorID: 0, productID: 0, configuration: serial)
            } else {
                .serial(host: address.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                        tls: useTLS, configuration: serial)
            }
        default:
            .http(URL(string: "https://example.invalid")!)
        }
    }

    private func connect() {
        attempted = true
        guard MacCommunicationValidation.issues(for: request).isEmpty else { return }
        let request = self.request
        password = ""
        Task { await owner.start(request, locale: locale) }
    }

    // MARK: - Save / export

    private func revealSaved(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportCapture(_ data: Data) {
        let type = UTType(filenameExtension: "jsonl") ?? .json
        Task {
            _ = try? await MacToolboxFilePanels.saveData(data, suggestedName: "Floe-Capture.jsonl",
                                                         contentType: type, locale: locale,
                                                         title: MacToolboxText.t("导出记录", "Export capture", locale))
        }
    }
}

/// Cancels the admitted communication session when the toolbox window closes,
/// mirroring the manual diagnostics surface. Tool switches inside the window
/// keep the session alive; only an explicit disconnect or window close ends it.
private struct MacToolboxWindowCloseObserver: NSViewRepresentable {
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
