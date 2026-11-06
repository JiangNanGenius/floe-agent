// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeExecution
import FloeToolboxCore
import FloeToolboxUI
import FloeToolboxClients
import FloeToolboxUtilities
import FloeToolboxWorkbenches

struct ToolboxRootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.locale) private var locale
    @ObservedObject var center: ToolboxCenter
    @ObservedObject private var files: ToolboxFileAccess
    @State private var selection: ToolboxTool?
    @State private var exportURL: URL?
    @State private var showingExport = false
    @State private var exportFailed = false
    @State private var showingCaptures = false
    init(center: ToolboxCenter) { self.center = center; files = center.files }
    private var availability: [ToolboxTool: ToolboxAvailability] {
        var values: [ToolboxTool: ToolboxAvailability] = [:]
        for tool in ToolboxTool.allCases {
            switch tool {
            case .http, .webSocket, .mqtt, .serialAssistant:
                values[tool] = center.connections[tool]?.active == true ? .available :
                    .needsConfiguration(IDELanguageRunText.t("打开后选择连接", "Choose a connection after opening"))
            case .terminal, .vnc:
                values[tool] = .needsConfiguration(IDELanguageRunText.t("选择运行环境或机器", "Choose an environment or machine"))
            default: values[tool] = .available
            }
        }
        return values
    }
    var body: some View {
        NavigationStack {
            ToolboxHomeView(availability: availability) { selection = $0 }
                .accessibilityIdentifier("toolbox.home")
                .toolbar { Button(IDELanguageRunText.t("记录与抓包", "Captures"), systemImage: "list.bullet.rectangle") { showingCaptures = true } }
                .navigationDestination(item: $selection) { tool in
                    destination(tool).navigationTitle(tool.title(in: locale))
                }
        }
        .sheet(isPresented: $showingCaptures) { ToolboxCaptureBrowser() }
        .onChange(of: selection) { old, new in
            guard let old, old != new else { return }
            if old == .hash { center.checksum.cancel() }
            if old == .browser { environment.toolboxBrowser.leave() }
            center.disconnectNow(old); environment.toolboxDiagnostics.closeNow(old)
            if old == .terminal || old == .vnc { environment.toolboxRemote.closeNow() }
        }
        .fileImporter(isPresented: $files.presenting, allowedContentTypes: files.types, allowsMultipleSelection: false) { result in
            files.finish(result.map { $0.first })
        }
        .sheet(isPresented: $showingExport) {
            NavigationStack {
                if let exportURL {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.badge.arrow.up").font(.largeTitle)
                        Text(exportURL.lastPathComponent).textSelection(.enabled)
                        ShareLink(item: exportURL) { Label(IDELanguageRunText.t("存储或分享", "Save or share"), systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }.padding()
                    .navigationTitle(IDELanguageRunText.t("导出", "Export"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { showingExport = false } } }
                }
            }.presentationDetents([.medium, .large])
        }
        .alert(IDELanguageRunText.t("未能导出", "Unable to export"), isPresented: $exportFailed) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) {}
        }
    }
    @ViewBuilder private func destination(_ tool: ToolboxTool) -> some View {
        switch tool {
        case .http, .webSocket, .mqtt, .serialAssistant:
            ToolboxConnectionPage(tool: tool, center: center, onSave: showExport, onExport: { save($0, extension: "jsonl") })
        case .ping, .traceroute, .dns, .port, .lan, .wifi:
            ToolboxDiagnosticPage(tool: tool, center: environment.toolboxDiagnostics)
        case .roaming:
            ToolboxRoamingPage(center: environment.toolboxDiagnostics, onExport: { save($0, extension: "json") })
        case .json: ToolboxTextUtilityView(mode: .json)
        case .encoding: ToolboxTextUtilityView(mode: .encoding)
        case .qr: ToolboxQRView(importImage: { try await files.image() }, exportImage: { save($0, extension: "png") })
        case .hash: ChecksumWorkbenchView(model: center.checksum)
        case .terminal, .vnc: ToolboxRemoteWorkspace(kind: tool == .terminal ? .terminal : .vnc)
        case .browser: ToolboxBrowserWorkspace()
        }
    }
    private func showExport(_ url: URL) { exportURL = url; showingExport = true }
    private func save(_ data: Data, extension suffix: String) {
        do {
            let root = try PersonalContentLibrary.applicationRoot().deletingLastPathComponent().appendingPathComponent("Toolbox/Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("Export-" + UUID().uuidString).appendingPathExtension(suffix)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            showExport(url)
        } catch { exportFailed = true }
    }
}

