// Floe Mac M00 — role name and icon presentation.
//
// SPDX-License-Identifier: MPL-2.0
//
// The install name (Finder) and CFBundleName stay fixed. M00 verifies the
// runtime window title and NSApplication.applicationIconImage only. A
// role-specific Dock display name needs a pre-signed role entry and is not
// claimed here.

import AppKit
import Foundation

struct RolePresentationSnapshot: Equatable, Sendable {
    var mode: AppMode
    var windowTitle: String
    var iconResource: String
    var iconLoaded: Bool
    var iconPixelSize: String?
    var applicationIconSet: Bool
}

@MainActor
enum RolePresentation {
    static func apply(_ mode: AppMode, window: NSWindow?) -> RolePresentationSnapshot {
        let image = loadIcon(mode: mode)
        if let image {
            // The Dock reads this image from the application object.
            NSApplication.shared.applicationIconImage = image
        }
        window?.title = mode.displayName
        window?.subtitle = "M00"
        let hasIcon = NSApplication.shared.applicationIconImage != nil
        return RolePresentationSnapshot(
            mode: mode,
            windowTitle: window?.title ?? mode.displayName,
            iconResource: mode.iconResourceName,
            iconLoaded: image != nil,
            iconPixelSize: image.map { "\(Int($0.size.width))x\(Int($0.size.height))" },
            applicationIconSet: hasIcon
        )
    }

    static func loadIcon(mode: AppMode) -> NSImage? {
        guard let url = Bundle.main.url(forResource: mode.iconResourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 128, height: 128)
        return image
    }

    static func aboutPanelOptions(for mode: AppMode) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: mode.displayName,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: NSAttributedString(
                string: String(localized: "host.details.m00"),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ]
        if let icon = loadIcon(mode: mode) {
            options[.applicationIcon] = icon
        }
        return options
    }
}
