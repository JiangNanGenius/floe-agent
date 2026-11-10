// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxDiagnostics

/// Reusable input only. No observed device, permission or implicit execution is saved.
public struct LANWorkbenchConfiguration: Codable, Equatable, Sendable {
    public var preset: LANDiscoveryPreset
    public var customTypes: Set<String>
    public var browseSeconds: Double

    public init(preset: LANDiscoveryPreset = .all, customTypes: Set<String> = [], browseSeconds: Double = 5) {
        self.preset = preset; self.customTypes = customTypes; self.browseSeconds = browseSeconds
    }
    public var requestedTypes: [String] {
        preset == .custom ? customTypes.sorted() : LANDiscoveryScope.types(for: preset)
    }
    public var isValid: Bool {
        browseSeconds.isFinite && (0.5...30).contains(browseSeconds)
            && !requestedTypes.isEmpty && requestedTypes.count <= 16
            && customTypes.count <= 16 && customTypes.allSatisfy(LANDiscoveryScope.isPlausibleType)
    }
    public func title(in locale: Locale) -> String { Self.title(preset, in: locale) }
    public func summary(in locale: Locale) -> String {
        let scope: String
        if preset == .custom {
            let names = requestedTypes.prefix(2).map { type in
                LANDiscoveryScope.declaredBonjourTypes.contains(type) ? Self.serviceTitle(type,in:locale) : Self.title(.custom,in:locale)
            }
            let separator = locale.language.languageCode?.identifier == "zh" ? "、" : ", "
            scope = names.joined(separator:separator) + (requestedTypes.count > 2 ? " +\(requestedTypes.count - 2)" : "")
        } else { scope = title(in:locale) }
        let seconds = String(format:"%g",browseSeconds)
        return scope + " · " + workbenchText("\(seconds) 秒","\(seconds) seconds",locale)
    }
    public static func title(_ preset: LANDiscoveryPreset, in locale: Locale) -> String {
        switch preset {
        case .all: workbenchText("全部设备", "All devices", locale)
        case .home: workbenchText("智能家居", "Smart home", locale)
        case .print: workbenchText("打印机与扫描仪", "Printers and scanners", locale)
        case .av: workbenchText("音响与投屏", "Audio and casting", locale)
        case .computers: workbenchText("电脑与文件共享", "Computers and file sharing", locale)
        case .web: workbenchText("网页服务", "Web services", locale)
        case .custom: workbenchText("自选类别", "Choose categories", locale)
        }
    }
    public static func serviceTitle(_ type: String, in locale: Locale) -> String {
        switch type {
        case "_airplay._tcp": "AirPlay"
        case "_raop._tcp": workbenchText("AirPlay 音频", "AirPlay audio", locale)
        case "_googlecast._tcp": "Google Cast"
        case "_hap._tcp": "HomeKit"
        case "_home-assistant._tcp": "Home Assistant"
        case "_http._tcp": workbenchText("网页", "Web", locale)
        case "_https._tcp": workbenchText("安全网页", "Secure web", locale)
        case "_ipp._tcp": workbenchText("网络打印", "Network printing", locale)
        case "_ipps._tcp": workbenchText("安全网络打印", "Secure network printing", locale)
        case "_printer._tcp": workbenchText("打印机", "Printers", locale)
        case "_uscan._tcp": workbenchText("扫描仪", "Scanners", locale)
        case "_workstation._tcp": workbenchText("电脑", "Computers", locale)
        case "_smb._tcp": workbenchText("Windows 文件共享", "Windows file sharing", locale)
        case "_afpovertcp._tcp": workbenchText("Mac 文件共享", "Mac file sharing", locale)
        case "_rfb._tcp": workbenchText("屏幕共享", "Screen sharing", locale)
        case "_sftp-ssh._tcp": workbenchText("SSH 文件传输", "SSH file transfer", locale)
        default: type // Old saved input is visible only in explicit details, never an invented device class.
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preset == rhs.preset && lhs.customTypes == rhs.customTypes && lhs.browseSeconds == rhs.browseSeconds
    }
    private enum CodingKeys: String, CodingKey { case preset, customTypes, browseSeconds }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .preset)
        guard let preset = LANDiscoveryPreset(rawValue: name) else {
            throw DecodingError.dataCorruptedError(forKey: .preset, in: values, debugDescription: "Unknown discovery scope")
        }
        self.init(preset: preset, customTypes: Set(try values.decode([String].self, forKey: .customTypes)),
                  browseSeconds: try values.decode(Double.self, forKey: .browseSeconds))
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .customTypes, in: values, debugDescription: "Invalid discovery input")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preset.rawValue, forKey: .preset)
        try values.encode(customTypes.sorted(), forKey: .customTypes)
        try values.encode(browseSeconds, forKey: .browseSeconds)
    }
}

