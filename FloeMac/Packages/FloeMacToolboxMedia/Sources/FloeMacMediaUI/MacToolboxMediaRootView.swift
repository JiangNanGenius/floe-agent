import SwiftUI
import FloeMacMediaSystem

/// Review-only entry surface for the three candidate tools. It is not added to
/// any Xcode target and does not create a second installable product; the future
/// Mac App should route its existing toolbox destinations here.
public enum MacToolboxMediaTool: String, CaseIterable, Identifiable, Hashable {
    case sound
    case magnifier
    case scanner

    public var id: String { rawValue }

    func title(_ locale: Locale) -> String {
        switch self {
        case .sound: macToolboxText("声音分析", "Sound Analyzer", locale)
        case .magnifier: macToolboxText("放大镜", "Magnifier", locale)
        case .scanner: macToolboxText("扫描与识别", "Scanner", locale)
        }
    }

    var systemImage: String {
        switch self {
        case .sound: "waveform"
        case .magnifier: "magnifyingglass"
        case .scanner: "doc.viewfinder"
        }
    }
}

@MainActor
public struct MacToolboxMediaRootView: View {
    private let environment: MacToolboxMediaEnvironment
    @State private var selection: MacToolboxMediaTool?

    @Environment(\.locale) private var locale

    public init(environment: MacToolboxMediaEnvironment? = nil) {
        self.environment = environment ?? .shared
        _selection = State(initialValue: .sound)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(MacToolboxMediaTool.allCases) { tool in
                        Label(tool.title(locale), systemImage: tool.systemImage)
                            .tag(tool)
                    }
                } header: {
                    Text(macToolboxText("工具箱（候选）", "Toolbox (candidate)", locale))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            NavigationStack {
                switch selection {
                case .sound: MacToolboxSoundView(environment: environment)
                case .magnifier: MacToolboxMagnifierView(environment: environment)
                case .scanner: MacToolboxScannerView(environment: environment)
                case nil:
                    Text(macToolboxText("选择一项工具", "Choose a tool", locale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
