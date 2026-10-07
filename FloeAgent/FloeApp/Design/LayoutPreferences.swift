// FloeApp — persisted layout preferences (Build265).
//
// Wraps the pure `LayoutSettings` model with UserDefaults persistence. List
// typography (files/assets/layers) is independent of code/terminal/document
// fonts, and the iPad sidebar width is persisted within explicit min/max.

import Foundation
import FloeCore
import SwiftUI

@MainActor
final class LayoutPreferences: ObservableObject {
    static let shared = LayoutPreferences()

    @Published private(set) var settings: LayoutSettings

    private enum Keys {
        static let fontPrefix = "floe.layout.listFont."
        static let fileNameLines = "floe.layout.fileNameLines"
        static let showFullPath = "floe.layout.showFullPath"
        static let showFileExtension = "floe.layout.showFileExtension"
        static let sidebarWidth = "floe.layout.sidebarWidth"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var fontSizes: [LayoutListKind: LayoutListFontSize] = [:]
        for kind in LayoutListKind.allCases {
            if let raw = defaults.string(forKey: Keys.fontPrefix + kind.rawValue),
               let size = LayoutListFontSize(rawValue: raw) {
                fontSizes[kind] = size
            }
        }
        let storedLines = defaults.object(forKey: Keys.fileNameLines) as? Int ?? 1
        let storedWidth = defaults.object(forKey: Keys.sidebarWidth) as? Double
            ?? LayoutSettings.sidebarDefaultWidth
        self.settings = LayoutSettings(
            fontSizes: fontSizes,
            fileNameLines: storedLines,
            showFullPath: defaults.bool(forKey: Keys.showFullPath),
            showFileExtension: defaults.object(forKey: Keys.showFileExtension) as? Bool ?? true,
            sidebarWidth: storedWidth)
    }

    func setFontSize(_ size: LayoutListFontSize, for kind: LayoutListKind) {
        settings.setFontSize(size, for: kind)
        defaults.set(size.rawValue, forKey: Keys.fontPrefix + kind.rawValue)
        objectWillChange.send()
    }

    func setFileNameLines(_ lines: Int) {
        settings.fileNameLines = min(max(lines, 1), FileNameDisplay.maximumLines)
        defaults.set(settings.fileNameLines, forKey: Keys.fileNameLines)
        objectWillChange.send()
    }

    func setShowFullPath(_ value: Bool) {
        settings.showFullPath = value
        defaults.set(value, forKey: Keys.showFullPath)
        objectWillChange.send()
    }

    func setShowFileExtension(_ value: Bool) {
        settings.showFileExtension = value
        defaults.set(value, forKey: Keys.showFileExtension)
        objectWillChange.send()
    }

    func setSidebarWidth(_ width: Double) {
        let clamped = min(max(width, LayoutSettings.sidebarMinimumWidth),
                          LayoutSettings.sidebarMaximumWidth)
        guard abs(clamped - settings.sidebarWidth) > 2 else { return }
        settings.sidebarWidth = clamped
        defaults.set(clamped, forKey: Keys.sidebarWidth)
        objectWillChange.send()
    }

    /// Display lines for a file name according to the persisted options.
    func fileDisplayLines(name: String, relativePath: String?) -> [String] {
        var displayName = name
        if !settings.showFileExtension {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { displayName = (name as NSString).deletingPathExtension }
        }
        return FileNameDisplay.lines(fileName: displayName,
                                     relativePath: relativePath,
                                     lineCount: settings.fileNameLines,
                                     showPath: settings.showFullPath)
    }
}
