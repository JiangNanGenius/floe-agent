import Foundation

/// Public tool identifiers used by the editor UI and host feature-gating configuration.
public enum ToolEnum: Int, CaseIterable, Identifiable, Codable, Sendable {

    // MARK: - Public Properties

    case cut = 0
    case speed = 1
    case presets = 2
    case audio = 3
    case transcript = 4
    case adjusts = 6

    /// Stable identifier for SwiftUI lists and selection.
    public var id: Int {
        rawValue
    }

    /// The set of tools exposed by default in the editor tray.
    public static var all: [ToolEnum] {
        allCases
            .filter { $0 != .cut }
            .sorted { $0.order < $1.order }
    }

    public var order: Int {
        switch self {
        case .transcript: 0
        case .presets: 1
        case .audio: 2
        case .adjusts: 3
        case .speed: 4
        case .cut: 5
        }
    }

    /// Human-readable tool title shown by the package UI.
    public var title: String {
        switch self {
        case .cut: VideoEditorStrings.toolCut
        case .speed: VideoEditorStrings.toolSpeed
        case .presets: VideoEditorStrings.toolPresets
        case .audio: VideoEditorStrings.toolAudio
        case .transcript: VideoEditorStrings.toolTranscript
        case .adjusts: VideoEditorStrings.toolAdjusts
        }
    }

    /// SF Symbol name used by the default package UI.
    public var image: String {
        switch self {
        case .cut: "scissors"
        case .speed: "timer"
        case .presets: "aspectratio"
        case .audio: "waveform"
        case .transcript: "captions.bubble"
        case .adjusts: "circle.righthalf.filled"
        }
    }

}

/// Describes whether a tool should be enabled or blocked in the host app UI.
public struct ToolAvailability: Hashable, Identifiable {

    // MARK: - Public Properties

    /// Access mode used by the host app for a tool entry.
    public enum Access: Hashable {
        case enabled
        case blocked
    }

    /// The tool being configured.
    public let tool: ToolEnum
    /// Whether the tool is enabled or visible-but-blocked.
    public let access: Access
    /// Relative ordering used by the editor tray.
    public let order: Int

    /// Stable identifier for SwiftUI collections.
    public var id: ToolEnum {
        tool
    }

    public var isBlocked: Bool {
        access == .blocked
    }

    public var isEnabled: Bool {
        access == .enabled
    }

    // MARK: - Initializer

    /// Creates a tool-availability entry with optional custom ordering.
    public init(
        _ tool: ToolEnum,
        access: Access = .enabled,
        order: Int? = nil
    ) {
        self.tool = tool
        self.access = access
        self.order = order ?? tool.order
    }

    /// Convenience constructor for an enabled tool.
    public static func enabled(
        _ tool: ToolEnum,
        order: Int? = nil
    ) -> Self {
        .init(tool, order: order)
    }

    /// Convenience constructor for a blocked tool.
    public static func blocked(
        _ tool: ToolEnum,
        order: Int? = nil
    ) -> Self {
        .init(tool, access: .blocked, order: order)
    }

    /// Maps a list of tools into enabled availability entries.
    public static func enabled(_ tools: [ToolEnum]) -> [Self] {
        tools.map { Self.enabled($0) }
    }

}
