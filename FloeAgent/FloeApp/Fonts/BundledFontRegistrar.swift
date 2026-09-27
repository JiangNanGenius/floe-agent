// FloeApp — Bundled font registration.
//
// scripts/fonts/fetch_fonts.py stages the curated open-license families into
// FloeApp/Resources/Fonts/Bundled, which project.yml embeds as a folder
// reference. Registering them process-wide makes the families available to
// every CoreText/WebKit surface (PDF editing, image drawing, HTML preview) and
// to the embedded Office engine, whose quartz backend asks CoreText for the
// process's available fonts (GetCoretextFontList) and can not see files by
// existence alone. scripts/embed_office_host.py additionally stages the same
// families into the engine-scanned internal font directory so the engine
// registers them itself at font-discovery time.
//
// Registration success is verified by real resolution — not by the font file
// yielding descriptors, which is true even for a font that was never
// registered.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreText

enum BundledFontRegistrar {
    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// Content-free discovery summary for one staged font root. Counts and
    /// file names only: never document text or file contents.
    struct DiscoveryReport: Equatable, Sendable {
        let stagedFiles: Int
        let parsedFiles: Int
        let resolvedFiles: Int
        /// File names (no paths) of staged fonts this process can not resolve.
        let unresolvedFiles: [String]
    }

    private static func stagedFontURLs(in root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Registers every staged font for this process. Missing directories are
    /// not an error: local developer builds may legitimately skip the font
    /// fetch, while CI/release builds enforce presence via --check.
    ///
    /// The returned list contains only fonts this process still can not
    /// resolve after the attempt — a registration failure whose font is truly
    /// unusable — never a font that merely reported a duplicate registration.
    static func activateBundledFonts() -> [String] {
        let root = Bundle.main.bundleURL.appendingPathComponent("Bundled", isDirectory: true)
        let staged = stagedFontURLs(in: root)
        guard !staged.isEmpty else { return [] }
        var failures = Set<String>()
        for url in staged {
            let (outcome, _) = CoreTextFontRegistration.register(url: url)
            if outcome == .failed { failures.insert(url.lastPathComponent) }
        }
        // Independently verify discovery: a font that still does not resolve
        // after its registration attempt is a real failure for every surface
        // that asks CoreText for available fonts.
        for name in discoveryReport(in: root).unresolvedFiles {
            failures.insert(name)
        }
        return failures.sorted()
    }

    /// Verifies what this process can really resolve, per staged font file.
    /// Used by the App's startup diagnostics and by tests: a file existing (or
    /// parsing) is deliberately not counted as discovered.
    static func discoveryReport(in root: URL) -> DiscoveryReport {
        let staged = stagedFontURLs(in: root)
        var parsed = 0
        var resolved = 0
        var unresolved: [String] = []
        for url in staged {
            let names = CoreTextFontRegistration.declaredPostScriptNames(at: url)
            if !names.isEmpty { parsed += 1 }
            if names.contains(where: CoreTextFontRegistration.resolves(postScriptName:)) {
                resolved += 1
            } else {
                unresolved.append(url.lastPathComponent)
            }
        }
        return DiscoveryReport(stagedFiles: staged.count,
                               parsedFiles: parsed,
                               resolvedFiles: resolved,
                               unresolvedFiles: unresolved)
    }
}
#endif
