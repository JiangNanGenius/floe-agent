import AppKit
import SwiftUI
import FloeToolboxWorkbenches
import FloeMacMediaUI
import FloeToolboxCore
import FloeToolboxUI
import FloeMacInstruments
import FloeMacNetwork
import FloeMacTerminal
import FloeMacVNC

enum MacToolboxAvailability {
    static let available: Set<ToolboxTool> = Set([.hash, .json, .encoding, .calculator, .qr,
        .ruler, .photoMeasure, .location, .timer, .magnifier, .browser, .sound, .scanner,
        .http, .webSocket, .mqtt, .serialAssistant, .terminal, .vnc]).union(MacToolboxNetworkScope.tools)

    static func groupTitle(_ group: ToolboxGroup, locale: Locale) -> String {
        switch group {
        case .instruments: MacToolboxText.t("测量与定位", "Measure and explore", locale)
        case .connections: MacToolboxText.t("终端与远程", "Terminal and remote", locale)
        case .diagnostics: MacToolboxText.t("网络诊断", "Network diagnostics", locale)
        case .communication: MacToolboxText.t("通信工具", "Communication tools", locale)
        case .utilities: MacToolboxText.utilities(locale)
        }
    }
}

public enum MacToolboxCatalog {
    public static var availableTools: Set<ToolboxTool> { MacToolboxAvailability.available }

    public static func isAvailable(toolID: String) -> Bool {
        guard let tool = ToolboxTool(rawValue: toolID) else { return false }
        return availableTools.contains(tool)
    }

    public struct Tool: Identifiable {
        public let id: String
        public let title: String
        public let symbol: String
        public let isAvailable: Bool
    }

    public struct Group: Identifiable {
        public let id: String
        public let title: String
        public let tools: [Tool]
    }

    public static func groups(locale: Locale) -> [Group] {
        ToolboxGroup.allCases.map { group in
            Group(id: group.rawValue, title: MacToolboxAvailability.groupTitle(group, locale: locale),
                  tools: ToolboxTool.allCases.filter { $0.group == group }.map { tool in
                Tool(id: tool.rawValue, title: tool.title(in: locale), symbol: tool.symbol,
                     isAvailable: MacToolboxAvailability.available.contains(tool))
            })
        }
    }
}

public struct MacToolboxDirectory: View {
    @Binding private var search: String
    private let openTool: (String) -> Void

    public init(search: Binding<String>, openTool: @escaping (String) -> Void) {
        _search = search
        self.openTool = openTool
    }

    public var body: some View {
        ToolboxHomeView(
            availability: Dictionary(uniqueKeysWithValues: MacToolboxCatalog.availableTools.map { ($0, .available) }),
            showsAssistantAvailability: false, search: $search,
            featuredTools: [.terminal, .browser, .calculator, .scanner]
        ) { openTool($0.rawValue) }
    }
}

@MainActor
fileprivate final class MacToolboxSelection: ObservableObject {
    private static let defaultsKey = "floe.mac.toolbox.selectedTool"
    private let preferences: UserDefaults
    @Published private(set) var tool: ToolboxTool

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let stored = preferences.string(forKey: Self.defaultsKey).flatMap(ToolboxTool.init(rawValue:))
        if let stored, MacToolboxCatalog.availableTools.contains(stored) {
            tool = stored
        } else {
            tool = .hash
        }
    }

    func select(_ tool: ToolboxTool) {
        guard self.tool != tool, MacToolboxCatalog.availableTools.contains(tool) else { return }
        self.tool = tool
        preferences.set(tool.rawValue, forKey: Self.defaultsKey)
    }
}

/// The toolbox is an auxiliary window in the existing Floe Mac app, not a
/// second product. The host owns `MacToolboxServices`; the window observes it.
public struct MacToolboxWindow: View {
    @ObservedObject private var services: MacToolboxServices
    @StateObject private var selectedTool: MacToolboxSelection
    @Environment(\.locale) private var locale

    public init(services: MacToolboxServices) {
        self.init(services: services, selectedTool: MacToolboxSelection())
    }

    fileprivate init(services: MacToolboxServices, selectedTool: MacToolboxSelection) {
        self.services = services
        _selectedTool = StateObject(wrappedValue: selectedTool)
    }