/// One native form inside the existing workbench and navigation/lease ownership.
struct LANDiscoveryWorkbenchSections: View {
    @ObservedObject var model: DiagnosticWorkbenchModel
    let onUseEndpoint: ((ToolboxTool, String, UInt16?) -> Void)?
    let onOpenSettings: (() -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            Picker(workbenchText("查找范围", "Look for", locale), selection: $model.lanConfiguration.preset) {
                ForEach(LANDiscoveryPreset.allCases) { value in
                    Text(LANWorkbenchConfiguration.title(value, in: locale)).tag(value)
                }
            }.disabled(model.running).accessibilityIdentifier("toolbox.lan.range")
            if model.lanConfiguration.preset == .custom {
                DisclosureGroup(workbenchText("选择设备类别", "Device categories", locale)) {
                    ForEach(LANDiscoveryScope.declaredBonjourTypes, id: \.self) { type in
                        Toggle(LANWorkbenchConfiguration.serviceTitle(type, in: locale), isOn: Binding(
                            get: { model.lanConfiguration.customTypes.contains(type) },
                            set: { if $0 { model.lanConfiguration.customTypes.insert(type) } else { model.lanConfiguration.customTypes.remove(type) } }))
                    }
                }.disabled(model.running)
            }
            Picker(workbenchText("扫描时长", "Scan duration", locale), selection: $model.lanConfiguration.browseSeconds) {
                ForEach(durations, id: \.self) { seconds in
                    Text(workbenchText("\(String(format:"%g",seconds)) 秒", "\(String(format:"%g",seconds)) seconds", locale)).tag(seconds)
                }
            }.disabled(model.running).accessibilityIdentifier("toolbox.lan.seconds")
            HStack {
                if model.running {
                    ProgressView().controlSize(.small)
                    Text(workbenchText("正在发现…", "Discovering…", locale)).foregroundStyle(.secondary)
                    Spacer()
                    Button(workbenchText("停止", "Stop", locale), role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("toolbox.lan.cancel")
                } else {
                    Button(model.request == nil ? workbenchText("开始发现", "Find devices", locale) : workbenchText("重新发现", "Scan again", locale), systemImage: "magnifyingglass") { model.run() }
                        .disabled(!model.lanConfiguration.isValid)
                        .accessibilityIdentifier("toolbox.lan.start")
                }
            }
        } footer: {
            Text(workbenchText("查找同一局域网中主动广播的设备。未出现的设备也可直接输入地址检测。", "Find devices advertising on the same local network. You can also check a device by entering its address.", locale))
        }
        Section(workbenchText("发现结果", "Discovered", locale)) {
            if let scope = model.request?.lanConfiguration {
                Text(scope.summary(in:locale)).font(.caption).foregroundStyle(.secondary)
            }
            status
            ForEach(model.lanServices, id: \.key) { service in
                HStack(spacing: 12) {
                    Image(systemName: icon(service.serviceType)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name).lineLimit(2)
                        if let endpoint = endpoint(service) {
                            Text(endpointLabel(endpoint.0, endpoint.1)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Text(workbenchText("地址尚未解析", "Address not resolved", locale)).font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let endpoint = endpoint(service), let onUseEndpoint {
                        Menu {
                            Button("Ping", systemImage: "waveform.path.ecg") { onUseEndpoint(.ping, endpoint.0, nil) }
                            Button(workbenchText("端口检测", "Port check", locale), systemImage: "network") { onUseEndpoint(.port, endpoint.0, endpoint.1) }
                        } label: {
                            Label(workbenchText("检测", "Check", locale), systemImage: "ellipsis.circle").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }.disabled(model.running).accessibilityLabel(workbenchText("检测 \(service.name)", "Check \(service.name)", locale))
                    }
                }.padding(.vertical, 4)
            }
            if let report = model.lanReport {
                if report.unresolvedCount > 0 {
                    Text(workbenchText("部分结果还没有可用地址，可稍后重试。", "Some results do not have an address yet. Try again shortly.", locale)).font(.caption).foregroundStyle(.secondary)
                }
                if report.truncated {
                    Text(workbenchText("结果较多，已保留前 256 项。可缩小范围后重试。", "Showing the first 256 results. Narrow the scope and retry.", locale)).font(.caption).foregroundStyle(.secondary)
                }
                if !report.notes.isEmpty {
                    DisclosureGroup(workbenchText("诊断详情", "Diagnostic details", locale)) {
                        Text(report.notes.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.accessibilityElement(children: .contain)
        Section(workbenchText("直接检测", "Check an address", locale)) {
            TextField(workbenchText("IP 地址或主机名", "IP address or hostname", locale), text: $model.target)
                .autocorrectionDisabled().disabled(model.running).accessibilityIdentifier("toolbox.lan.manual")
            HStack {
                Button("Ping") { if let target = model.manualTarget { onUseEndpoint?(.ping, target, nil) } }
                Button(workbenchText("端口检测", "Port check", locale)) { if let target = model.manualTarget { onUseEndpoint?(.port, target, nil) } }
            }.disabled(model.running || model.manualTarget == nil || onUseEndpoint == nil)
        }
    }

    private var durations: [Double] {
        var values: Set<Double> = [3,5,10,15]
        let saved = model.lanConfiguration.browseSeconds
        if saved.isFinite, (0.5...30).contains(saved) { values.insert(saved) }
        return values.sorted()
    }
    @ViewBuilder private var status: some View {
        if model.cancelled {
            Text(workbenchText("本次发现已停止。", "Discovery stopped.", locale)).foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.lan.status")
        } else if let report = model.lanReport {
            switch report.status {
            case .foundDevices:
                Text(workbenchText("找到 \(report.services.count) 项结果", "Found \(report.services.count) results", locale))
                    .accessibilityIdentifier("toolbox.lan.status")
            case .noDevices:
                Text(workbenchText("未发现所选类别的设备。可更换范围或直接输入地址。", "No devices advertised in this scope. Try another category or enter an address.", locale))
                    .foregroundStyle(.secondary).accessibilityIdentifier("toolbox.lan.status")
            case .permissionUncertain:
                Text(workbenchText("发现未完成，请检查本地网络权限或网络连接。", "Discovery could not finish. Check Local Network permission and your connection.", locale))
                    .foregroundStyle(.secondary).accessibilityIdentifier("toolbox.lan.status")
                if let onOpenSettings {
                    Button(workbenchText("检查权限", "Check permission", locale), action: onOpenSettings)
                }
            case .noWiFiPath:
                Text(workbenchText("请先连接设备所在的局域网，再重新发现。", "Connect to the same local network as the devices, then scan again.", locale))
                    .foregroundStyle(.secondary).accessibilityIdentifier("toolbox.lan.status")
            case .outOfScopeOnly:
                Text(workbenchText("保存的查找范围暂不受支持，请重新选择范围。", "The saved discovery scope is not supported. Choose another scope.", locale))
                    .foregroundStyle(.secondary).accessibilityIdentifier("toolbox.lan.status")
                Button(workbenchText("使用全部设备", "Use all devices", locale)) { model.lanConfiguration.preset = .all }
            }
        } else if model.running {
            Text(workbenchText("已发现 \(model.lanServices.count) 项，正在继续查找与解析地址。", "Found \(model.lanServices.count) results. Still discovering and resolving addresses.", locale))
                .foregroundStyle(.secondary).accessibilityIdentifier("toolbox.lan.status")
        } else if model.failure == nil {
            Text(workbenchText("选择范围后开始发现。", "Choose a scope, then find devices.", locale)).foregroundStyle(.secondary)
                .accessibilityIdentifier("toolbox.lan.status")
        }
    }
    private func endpoint(_ service: LANDiscoveredService) -> (String, UInt16)? {
        guard service.resolved, let host = DiagnosticWorkbenchModel.normalizedTarget(service.displayAddress), let port = service.port, let value = UInt16(exactly: port), value > 0 else { return nil }
        return (host, value)
    }
    private func endpointLabel(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
    private func icon(_ type: String) -> String {
        switch type {
        case "_ipp._tcp", "_ipps._tcp", "_printer._tcp": "printer"
        case "_uscan._tcp": "scanner"
        case "_airplay._tcp", "_googlecast._tcp": "airplay.video"
        case "_raop._tcp": "hifispeaker"
        case "_hap._tcp", "_home-assistant._tcp": "house"
        case "_http._tcp", "_https._tcp": "globe"
        default: "desktopcomputer"
        }
    }
}
