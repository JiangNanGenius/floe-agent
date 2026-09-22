// FloeExecutionTests — shard-level resume, staging hygiene and purge
// semantics of `LinuxGuestImageShardFetch`.
//
// The pinned mirror publishes the archive as a manifest plus pieces whose
// names may live in a subdirectory ("shards/part-00.bin"). A failed install
// must resume after the pieces that already passed their SHA-512 check
// instead of re-downloading them, while untrusted content must leave nothing
// reusable behind. These tests call the fetcher directly with a piece-serving
// fake downloader, so no network is involved.

import Foundation
import os
import XCTest
import FloeCore
@testable import FloeExecution

final class LinuxGuestShardStagingTests: XCTestCase {
    private let baseURL = URL(string: "https://mirror.example/releases/download/tag/")!

    // MARK: resume

    /// The coordinator's regression: after a network failure on part-01, a
    /// second fetch must not re-download the already verified part-00, and
    /// piece names live under "shards/".
    func testResumeAfterNetworkFailureReusesVerifiedPieces() async throws {
        let piece0 = Data("first-piece ".utf8)
        let piece1 = Data("second-piece".utf8)
        let manifest = makeManifest(pieces: [("shards/part-00.bin", piece0), ("shards/part-01.bin", piece1)])
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("archive.zip")

        let downloader = PiecemealDownloader(manifest: manifest, pieces: ["shards/part-00.bin": piece0, "shards/part-01.bin": piece1])
        // First attempt: part-01 keeps failing with an availability error.
        downloader.availabilityFailures["shards/part-01.bin"] = .networkFailure(detail: "link dropped")
        do {
            try await LinuxGuestImageShardFetch.fetch(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                to: destination,
                onProgress: { _, _ in }
            )
            XCTFail("the availability failure must surface")
        } catch {
            guard case .networkFailure = error else {
                return XCTFail("expected networkFailure, got \(error)")
            }
        }

        // The verified first piece survived for the retry.
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: root, imageID: manifest.imageID, archiveSHA512: manifest.archiveSHA512
        )
        let stagedPiece0 = staging.appendingPathComponent("shards/part-00.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPiece0.path), "verified piece must be kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // Second attempt succeeds.
        downloader.availabilityFailures["shards/part-01.bin"] = nil
        try await LinuxGuestImageShardFetch.fetch(
            downloader: downloader,
            baseURL: baseURL,
            manifest: manifest,
            to: destination,
            onProgress: { _, _ in }
        )

        XCTAssertEqual(downloader.downloadCount(for: "shards/part-00.bin"), 1, "verified piece is downloaded exactly once")
        XCTAssertGreaterThanOrEqual(downloader.downloadCount(for: "shards/part-01.bin"), 3, "first attempt retried the failing piece")
        XCTAssertEqual(try Data(contentsOf: destination), piece0 + piece1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "staging is removed after success")
    }

    /// Stale cleanup must recognize pieces by normalized relative path:
    /// a nested piece directory is not "unknown", while an unrelated stale
    /// file is removed.
    func testStalePurgeKeepsNestedVerifiedPiecesAndRemovesJunk() async throws {
        let piece0 = Data("kept-piece ".utf8)
        let piece1 = Data("second-piece".utf8)
        let manifest = makeManifest(pieces: [("shards/part-00.bin", piece0), ("shards/part-01.bin", piece1)])
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("archive.zip")
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: root, imageID: manifest.imageID, archiveSHA512: manifest.archiveSHA512
        )

        // Seed staging as a previous attempt left it: one verified nested
        // piece plus one file this manifest does not know about.
        let stagedPiece0 = staging.appendingPathComponent("shards/part-00.bin")
        try FileManager.default.createDirectory(at: stagedPiece0.deletingLastPathComponent(), withIntermediateDirectories: true)
        try piece0.write(to: stagedPiece0)
        try Data("junk".utf8).write(to: staging.appendingPathComponent("stale-junk.bin"))

