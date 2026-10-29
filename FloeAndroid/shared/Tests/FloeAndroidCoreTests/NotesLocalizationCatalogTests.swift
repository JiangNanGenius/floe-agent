// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeCore
@testable import FloeNotes

final class NotesLocalizationCatalogTests: XCTestCase {
    func testExistingCatalogReceivesSeparateArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-catalog-" + UUID().uuidString, isDirectory: true)
        let localization = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        let key = "notes.catalog_fixture.two_arguments"
        let strings = "\"" + key + "\" = \"Catalog: %@ -> %@\";\n"
        try strings.write(to: localization.appendingPathComponent("Localizable.strings"),
                          atomically: true, encoding: .utf8)
        try "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.floe.notes.catalog.fixture</string></dict></plist>"
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: root))
        let previous = FloeL10n.additionalResourceBundles
        let suite = "notes-catalog-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        FloeL10n.additionalResourceBundles = previous + [bundle]
        FloeL10n.setPreference(rawValue: "en", standardDefaults: defaults,
                               suiteDefaults: nil, arguments: [])
        defer {
            FloeL10n.additionalResourceBundles = previous
            FloeL10n.setPreference(rawValue: nil, standardDefaults: defaults,
                                   suiteDefaults: nil, arguments: [])
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let expected = "Catalog: old -> new"
        // Prove the real table is present, rather than testing only the fallback.
        XCTAssertEqual(FloeL10n.localized(key: key, arguments: ["old", "new"]), expected)
        XCTAssertEqual(NoteLocalization.localized(key, "old", "new"), expected)
        XCTAssertEqual(NoteLocalization.format(key, english: "Wrong fallback",
                                               chinese: "错误回退", "old", "new"), expected)
    }
}
