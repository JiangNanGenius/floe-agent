// FloeExecutionTests — primary→mirror ordering, bounded fallback and the
// fail-closed contract for the pinned Linux image download.
//
// These checks pin the device-facing mirror promises without a network:
//   * GitHub is contacted first; Gitee second and only after a bounded
//     primary availability failure;
//   * a definite answer, invalid response, local rejection or cancellation
//     never falls back;
//   * a mirror manifest that does not pin the trusted archive is rejected
//     before any piece is fetched;
//   * a piece that fails its pinned SHA-512 fails closed and purges staging.
//
// Reconstruction itself (resume, purge, assembly, whole-archive digest) is
// covered by LinuxGuestShardStagingTests; here the source fetch coordinator
// is exercised end to end with synthetic, genuinely pinned pieces.

import Foundation
import os
import XCTest
import FloeCore
@testable import FloeExecution

final class LinuxGuestImageMirrorContractTests: XCTestCase {
    // MARK: catalog ordering

    func testPinnedImageOrdersGitHubFirstAndGiteeSecond() {
        let trusted = LinuxGuestImageDistributionCatalog.entry(
            id: LinuxGuestImageDistributionCatalog.defaultImageID
        )
        guard let trusted else { return XCTFail("the catalog pins no default image") }

        XCTAssertEqual(trusted.archiveURL.host, "github.com", "GitHub Releases is the trust-bearing primary")
        XCTAssertEqual(trusted.archiveURL.scheme, "https")
        XCTAssertEqual(trusted.mirrors.count, 1, "one Gitee mirror is pinned")

        let mirror = trusted.mirrors[0]
        XCTAssertEqual(mirror.archiveURL.host, "gitee.com")
        XCTAssertEqual(mirror.shardManifestURL.host, "gitee.com")
        XCTAssertEqual(mirror.shardManifestURL.scheme, "https")
        XCTAssertEqual(mirror.shardManifestURL.lastPathComponent, LinuxGuestImageShardManifest.assetName)

        // The mirror never replaces the primary: a separate ordered entry.
        XCTAssertNotEqual(trusted.archiveURL, mirror.archiveURL)
    }

    // MARK: classification