private struct ToolboxConnectionPage: View {
    let tool: ToolboxTool
    @ObservedObject var center: ToolboxCenter
    let onSave: (URL) -> Void
    let onExport: (Data) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var setup = ToolboxConnectionSetup()
    @State private var assistant: ToolboxConnection?
    @State private var peripherals: [BluetoothSerialPeripheral] = []
    @State private var selectedPeripheral: UUID?
    @State private var serviceUUID = ""
    @State private var writeUUID = ""
    @State private var notifyUUID = ""
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var packetFailure: String?
    var body: some View {
        Group {
            if let owner = center.connections[tool], owner.active {
                workbench(owner)
                    .toolbar {
                        Button(IDELanguageRunText.t("助手", "Assistant"), systemImage: "sparkles") { assistant = owner }
                            .accessibilityIdentifier("toolbox.assistant")
                        if tool == .serialAssistant {
                            Button(IDELanguageRunText.t("导入抓包", "Import packets"), systemImage: "square.and.arrow.down") {
                                Task {
                                    do {
                                        guard let url = try await center.files.choose([UTType(filenameExtension: "pcap") ?? .data, UTType(filenameExtension: "pcapng") ?? .data]) else { return }
                                        let capture = try await ToolboxPacketImport.read(url)
                                        guard owner.active else { return }
                                        try await ToolboxPacketImport.append(capture, to: owner.journal)
                                        await owner.serialModel?.refresh()
                                    } catch { packetFailure = IDELanguageRunText.t("未能导入，请检查 PCAP/PCAPNG 文件。", "Unable to import. Check the PCAP/PCAPNG file.") }
                                }
                            }
                        }
                        Button(IDELanguageRunText.t("断开", "Disconnect"), systemImage: "xmark.circle") { Task { await center.disconnect(tool) } }
                    }
            } else { connectionForm }
        }
        .sheet(item: $assistant) { ToolboxAssistantView(connection: $0) }
        .alert(IDELanguageRunText.t("抓包导入", "Packet import"), isPresented: Binding(get: { packetFailure != nil }, set: { if !$0 { packetFailure = nil } })) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { packetFailure = nil }
        } message: { Text(packetFailure ?? "") }
    }
    private var connectionForm: some View {
        Form {
            if tool == .serialAssistant {
                Section { SerialAssistantSetupView(configuration: $setup.serial, connected: false) }
            }
            Section(IDELanguageRunText.t("连接", "Connection")) {
                if tool == .serialAssistant, setup.serial.connection == .bluetooth {
                    Button(IDELanguageRunText.t("查找蓝牙设备", "Find Bluetooth devices")) {
                        guard !scanning else { return }; scanning = true; scanFailed = false
                        Task {
                            defer { scanning = false }
                            do { peripherals = try await environment.bluetoothSerialService.scan(duration: 5) }
                            catch { scanFailed = true }
                        }
                    }.disabled(scanning)
                    if scanning { ProgressView() }
                    if scanFailed { Text(IDELanguageRunText.t("未能搜索，请检查蓝牙权限和设备。", "Unable to search. Check Bluetooth permission and the device.")) }
                    Picker(IDELanguageRunText.t("设备", "Device"), selection: $selectedPeripheral) {
                        Text(IDELanguageRunText.t("请选择", "Choose")).tag(UUID?.none)
                        ForEach(peripherals, id: \.id) { Text(($0.name ?? IDELanguageRunText.t("未命名设备", "Unnamed device")) + " · \($0.rssi) dBm").tag(Optional($0.id)) }
                    }
                    TextField(IDELanguageRunText.t("服务 UUID", "Service UUID"), text: $serviceUUID)
                    TextField(IDELanguageRunText.t("写入特征 UUID", "Write characteristic UUID"), text: $writeUUID)
                    TextField(IDELanguageRunText.t("通知特征 UUID（可选）", "Notify characteristic UUID (optional)"), text: $notifyUUID)
                } else if tool == .serialAssistant, setup.serial.connection == .usb {
                    TextField("USB Vendor ID · HEX", text: $setup.usbVendorID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("USB Product ID · HEX", text: $setup.usbProductID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(IDELanguageRunText.t("波特率", "Baud rate"), text: $setup.usbBaud).keyboardType(.numberPad)
                    Text(IDELanguageRunText.t("USB 需要受支持的 iPad、驱动与应用授权。当前候选尚未连接 USB 驱动宿主，可先使用 TCP、UDP 或蓝牙。", "USB needs a supported iPad, driver and app authorization. This candidate has no USB driver host connected; use TCP, UDP or Bluetooth in the meantime.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField([ToolboxTool.http, .webSocket].contains(tool) ? "URL" : IDELanguageRunText.t("地址或主机名", "Address or hostname"), text: $setup.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("toolbox.address")
                    if ![ToolboxTool.http, .webSocket].contains(tool) {
                        TextField(IDELanguageRunText.t("端口", "Port"), text: $setup.port).keyboardType(.numberPad)
                        if tool == .mqtt || setup.serial.connection == .tcp { Toggle("TLS", isOn: $setup.useTLS) }
                    }
                }
                if tool == .mqtt {
                    Picker(IDELanguageRunText.t("版本", "Version"), selection: $setup.mqttVersion) {
                        Text("MQTT 5").tag(MQTTVersion.v5); Text("MQTT 3.1.1").tag(MQTTVersion.v311)
                    }
                    TextField(IDELanguageRunText.t("用户名（可选）", "Username (optional)"), text: $setup.username).textInputAutocapitalization(.never)
                    SecureField(IDELanguageRunText.t("密码（可选）", "Password (optional)"), text: $setup.password)
                }
                if let error = center.failures[tool] { Text(error).foregroundStyle(.secondary) }
                Button(IDELanguageRunText.t("连接", "Connect")) {
                    var value = setup
                    if let selectedPeripheral {
                        value.bluetooth = BluetoothSerialEndpoint(peripheralID: selectedPeripheral, serviceUUID: serviceUUID,
                            writeCharacteristicUUID: writeUUID, notifyCharacteristicUUID: notifyUUID.isEmpty ? nil : notifyUUID)
                    }
                    center.connect(tool, setup: value); setup.password = ""
                }.disabled(center.connecting.contains(tool))
                    .accessibilityIdentifier("toolbox.connect")
                if center.connecting.contains(tool) {
                    HStack { ProgressView(); Button(IDELanguageRunText.t("取消", "Cancel")) { Task { await center.disconnect(tool) } } }
                }
            }
        }
        .onChange(of: setup.serial.connection) { _, value in if value != .tcp { setup.useTLS = false } }
    }
    @ViewBuilder private func workbench(_ owner: ToolboxConnection) -> some View {
        if let model = owner.httpModel { HTTPWorkbenchView(model: model, onSave: onSave, onExport: onExport) }
        else if let model = owner.webSocketModel { WebSocketWorkbenchView(model: model, onSave: onSave, onExport: onExport) }
        else if let model = owner.mqttModel { MQTTWorkbenchView(model: model, onSave: onSave, onExport: onExport) }
        else if let model = owner.modbusModel { ModbusWorkbenchView(model: model, onSave: onSave, onExport: onExport) }
        else if let model = owner.serialModel { SerialClientPanel(model: model, onSaved: onSave, onExport: onExport) }
    }
}

private struct ToolboxDiagnosticPage: View {
    let tool: ToolboxTool
    @ObservedObject var center: ToolboxDiagnosticsCenter
    @State private var model: DiagnosticWorkbenchModel?
    @State private var failed = false
    var body: some View {
        Group {
            if let model { DiagnosticWorkbenchView(model: model) }
            else if failed { ContentUnavailableView(IDELanguageRunText.t("暂时无法打开", "Unable to open"), systemImage: "network.slash") }
            else { ProgressView() }
        }.task { do { model = try center.model(for: tool) } catch { failed = true } }
    }
}

private struct ToolboxRoamingPage: View {
    @ObservedObject var center: ToolboxDiagnosticsCenter
    let onExport: (Data) -> Void
    @State private var target = ""
    var body: some View {
        Group {
            if let snapshot = center.roaming {
                RoamingTraceView(snapshot: snapshot, isRecording: center.tracing,
                    onStart: { center.startTrace(target: $0, interval: $1) },
                    onStop: { Task { await center.stopTrace() } },
                    onExport: { if let bytes = try? JSONEncoder().encode(snapshot) { onExport(bytes) } })
            } else {
                Form {
                    TextField(IDELanguageRunText.t("探测目标", "Probe target"), text: $target).textInputAutocapitalization(.never)
                    Button(IDELanguageRunText.t("开始追踪", "Start trace")) { center.startTrace(target: target, interval: 1) }.disabled(target.isEmpty || center.tracing)
                    if center.tracing { ProgressView() }
                    if center.failed { Text(IDELanguageRunText.t("未能开始，请检查目标与权限。", "Unable to start. Check the target and permissions.")) }
                }
            }
        }.padding()
    }
}
#endif
