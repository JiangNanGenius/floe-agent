// FloeCore — pure layout/typography model for list surfaces.
//
// Persisted user choices for file/asset/layer list typography and the iPad
// sidebar width. Kept free of UIKit so the formatting rules are unit-testable
// and identical for every list surface.

import Foundation

public enum LayoutListKind: String, CaseIterable, Codable, Sendable {
    case files
    case assets
    case layers

    public var titleZH: String {
        switch self {
        case .files: "文件"
        case .assets: "素材"
        case .layers: "图层"
        }
    }

    public var titleEN: String {
        switch self {
        case .files: "Files"
        case .assets: "Assets"
        case .layers: "Layers"
        }
    }
}

public enum LayoutListFontSize: String, CaseIterable, Codable, Sendable {
    case small
    case normal
    case large

    /// Point size applied to list primary text. Independent of code/terminal
    /// and document fonts by design.
    public var pointSize: Double {
        switch self {
        case .small: 12
        case .normal: 14
        case .large: 17
        }
    }

    public var titleZH: String {
        switch self {
        case .small: "小"
        case .normal: "标准"
        case .large: "大"
        }
    }

    public var titleEN: String {
        switch self {
        case .small: "Small"
        case .normal: "Normal"
        case .large: "Large"
        }
    }
}

/// File-name display rules: 1 or 2 lines, the extension always visible, an
/// optional full path line, and middle truncation that keeps the extension.
public enum FileNameDisplay {
    public static let maximumLines = 2

    /// Returns 1...2 display lines. Line 0 is the (possibly middle-truncated)
    /// file name with its extension preserved; line 1 is the relative path when
    /// requested and available.
    public static func lines(fileName: String,
                             relativePath: String? = nil,
                             lineCount: Int,
                             showPath: Bool,
                             maximumLength: Int = 48) -> [String] {
        let clampedLines = min(max(lineCount, 1), maximumLines)
        let name = middleTruncated(fileName, limit: maximumLength)
        guard clampedLines == 2 else { return [name] }
        guard showPath,
              let path = relativePath,
              !path.isEmpty,
              path != fileName else {
            return [name]
        }
        // The path line keeps the file name or directory tail readable.
        let tail = path.split(separator: "/").suffix(3).joined(separator: "/")
        return [name, middleTruncated(tail, limit: maximumLength + 12)]
    }

    /// Truncates the middle, preserving both the start and the extension.
    public static func middleTruncated(_ value: String, limit: Int) -> String {
        guard limit > 4, value.count > limit else { return value }
        let ns = value as NSString
        let extensionPart = ns.pathExtension
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        let headBudget = max(1, limit - suffix.count - 1)
        let head = ns.deletingPathExtension.prefix(headBudget)
        return "\(head)…\(suffix)"
    }

    /// True when two visible list entries share the same base name, so the UI
    /// can surface a same-name hint instead of appearing to duplicate a file.
    public static func hasSameNameConflict(_ name: String, among others: [String]) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return others.contains { other in
            other != name
                && (other as NSString).deletingPathExtension.lowercased() == base
        }
    }
}

/// Persisted layout values with explicit bounds. Stored through UserDefaults by
/// the app layer; this value type owns the defaults and clamping rules.
public struct LayoutSettings: Sendable, Equatable {
    public static let sidebarMinimumWidth: Double = 260
    public static let sidebarMaximumWidth: Double = 460
    public static let sidebarDefaultWidth: Double = 320

    public var fontSizes: [LayoutListKind: LayoutListFontSize]
    public var fileNameLines: Int
    public var showFullPath: Bool
    public var showFileExtension: Bool
    public var sidebarWidth: Double

    public init(fontSizes: [LayoutListKind: LayoutListFontSize] = [:],
                fileNameLines: Int = 1,
                showFullPath: Bool = false,
                showFileExtension: Bool = true,
                sidebarWidth: Double = LayoutSettings.sidebarDefaultWidth) {
        self.fontSizes = fontSizes
        self.fileNameLines = min(max(fileNameLines, 1), FileNameDisplay.maximumLines)
        self.showFullPath = showFullPath
        self.showFileExtension = showFileExtension
        self.sidebarWidth = min(max(sidebarWidth,
                                    LayoutSettings.sidebarMinimumWidth),
                                LayoutSettings.sidebarMaximumWidth)
    }

    public func fontSize(for kind: LayoutListKind) -> LayoutListFontSize {
        fontSizes[kind] ?? .normal
    }

    public mutating func setFontSize(_ size: LayoutListFontSize, for kind: LayoutListKind) {
        fontSizes[kind] = size
    }
}