        let downloader = PiecemealDownloader(manifest: manifest, pieces: ["shards/part-00.bin": piece0, "shards/part-01.bin": piece1])
        downloader.availabilityFailures["shards/part-01.bin"] = .networkFailure(detail: "offline")
        do {
            try await LinuxGuestImageShardFetch.fetch(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                to: destination,
                onProgress: { _, _ in }
            )
            XCTFail("expected the availability failure")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPiece0.path), "nested verified piece must survive the purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("stale-junk.bin").path), "stale files must be purged")
        XCTAssertEqual(downloader.downloadCount(for: "shards/part-00.bin"), 0, "seeded verified piece is reused, not refetched")
    }

    // MARK: purge semantics

    func testContentFailurePurgesStagingAndAssembledDestination() async throws {
        // Pieces that satisfy their own pinned digests but concatenate into
        // bytes the manifest's archive digest does not pin.
        let piece0 = Data("aaaa".utf8)
        let piece1 = Data("bbbb".utf8)
        var manifest = makeManifest(pieces: [("part-00.bin", piece0), ("part-01.bin", piece1)])
        manifest.archiveSHA512 = FloeDigest.sha512Hex(Data("different-bytes".utf8))
        manifest.archiveBytes = piece0.count + piece1.count

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("archive.zip")
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: root, imageID: manifest.imageID, archiveSHA512: manifest.archiveSHA512
        )

        let downloader = PiecemealDownloader(manifest: manifest, pieces: ["part-00.bin": piece0, "part-01.bin": piece1])
        do {
            try await LinuxGuestImageShardFetch.fetch(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                to: destination,
                onProgress: { _, _ in }
            )
            XCTFail("a mismatched assembled digest must fail")
        } catch {
            guard case .responseInvalid = error else {
                return XCTFail("expected responseInvalid, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "untrusted staging is purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the untrusted archive is removed")
    }

    func testPieceDigestMismatchPurgesStaging() async throws {
        let piece0 = Data("good-piece-00".utf8)
        let manifest = makeManifest(pieces: [("part-00.bin", piece0)])
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: root, imageID: manifest.imageID, archiveSHA512: manifest.archiveSHA512
        )

        let downloader = PiecemealDownloader(manifest: manifest, pieces: ["part-00.bin": piece0])
        downloader.corruptPieces.insert("part-00.bin")
        do {
            try await LinuxGuestImageShardFetch.fetch(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                to: root.appendingPathComponent("archive.zip"),
                onProgress: { _, _ in }
            )
            XCTFail("a corrupted piece must fail")
        } catch {
            guard case .responseInvalid = error else {
                return XCTFail("expected responseInvalid, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCancellationKeepsVerifiedPieces() async throws {
        let piece0 = Data("cancel-piece0".utf8)
        let piece1 = Data("cancel-piece1".utf8)
        let manifest = makeManifest(pieces: [("part-00.bin", piece0), ("part-01.bin", piece1)])
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: root, imageID: manifest.imageID, archiveSHA512: manifest.archiveSHA512
        )

        let downloader = PiecemealDownloader(manifest: manifest, pieces: ["part-00.bin": piece0, "part-01.bin": piece1])
        downloader.availabilityFailures["part-01.bin"] = .cancelled
        do {
            try await LinuxGuestImageShardFetch.fetch(
                downloader: downloader,
                baseURL: baseURL,
                manifest: manifest,
                to: root.appendingPathComponent("archive.zip"),
                onProgress: { _, _ in }
            )
            XCTFail("cancellation must surface")
        } catch {
            guard case .cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("part-00.bin").path), "verified pieces survive cancellation")
    }

    // MARK: staging identity

    func testStagingDirectoryIsStablePerPinAndUniqueAcrossVersions() {
        let digestA = String(repeating: "a", count: 128)
        let digestB = String(repeating: "b", count: 128)
        let root = URL(fileURLWithPath: "/tmp/floe-staging-test")

        let first = LinuxGuestImageShardFetch.stagingDirectory(root: root, imageID: "img", archiveSHA512: digestA)
        let same = LinuxGuestImageShardFetch.stagingDirectory(root: root, imageID: "img", archiveSHA512: digestA)
        let otherDigest = LinuxGuestImageShardFetch.stagingDirectory(root: root, imageID: "img", archiveSHA512: digestB)
        let otherImage = LinuxGuestImageShardFetch.stagingDirectory(root: root, imageID: "img2", archiveSHA512: digestA)

        XCTAssertEqual(first, same, "the same pin maps to the same staging directory (resume)")
        XCTAssertNotEqual(first, otherDigest, "a new pinned digest must not reuse the old staging directory")
        XCTAssertNotEqual(first, otherImage, "a different image must not reuse the staging directory")
        XCTAssertTrue(first.lastPathComponent.hasPrefix(".shards-"))
    }

    // MARK: helpers

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-shard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeManifest(pieces: [(name: String, bytes: Data)]) -> LinuxGuestImageShardManifest {
        let archive = pieces.map(\.bytes).reduce(Data(), +)
        return LinuxGuestImageShardManifest(
            imageID: "img",
            archive: "archive.zip",
            archiveBytes: archive.count,
            archiveSHA512: FloeDigest.sha512Hex(archive),
            shards: pieces.enumerated().map { index, piece in
                LinuxGuestImageShard(
                    index: index,
                    name: piece.name,
                    bytes: piece.bytes.count,
                    sha512: FloeDigest.sha512Hex(piece.bytes)
                )
            }
        )
    }
}

private final class PiecemealDownloader: LinuxGuestImageDownloading, @unchecked Sendable {
    let manifest: LinuxGuestImageShardManifest
    let pieces: [String: Data]
    /// Piece name -> availability failure thrown on every attempt (until cleared).
    var availabilityFailures: [String: LinuxGuestImageTransferError] = [:]
    /// Piece names whose served bytes are corrupted on the first attempt.
    var corruptPieces: Set<String> = []
    /// Async-safe lock over mutable call state.
    private let stateLock = OSAllocatedUnfairLock(
        initialState: (servedCorrupt: Set<String>(), downloadCounts: [String: Int]())
    )

    init(manifest: LinuxGuestImageShardManifest, pieces: [String: Data]) {
        self.manifest = manifest
        self.pieces = pieces
    }

    func downloadCount(for name: String) -> Int {
        stateLock.withLock { $0.downloadCounts[name] ?? 0 }
    }

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        let name = manifest.shards.first { url.absoluteString.hasSuffix($0.name) }?.name ?? url.lastPathComponent
        // Count every request, including ones that fail, so retries are observable.
        stateLock.withLock { $0.downloadCounts[name, default: 0] += 1 }
        if let failure = availabilityFailures[name] {
            throw failure
        }
        guard let piece = manifest.shards.first(where: { $0.name == name }) else {
            throw .responseInvalid(detail: "no such piece \(name)")
        }
        let payload = stateLock.withLock { state -> Data in
            if corruptPieces.contains(name), !state.servedCorrupt.contains(name) {
                state.servedCorrupt.insert(name)
                return Data("corrupted!".utf8)
            }
            return pieces[name] ?? Data()
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: destination)
        } catch {
            throw .localRejection(detail: error.localizedDescription)
        }
        onProgress(Int64(payload.count), Int64(piece.bytes))
    }
}