    func testOnlyAvailabilityFailuresAllowTheNextSource() {
        let fallback: [LinuxGuestImageTransferError] = [
            .networkFailure(detail: "x"),
            .serverUnavailable(status: 503, detail: "x"),
            .serverUnavailable(status: nil, detail: "x"),
        ]
        for error in fallback {
            XCTAssertTrue(error.allowsNextSource, "\(error) must activate a mirror")
        }

        let closed: [LinuxGuestImageTransferError] = [
            .responseRejected(status: 404, detail: "x"),
            .responseRejected(status: 403, detail: "x"),
            .responseInvalid(detail: "x"),
            .localRejection(detail: "x"),
            .cancelled,
        ]
        for error in closed {
            XCTAssertFalse(error.allowsNextSource, "\(error) must fail closed")
        }

        // 408/429/5xx are availability; other 4xx are definite answers.
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(LinuxGuestImageTransferError.serverUnavailable(status: status, detail: "").allowsNextSource)
        }
        for status in [400, 401, 403, 404, 409, 410, 451] {
            XCTAssertFalse(LinuxGuestImageTransferError.responseRejected(status: status, detail: "").allowsNextSource)
        }
    }

    // MARK: coordinator fallback

    func testPrimaryNetworkFailureFallsBackToGiteeAndReconstructs() async {
        let fixture = makeFixture()
        let downloader = ScriptedMirrorDownloader(
            primaryFailure: .networkFailure(detail: "primary unreachable"),
            manifest: fixture.manifest,
            pieces: fixture.pieces
        )
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in }
            )
        } catch {
            return XCTFail("a bounded primary network failure must fall back: \(error)")
        }

        let hosts = await downloader.calls.map(\.host)
        XCTAssertEqual(hosts.first, "primary.example", "the primary is contacted first")
        let orderedCalls = await downloader.calls.map(\.url)
        XCTAssertTrue(orderedCalls.contains(fixture.trusted.mirrors[0].shardManifestURL), "the Gitee manifest is fetched")
        XCTAssertTrue(orderedCalls.contains { $0.absoluteString.hasSuffix(fixture.pieceNames[0]) }, "the first piece is fetched")
        let bytes = try? Data(contentsOf: destination)
        let expected = fixture.manifest.shards.reduce(Data()) { $0 + (fixture.pieces[$1.name] ?? Data()) }
        XCTAssertEqual(bytes, expected, "the staged archive was reconstructed from verified mirror pieces")
    }

    func testPrimaryServerUnavailableFallsBack() async {
        let fixture = makeFixture()
        let downloader = ScriptedMirrorDownloader(
            primaryFailure: .serverUnavailable(status: 503, detail: "busy"),
            manifest: fixture.manifest,
            pieces: fixture.pieces
        )
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in }
            )
        } catch {
            return XCTFail("a primary 5xx must fall back: \(error)")
        }
        let expected = fixture.pieces.map(\.value).reduce(Data(), +)
        let actual = try Data(contentsOf: destination)
        if actual != expected {
            XCTFail("actual=\(actual.map { String(format: "%02x", $0) }.joined()) expected=\(expected.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func testDefiniteAnswerDoesNotFallBack() async {
        // 404: another host cannot turn a pinned missing asset into the bytes.
        try await assertNoFallback(primaryFailure: .responseRejected(status: 404, detail: "missing"))
    }

    func testInvalidResponseDoesNotFallBack() async {
        try await assertNoFallback(primaryFailure: .responseInvalid(detail: "bad framing"))
    }

    func testLocalRejectionDoesNotFallBack() async {
        try await assertNoFallback(primaryFailure: .localRejection(detail: "out of space"))
    }

    func testCancellationDoesNotFallBack() async {
        try await assertNoFallback(primaryFailure: .cancelled)
    }

    func testUntrustedShardManifestIsRejectedBeforePieces() async {
        let fixture = makeFixture()
        // Manifest pins a different archive digest: rejected before pieces.
        var manifest = fixture.manifest
        manifest.archiveSHA512 = String(repeating: "a", count: 128)
        let downloader = ScriptedMirrorDownloader(
            primaryFailure: .networkFailure(detail: "offline"),
            manifest: manifest,
            pieces: fixture.pieces
        )
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in }
            )
            XCTFail("a manifest that does not pin the trusted digest must fail")
        } catch let error as LinuxGuestImageInstallError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        let suffixes = await downloader.calls.map(\.url.lastPathComponent)
        XCTAssertFalse(suffixes.contains { fixture.pieceNames.contains($0) }, "no piece may be fetched for an untrusted manifest")
        XCTAssertTrue(suffixes.contains(LinuxGuestImageShardManifest.assetName))
    }

    func testPieceIntegrityFailureFailsClosed() async {
        let fixture = makeFixture()
        let downloader = ScriptedMirrorDownloader(
            primaryFailure: .networkFailure(detail: "offline"),
            manifest: fixture.manifest,
            pieces: fixture.pieces,
            pieceFailure: (fixture.pieceNames[1], .responseInvalid(detail: "shard SHA-512 mismatch"))
        )
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in }
            )
            XCTFail("a piece digest mismatch must fail closed")
        } catch let error as LinuxGuestImageInstallError {
            guard case .downloadFailed(let detail) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(detail.contains("SHA-512"))
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        // The package purges both staging and the assembled destination.
        let staging = LinuxGuestImageShardFetch.stagingDirectory(
            root: destination.deletingLastPathComponent(),
            imageID: fixture.manifest.imageID,
            archiveSHA512: fixture.manifest.archiveSHA512
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testShardManifestValidationChecksContiguityAndSizes() {
        let digest = String(repeating: "b", count: 128)
        let trustedDigest = String(repeating: "c", count: 128)
        let good = LinuxGuestImageShardManifest(
            imageID: "img",
            archive: "a.zip",
            archiveBytes: 10,
            archiveSHA512: trustedDigest,
            shards: [
                .init(index: 0, name: "shards/part-00.bin", bytes: 6, sha512: digest),
                .init(index: 1, name: "shards/part-01.bin", bytes: 4, sha512: digest),
            ]
        )
        XCTAssertNil(good.validationFailure(imageID: "img", archiveSHA512: trustedDigest))

        let gapped = LinuxGuestImageShardManifest(
            imageID: "img",
            archive: "a.zip",
            archiveBytes: 4,
            archiveSHA512: trustedDigest,
            shards: [.init(index: 2, name: "shards/part-02.bin", bytes: 4, sha512: digest)]
        )
        XCTAssertNotNil(gapped.validationFailure(imageID: "img", archiveSHA512: trustedDigest))

        let wrongSize = LinuxGuestImageShardManifest(
            imageID: "img",
            archive: "a.zip",
            archiveBytes: 99,
            archiveSHA512: trustedDigest,
            shards: [.init(index: 0, name: "shards/part-00.bin", bytes: 4, sha512: digest)]
        )
        XCTAssertNotNil(wrongSize.validationFailure(imageID: "img", archiveSHA512: trustedDigest))
    }

    // MARK: helpers

    private struct Fixture {
        let trusted: LinuxGuestTrustedImage
        let manifest: LinuxGuestImageShardManifest
        let pieces: [String: Data]
        let pieceNames: [String]
    }

    private func makeFixture() -> Fixture {
        let pieceNames = ["shards/part-00.bin", "shards/part-01.bin"]
        let pieceBytes = [Data("first-piece ".utf8), Data("second-piece".utf8)]
        let archive = pieceBytes.reduce(Data(), +)
        let archiveDigest = FloeDigest.sha512Hex(archive)
        let manifest = LinuxGuestImageShardManifest(
            imageID: "img",
            archive: "archive.zip",
            archiveBytes: archive.count,
            archiveSHA512: archiveDigest,
            shards: zip(pieceNames, pieceBytes).enumerated().map { index, pair in
                LinuxGuestImageShard(
                    index: index,
                    name: pair.0,
                    bytes: pair.1.count,
                    sha512: FloeDigest.sha512Hex(pair.1)
                )
            }
        )
        let trusted = LinuxGuestTrustedImage(
            id: "img",
            archiveURL: URL(string: "https://primary.example/archive.zip")!,
            mirrors: [
                LinuxGuestImageMirror(
                    archiveURL: URL(string: "https://gitee.example/archive.zip")!,
                    shardManifestURL: URL(string: "https://gitee.example/shard-manifest.json")!
                )
            ],
            archiveSHA512: archiveDigest,
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://primary.example/tag",
                license: "test",
                distributionAllowed: true
            )
        )
        return Fixture(
            trusted: trusted,
            manifest: manifest,
            pieces: Dictionary(uniqueKeysWithValues: zip(pieceNames, pieceBytes)),
            pieceNames: pieceNames
        )
    }

    private func assertNoFallback(primaryFailure: LinuxGuestImageTransferError) async {
        let fixture = makeFixture()
        let downloader = ScriptedMirrorDownloader(
            primaryFailure: primaryFailure,
            manifest: fixture.manifest,
            pieces: fixture.pieces
        )
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in }
            )
            XCTFail("expected the primary failure to stay closed")
        } catch let error as LinuxGuestImageInstallError {
            if case .cancelled = primaryFailure {
                guard case .cancelled = error else { return XCTFail("cancellation must map to cancelled") }
            } else {
                guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
            }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        let hosts = await downloader.calls.map(\.host)
        XCTAssertEqual(hosts, ["primary.example"], "only the primary is contacted")
    }

    private func makeDestination() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mirror-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("archive.zip")
    }
}

