// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeElectronicsCore

final class ElectronicsRemoteModelsTests: XCTestCase {
    func testValidatedPublicationCatalogAndModelIndex() throws {
        let fixture = try RemoteTestSupport.fixture()
        XCTAssertEqual(fixture.publication.tag, "data-v1-" + RemoteTestSupport.versionSuffix)
        XCTAssertEqual(fixture.catalog.sources.count, 1)
        XCTAssertEqual(fixture.catalog.modelCount, 1)
        let index = try ElectronicsRemoteModelIndex.decode(compressed: fixture.modelGzip, catalog: fixture.catalog)
        XCTAssertEqual(index.records, [fixture.model])
        XCTAssertEqual(try index.record(id: fixture.model.id), fixture.model)
        let page = try index.search(.init(text: "PhoenixContact", limit: 10))
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.models.first?.path, RemoteTestSupport.realModelPath)
        let none = try index.search(.init(text: "PhoenixContact", sourceID: "other", limit: 10))
        XCTAssertEqual(none.total, 0)
    }

    func testRealCommaSpaceParenthesisPathEncodesCanonically() throws {
        let encoded = try ElectronicsRemoteValidation.encodePath(RemoteTestSupport.realModelPath)
        XCTAssertTrue(encoded.contains("%2C"))
        let spaced = try ElectronicsRemoteValidation.encodePath("A (B) C.step")
        XCTAssertTrue(spaced.contains("%20"))
        XCTAssertTrue(spaced.contains("%28"))
        XCTAssertTrue(spaced.contains("%29"))
        let target = try ElectronicsRemoteTarget.repositoryFile(
            repository: "https://github.com/sparkfun/SparkFun-KiCad-Libraries",
            revision: RemoteTestSupport.sourceCommit, path: RemoteTestSupport.realModelPath)
        XCTAssertEqual(target.mirrorRole, .rawFiles)
        XCTAssertTrue(target.canonicalURL.absoluteString.contains("%2C"))
        XCTAssertEqual(target.routes.count, 1)
    }

    func testKiCadGitLabTargetKeepsAuthorityAndAddsOneCompiledGitHubAlias() throws {
        let target = try ElectronicsRemoteTarget.repositoryFile(
            repository: "https://gitlab.com/kicad/libraries/kicad-packages3D",
            revision: "8975715167d1a76f9b44be155ac02326f704cdbb",
            path: "Resistor_SMD.3dshapes/R_0603_1608Metric.step")
        XCTAssertEqual(target.canonicalURL.host, "gitlab.com")
        XCTAssertEqual(target.canonicalURL.absoluteString,
            "https://gitlab.com/kicad/libraries/kicad-packages3D/-/raw/8975715167d1a76f9b44be155ac02326f704cdbb/Resistor_SMD.3dshapes/R_0603_1608Metric.step")
        XCTAssertEqual(target.routes.count, 2)
        XCTAssertEqual(target.routes[1].mirrorRole, .rawFiles)
        XCTAssertEqual(target.routes[1].url.absoluteString,
            "https://raw.githubusercontent.com/KiCad/kicad-packages3D/8975715167d1a76f9b44be155ac02326f704cdbb/Resistor_SMD.3dshapes/R_0603_1608Metric.step")
        // Arbitrary alternate hosts are rejected; only the repository identity
        // can produce a route.
        XCTAssertThrowsError(try ElectronicsRemoteTarget.repositoryFile(
            repository: "https://gitlab.com/kicad/libraries/other", revision: "8975715167d1a76f9b44be155ac02326f704cdbb",
            path: "x.step"))
    }

    func testGzipRejectsCorruptionTruncationTrailingAndOverflow() throws {
        let payload = Data(repeating: 0x41, count: 2_048)
        let gzip = try RemoteTestSupport.gzip(payload)
        XCTAssertEqual(try ElectronicsRemoteGzip.decompress(gzip, maximumBytes: 4_096), payload)
        var corrupt = gzip
        corrupt[corrupt.count / 2] ^= 0x5a
        XCTAssertThrowsError(try ElectronicsRemoteGzip.decompress(corrupt, maximumBytes: 4_096))
        XCTAssertThrowsError(try ElectronicsRemoteGzip.decompress(gzip.dropLast(4), maximumBytes: 4_096))
        XCTAssertThrowsError(try ElectronicsRemoteGzip.decompress(gzip + Data([0]), maximumBytes: 4_096))
        XCTAssertThrowsError(try ElectronicsRemoteGzip.decompress(gzip, maximumBytes: 1_024))
    }

    func testJSONLRejectsDuplicateUnknownSourceAndMalformedRows() throws {
        let fixture = try RemoteTestSupport.fixture()
        let line = try RemoteTestSupport.encoder.encode(fixture.model) + Data([0x0A])
        XCTAssertThrowsError(try ElectronicsRemoteModelIndex(records: [fixture.model, fixture.model],
            catalog: fixture.catalog))
        let _ = line
        var unknown = fixture.model
        unknown.sourceID = "unknown-source"
        unknown.id = "model:unknown-source:" + unknown.path
        let unknownLine = try RemoteTestSupport.encoder.encode(unknown) + Data([0x0A])
        XCTAssertThrowsError(try ElectronicsRemoteModelIndex.decodeJSONL(unknownLine, catalog: fixture.catalog))
        XCTAssertThrowsError(try ElectronicsRemoteModelIndex.decodeJSONL(Data([0x7b]), catalog: fixture.catalog))
    }

    func testBindingRejectsAnyChangedCatalogOrManifestIdentity() throws {
        let fixture = try RemoteTestSupport.fixture()
        try ElectronicsRemoteBinding.validate(publication: fixture.publication, catalog: fixture.catalog,
                                               manifest: fixture.manifest, modelIndexBytes: fixture.modelGzip.count)
        var changed = fixture.catalog
        changed.sources[0].index.sha256 = String(repeating: "00", count: 32)
        XCTAssertThrowsError(try ElectronicsRemoteBinding.validate(publication: fixture.publication,
            catalog: changed, manifest: fixture.manifest, modelIndexBytes: fixture.modelGzip.count))
        let missing = ElectronicsRemoteManifest(dataVersion: fixture.manifest.dataVersion,
            datasetSHA256: fixture.manifest.datasetSHA256, producerRevision: fixture.manifest.producerRevision,
            toolingSHA256: fixture.manifest.toolingSHA256,
            files: fixture.manifest.files.filter { $0.path != RemoteTestSupport.indexPath })
        XCTAssertThrowsError(try ElectronicsRemoteBinding.validate(publication: fixture.publication,
            catalog: fixture.catalog, manifest: missing, modelIndexBytes: fixture.modelGzip.count))
    }

    func testPartIndexSearchAndVerifiedChunkRead() throws {
        let fixture = try RemoteTestSupport.fixture()
        let index = try ElectronicsRemotePartIndex.decode(compressed: fixture.indexGzip, sourceID: "lib-a",
                                                          catalog: fixture.catalog)
        let page = try index.search(.init(text: "Demo", limit: 10))
        XCTAssertEqual(page.total, 1)
        let row = try XCTUnwrap(page.parts.first)
        let record = try ElectronicsRemotePartIndex.recordJSON(row: row, sourceID: "lib-a",
            catalog: fixture.catalog, chunk: fixture.chunkGzip)
        XCTAssertEqual(record.observedSHA256, row.sha256)
        XCTAssertTrue(record.json.contains("Demo.kicad_sym"))
        var wrong = row
        wrong.sha256 = String(repeating: "00", count: 32)
        XCTAssertThrowsError(try ElectronicsRemotePartIndex.recordJSON(row: wrong, sourceID: "lib-a",
            catalog: fixture.catalog, chunk: fixture.chunkGzip))
    }

    func testStoreKeepsPreviousSnapshotWhenANewInstallFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-electronics-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try RemoteTestSupport.fixture()
        let store = ElectronicsRemoteStore(root: root)
        let installed = try await store.installSnapshot(releaseData: fixture.releaseData,
            publication: fixture.publication, catalogData: fixture.catalogData, catalog: fixture.catalog,
            manifestData: fixture.manifestData, manifest: fixture.manifest,
            modelIndexGzip: fixture.modelGzip, records: [fixture.model])
        XCTAssertEqual(installed.publication.tag, fixture.publication.tag)
        let loaded = try await store.loadSnapshot()
        XCTAssertEqual(loaded?.catalog.dataVersion, fixture.catalog.dataVersion)
        var tampered = fixture.catalogData
        tampered.append(0x20)
        do {
            _ = try await store.installSnapshot(releaseData: fixture.releaseData,
                publication: fixture.publication, catalogData: tampered, catalog: fixture.catalog,
                manifestData: fixture.manifestData, manifest: fixture.manifest,
                modelIndexGzip: fixture.modelGzip, records: [fixture.model])
            XCTFail("tampered catalogue must not install")
        } catch {}
        let still = try await store.loadSnapshot()
        XCTAssertEqual(still?.catalog.datasetSHA256, fixture.catalog.datasetSHA256)
    }

    func testCacheReuseAndCorruptionNeverReplacesUsableBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-electronics-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ElectronicsRemoteStore(root: root)
        let bytes = Data("verified asset".utf8)
        let sha = ElectronicsRemoteDigest.sha256(bytes)
        let staged = root.appendingPathComponent("staged")
        try bytes.write(to: staged)
        let cached = try await store.promoteAsset(staged: staged, name: "lib.zip", sha256: sha,
            bytes: bytes.count, role: "single-upstream-2d-library", tag: "data-v1-" + RemoteTestSupport.versionSuffix)
        let again = await store.cachedAsset(name: "lib.zip", sha256: sha, bytes: bytes.count)
        XCTAssertEqual(again, cached)
        try Data("corrupt".utf8).write(to: cached)
        let corrupted = await store.cachedAsset(name: "lib.zip", sha256: sha, bytes: bytes.count)
        XCTAssertNil(corrupted)
        let bad = root.appendingPathComponent("bad")
        try Data("different".utf8).write(to: bad)
        do {
            _ = try await store.promoteAsset(staged: bad, name: "lib.zip", sha256: sha,
                bytes: bytes.count, role: "single-upstream-2d-library", tag: "data-v1-" + RemoteTestSupport.versionSuffix)
            XCTFail("mismatched staged bytes must not replace the cache")
        } catch {}
    }

    func testModelCacheUsesGitObjectIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-electronics-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ElectronicsRemoteStore(root: root)
        let fixture = try RemoteTestSupport.fixture()
        let staged = root.appendingPathComponent("staged-model")
        try fixture.modelBytes.write(to: staged)
        let url = try await store.promoteModel(staged: staged, record: fixture.model,
            sha256: fixture.model.sha256!, bytes: fixture.modelBytes.count)
        let cached = await store.cachedModel(record: fixture.model)
        XCTAssertEqual(cached?.url, url)
        try Data("not the model".utf8).write(to: url)
        let corrupted = await store.cachedModel(record: fixture.model)
        XCTAssertNil(corrupted)
    }
}
