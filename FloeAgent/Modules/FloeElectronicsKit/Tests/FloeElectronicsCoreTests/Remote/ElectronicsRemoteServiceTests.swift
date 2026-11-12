// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeElectronicsCore

private final class FakeRemoteNetwork: @unchecked Sendable {
    let fixture: RemoteTestSupport.Fixture
    private let lock = NSLock()
    private var dataURLs: [String] = []
    private var fileURLs: [String] = []
    private var archivePaths: [String] = []
    var corruptCatalog = false
    var slowFile = false
    let offline: Bool

    init(fixture: RemoteTestSupport.Fixture, offline: Bool = false) {
        self.fixture = fixture; self.offline = offline
    }

    func dataCalls() -> [String] { lock.withLock { dataURLs } }
    func fileCalls() -> [String] { lock.withLock { fileURLs } }
    func archives() -> [String] { lock.withLock { archivePaths } }
    private func recordData(_ url: URL) { lock.withLock { dataURLs.append(url.absoluteString) } }
    private func recordFile(_ url: URL) { lock.withLock { fileURLs.append(url.absoluteString) } }

    func network() -> ElectronicsRemoteNetwork {
        .init(canonicalBytes: { [self] url, maximum in
            recordData(url)
            if offline { throw ElectronicsRemoteError.unavailable("offline test transport") }
            guard url.absoluteString == "https://github.com/JiangNanGenius/floe-electronics-library/releases/latest/download/release.json",
                  fixture.releaseData.count <= maximum else {
                throw ElectronicsRemoteError.invalidTarget("unexpected canonical route")
            }
            return fixture.releaseData
        }, mirroredBytes: { [self] target, maximum in
            recordData(target.canonicalURL)
            if offline { throw ElectronicsRemoteError.unavailable("offline test transport") }
            let name = target.canonicalURL.lastPathComponent
            let data: Data
            switch name {
            case "catalog.json": data = corruptCatalog ? Data("wrong".utf8) : fixture.catalogData
            case "manifest.json": data = fixture.manifestData
            case "models.jsonl.gz": data = fixture.modelGzip
            default: throw ElectronicsRemoteError.invalidAsset("unexpected data asset \(name)")
            }
            guard data.count <= maximum else { throw ElectronicsRemoteError.limits("fixture data") }
            return data
        }, mirroredFile: { [self] target, maximum, destination, progress in
            recordFile(target.canonicalURL)
            if offline { throw ElectronicsRemoteError.unavailable("offline test transport") }
            if slowFile { try await Task.sleep(for: .seconds(30)) }
            try Task.checkCancellation()
            let name = target.canonicalURL.lastPathComponent
            let data: Data
            if name == fixture.publication.assets.first(where: { $0.role == "all-2d-libraries" })?.name {
                data = fixture.fullPackageBytes
            } else if name == "lib-a-2d.zip" {
                data = fixture.packageBytes
            } else if target.canonicalURL.absoluteString.contains("SparkFun-KiCad-Libraries") {
                data = fixture.modelBytes
            } else {
                throw ElectronicsRemoteError.invalidTarget("unexpected file route \(name)")
            }
            guard data.count <= maximum else { throw ElectronicsRemoteError.limits("fixture file") }
            progress.report(received: 0, expected: Int64(data.count))
            progress.report(received: Int64(data.count / 2), expected: Int64(data.count))
            progress.report(received: Int64(data.count), expected: Int64(data.count))
            try data.write(to: destination)
        }, archiveEntry: { [self] url, path in
            lock.withLock { archivePaths.append(path) }
            guard url.lastPathComponent == "lib-a-2d.zip" || url.lastPathComponent == "floe-electronics-all-2d.zip" else {
                throw ElectronicsRemoteError.integrity("unexpected archive")
            }
            if path == RemoteTestSupport.indexPath { return fixture.indexGzip }
            if path == RemoteTestSupport.chunkPath { return fixture.chunkGzip }
            throw ElectronicsRemoteError.integrity("unexpected archive entry \(path)")
        })
    }
}

final class ElectronicsRemoteServiceTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("floe-electronics-service-" + UUID().uuidString)
    }

    func testRefreshSearchReadAndVerifiedCachedDownloads() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeRemoteNetwork(fixture: fixture)
        let service = ElectronicsRemoteService(storeRoot: root, network: fake.network())

        let refreshed = try await service.refresh()
        XCTAssertTrue(refreshed.changed)
        XCTAssertEqual(refreshed.sourceCount, 1)
        XCTAssertEqual(refreshed.modelCount, 1)
        XCTAssertTrue(fake.dataCalls().contains { $0.contains("/releases/download/data-v1-\(RemoteTestSupport.versionSuffix)/catalog.json") })

        let status = try await service.status()
        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.sourceCount, 1)
        XCTAssertEqual(status.modelCount, 1)

        let libraries = try await service.searchLibraries(.init(text: "lib", limit: 10))
        XCTAssertEqual(libraries.total, 1)
        XCTAssertEqual(libraries.libraries.first?.downloadAssetName, "lib-a-2d.zip")

        let page = try await service.searchParts(libraryID: "lib-a", query: .init(text: "Demo", limit: 10))
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.parts.first?.name, "Demo")
        XCTAssertEqual(fake.archives(), [RemoteTestSupport.indexPath])

        let part = try await service.readPart(libraryID: "lib-a", id: try XCTUnwrap(page.parts.first?.id))
        XCTAssertEqual(part.recordSHA256, page.parts.first?.sha256)
        XCTAssertTrue(part.recordJSON.contains("Demo.kicad_sym"))
        XCTAssertEqual(fake.archives().last, RemoteTestSupport.chunkPath)

        let library = try await service.downloadLibrary(id: "lib-a")
        XCTAssertTrue(library.cached)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: library.path)), fixture.packageBytes)

        let firstModel = try await service.downloadModel(id: fixture.model.id)
        XCTAssertFalse(firstModel.cached)
        XCTAssertEqual(firstModel.sha256, fixture.model.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstModel.cachePath))
        let secondModel = try await service.downloadModel(id: fixture.model.id)
        XCTAssertTrue(secondModel.cached)
        XCTAssertEqual(fake.fileCalls().filter { $0.contains("SparkFun-KiCad-Libraries") }.count, 1)

        let full = try await service.downloadFull2D()
        XCTAssertFalse(full.cached)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: full.path)), fixture.fullPackageBytes)
        let fullAgain = try await service.downloadFull2D()
        XCTAssertTrue(fullAgain.cached)
    }

    func testFull2DCacheSupportsOfflinePartSearchAndRead() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let online = FakeRemoteNetwork(fixture: fixture)
        let first = ElectronicsRemoteService(storeRoot: root, network: online.network())
        _ = try await first.refresh()
        let full = try await first.downloadFull2D()
        XCTAssertFalse(full.cached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: full.path))

        let offline = FakeRemoteNetwork(fixture: fixture, offline: true)
        let second = ElectronicsRemoteService(storeRoot: root, network: offline.network())
        let page = try await second.searchParts(libraryID: "lib-a", query: .init(text: "Demo", limit: 10))
        XCTAssertEqual(page.total, 1)
        let part = try await second.readPart(libraryID: "lib-a", id: try XCTUnwrap(page.parts.first?.id))
        XCTAssertTrue(part.recordJSON.contains("Demo.kicad_sym"))
        XCTAssertTrue(offline.dataCalls().isEmpty)
        XCTAssertTrue(offline.fileCalls().isEmpty)
    }

    func testIntegrityFailurePreservesInstalledSnapshotAndDoesNotRetry() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeRemoteNetwork(fixture: fixture)
        let service = ElectronicsRemoteService(storeRoot: root, network: fake.network())
        _ = try await service.refresh()
        fake.corruptCatalog = true
        do {
            _ = try await service.refresh()
            XCTFail("tampered catalogue must not install")
        } catch let error as ElectronicsRemoteError {
            guard case .integrity = error else { return XCTFail("expected integrity error, got \(error)") }
        }
        let status = try await service.status()
        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.tag, "data-v1-" + RemoteTestSupport.versionSuffix)
        XCTAssertEqual(fake.dataCalls().filter { $0.hasSuffix("/catalog.json") }.count, 2)
    }

    func testCancellationLeavesExistingModelCacheAndNoNewAsset() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeRemoteNetwork(fixture: fixture)
        let service = ElectronicsRemoteService(storeRoot: root, network: fake.network())
        _ = try await service.refresh()
        let cached = try await service.downloadModel(id: fixture.model.id)
        XCTAssertFalse(cached.cached)
        fake.slowFile = true
        let task = Task { try await service.downloadLibrary(id: "lib-a") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled transfer must not succeed")
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
        let still = try await service.downloadModel(id: fixture.model.id)
        XCTAssertTrue(still.cached)
        let asset = await service.store.cachedAsset(name: "lib-a-2d.zip",
            sha256: fake.fixture.publication.assets.first(where: { $0.name == "lib-a-2d.zip" })!.sha256,
            bytes: fake.fixture.packageBytes.count)
        XCTAssertNil(asset)
    }

    func testProgressReportsRealBytes() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeRemoteNetwork(fixture: fixture)
        let service = ElectronicsRemoteService(storeRoot: root, network: fake.network())
        _ = try await service.refresh()
        let collector = ProgressCollector()
        _ = try await service.downloadModel(id: fixture.model.id,
            progress: .init { received, expected in collector.record(received, expected) })
        XCTAssertEqual(collector.received.max(), Int64(fixture.modelBytes.count))
        XCTAssertEqual(collector.expected.max(), Int64(fixture.modelBytes.count))
    }

    func testOnlyExactPublishedIDsAreAccepted() async throws {
        let fixture = try RemoteTestSupport.fixture()
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeRemoteNetwork(fixture: fixture)
        let service = ElectronicsRemoteService(storeRoot: root, network: fake.network())
        _ = try await service.refresh()
        do {
            _ = try await service.downloadModel(id: "https://evil.invalid/model.step")
            XCTFail("arbitrary URL must not be accepted")
        } catch {}
        do {
            _ = try await service.downloadLibrary(id: "../lib-a")
            XCTFail("unsafe library ID must not be accepted")
        } catch {}
        do {
            _ = try await service.downloadModel(id: "model:lib-a:" + RemoteTestSupport.realModelPath + "?x=1")
            XCTFail("unknown exact ID must not be accepted")
        } catch {}
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received: [Int64] = []
    private(set) var expected: [Int64] = []
    func record(_ received: Int64, _ expected: Int64?) {
        lock.withLock {
            self.received.append(received)
            if let expected { self.expected.append(expected) }
        }
    }
}
