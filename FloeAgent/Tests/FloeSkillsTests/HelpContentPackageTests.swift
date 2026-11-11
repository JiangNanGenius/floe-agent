// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCore
@testable import FloeSkills

final class HelpContentPackageTests: XCTestCase {
    private func files() throws -> [String: Data] {
        #if canImport(UIKit)
        let root = try XCTUnwrap(Bundle.main.url(forResource: "Help", withExtension: nil))
        #else
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FloeApp/Resources/Help", isDirectory: true)
        #endif
        let manager = FileManager.default
        let iterator = try XCTUnwrap(manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let file as URL in iterator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        return files
    }

    private func entry(_ files: [String: Data], sourceRevision: String? = nil) throws -> SignedContentEntry {
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["content.json"])) as? [String: Any])
        return SignedContentEntry(id: HelpBundleMetadata.packageID, kind: .help,
            version: try XCTUnwrap(content["version"] as? String), schemaVersion: 1,
            minimumAppVersion: "1.0.0", requiredCapabilities: [], dependencies: [],
            path: "content-hub/packages/help.zip", size: 1,
            sha256: String(repeating: "a", count: 64), contentDigest: String(repeating: "b", count: 64),
            releaseNotes: ["en": "Guides", "zh-Hans": "指南"],
            sourceRevision: sourceRevision ?? (content["sourceRevision"] as? String ?? ""), containsScripts: false)
    }

    func testNewHelpPackageUsesTypedValidationAndPreservesLegacyProjection() throws {
        let payload = try files()
        try ContentPackageCodec(kind: .help).validate(entry: entry(payload), files: payload)
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(payload["content.json"])) as? [String: Any])
        let documents = try XCTUnwrap(content["documents"] as? [String: String])
        for language in HelpLanguage.allCases {
            XCTAssertNotNil(payload[try XCTUnwrap(documents[language.rawValue])])
        }
    }

    func testNewVersionRequiresManifestAndRejectsChangedAsset() throws {
        var missing = try files()
        var content = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(missing["content.json"])) as? [String: Any])
        content["helpManifest"] = nil
        missing["content.json"] = try JSONSerialization.data(withJSONObject: content)
        XCTAssertThrowsError(try ContentPackageCodec(kind: .help).validate(entry: entry(missing), files: missing))
        var corrupt = try files()
        let manifest = try JSONDecoder().decode(HelpPackageManifest.self, from: XCTUnwrap(corrupt[HelpBundleMetadata.manifestPath]))
        let resource = try XCTUnwrap(manifest.resources.first)
        corrupt[resource.path] = Data("changed".utf8)
        XCTAssertThrowsError(try ContentPackageCodec(kind: .help).validate(entry: entry(corrupt), files: corrupt))
    }

    func testManifestMustMatchSignedSourceRevision() throws {
        let payload = try files()
        XCTAssertThrowsError(try ContentPackageCodec(kind: .help).validate(
            entry: entry(payload, sourceRevision: String(repeating: "f", count: 40)), files: payload))
    }

    func testOldLegacyOnlyHelpRemainsReadable() throws {
        let content: [String: Any] = ["schemaVersion": 1, "id": HelpBundleMetadata.packageID,
            "version": "1.0.0", "kind": "help", "documents": ["en": "en/index.md", "zh-Hans": "zh-Hans/index.md"]]
        let payload = ["content.json": try JSONSerialization.data(withJSONObject: content),
            "en/index.md": Data("Legacy guide".utf8), "zh-Hans/index.md": Data("旧版指南".utf8)]
        try ContentPackageCodec(kind: .help).validate(entry: entry(payload), files: payload)
    }
}
