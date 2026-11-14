// FloeApp — Bundled font registration.
//
// scripts/fonts/fetch_fonts.py stages the curated open-license families into
// FloeApp/Resources/Fonts/Bundled. The App build's post-build step
// (scripts/embed_office_host.py) then places exactly one physical copy of each
// font in the engine-scanned program/resource/common/fonts directory and
// removes the packaged font binaries from Bundled/; only the per-family
// LICENSE.txt/provenance.json files stay there.
//
// This registrar therefore registers the same single copy the engine discovers
// itself. Registering process-wide makes the families available to every
// CoreText/WebKit surface (PDF editing, image drawing, HTML preview) and to
// the embedded Office engine, whose quartz backend asks CoreText for the
// process's available fonts (GetCoretextFontList) and can not see files by
// existence alone. The old Bundled/ root remains a fallback for hosts built
// without the post-build step (for example a narrow developer harness); the
// shipping App build must contain no font binaries there and the
// verify_font_single_copy.py gate checks that.
//
// Registration success is verified by real resolution — not by the font file
// yielding descriptors, which is true even for a font that was never
// registered.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreText

struct BundledFontFace: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

struct BundledFontFamily: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let faces: [BundledFontFace]
    let byteCount: Int64
}

enum FontManagementItemID: Hashable, Sendable {
    case design(UUID), imported(String), bundled(String)
    var canDelete: Bool {
        if case .bundled = self { return false }
        return true
    }
}

struct FontManagementSelection: Equatable, Sendable {
    private(set) var items = Set<FontManagementItemID>()
    mutating func toggle(_ item: FontManagementItemID) {
        guard item.canDelete else { return }
        if !items.insert(item).inserted { items.remove(item) }
    }
    mutating func selectAll(_ available: Set<FontManagementItemID>) {
        items = available.filter(\.canDelete)
    }
    mutating func retainAvailable(_ available: Set<FontManagementItemID>) {
        items.formIntersection(available.filter(\.canDelete))
    }
    mutating func clear() { items.removeAll() }
}

enum BundledFontRegistrar {
    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// The engine-scanned directory first, then the historical App-resource
    /// folder. `existingFontRoots` is what the App actually registers; the
    /// order is part of the packaging contract (and is asserted by the font
    /// packaging contract test).
    static func fontRoots(in appRoot: URL) -> [URL] {
        [
            appRoot.appendingPathComponent("program/resource/common/fonts", isDirectory: true),
            appRoot.appendingPathComponent("Bundled", isDirectory: true),
        ]
    }

    /// Existing candidate roots, in registration order. Missing directories
    /// are not an error: local developer builds may legitimately skip the font
    /// fetch, while CI/release builds enforce presence via --check.
    static func existingFontRoots(in appRoot: URL) -> [URL] {
        fontRoots(in: appRoot).filter { root in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// The same real files the process registers, grouped into families. Never
    /// enumerate all system fonts or treat the old fallback copy as another
    /// installed typeface. PostScript identity deduplicates files/collections.
    static func families(in appRoot: URL) -> [BundledFontFamily] {
        var seen = Set<String>()
        var faces: [String: [BundledFontFace]] = [:]
        var names: [String: String] = [:]
        var files: [String: [URL: Int64]] = [:]
        for url in existingFontRoots(in: appRoot).flatMap({ stagedFontURLs(in: $0).sorted { $0.path < $1.path } }) {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
            for descriptor in descriptors {
                guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                      !postScript.isEmpty, seen.insert(postScript.lowercased()).inserted,
                      let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                      !family.isEmpty else { continue }
                let key = family.lowercased()
                let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? postScript
                faces[key, default: []].append(.init(id: postScript, displayName: name))
                names[key] = family
                files[key, default: [:]][url] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return faces.keys.map { key in
            BundledFontFamily(id: key, displayName: names[key] ?? key,
                faces: (faces[key] ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                byteCount: (files[key] ?? [:]).values.reduce(0, +))
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

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
        let roots = existingFontRoots(in: Bundle.main.bundleURL)
        let staged = roots.flatMap(stagedFontURLs)
        guard !staged.isEmpty else { return [] }
        var failures = Set<String>()
        for url in staged {
            let (outcome, _) = CoreTextFontRegistration.register(url: url)
            if outcome == .failed { failures.insert(url.lastPathComponent) }
        }
        // Independently verify discovery: a font that still does not resolve
        // after its registration attempt is a real failure for every surface
        // that asks CoreText for available fonts.
        for name in roots.flatMap({ discoveryReport(in: $0).unresolvedFiles }) {
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
