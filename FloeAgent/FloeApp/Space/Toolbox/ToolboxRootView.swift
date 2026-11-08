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
import FloeToolboxDiagnostics
import UIKit

struct ToolboxRootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.locale) private var locale
    @ObservedObject var center: ToolboxCenter
    @ObservedObject private var files: ToolboxFileAccess
    @State private var selection: ToolboxTool?
    @State private var exportArtifact: ToolboxExportArtifact?
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
                .navigationBarTitleDisplayMode(.inline)
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
        .sheet(item: $exportArtifact) { artifact in
            NavigationStack {
                VStack(spacing: 20) {
                    Image(systemName: "doc.badge.arrow.up").font(.largeTitle)
                    Text(artifact.url.lastPathComponent).textSelection(.enabled)
                        .accessibilityIdentifier("toolbox.export.filename")
                    ShareLink(item: artifact.url) { Label(IDELanguageRunText.t("存储或分享", "Save or share"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("toolbox.export.share")
                }.padding()
                .navigationTitle(IDELanguageRunText.t("导出", "Export"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { exportArtifact = nil } } }
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
        case .ping, .traceroute, .dns, .port, .lan:
            ToolboxDiagnosticPage(tool: tool, center: environment.toolboxDiagnostics)
        case .wifi:
            ToolboxWiFiPage(center: environment.toolboxDiagnostics)
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
    private func showExport(_ url: URL) { exportArtifact = ToolboxExportArtifact(url: url) }
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

private struct ToolboxExportArtifact: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ToolboxConnectionPage: View {
    let tool: ToolboxTool
    @ObservedObject var center: ToolboxCenter
    @ObservedObject private var usbDevices: ToolboxUSBDevices
    let onSave: (URL) -> Void
    let onExport: (Data) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var setup = ToolboxConnectionSetup()
    @State private var attemptedConnection = false
    @State private var assistant: ToolboxConnection?
    @State private var peripherals: [BluetoothSerialPeripheral] = []
    @State private var selectedPeripheral: UUID?
    @State private var serviceUUID = ""
    @State private var writeUUID = ""
    @State private var notifyUUID = ""
    @State private var scanning = false
    @State private var scanFailure: String?
    @State private var scanGeneration = UUID()
    @State private var scanTask: Task<Void, Never>?
    @State private var manualBluetooth = false
    @State private var packetFailure: String?
    @State private var confirmingConfiguration = false
    @MainActor init(tool: ToolboxTool, center: ToolboxCenter, onSave: @escaping (URL) -> Void, onExport: @escaping (Data) -> Void) {
        self.tool = tool; self.center = center; self.onSave = onSave; self.onExport = onExport
        _usbDevices = ObservedObject(wrappedValue: center.usbDevices)
    }
    var body: some View {
        Group {
            if let owner = center.connections[tool], owner.active {
                connectedWorkbench(owner)
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
                        if tool != .serialAssistant {
                            Button(IDELanguageRunText.t("断开", "Disconnect"), systemImage: "xmark.circle") { center.disconnectNow(tool) }
                        }
                    }
            } else { connectionForm }
        }
        .sheet(item: $assistant) { ToolboxAssistantView(connection: $0) }
        .confirmationDialog(IDELanguageRunText.t("断开后修改连接设置？", "Disconnect to change connection settings?"), isPresented: $confirmingConfiguration, titleVisibility: .visible) {
            Button(IDELanguageRunText.t("断开并配置", "Disconnect and configure")) { center.disconnectNow(tool) }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { }
        }
        .alert(IDELanguageRunText.t("抓包导入", "Packet import"), isPresented: Binding(get: { packetFailure != nil }, set: { if !$0 { packetFailure = nil } })) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { packetFailure = nil }
        } message: { Text(packetFailure ?? "") }
    }
    private var connectionForm: some View {
        Form {
            if tool == .serialAssistant {
                Section {
                    Label(center.connecting.contains(tool) ? IDELanguageRunText.t("正在连接", "Connecting") : IDELanguageRunText.t("未连接", "Disconnected"),
                        systemImage: center.connecting.contains(tool) ? "arrow.triangle.2.circlepath" : "cable.connector")
                        .accessibilityIdentifier("toolbox.serial.connectionStatus")
                }
                Section { SerialAssistantSetupView(configuration: $setup.serial, connected: false,
                    allowsUSB: ToolboxConnection.includesUSBSerialDriver) }
                    .disabled(center.connecting.contains(tool))
            }
            Section(IDELanguageRunText.t("连接", "Connection")) {
                if tool == .serialAssistant, setup.serial.connection == .bluetooth {
                    bluetoothFields
                } else if tool == .serialAssistant, setup.serial.connection == .usb {
                    ToolboxUSBSetupView(devices: usbDevices, setup: $setup,
                        busy: center.connecting.contains(tool), find: center.refreshUSBDevices)
                } else {
                    TextField([ToolboxTool.http, .webSocket].contains(tool) ? "URL" : IDELanguageRunText.t("地址或主机名", "Address or hostname"), text: $setup.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("toolbox.address")
                    inputError(.address)
                    if ![ToolboxTool.http, .webSocket].contains(tool) {
                        TextField(IDELanguageRunText.t("端口", "Port"), text: $setup.port).keyboardType(.numberPad)
                            .accessibilityIdentifier("toolbox.port")
                        inputError(.port)
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
                if inputIssues.isEmpty, let error = center.failures[tool] {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        .accessibilityIdentifier("toolbox.connection.error")
                }
                if let details = center.failureDetails[tool] {
                    DisclosureGroup(IDELanguageRunText.t("详情", "Details")) { Text(details).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Button(IDELanguageRunText.t("连接", "Connect")) {
                    attemptedConnection = true
                    var value = connectionInput
                    guard value.inputIssues(for: tool).isEmpty else { return }
                    cancelBluetoothScan()
                    do {
                        if tool == .serialAssistant, value.serial.connection == .usb {
                            value.usbRequest = try usbDevices.request(settings: value.usbSettings())
                        }
                        center.connect(tool, setup: value); setup.password = ""
                    } catch { center.reportUSBFailure(error) }
                }.disabled(center.connecting.contains(tool) || (tool == .serialAssistant && setup.serial.connection == .usb && !usbDevices.canConnect))
                    .accessibilityIdentifier("toolbox.connect")
                if center.connecting.contains(tool) {
                    HStack { ProgressView(); Button(IDELanguageRunText.t("取消", "Cancel")) { Task { await center.disconnect(tool) } } }
                }
            }
            ToolboxHistorySection(tool: tool, history: center.history, busy: center.connecting.contains(tool)) { configuration in
                guard let restored = configuration.connectionSetup() else { return }
                cancelBluetoothScan()
                setup = restored; attemptedConnection = false
                selectedPeripheral = restored.bluetooth?.peripheralID; manualBluetooth = false
                peripherals = []; serviceUUID = restored.bluetooth?.serviceUUID ?? ""
                writeUUID = restored.bluetooth?.writeCharacteristicUUID ?? ""; notifyUUID = restored.bluetooth?.notifyCharacteristicUUID ?? ""
                center.clearBluetoothChannels()
                center.resetUSBDevices()
            }
        }
        .onChange(of: setup.serial.connection) { _, value in
            if value != .tcp { setup.useTLS = false }
            if value != .usb { center.resetUSBDevices() }
            if value != .bluetooth { cancelBluetoothScan(); center.clearBluetoothChannels() }
        }
        .onDisappear { cancelBluetoothScan() }
    }
    private var connectionInput: ToolboxConnectionSetup {
        var value = setup
        if tool == .serialAssistant, setup.serial.connection == .bluetooth {
            value.bluetoothPeripheralID = selectedPeripheral
            if let selectedPeripheral, manualBluetooth {
                value.bluetooth = .init(peripheralID: selectedPeripheral, serviceUUID: serviceUUID,
                    writeCharacteristicUUID: writeUUID, notifyCharacteristicUUID: notifyUUID.isEmpty ? nil : notifyUUID)
            } else if value.bluetooth?.peripheralID != selectedPeripheral { value.bluetooth = nil }
        }
        return value
    }
    private var inputIssues: [ToolboxConnectionInputIssue] {
        attemptedConnection ? connectionInput.inputIssues(for: tool) : []
    }
    private func cancelBluetoothScan() {
        scanGeneration = UUID(); scanTask?.cancel(); scanTask = nil; scanning = false
    }
    private var bluetoothFields: some View {
        Group {
            Button(IDELanguageRunText.t("查找蓝牙设备", "Find Bluetooth devices")) {
                guard !scanning else { return }; scanning = true; scanFailure = nil
                let generation = UUID(); scanGeneration = generation
                scanTask = Task {
                    defer { if scanGeneration == generation { scanning = false; scanTask = nil } }
                    do {
                        let result = try await environment.bluetoothSerialService.scan(duration: 5)
                        try Task.checkCancellation()
                        guard scanGeneration == generation else { return }; peripherals = result
                    } catch is CancellationError { }
                    catch { if scanGeneration == generation { scanFailure = ToolboxBluetoothPresentation.message(error) } }
                }
            }.disabled(scanning)
            if scanning { ProgressView() }
            if let scanFailure { Text(scanFailure).foregroundStyle(.secondary) }
            Picker(IDELanguageRunText.t("设备", "Device"), selection: Binding(get: { selectedPeripheral }, set: {
                selectedPeripheral = $0; setup.bluetooth = nil; attemptedConnection = false
                center.clearBluetoothChannels()
            })) {
                Text(IDELanguageRunText.t("请选择", "Choose")).tag(UUID?.none)
                if let selectedPeripheral, !peripherals.contains(where: { $0.id == selectedPeripheral }) {
                    Text(IDELanguageRunText.t("上次使用的设备", "Previously used device")).tag(Optional(selectedPeripheral))
                }
                ForEach(peripherals, id: \.id) {
                    Text(($0.name ?? IDELanguageRunText.t("未命名设备", "Unnamed device")) + " · \($0.rssi) dBm").tag(Optional($0.id))
                }
            }.accessibilityIdentifier("toolbox.bluetooth.device")
            inputError(.bluetooth)
            if !manualBluetooth, setup.bluetooth != nil {
                Text(IDELanguageRunText.t("使用上次选择的通道", "Using the previously selected channel")).foregroundStyle(.secondary)
                Button(IDELanguageRunText.t("重新识别通道", "Detect channels again")) {
                    setup.bluetooth = nil; center.clearBluetoothChannels()
                }
            }
            let channels = center.bluetoothChannels.filter { $0.endpoint.peripheralID == selectedPeripheral }
            if !manualBluetooth, !channels.isEmpty {
                ForEach(channels.indices, id: \.self) { index in
                    Button {
                        setup.bluetooth = channels[index].endpoint
                        var value = setup; value.bluetoothPeripheralID = selectedPeripheral
                        center.connect(tool, setup: value)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(ToolboxBluetoothPresentation.title(channels[index], index: index), systemImage: "arrow.up.arrow.down")
                            Text(channels[index].recognition == .unverified
                                ? IDELanguageRunText.t("仅在确认为设备的数据通道时选择", "Choose only if this is your device's data channel")
                                : IDELanguageRunText.t("发送与接收", "Send and receive"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("toolbox.bluetooth.channel.\(index)")
                }
            }
            DisclosureGroup(IDELanguageRunText.t("高级设置", "Advanced settings")) {
                Toggle(IDELanguageRunText.t("手动指定通道", "Specify channel manually"), isOn: Binding(get: { manualBluetooth }, set: {
                    manualBluetooth = $0; setup.bluetooth = nil; center.clearBluetoothChannels()
                }))
                if manualBluetooth {
                    TextField(IDELanguageRunText.t("服务 UUID", "Service UUID"), text: $serviceUUID)
                    TextField(IDELanguageRunText.t("写入特征 UUID", "Write characteristic UUID"), text: $writeUUID)
                    TextField(IDELanguageRunText.t("通知特征 UUID（可选）", "Notify characteristic UUID (optional)"), text: $notifyUUID)
                }
                if let endpoint = setup.bluetooth {
                    Text("\(endpoint.serviceUUID)\n\(endpoint.writeCharacteristicUUID)\n\(endpoint.notifyCharacteristicUUID ?? "")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }.disabled(center.connecting.contains(tool))
    }
    @ViewBuilder private func inputError(_ field: ToolboxConnectionInputIssue.Field) -> some View {
        if let issue = inputIssues.first(where: { $0.field == field }) {
            Label(issue.localizedDescription, systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.red)
                .accessibilityIdentifier("toolbox." + field.rawValue + ".error")
        }
    }
    @ViewBuilder private func connectedWorkbench(_ owner: ToolboxConnection) -> some View {
        if tool == .serialAssistant {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(IDELanguageRunText.t("已连接", "Connected"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("toolbox.serial.connectionStatus")
                        if let endpoint = owner.serial?.endpoint { Text(endpoint.title).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button(IDELanguageRunText.t("连接设置", "Connection settings"), systemImage: "slider.horizontal.3") { confirmingConfiguration = true }
                        .accessibilityIdentifier("toolbox.serial.configure")
                    Button(IDELanguageRunText.t("断开", "Disconnect")) { center.disconnectNow(tool) }
                        .accessibilityIdentifier("toolbox.serial.disconnect")
                }.padding(.horizontal).padding(.vertical, 8)
                Divider()
                workbench(owner)
            }
        } else { workbench(owner) }
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
            if let model {
                DiagnosticWorkbenchView(model: model, history: AnyView(ToolboxDiagnosticHistory(model: model, history: center.history)))
            }
            else if failed { ContentUnavailableView(IDELanguageRunText.t("暂时无法打开", "Unable to open"), systemImage: "network.slash") }
            else { ProgressView() }
        }.task { do { model = try center.model(for: tool) } catch { failed = true } }
    }
}

private struct ToolboxDiagnosticHistory: View {
    @ObservedObject var model: DiagnosticWorkbenchModel
    @ObservedObject var history: ToolboxHistoryStore
    var body: some View {
        ToolboxHistorySection(tool: model.tool, history: history, runsImmediately: true, busy: model.running) { configuration in
            guard !model.running else { return }
            configuration.apply(to: model); model.run()
        }
    }
}

private struct ToolboxRoamingPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var center: ToolboxDiagnosticsCenter
    let onExport: (Data) -> Void
    @State private var target = ""
    @State private var targetWasEdited = false
    @State private var showingHistory = false
    var body: some View {
        VStack(spacing: 0) {
            ToolboxWiFiIdentityPanel(center: center).padding()
            Divider()
            if let snapshot = center.roaming {
                RoamingTraceView(snapshot: snapshot, isRecording: center.tracing,
                    onStart: { center.startTrace(target: $0, interval: $1) },
                    onStop: { Task { await center.stopTrace() } },
                    onExport: { if let bytes = try? JSONEncoder().encode(snapshot) { onExport(bytes) } },
                    defaultGateway: center.defaultGateway)
            } else {
                Form {
                    TextField(IDELanguageRunText.t("探测目标", "Probe target"), text: Binding(
                        get: { target }, set: { target = $0; targetWasEdited = true }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("toolbox.roaming.target")
                    Button(IDELanguageRunText.t("使用当前网关", "Use current gateway")) {
                        if let gateway = center.defaultGateway { target = gateway; targetWasEdited = false }
                    }.disabled(center.defaultGateway == nil || center.tracing)
                    if !center.readingNetwork && center.defaultGateway == nil {
                        Text(IDELanguageRunText.t("未能读取当前 Wi-Fi 网关，可手动填写探测目标。", "The current Wi-Fi gateway is unavailable. Enter a probe target manually."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(IDELanguageRunText.t("开始追踪", "Start trace")) { center.startTrace(target: target.trimmingCharacters(in: .whitespacesAndNewlines), interval: 1) }
                        .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.tracing)
                        .accessibilityIdentifier("toolbox.roaming.start")
                    if center.tracing { ProgressView() }
                    if center.failed { Text(IDELanguageRunText.t("未能开始，请检查目标与权限。", "Unable to start. Check the target and permissions.")) }
                    historySection
                }
            }
        }
        .toolbar {
            if center.roaming != nil {
                Button(IDELanguageRunText.t("历史记录", "History"), systemImage: "clock.arrow.circlepath") { showingHistory = true }
            }
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack {
                Form { historySection }.navigationTitle(IDELanguageRunText.t("漫游追踪历史", "Roaming history"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(IDELanguageRunText.t("完成", "Done")) { showingHistory = false } } }
            }
        }
        .task { await refresh() }
        .onChange(of: center.defaultGateway) { _, gateway in
            if !targetWasEdited, let gateway { target = gateway }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }
    private var historySection: some View {
        ToolboxHistorySection(tool: .roaming, history: center.history, runsImmediately: true, busy: center.tracing) { configuration in
            guard !center.tracing else { return }
            target = configuration.target; targetWasEdited = true; showingHistory = false
            center.startTrace(target: configuration.target, interval: configuration.interval)
        }
    }
    private func refresh() async {
        await center.refreshNetworkInfo()
        if !targetWasEdited, let gateway = center.defaultGateway { target = gateway }
    }
}

private struct ToolboxWiFiPage: View {
    @ObservedObject var center: ToolboxDiagnosticsCenter
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            ToolboxWiFiIdentityPanel(center: center)
            LabeledContent(IDELanguageRunText.t("网关", "Gateway"), value: center.defaultGateway ?? "—")
            Button(IDELanguageRunText.t("刷新", "Refresh")) { Task { await center.refreshNetworkInfo() } }
                .disabled(center.readingNetwork)
        }
        .task { await center.refreshNetworkInfo() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await center.refreshNetworkInfo() } } }
    }
}

private struct ToolboxWiFiIdentityPanel: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var center: ToolboxDiagnosticsCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(IDELanguageRunText.t("网络名称（SSID）", "Network name (SSID)"), value: identity?.ssid ?? "—")
            LabeledContent(IDELanguageRunText.t("当前 AP（BSSID）", "Current AP (BSSID)")) {
                Text(identity?.bssid ?? "—").monospaced().textSelection(.enabled)
            }.accessibilityIdentifier("toolbox.wifi.bssid")
            if let message = center.wifiIdentityMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if !center.canReadWiFiIdentity {
                Button(center.needsInitialWiFiAuthorization ? IDELanguageRunText.t("允许读取 Wi-Fi 信息", "Allow Wi-Fi information") : IDELanguageRunText.t("打开定位设置", "Open Location settings")) {
                    if center.needsInitialWiFiAuthorization { Task { await center.requestWiFiIdentityAuthorization() } }
                    else if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.frame(minHeight: 44)
            }
            if center.readingNetwork { ProgressView().accessibilityLabel(IDELanguageRunText.t("正在读取网络", "Reading network")) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var identity: FloeToolboxDiagnostics.WiFiIdentity? {
        center.wifiIdentity
    }
}
#endif