    private var selection: Binding<ToolboxTool?> {
        Binding(
            get: { selectedTool.tool },
            set: { selectedTool.select($0 ?? .hash) }
        )
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(ToolboxGroup.allCases, id: \.rawValue) { group in
                    let tools = ToolboxTool.allCases.filter { $0.group == group && MacToolboxCatalog.availableTools.contains($0) }
                    if !tools.isEmpty {
                        Section(MacToolboxAvailability.groupTitle(group, locale: locale)) {
                            ForEach(tools) { tool in
                                Label(tool.title(in: locale), systemImage: tool.symbol)
                                    .tag(Optional(tool))
                                    .accessibilityIdentifier("mac.toolbox.sidebar.\(tool.rawValue)")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .disabled(services.isClosing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle((selection.wrappedValue ?? .hash).title(in: locale))
                .navigationSubtitle(MacToolboxText.windowTitle(locale))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 940, minHeight: 620)
        .task { await services.start() }
    }

    @ViewBuilder private var detail: some View {
        switch selection.wrappedValue ?? .hash {
        case .terminal:
            MacTerminalToolView(session: services.terminalSession)
        case .vnc:
            MacVNCToolView(owner: services.vncOwner)
        case .browser:
            MacBrowserToolView()
        case .hash:
            MacHashToolView(
                selectFile: { try await MacToolboxFilePanels.chooseChecksumFile(locale: locale) }
            )
        case .json:
            MacTextToolView(mode: .json)
        case .encoding:
            MacTextToolView(mode: .encoding)
        case .qr:
            MacQRToolView(locale: locale, mediaEnvironment: services.mediaEnvironment)
        case .magnifier:
            MacToolboxMagnifierView(environment: services.mediaEnvironment)
        case .scanner:
            MacToolboxScannerView(environment: services.mediaEnvironment)
        case .sound:
            MacToolboxSoundView(environment: services.mediaEnvironment)
        case .calculator:
            MacCalculatorToolView(historyCoordinator: services.calculatorHistoryCoordinator)
        case .ruler:
            MacRulerInstrumentView(model: services.instrumentModels.ruler)
        case .photoMeasure:
            MacPhotoMeasureView(model: services.instrumentModels.photo)
        case .location:
            MacLocationInstrumentView(model: services.instrumentModels.location)
        case .ping, .traceroute, .dns, .port, .lan, .wifi, .roaming:
            if let tool = selection.wrappedValue {
                MacNetworkToolView(tool: tool, owner: services.networkOwner).id(tool.rawValue)
            }
        case .http, .webSocket, .mqtt, .serialAssistant:
            if let tool = selection.wrappedValue {
                MacCommunicationToolView(tool: tool, owner: services.communicationOwner).id(tool.rawValue)
            }
        case .timer:
            MacSilentTimerView(service: services.silentTimekeeping())
        case .level, .motion, .compass, .measure, .barometer:
            EmptyView()
        }
    }
}

@MainActor
public final class MacToolboxWindowController: NSWindowController {
    public let services: MacToolboxServices
    private let selectedTool: MacToolboxSelection

    public init(services: MacToolboxServices, autosavesFrame: Bool = true, preferences: UserDefaults = .standard) {
        self.services = services
        let selectedTool = MacToolboxSelection(preferences: preferences)
        self.selectedTool = selectedTool
        let hosting = NSHostingController(rootView: MacToolboxWindow(services: services, selectedTool: selectedTool))
        let window = NSWindow(contentViewController: hosting)
        window.title = MacToolboxText.windowTitle(.current)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_120, height: 760))
        window.minSize = NSSize(width: 940, height: 620)
        window.isReleasedWhenClosed = false
        if autosavesFrame { window.setFrameAutosaveName("FloeMacToolboxWindow") }
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func present() {
        present(toolID: nil)
    }

    public func present(toolID: String?) {
        if let toolID {
            guard let tool = ToolboxTool(rawValue: toolID), MacToolboxAvailability.available.contains(tool) else { return }
            selectedTool.select(tool)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// AppKit menu item for the existing manual main menu. The host owns the
/// action and retains the window controller.
@MainActor
public enum MacToolboxMenu {
    public static func makeItem(locale: Locale, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: MacToolboxText.windowTitle(locale), action: action, keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = target
        return item
    }
}
