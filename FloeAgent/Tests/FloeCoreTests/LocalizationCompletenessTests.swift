// FloeCoreTests — Localization catalog completeness.
// See docs/ARCHITECTURE_SETTINGS.md §9 and PRD UX/L10N acceptance: every
// user-facing string lives in Localizable.xcstrings with a non-empty en and
// zh-Hans value. This test reads the real catalog and asserts completeness
// so a missing translation fails CI instead of surfacing a raw key.

import Foundation
import Testing

@Suite("FloeCore.LocalizationCompleteness")
struct LocalizationCompletenessTests {

    /// Path to the real string catalog, resolved from this source file.
    /// Tests/FloeCoreTests/LocalizationCompletenessTests.swift → package
    /// root → FloeApp/Resources/Localizable.xcstrings.
    private static func catalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FloeCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("FloeApp/Resources/Localizable.xcstrings")
    }

    /// Decoded catalog entry.
    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }
    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }
    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }
    private struct StringUnit: Decodable {
        let state: String?
        let value: String?
    }

    private func loadCatalog() throws -> Catalog {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    @Test("Catalog exists and is non-empty")
    func catalogExists() throws {
        let url = Self.catalogURL()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let catalog = try loadCatalog()
        #expect(!catalog.strings.isEmpty)
    }

    @Test("Every key has a non-empty en and zh-Hans value")
    func everyKeyIsBilingual() throws {
        let catalog = try loadCatalog()
        var missing: [String] = []
        var empty: [String] = []
        for (key, entry) in catalog.strings {
            guard let localizations = entry.localizations else {
                missing.append("\(key): no localizations")
                continue
            }
            guard let en = localizations["en"]?.stringUnit?.value, !en.trimmingCharacters(in: .whitespaces).isEmpty else {
                if localizations["en"]?.stringUnit?.value != nil {
                    empty.append("\(key): en empty")
                } else {
                    missing.append("\(key): missing en")
                }
                continue
            }
            guard let zh = localizations["zh-Hans"]?.stringUnit?.value,
                  !zh.trimmingCharacters(in: .whitespaces).isEmpty else {
                if localizations["zh-Hans"]?.stringUnit?.value != nil {
                    empty.append("\(key): zh-Hans empty")
                } else {
                    missing.append("\(key): missing zh-Hans")
                }
                continue
            }
        }
        #expect(missing.isEmpty, "missing translations: \(missing)")
        #expect(empty.isEmpty, "empty translations: \(empty)")
    }

    @Test("Keys follow the dotted-namespacing convention")
    func keysAreNamespaced() throws {
        let catalog = try loadCatalog()
        // Keys like "settings.general.appearance" or "tab.home"; a bare key
        // without a dot is a smell (harder to audit for collisions).
        let nonNamespaced = catalog.strings.keys.filter { !$0.contains(".") }
        #expect(nonNamespaced.isEmpty, "non-namespaced keys: \(nonNamespaced)")
    }
}