// MARK: - fake downloader

/// Scripted downloader for the coordinator. The primary request fails with the
/// supplied classification; the manifest request writes the JSON manifest; a
/// piece request writes that piece's real bytes (or fails with a per-piece
/// classification). Route recognition is exact, and the call log is ordered.
private final class ScriptedMirrorDownloader: LinuxGuestImageDownloading, @unchecked Sendable {
    struct Call: Sendable { let url: URL; var host: String { url.host ?? "?" } }

    let primaryFailure: LinuxGuestImageTransferError
    let manifest: LinuxGuestImageShardManifest
    let pieces: [String: Data]
    let pieceFailure: (name: String, failure: LinuxGuestImageTransferError)?

    private var recordedCalls: [Call] = []
    private let callLock = OSAllocatedUnfairLock(initialState: [Call]())

    init(
        primaryFailure: LinuxGuestImageTransferError,
        manifest: LinuxGuestImageShardManifest,
        pieces: [String: Data],
        pieceFailure: (name: String, failure: LinuxGuestImageTransferError)? = nil
    ) {
        self.primaryFailure = primaryFailure
        self.manifest = manifest
        self.pieces = pieces
        self.pieceFailure = pieceFailure
    }

    var calls: [Call] {
        callLock.withLock { $0 }
    }

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        callLock.withLock { $0.append(Call(url: url)) }

        if url.host == "primary.example" {
            throw primaryFailure
        }
        if url.lastPathComponent == LinuxGuestImageShardManifest.assetName {
            let encoded: Data
            do {
                encoded = try JSONEncoder().encode(manifest)
            } catch {
                throw LinuxGuestImageTransferError.responseInvalid(detail: "cannot encode manifest: \(error.localizedDescription)")
            }
            try await write(encoded, to: destination)
            return
        }
        guard let name = pieces.keys.first(where: { url.absoluteString.hasSuffix($0) }) else {
            throw .responseInvalid(detail: "unexpected request \(url.lastPathComponent)")
        }
        if let pieceFailure, pieceFailure.name == name {
            throw pieceFailure.failure
        }
        guard let payload = pieces[name] else {
            throw .responseInvalid(detail: "no payload for \(name)")
        }
        try await write(payload, to: destination)
        onProgress(Int64(payload.count), Int64(payload.count))
    }

    private func write(_ payload: Data, to destination: URL) async throws(LinuxGuestImageTransferError) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: destination)
        } catch {
            throw LinuxGuestImageTransferError.localRejection(detail: error.localizedDescription)
        }
    }
}
