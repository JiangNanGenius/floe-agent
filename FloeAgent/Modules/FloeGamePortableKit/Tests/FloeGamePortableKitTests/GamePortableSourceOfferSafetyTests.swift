// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import Darwin
import FloeGameCore
@testable import FloeGamePortableKit

/// Source-only safety portfolio for the explicit source-accompanied export
/// mode, the two real producer layouts and descriptor-relative no-follow IO.
/// These tests are authored but NOT executed in this source-only task.
final class GamePortableSourceOfferSafetyTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let licenses: URL
        let relink: URL
        let packages: URL
        let bundles: URL
        let notice = Data("notice".utf8)
        let relinkData = Data("relink".utf8)
        let sourceData = Data("source".utf8)
        let bundleData: Data

        var bundleID: String { "love-runtime-and-source.zip" }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-source-safety-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFixture(bundleBytes: Int = 64) throws -> Fixture {
        let root = try temporaryDirectory()
        let licenses = root.appendingPathComponent("licenses-root", isDirectory: true)
        let relink = root.appendingPathComponent("relink-root", isDirectory: true)
        let packages = root.appendingPathComponent("packages-root", isDirectory: true)
        let bundles = root.appendingPathComponent("bundle-root", isDirectory: true)
        let bundle = Data(repeating: 0x41, count: bundleBytes)
        try write(Data("notice".utf8), "licenses/NOTICE.txt", under: licenses)
        try write(Data("relink".utf8), "love/RELINK.md", under: relink)
        try write(Data("source".utf8), "love/source.tar.gz", under: packages)
        try write(bundle, "love-runtime-and-source.zip", under: bundles)
        return .init(root: root, licenses: licenses, relink: relink, packages: packages,
                     bundles: bundles, bundleData: bundle)
    }

    private func roots(_ fixture: Fixture) -> GamePortableSourceOfferRoots {
        .init(licenses: fixture.licenses, relink: fixture.relink,
              sourcePackages: fixture.packages, sourceBundle: fixture.bundles)
    }

    private func catalogData(_ fixture: Fixture, state: String = "unpublished",
                             distributionReady: Bool = false,
                             noticeHash: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
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
                    "pairedSourceID": "love-runtime-and-source-2",
                    "licenses": [[
                        "path": "licenses/NOTICE.txt",
                        "sha256": noticeHash ?? GameDigest.sha256(fixture.notice),
                        "bytes": fixture.notice.count,
                    ]],
                    "helperSources": [],
                    "relink": [[
                        "path": "love/RELINK.md",
                        "sha256": GameDigest.sha256(fixture.relinkData),
                        "bytes": fixture.relinkData.count,
                    ]],
                    "sourcePackages": [[
                        "path": "love/source.tar.gz",
                        "sha256": GameDigest.sha256(fixture.sourceData),
                        "bytes": fixture.sourceData.count,
                    ]],
                    "sourceBundle": [
                        "id": fixture.bundleID,
                        "sha256": GameDigest.sha256(fixture.bundleData),
                        "bytes": fixture.bundleData.count,
                    ],
                    "publication": [
                        "state": state,
                        "distributionReady": distributionReady,
                        "writtenOfferCreated": false,
                        "publicURL": NSNull(),
                        "detail": "exact local bytes; publication state is explicit",
                    ],
                ],
            ],
        ], options: [.sortedKeys])
    }

    private func catalog(_ fixture: Fixture, state: String = "unpublished",
                         distributionReady: Bool = false,
                         noticeHash: String? = nil) throws -> GamePortableSourceAccompanimentCatalog {
        try .init(from: try catalogData(fixture, state: state,
                                        distributionReady: distributionReady,
                                        noticeHash: noticeHash))
    }

    private func pack(_ catalog: GamePortableSourceAccompanimentCatalog) throws
        -> GamePortableSourcePackAccompaniment {
        try XCTUnwrap(catalog.accompaniment(for: .love))
    }

    private func leftovers(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".floe-source-offer-") }
    }

    private func makeFIFO(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let result = url.path.withCString { mkfifo($0, 0o600) }
        XCTAssertEqual(result, 0, "mkfifo failed: \(String(cString: strerror(errno)))")
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        let inspected = url.path.withCString { Darwin.lstat($0, &metadata) }
        XCTAssertEqual(inspected, 0)
        guard inspected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO)
    }

    // MARK: - Source-accompanied export

    func testSourceAccompaniedExportSucceedsWithUnpublishedCatalog() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        let receipt = try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport)
        XCTAssertEqual(receipt.mode, "sourceAccompaniedExport")
        XCTAssertEqual(receipt.state, "unpublished")
        XCTAssertEqual(receipt.publicSourceState, "unpublished")
        XCTAssertFalse(receipt.distributionReady)
        XCTAssertFalse(receipt.writtenOfferCreated)
        XCTAssertTrue(receipt.engineeringComplete)
        XCTAssertEqual(receipt.sourceBundleID, fixture.bundleID)
        XCTAssertEqual(receipt.sourceBundleSHA256, GameDigest.sha256(fixture.bundleData))
        XCTAssertEqual(try Data(contentsOf: destination
            .appendingPathComponent("sources/exact/\(fixture.bundleID)")), fixture.bundleData)

        let profile = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: destination
                .appendingPathComponent("PAIRED-SOURCE.json"))) as! [String: Any]
        XCTAssertEqual(profile["mode"] as? String, "sourceAccompaniedExport")
        XCTAssertEqual(profile["publicSourceState"] as? String, "unpublished")
        XCTAssertEqual(profile["distributionReady"] as? Bool, false)
        XCTAssertEqual(profile["engineeringComplete"] as? Bool, true)
        XCTAssertEqual(profile["writtenOfferCreated"] as? Bool, false)

        let resolution = try GamePortableSourceOfferResolver.resolve(
            pack: try pack(catalog), root: destination)
        XCTAssertEqual(resolution.layout, .materializedSourceOffer)
        XCTAssertEqual(resolution.relativePath, "sources/exact/\(fixture.bundleID)")
        XCTAssertEqual(resolution.sha256, GameDigest.sha256(fixture.bundleData))
        XCTAssertTrue(try leftovers(in: fixture.root).isEmpty)
    }

    func testDistributionModeStillFailsClosedWhileUnpublished() throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1",
            roots: roots(fixture), to: destination, mode: .distribution)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .notPublished("lovejs-11.4.1"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSourceAccompaniedExportRejectsWrongHashAndLeavesNoDestination() throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture, noticeHash: String(repeating: "0", count: 64)),
            packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .digestMismatch("licenses/NOTICE.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try leftovers(in: fixture.root).isEmpty)
    }

    func testSourceAccompaniedExportRejectsMissingBundleRoot() throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1",
            roots: .init(licenses: fixture.licenses, relink: fixture.relink,
                         sourcePackages: fixture.packages),
            to: destination, mode: .sourceAccompaniedExport)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .missingRoot("source-bundle"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDestinationIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("keep.txt")),
                       Data("existing".utf8))
    }

    func testCancelledExportLeavesNoDestination() async throws {
        let fixture = try makeFixture(bundleBytes: 16 * 1_024 * 1_024)
        let catalog = try catalog(fixture)
        let roots = roots(fixture)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        let task = Task {
            try GamePortableSourceOfferMaterializer.materialize(
                catalog: catalog, packID: "lovejs-11.4.1", roots: roots,
                to: destination, mode: .sourceAccompaniedExport)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled export unexpectedly completed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try leftovers(in: fixture.root).isEmpty)
    }

    // MARK: - Descriptor-relative source safety

    func testMaterializerRejectsSymlinkedNoticeFile() throws {
        let fixture = try makeFixture()
        let outside = try temporaryDirectory().appendingPathComponent("NOTICE.txt")
        try fixture.notice.write(to: outside)
        let notice = fixture.licenses.appendingPathComponent("licenses/NOTICE.txt")
        try FileManager.default.removeItem(at: notice)
        try FileManager.default.createSymbolicLink(at: notice, withDestinationURL: outside)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try leftovers(in: fixture.root).isEmpty)
    }

    func testMaterializerRejectsSymlinkedIntermediateDirectory() throws {
        let fixture = try makeFixture()
        let outside = try temporaryDirectory().appendingPathComponent("love", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.relinkData.write(to: outside.appendingPathComponent("RELINK.md"))
        let link = fixture.relink.appendingPathComponent("love")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMaterializerRejectsFIFOBundleWithoutBlocking() throws {
        let fixture = try makeFixture()
        try makeFIFO(at: fixture.bundles.appendingPathComponent(fixture.bundleID))
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try GamePortableSourceOfferMaterializer.materialize(
            catalog: try catalog(fixture), packID: "lovejs-11.4.1", roots: roots(fixture),
            to: destination, mode: .sourceAccompaniedExport))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Resolver producer layouts

    func testResolverAcceptsMaterializedAndFlatProducerLayouts() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let pack = try pack(catalog)
        let materializedRoot = fixture.root.appendingPathComponent("offer", isDirectory: true)
        _ = try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1", roots: roots(fixture),
            to: materializedRoot, mode: .sourceAccompaniedExport)
        let materialized = try GamePortableSourceOfferResolver.resolve(
            pack: pack, root: materializedRoot)
        XCTAssertEqual(materialized.layout, .materializedSourceOffer)

        let flatRoot = fixture.root.appendingPathComponent("flat", isDirectory: true)
        try write(fixture.bundleData, fixture.bundleID, under: flatRoot)
        let flat = try GamePortableSourceOfferResolver.resolve(pack: pack, root: flatRoot)
        XCTAssertEqual(flat.layout, .flatSourceOffer)
        XCTAssertEqual(flat.relativePath, fixture.bundleID)
        XCTAssertEqual(flat.sha256, GameDigest.sha256(fixture.bundleData))
        XCTAssertEqual(flat.bytes, fixture.bundleData.count)
    }

    func testResolverAcceptsDirectBundleFile() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let resolution = try GamePortableSourceOfferResolver.resolve(
            pack: try pack(catalog),
            root: fixture.bundles.appendingPathComponent(fixture.bundleID))
        XCTAssertEqual(resolution.layout, .directBundleFile)
        XCTAssertEqual(resolution.sha256, GameDigest.sha256(fixture.bundleData))
    }

    func testResolverRejectsWrongBytesAndLateReplacement() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let pack = try pack(catalog)
        let root = fixture.root.appendingPathComponent("flat", isDirectory: true)
        try write(fixture.bundleData, fixture.bundleID, under: root)
        XCTAssertEqual(try GamePortableSourceOfferResolver.resolve(pack: pack, root: root).layout,
                       .flatSourceOffer)
        let target = root.appendingPathComponent(fixture.bundleID)
        try Data(repeating: 0x42, count: fixture.bundleData.count).write(to: target)
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(pack: pack, root: root)) {
            XCTAssertEqual($0 as? GamePortableSourceOfferError,
                           .digestMismatch(fixture.bundleID))
        }
        let outside = try temporaryDirectory()
            .appendingPathComponent("exact.zip")
        try fixture.bundleData.write(to: outside)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(pack: pack, root: root))
    }

    func testResolverRejectsUnrelatedDirectoryAndSymlinkedLayoutDirectory() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let pack = try pack(catalog)
        let unrelated = fixture.root.appendingPathComponent("unrelated", isDirectory: true)
        try write(fixture.bundleData, "other.zip", under: unrelated)
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(
            pack: pack, root: unrelated)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .missingFile(fixture.bundleID))
        }

        let outside = try temporaryDirectory()
        try write(fixture.bundleData, "exact/\(fixture.bundleID)", under: outside)
        let escaped = fixture.root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: escaped.appendingPathComponent("sources", isDirectory: true),
            withDestinationURL: outside)
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(
            pack: pack, root: escaped))
    }

    func testResolverIgnoresProducerManifestClaims() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let pack = try pack(catalog)
        let root = fixture.root.appendingPathComponent("offer", isDirectory: true)
        _ = try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: "lovejs-11.4.1", roots: roots(fixture),
            to: root, mode: .sourceAccompaniedExport)
        let bundle = root.appendingPathComponent("sources/exact/\(fixture.bundleID)")
        try Data(repeating: 0x43, count: fixture.bundleData.count).write(to: bundle)
        // PAIRED-SOURCE.json still claims the original exact bytes; the resolver
        // must hash the actual file and fail instead of trusting the manifest.
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(
            pack: pack, root: root)) { error in
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .digestMismatch(fixture.bundleID))
        }
    }

    func testResolverRejectsFIFOBundleWithoutBlocking() throws {
        let fixture = try makeFixture()
        let catalog = try catalog(fixture)
        let root = fixture.root.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFIFO(at: root.appendingPathComponent(fixture.bundleID))
        XCTAssertThrowsError(try GamePortableSourceOfferResolver.resolve(
            pack: try pack(catalog), root: root))
    }
}
