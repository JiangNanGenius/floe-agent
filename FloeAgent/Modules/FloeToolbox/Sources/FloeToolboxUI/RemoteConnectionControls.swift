import SwiftUI
import FloeToolboxCore
import FloeToolboxRemoteFiles

public struct RemoteFileProtocolPicker: View {
    @Environment(\.locale) private var toolboxLocale
    private func connectionText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @Binding private var transport: RemoteFileProtocol
    @Binding private var ftpsMode: FTPSTLSMode
    public init(transport: Binding<RemoteFileProtocol>, ftpsMode: Binding<FTPSTLSMode>) { _transport = transport; _ftpsMode = ftpsMode }
    public var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker(connectionText("连接方式","Connection"),selection:$transport) {
                ForEach(RemoteFileProtocol.allCases,id:\.self) { item in Text(item == .webDAV ? "WebDAV" : item.rawValue.uppercased()).tag(item) }
            }
            if transport == .ftps {
                Picker(connectionText("TLS 模式","TLS mode"),selection:$ftpsMode) {
                    Text(connectionText("显式 TLS","Explicit TLS")).tag(FTPSTLSMode.explicit)
                    Text(connectionText("隐式 TLS","Implicit TLS")).tag(FTPSTLSMode.implicit)
                }
            }
            if transport == .ftp { Text(connectionText("FTP 连接未加密。","FTP connections are unencrypted.")).font(.caption).foregroundStyle(.secondary) }
            if transport == .scp { Text(connectionText("SCP 用于文件传输，目录浏览请使用 SFTP。","SCP transfers files. Use SFTP to browse folders.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

public struct ToolboxMachineChoice: Identifiable, Sendable {
    public let id: MachineReference
    public let title: String
    public let detail: String
    public let supportsTerminal: Bool
    public let supportsVNC: Bool
    public init(id: MachineReference, title: String, detail: String, supportsTerminal: Bool, supportsVNC: Bool) {
        self.id = id; self.title = title; self.detail = detail; self.supportsTerminal = supportsTerminal; self.supportsVNC = supportsVNC
    }
}
public enum ToolboxRemoteTargetKind: Sendable { case terminal, vnc }
/// Read the host's actual environment and saved-machine owners; do not infer VNC from an SSH port.
public struct ToolboxMachinePicker: View {
    @Environment(\.locale) private var toolboxLocale
    private func connectionText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let kind: ToolboxRemoteTargetKind
    private let machines: [ToolboxMachineChoice]
    private let onSelect: (MachineReference) -> Void
    private let onTemporary: () -> Void
    private let onSettings: () -> Void
    public init(kind: ToolboxRemoteTargetKind, machines: [ToolboxMachineChoice], onSelect: @escaping (MachineReference) -> Void,
                onTemporary: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.kind = kind; self.machines = machines; self.onSelect = onSelect; self.onTemporary = onTemporary; self.onSettings = onSettings
    }
    public var body: some View {
        List {
            if kind == .terminal { choices(connectionText("内置环境","Built-in environment"),matching:0) }
            choices(connectionText("系统环境","System environments"),matching:1)
            choices(connectionText("我的机器","My machines"),matching:2)
            Section {
                Button(connectionText("临时连接","Temporary connection"),systemImage:"plus") { onTemporary() }
                Button(connectionText("去设置添加运行环境","Add an environment in Settings"),systemImage:"gearshape") { onSettings() }
            }
        }
    }
    @ViewBuilder private func choices(_ title: String, matching group: Int) -> some View {
        let items = machines.filter { item in
            guard kind == .terminal ? item.supportsTerminal : item.supportsVNC else { return false }
            switch item.id {
            case .builtIn: return group == 0 && kind == .terminal
            case .systemEnvironment: return group == 1
            case .toolboxMachine: return group == 2
            case .temporary: return false
            }
        }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { onSelect(item.id) } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text(item.title).foregroundStyle(.primary)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight:44)
                    }
                }
            }
        }
    }
}

public enum VNCInteractionMode: String, Hashable, Sendable { case mouse, touch }
public enum VNCDisplayScale: String, Hashable, Sendable { case fit, actualSize }
public enum VNCToolbarAction: Sendable { case keyboard, secureAttention, reconnect, disconnect }
/// Viewer controls only; remote input is delivered by the existing VNC session owner. No AI dependency.
public struct VNCToolboxControls: View {
    @Environment(\.locale) private var toolboxLocale
    private func connectionText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @Binding private var interaction: VNCInteractionMode
    @Binding private var scale: VNCDisplayScale
    private let onAction: (VNCToolbarAction) -> Void
    public init(interaction: Binding<VNCInteractionMode>, scale: Binding<VNCDisplayScale>, onAction: @escaping (VNCToolbarAction) -> Void) {
        _interaction = interaction; _scale = scale; self.onAction = onAction
    }
    public var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack { mode; controls }
            VStack(alignment:.leading) { mode; HStack { controls } }
        }
    }
    private var mode: some View {
        Picker(connectionText("交互方式","Interaction"),selection:$interaction) {
            Text(connectionText("鼠标","Mouse")).tag(VNCInteractionMode.mouse)
            Text(connectionText("触控","Touch")).tag(VNCInteractionMode.touch)
        }.pickerStyle(.segmented)
    }
    private var controls: some View {
        Group {
            Picker(connectionText("缩放","Zoom"),selection:$scale) {
                Text(connectionText("适应窗口","Fit window")).tag(VNCDisplayScale.fit)
                Text(connectionText("实际大小","Actual size")).tag(VNCDisplayScale.actualSize)
            }
            Button(connectionText("键盘","Keyboard"),systemImage:"keyboard") { onAction(.keyboard) }
            Menu(connectionText("更多","More"),systemImage:"ellipsis") {
                Button("Ctrl–Alt–Delete") { onAction(.secureAttention) }
                Button(connectionText("重新连接","Reconnect")) { onAction(.reconnect) }
                Button(connectionText("断开连接","Disconnect"),role:.destructive) { onAction(.disconnect) }
            }
        }
    }
}
