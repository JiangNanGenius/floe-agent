#if canImport(UIKit)
import Foundation
import XCTest
import FloeSkills
import FloeElectronicsCore
import FloeElectronicsUI
@testable import FloeApp

@MainActor final class NextRoundElectronicsContentTests: XCTestCase {
    func testColdDirectoryURLLoadsTheActualBundledCatalogAndReopensIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EDLibraryCold-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The actual App service supplies an explicitly-directory URL before
        // its user-library folder exists. URL slash flags are not identity.
        let root = base.appendingPathComponent("Libraries", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let store = try EDALibraryStore(root: root)
        let controller = EDLibraryController(store: store)
        let catalog = try await controller.prepare()
        XCTAssertEqual(catalog.entries.count, 47)
        XCTAssertEqual(Set(catalog.entries.map(\.part.category)).count, 12)
        let first = try XCTUnwrap(catalog.entries.first)
        let snapshot = try await store.snapshot(first.reference)
        XCTAssertEqual(snapshot.part, first.part)
        let reopened = try EDALibraryStore(root: root)
        let durable = try await reopened.catalog()
        XCTAssertEqual(durable, catalog)
        // A real alias is still refused before touching the selected target.
        let alias = base.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try EDALibraryStore(root: alias))
        let afterRejectedAlias = try await reopened.catalog()
        XCTAssertEqual(afterRejectedAlias, catalog)
    }

    /// Exercises the App's real post-signature domain dispatcher, not a new
    /// updater or a test trust root. Signature/transport checks remain upstream.
    func testActualBundledLibraryPassesTheTemplateDomainGateAndRejectsChangedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EDLibraryDomain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EDALibraryStore(root: root)
        let controller = EDLibraryController(store: store)
        let catalog = try await controller.prepare()
        let part = try XCTUnwrap(catalog.entries.first)
        let package = try await store.package(id: part.reference.packageID, version: part.reference.version)
        let library = try EDALibraryDigest.encoded(package)
        let metadata: [String: Any] = ["schemaVersion": 1, "id": package.id, "kind": "templates",
            "version": package.version, "minimumAppVersion": "1.9.0",
            "template": "Library.json", "domain": "org.floe.electronics.library",
            "librarySHA256": EDALibraryDigest.sha256(library),
            "releaseNotes": ["en": "Synthetic content contract", "zh-Hans": "内容合同测试"]]
        let content = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let files = ["Library.json": library, "content.json": content]
        let entry = SignedContentEntry(id: package.id, kind: .templates, version: package.version,
            schemaVersion: 1, minimumAppVersion: "1.9.0", requiredCapabilities: [], dependencies: [],
            path: "content-hub/packages/\(package.id)/\(package.version)/\(package.id).zip",
            size: library.count + content.count, sha256: String(repeating: "a", count: 64),
            contentDigest: SignedContentArchive.canonicalDigest(files),
            releaseNotes: ["en": "Synthetic content contract", "zh-Hans": "内容合同测试"], sourceRevision: "", containsScripts: false)
        XCTAssertNoThrow(try ContentUpdateCenter.domainValidator(entry: entry, files: files))
        XCTAssertEqual(ContentUpdateCenter.builtInBaselines[package.id], package.version)
        XCTAssertFalse(entry.isCompatible(appVersion: "1.8.6"))
        XCTAssertTrue(entry.isCompatible(appVersion: "1.9.0"))
        var changed = files
        changed["Library.json"] = library + Data(" ".utf8)
        XCTAssertThrowsError(try ContentUpdateCenter.domainValidator(entry: entry, files: changed))
        var unexpected = files
        unexpected["unclaimed.txt"] = Data("unclaimed".utf8)
        XCTAssertThrowsError(try ContentUpdateCenter.domainValidator(entry: entry, files: unexpected))
        var wrongIdentity = metadata
        wrongIdentity["id"] = package.id + ".other"
        var wrongFiles = files
        wrongFiles["content.json"] = try JSONSerialization.data(withJSONObject: wrongIdentity, options: [.sortedKeys])
        XCTAssertThrowsError(try ContentUpdateCenter.domainValidator(entry: entry, files: wrongFiles))
        // These domain failures never install into the actual user library.
        let retained = try await store.catalog()
        XCTAssertEqual(retained.entries.count, 47)
    }
}
#endif
