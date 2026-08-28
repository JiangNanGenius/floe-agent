import Foundation

public enum CanvasDoubleTapAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case toggleEraser
    case showToolPalette
    case createCard

    public var id: String { rawValue }
}

public enum CanvasInkUnderstandingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case text
    case cards
    case diagram

    public var id: String { rawValue }
}

/// User-facing Canvas defaults. Model routing remains in
/// `ModelSelectionPreferences` because those identifiers participate in the
/// existing configuration sync and foreign-key lifecycle.
public struct CanvasPreferences: Codable, Sendable, Equatable {
    public static let defaultsKey = "creative.canvas.preferences.v1"

    public var pencilWidth: Double
    public var pencilColor: String
    public var fingerDrawingEnabled: Bool
    public var doubleTapAction: CanvasDoubleTapAction
    public var showGrid: Bool
    public var snapToGrid: Bool
    public var preserveInkAfterConversion: Bool
    public var understandingMode: CanvasInkUnderstandingMode

    public init(
        pencilWidth: Double = 3,
        pencilColor: String = "primary",
        fingerDrawingEnabled: Bool = false,
        doubleTapAction: CanvasDoubleTapAction = .toggleEraser,
        showGrid: Bool = true,
        snapToGrid: Bool = false,
        preserveInkAfterConversion: Bool = true,
        understandingMode: CanvasInkUnderstandingMode = .automatic
    ) {
        self.pencilWidth = pencilWidth
        self.pencilColor = pencilColor
        self.fingerDrawingEnabled = fingerDrawingEnabled
        self.doubleTapAction = doubleTapAction
        self.showGrid = showGrid
        self.snapToGrid = snapToGrid
        self.preserveInkAfterConversion = preserveInkAfterConversion
        self.understandingMode = understandingMode
    }

    public static func load(from defaults: UserDefaults = .standard) -> CanvasPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(CanvasPreferences.self, from: data)
        else { return CanvasPreferences() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
