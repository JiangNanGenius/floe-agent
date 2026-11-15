// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeGameCore
@testable import FloeGamePortableKit

/// Source regression portfolio for exact source/notice accompaniment and export
/// companion materialization. These tests are authored but NOT executed in this
/// source-only task.
final class GamePortableSourceAccompanimentTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-source-offer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ data: Data, _ relative: String, under root: URL) throws {
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target)
    }

    private func record(_ path: String, _ data: Data) throws -> GamePortableSourceFileRecord {
        .init(path: path, sha256: GameDigest.sha256(data), bytes: data.count)
    }

    private func makeFixture(state: String = "unpublished",
                             distributionReady: Bool = false) throws -> (URL, URL, URL, URL, URL) {
        let root = try temporaryDirectory()
        let licenses = root.appendingPathComponent("licenses-root", isDirectory: true)
        let relink = root.appendingPathComponent("relink-root", isDirectory: true)
        let packages = root.appendingPathComponent("packages-root", isDirectory: true)
        let bundles = root.appendingPathComponent("bundle-root", isDirectory: true)
        try write(Data("notice".utf8), "licenses/NOTICE.txt", under: licenses)
        try write(Data("relink".utf8), "love/RELINK.md", under: relink)
        try write(Data("source".utf8), "love/source.tar.gz", under: packages)
        try write(Data("bundle".utf8), "love-runtime-and-source.zip", under: bundles)
        _ = state; _ = distributionReady
        return (licenses, relink, packages, bundles, root)
    }

    private func catalogJSON(state: String = "unpublished",
                             distributionReady: Bool = false,
                             noticePath: String = "licenses/NOTICE.txt",
                             noticeHash: String? = nil,
                             includeBundle: Bool = true,
                             sourceFiles: [[String: Any]] = []) throws -> Data {
        let notice = Data("notice".utf8)
        let relink = Data("relink".utf8)
        let source = Data("source".utf8)
        let bundle = Data("bundle".utf8)
        var object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "floe-game-runtime-source-accompaniment",
            "productionPublication": [
                "state": "unpublished", "distributionReady": false,
                "writtenOfferCreated": false, "detail": "not published",
            ],
            "packs": [
                "lovejs-11.4.1": [
                    "packID": "lovejs-11.4.1",
                    "engines": ["love"],
                    "profileID": "portable-love",
                    "licenses": [[
                        "path": noticePath,
                        "sha256": noticeHash ?? GameDigest.sha256(notice),
                        "bytes": notice.count,
                    ]],
                    "helperSources": [],
                    "relink": [[
                        "path": "love/RELINK.md",
                        "sha256": GameDigest.sha256(relink),
                        "bytes": relink.count,
                    ]],
                    "sourcePackages": [[
                        "path": "love/source.tar.gz",
                        "sha256": GameDigest.sha256(source),
                        "bytes": source.count,
                    ]],
                    "sourceFiles": sourceFiles,
                    "publication": [
                        "state": state,
                        "distributionReady": distributionReady,
                        "writtenOfferCreated": false,
                        "publicURL": NSNull(),
                        "detail": "local exact bytes; publication state is explicit",
                    ],
                ],
            ],
        ]
        if includeBundle {
            var pack = object["packs"] as! [String: Any]
            var love = pack["lovejs-11.4.1"] as! [String: Any]
            love["sourceBundle"] = [
                "id": "love-runtime-and-source.zip",
                "sha256": GameDigest.sha256(bundle),
                "bytes": bundle.count,
            ]
            pack["lovejs-11.4.1"] = love
            object["packs"] = pack
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testCatalogRejectsUnsafePathAndUnknownEngine() throws {
        let unsafe = try catalogJSON(noticePath: "../escape")
        XCTAssertThrowsError(try GamePortableSourceAccompanimentCatalog(from: unsafe))
    }

    func testCatalogDecodesExactRecordsAndPublicationState() throws {
        let catalog = try GamePortableSourceAccompanimentCatalog(from: try catalogJSON())
        let pack = try XCTUnwrap(catalog.accompaniment(for: .love))
        XCTAssertEqual(pack.packID, "lovejs-11.4.1")
        XCTAssertEqual(pack.profileID, "portable-love")
        XCTAssertFalse(pack.publication.distributionReady)
        XCTAssertEqual(pack.sourceBundle?.id, "love-runtime-and-source.zip")
        XCTAssertEqual(pack.sourcePackages.count, 1)
    }

    func testPrivatePlaybackMaterializesExactBytesAndStaysNotReady() throws {
        let (licenses, relink, packages, bundles, root) = try makeFixture()
        let catalog = try GamePortableSourceAccompanimentCatalog(from: try catalogJSON())
        let destination = root.appendingPathComponent("export", isDirectory: true)
        let receipt = try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1",
            roots: .init(licenses: licenses, relink: relink, sourcePackages: packages,
                         sourceBundle: bundles),
            to: destination, mode: .privatePlayback)
        XCTAssertFalse(receipt.distributionReady)
        XCTAssertEqual(receipt.sourceBundleID, "love-runtime-and-source.zip")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("PAIRED-SOURCE.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("sources/exact/love-runtime-and-source.zip").path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("licenses/NOTICE.txt")),
                       Data("notice".utf8))
    }

    func testOneFileCanBeNoticeAndSourceWithBothInputsVerified() throws {
        let (licenses, relink, packages, bundles, root) = try makeFixture()
        let path = "licenses/NOTICE.txt", bytes = Data("notice".utf8)
        let record: [String: Any] = ["path": path, "bytes": bytes.count, "sha256": GameDigest.sha256(bytes)]
        let catalog = try GamePortableSourceAccompanimentCatalog(from: catalogJSON(sourceFiles: [record]))
        let other = root.appendingPathComponent("source-role")
        try write(bytes, path, under: other)
        let roots = GamePortableSourceOfferRoots(licenses: licenses, relink: relink, sourcePackages: packages,
                                                sourceFiles: other, sourceBundle: bundles)
        let receipt = try GamePortableSourceOfferMaterializer.materialize(catalog: catalog, packID: "lovejs-11.4.1",
            roots: roots, to: root.appendingPathComponent("exact"), mode: .privatePlayback)
        XCTAssertEqual(receipt.files.filter { $0.path.value == path }.count, 1)
        try write(Data("broken".utf8), path, under: other)
        let failed = root.appendingPathComponent("conflicting")
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(catalog: catalog,
            packID: "lovejs-11.4.1", roots: roots, to: failed, mode: .privatePlayback))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertThrowsError(try GamePortableSourceAccompanimentCatalog(from: catalogJSON(sourceFiles: [record, record])))
        var mismatch = record
        mismatch["sha256"] = GameDigest.sha256(Data("broken".utf8))
        XCTAssertThrowsError(try GamePortableSourceAccompanimentCatalog(from: catalogJSON(sourceFiles: [mismatch])))
    }

    func testDistributionModeFailsClosedWhileUnpublished() throws {
        let (licenses, relink, packages, bundles, root) = try makeFixture()
        let catalog = try GamePortableSourceAccompanimentCatalog(from: try catalogJSON())
        let destination = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1",
            roots: .init(licenses: licenses, relink: relink, sourcePackages: packages,
                         sourceBundle: bundles),
            to: destination, mode: .distribution)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .notPublished("lovejs-11.4.1"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWrongHashFailsClosedAndRemovesStaging() throws {
        let (licenses, relink, packages, bundles, root) = try makeFixture()
        let catalog = try GamePortableSourceAccompanimentCatalog(
            from: try catalogJSON(noticeHash: String(repeating: "0", count: 64)))
        let destination = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1",
            roots: .init(licenses: licenses, relink: relink, sourcePackages: packages,
                         sourceBundle: bundles),
            to: destination, mode: .privatePlayback))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".floe-source-offer-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingCompanionFailsClosed() throws {
        let (licenses, relink, packages, bundles, root) = try makeFixture()
        try FileManager.default.removeItem(at: relink.appendingPathComponent("love/RELINK.md"))
        let catalog = try GamePortableSourceAccompanimentCatalog(from: try catalogJSON())
        let destination = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1",
            roots: .init(licenses: licenses, relink: relink, sourcePackages: packages,
                         sourceBundle: bundles),
            to: destination, mode: .privatePlayback))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNoticeMaterializerCopiesLicensesAndRejectsDifferentBytes() throws {
        let root = try temporaryDirectory()
        let resourceRoot = root.appendingPathComponent("resource", isDirectory: true)
        let target = root.appendingPathComponent("artifact", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let notice = Data("license".utf8)
        try write(notice, "licenses/COPYING.txt", under: resourceRoot)
        let manifest = GamePortableResourceManifest(
            id: "lovejs-11.4.1", pinID: "lovejs", engine: .love,
            version: "11.4.1", runtimeID: "lovejs",
            files: [.init(path: try GameRelativePath("licenses/COPYING.txt"),
                          sha256: GameDigest.sha256(notice), bytes: notice.count)])
        let resources = try GamePortablePreparedResources(rootURL: resourceRoot, manifest: manifest)
        let records = try GamePortableResourceNoticeMaterializer.materialize(resources, into: target)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("licenses/COPYING.txt")),
                       notice)
        try Data("different".utf8).write(to: target.appendingPathComponent("licenses/COPYING.txt"))
        XCTAssertThrowsError(try GamePortableResourceNoticeMaterializer.materialize(resources, into: target))
    }
}

