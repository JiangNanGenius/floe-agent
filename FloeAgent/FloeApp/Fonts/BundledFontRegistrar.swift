// FloeApp — Bundled font registration.
//
// scripts/fonts/fetch_fonts.py stages the curated open-license families into
// FloeApp/Resources/Fonts/Bundled, which project.yml embeds as a folder
// reference. Registering them process-wide makes the families available to
// every CoreText/WebKit surface (PDF editing, image drawing, HTML preview),
// while the LibreOffice engine receives its own copy under the app-level
// Fonts/ directory via embed_office_host.py.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreText

enum BundledFontRegistrar {
    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// Registers every staged font for this process. Missing directories are
    /// not an error: local developer builds may legitimately skip the font
    /// fetch, while CI/release builds enforce presence via --check.
    static func activateBundledFonts() -> [String] {
        let root = Bundle.main.bundleURL.appendingPathComponent("Bundled", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var failures: [String] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var error: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
                // CoreText reports an already-registered font as false. If the
                // file still yields descriptors, it is usable — not a fault.
                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL),
                   CFArrayGetCount(descriptors) > 0 {
                    continue
                }
                failures.append(url.lastPathComponent)
                continue
            }
        }
        return failures
    }
}
#endif