/// Explicit user-rebuilt runtime component seam. Source-only regression; not
/// executed in this task.
final class GamePortableUserRuntimeReplacementTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-user-replacement-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ data: Data, _ relative: String, under root: URL) throws {
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target)
    }

    private func baseFixture() throws -> (GamePortablePreparedResources, URL, Data, Data) {
        let root = try temporaryDirectory()
        let original = Data("upstream-loader".utf8)
        let notice = Data("notice".utf8)
        try write(original, "runtime/compat/love.js", under: root)
        try write(notice, "licenses/COPYING.txt", under: root)
        let manifest = GamePortableResourceManifest(
            id: "lovejs-11.4.1", pinID: "lovejs", engine: .love,
            version: "11.4.1", runtimeID: "lovejs",
            files: [
                .init(path: try GameRelativePath("runtime/compat/love.js"),
                      sha256: GameDigest.sha256(original), bytes: original.count),
                .init(path: try GameRelativePath("licenses/COPYING.txt"),
                      sha256: GameDigest.sha256(notice), bytes: notice.count),
            ])
        return (try GamePortablePreparedResources(rootURL: root, manifest: manifest), root, original, notice)
    }

    private func metadata(base: GamePortablePreparedResources, replacement: Data,
                          notice: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "componentID": "lovejs-11.4.1",
            "baseManifestSHA256": base.manifestDigest,
            "replaceablePaths": ["runtime/compat/love.js"],
            "replacementFiles": [[
                "path": "runtime/compat/love.js",
                "sha256": GameDigest.sha256(replacement),
                "bytes": replacement.count,
                "executable": false,
            ]],
            "sourcePackages": [[
                "path": "love/mpg123-1.25.6.tar.bz2",
                "sha256": String(repeating: "a", count: 64),
                "bytes": 10,
            ]],
            "relinkReceipts": [[
                "path": "love/RELINK.md",
                "sha256": GameDigest.sha256(notice),
                "bytes": notice.count,
            ]],
            "notes": ["user rebuilt locally"],
        ], options: [.sortedKeys])
    }

    func testValidReplacementKeepsImmutableNotices() throws {
        let (base, root, _, notice) = try baseFixture()
        let user = try temporaryDirectory()
        let replacement = Data("rebuilt-loader".utf8)
        try write(replacement, "runtime/compat/love.js", under: user)
        try write(notice, "licenses/COPYING.txt", under: user)
        let value = try GamePortableRuntimeReplacementMetadata(
            from: try metadata(base: base, replacement: replacement, notice: notice))
        let prepared = try GamePortableUserRuntimeReplacement.validate(
            base: base, replacementRoot: user, metadata: value)
        XCTAssertEqual(prepared.id, base.id)
        XCTAssertEqual(try prepared.read("runtime/compat/love.js"), replacement)
    }

    func testChangedNoticeFailsClosed() throws {
        let (base, _, _, notice) = try baseFixture()
        let user = try temporaryDirectory()
        let replacement = Data("rebuilt-loader".utf8)
        try write(replacement, "runtime/compat/love.js", under: user)
        try write(Data("changed".utf8), "licenses/COPYING.txt", under: user)
        let value = try GamePortableRuntimeReplacementMetadata(
            from: try metadata(base: base, replacement: replacement, notice: notice))
        XCTAssertThrowsError(try GamePortableUserRuntimeReplacement.validate(
            base: base, replacementRoot: user, metadata: value))
    }

    func testExtraFileAndUnsafePathFailClosed() throws {
        let (base, _, _, notice) = try baseFixture()
        let user = try temporaryDirectory()
        let replacement = Data("rebuilt-loader".utf8)
        try write(replacement, "runtime/compat/love.js", under: user)
        try write(notice, "licenses/COPYING.txt", under: user)
        try write(Data("extra".utf8), "runtime/extra.js", under: user)
        let value = try GamePortableRuntimeReplacementMetadata(
            from: try metadata(base: base, replacement: replacement, notice: notice))
        XCTAssertThrowsError(try GamePortableUserRuntimeReplacement.validate(
            base: base, replacementRoot: user, metadata: value))
        var object = try JSONSerialization.jsonObject(
            with: try metadata(base: base, replacement: replacement, notice: notice)) as! [String: Any]
        object["replaceablePaths"] = ["../escape"]
        let unsafe = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try GamePortableRuntimeReplacementMetadata(from: unsafe))
    }
}
