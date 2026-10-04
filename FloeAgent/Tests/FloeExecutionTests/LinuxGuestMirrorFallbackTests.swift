// FloeExecutionTests — primary→mirror ordering, bounded failover and the
// fail-closed contract for the pinned Linux image download.
//
// These checks pin the device-facing mirror promises without a network:
//   * the shipping catalog pins no Gitee (or other unverified) URLs;
//   * the primary is contacted first; a mirror is contacted only after a
//     bounded primary availability failure;
//   * with multiple mirrors, order is strict: a failed first mirror moves to
//     the second and a successful second mirror finishes the job;
//   * a definite answer, invalid/content-shaped response, local rejection or
//     cancellation never switches sources, including from one mirror to the
//     next;
//   * a mirror serves the archive directly; when a shard manifest URL is also
//     pinned, a direct availability failure reconstructs from verified pieces;
//   * a manifest that does not pin the trusted digest is rejected before any
//     piece is fetched, and a piece digest failure fails closed.
//
// Reconstruction itself (resume, purge, assembly, whole-archive digest) is
// covered by LinuxGuestShardStagingTests; here the source fetch coordinator
// is exercised end to end with synthetic, genuinely pinned bytes.

import Foundation
import os
import XCTest
import FloeCore
@testable import FloeExecution

final class LinuxGuestImageMirrorContractTests: XCTestCase {
    // MARK: shipping catalog

    func testShippingCatalogContainsNoGiteeURLs() {
        // Gitee stays an independent distribution channel (its CI
        // synchronization is untouched), but no Gitee download URL may ship in
        // the App catalog: Gitee is not an automatic fallback/accelerator.
        var urls: [URL] = []
        for image in LinuxGuestImageDistributionCatalog.bundled {
            urls.append(image.archiveURL)
            for mirror in image.mirrors {
                urls.append(mirror.archiveURL)
                if let shardManifestURL = mirror.shardManifestURL {
                    urls.append(shardManifestURL)
                }
            }
        }
        for url in urls {
            XCTAssertNotEqual(url.host, "gitee.com", "no Gitee host may be preinstalled: \(url)")
            XCTAssertFalse(url.absoluteString.lowercased().contains("gitee"),
                           "no Gitee URL may be preinstalled: \(url)")
            XCTAssertEqual(url.scheme, "https", "every pinned URL must be HTTPS")
        }
    }

    func testNewDefaultImageUsesPrimaryUntilMirrorsAreVerified() {
        let current = LinuxGuestImageDistributionCatalog.entry(
            id: LinuxGuestImageDistributionCatalog.defaultImageID
        )
        guard let current else { return XCTFail("the catalog pins no default image") }
        XCTAssertEqual(current.archiveURL.host, "github.com", "GitHub Releases is the trust-bearing primary")
        XCTAssertTrue(current.mirrors.isEmpty, "the new archive has no independently verified mirror yet")

        let previous = LinuxGuestImageDistributionCatalog.entry(
            id: "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1"
        )
        guard let previous else { return XCTFail("the catalog must retain the prior SMP image") }
        XCTAssertEqual(previous.mirrors.map { $0.archiveURL.host }, ["gh-proxy.com", "ghproxy.net"],
                       "mirrors keep the declared, verified order")

        for mirror in previous.mirrors {
            XCTAssertEqual(mirror.archiveURL.scheme, "https")
            XCTAssertNil(mirror.shardManifestURL, "both verified mirrors are direct whole-archive mirrors")
            XCTAssertNotEqual(mirror.archiveURL, previous.archiveURL, "a mirror never replaces the primary URL")
            // Each direct mirror addresses the exact same pinned archive bytes.
            XCTAssertTrue(
                mirror.archiveURL.absoluteString.hasSuffix(previous.archiveURL.absoluteString),
                "the accelerator URL must name the exact primary archive path"
            )
        }
    }

    func testLegacyImagePinsNoMirror() {
        let legacy = LinuxGuestImageDistributionCatalog.entry(id: "floe-debian13-riscv64-20260922.2")
        guard let legacy else { return XCTFail("the catalog no longer lists the legacy image") }
        XCTAssertEqual(legacy.archiveURL.host, "github.com")
        XCTAssertEqual(legacy.mirrors.count, 0,
                       "no mirror may ship for the legacy image without verified byte availability")
    }

    // MARK: classification

    func testOnlyAvailabilityFailuresAllowTheNextSource() {
        let fallback: [LinuxGuestImageTransferError] = [
            .networkFailure(detail: "x"),
            .serverUnavailable(status: 503, detail: "x"),
            .serverUnavailable(status: nil, detail: "x"),
        ]
        for error in fallback {
            XCTAssertTrue(error.allowsNextSource, "\(error) must activate the next source")
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

    // MARK: ordered direct-mirror failover

    /// The core multi-mirror proof: primary unavailable → first direct mirror
    /// unavailable → second direct mirror serves the pinned bytes. Sources are
    /// contacted strictly in declared order and no other source is invented.
    func testPrimaryAndFirstMirrorUnavailableFailOverToSecondDirectMirror() async {
        let fixture = makeFixture(mirrorCount: 2)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "primary unreachable"))),
            .init(match: { $0.host == "mirror1.example" }, outcome: .failure(.serverUnavailable(status: 503, detail: "busy"))),
            .init(match: { $0.host == "mirror2.example" }, outcome: .payload(fixture.archive)),
        ])
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
            return XCTFail("availability failures must fail over in order: \(error)")
        }

        let hosts = downloader.calls.map(\.url.host)
        XCTAssertEqual(hosts, ["primary.example", "mirror1.example", "mirror2.example"],
                       "sources are contacted strictly in primary, mirror1, mirror2 order")
        XCTAssertEqual(try? Data(contentsOf: destination), fixture.archive,
                       "the second mirror's bytes are the staged archive")
    }

    func testPrimaryNetworkFailureFailsOverToDirectMirror() async {
        let fixture = makeFixture(mirrorCount: 1)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.host == "mirror1.example" }, outcome: .payload(fixture.archive)),
        ])
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try? await LinuxGuestImageSourceFetch.fetch(
            image: fixture.trusted,
            to: destination,
            maxBytes: 1024,
            downloader: downloader,
            onProgress: { _, _ in }
        )
        XCTAssertEqual(downloader.calls.map(\.url.host), ["primary.example", "mirror1.example"])
        XCTAssertEqual(try? Data(contentsOf: destination), fixture.archive)
    }

    func testUnreachablePrimaryWithoutPinnedMirrorFailsClosed() async {
        let fixture = makeFixture(mirrorCount: 0)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { _ in true }, outcome: .failure(.responseInvalid(detail: "must not be contacted"))),
        ])
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
            XCTFail("with no pinned mirror an unavailable primary must fail, never invent a source")
        } catch let error as LinuxGuestImageInstallError {
            guard case .downloadFailed = error else { return XCTFail("expected the bounded download failure, got \(error)") }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(downloader.calls.map(\.url.host), ["primary.example"],
                       "only the primary is contacted when no mirror is pinned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "no partial archive may survive a closed failure")
    }

    // MARK: no-switch contract

    func testDefiniteAnswerDoesNotFallBack() async {
        // 404: another host cannot turn a pinned missing asset into the bytes.
        await assertNoFallback(primaryFailure: .responseRejected(status: 404, detail: "missing"))
    }

    func testInvalidResponseDoesNotFallBack() async {
        await assertNoFallback(primaryFailure: .responseInvalid(detail: "bad framing"))
    }

    func testLocalRejectionDoesNotFallBack() async {
        await assertNoFallback(primaryFailure: .localRejection(detail: "out of space"))
    }

    func testCancellationDoesNotFallBack() async {
        await assertNoFallback(primaryFailure: .cancelled)
    }

    /// A content-shaped fault from the first mirror must not move to the
    /// second mirror: wrong bytes from one host are never "repaired" by
    /// trying another, since the pinned digest — not the host — is on trial.
    func testMirrorContentFaultDoesNotSwitchToNextMirror() async {
        let fixture = makeFixture(mirrorCount: 2)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.host == "mirror1.example" },
                  outcome: .failure(.responseInvalid(detail: "archive content fault"))),
            .init(match: { $0.host == "mirror2.example" }, outcome: .payload(fixture.archive)),
        ])
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
            XCTFail("a mirror content fault must fail closed")
        } catch let error as LinuxGuestImageInstallError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(downloader.calls.map(\.url.host), ["primary.example", "mirror1.example"],
                       "a content fault on mirror1 must never contact mirror2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Owner cancellation landing between the failed primary and the mirror
    /// loop stops the install: no mirror is contacted.
    func testOwnerCancellationBetweenSourcesStopsFailover() async {
        let fixture = makeFixture(mirrorCount: 2)
        let token = CancellationToken()
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" },
                  outcome: .failure(.networkFailure(detail: "offline")),
                  onRequest: { token.cancel() }),
            .init(match: { $0.host == "mirror1.example" }, outcome: .payload(fixture.archive)),
            .init(match: { $0.host == "mirror2.example" }, outcome: .payload(fixture.archive)),
        ])
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in },
                isCancelled: { token.isCancelled }
            )
            XCTFail("an owner cancel between sources must stop the failover")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else { return XCTFail("expected cancelled, got \(error)") }
        } catch let error as LinuxGuestImageTransferError {
            // The between-sources checkpoint throws the transfer class; both
            // spellings mean the same cooperative stop.
            guard case .cancelled = error else { return XCTFail("expected cancelled, got \(error)") }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(downloader.calls.map(\.url.host), ["primary.example"],
                       "no mirror is contacted after an owner cancel")
    }

    // MARK: direct → shard fallback within one mirror

    /// Direct request fails with a bounded availability error; the pinned
    /// shard manifest validates and the archive is reconstructed from pieces.
    func testDirectFailureReconstructsFromPinnedShardManifest() async {
        let fixture = makeShardMirrorFixture()
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.host == "shard-mirror.example" && $0.lastPathComponent == "archive.zip" },
                  outcome: .failure(.serverUnavailable(status: 502, detail: "direct busy"))),
            .init(match: { $0.lastPathComponent == LinuxGuestImageShardManifest.assetName },
                  outcome: .payload(fixture.encodedManifest)),
            .init(match: { $0.lastPathComponent == fixture.pieceNames[0].split(separator: "/").last.map(String.init) },
                  outcome: .payload(fixture.pieces[fixture.pieceNames[0]]!)),
            .init(match: { $0.lastPathComponent == fixture.pieceNames[1].split(separator: "/").last.map(String.init) },
                  outcome: .payload(fixture.pieces[fixture.pieceNames[1]]!)),
        ])
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
            return XCTFail("a direct failure must reconstruct from the pinned piece set: \(error)")
        }
        let suffixes = downloader.calls.map(\.url.lastPathComponent)
        XCTAssertEqual(suffixes.filter { $0 == LinuxGuestImageShardManifest.assetName }.count, 1)
        let expected = fixture.pieceNames.compactMap { fixture.pieces[$0] }.reduce(Data(), +)
        XCTAssertEqual(try? Data(contentsOf: destination), expected, "reconstructed bytes match the pinned archive")
    }

    /// Direct request fails and the mirror pins no shard manifest: the
    /// availability error falls through to the NEXT mirror instead of being
    /// treated as a closed failure.
    func testDirectFailureWithoutShardManifestFallsThroughToNextMirror() async {
        let fixture = makeFixture(mirrorCount: 2)
        // mirror1 stays a direct-only mirror (the default); mirror2 serves.
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.host == "mirror1.example" },
                  outcome: .failure(.serverUnavailable(status: 503, detail: "busy"))),
            .init(match: { $0.host == "mirror2.example" }, outcome: .payload(fixture.archive)),
        ])
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
            return XCTFail("a direct-only mirror's availability failure must reach the next mirror: \(error)")
        }
        XCTAssertEqual(downloader.calls.map(\.url.host),
                       ["primary.example", "mirror1.example", "mirror2.example"])
        XCTAssertEqual(try? Data(contentsOf: destination), fixture.archive)
    }

    func testUntrustedShardManifestIsRejectedBeforePieces() async {
        let fixture = makeShardMirrorFixture()
        // Manifest pins a different archive digest: rejected before pieces.
        var badManifest = fixture.manifest
        badManifest.archiveSHA512 = String(repeating: "a", count: 128)
        let encodedBad = try! JSONEncoder().encode(badManifest)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.lastPathComponent == "archive.zip" },
                  outcome: .failure(.serverUnavailable(status: 502, detail: "busy"))),
            .init(match: { $0.lastPathComponent == LinuxGuestImageShardManifest.assetName },
                  outcome: .payload(encodedBad)),
            .init(match: { $0.lastPathComponent.hasPrefix("part-") },
                  outcome: .failure(.responseInvalid(detail: "piece must never be requested"))),
        ])
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
        let suffixes = downloader.calls.map(\.url.lastPathComponent)
        XCTAssertFalse(suffixes.contains { $0.hasPrefix("part-") }, "no piece may be fetched for an untrusted manifest")
        XCTAssertTrue(suffixes.contains(LinuxGuestImageShardManifest.assetName))
    }

    func testPieceIntegrityFailureFailsClosed() async {
        let fixture = makeShardMirrorFixture()
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.lastPathComponent == "archive.zip" },
                  outcome: .failure(.serverUnavailable(status: 502, detail: "busy"))),
            .init(match: { $0.lastPathComponent == LinuxGuestImageShardManifest.assetName },
                  outcome: .payload(fixture.encodedManifest)),
            .init(match: { $0.lastPathComponent == "part-00.bin" },
                  outcome: .payload(fixture.pieces[fixture.pieceNames[0]]!)),
            .init(match: { $0.lastPathComponent == "part-01.bin" },
                  outcome: .failure(.responseInvalid(detail: "shard SHA-512 mismatch"))),
        ])
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

    /// Owner cancellation observed right after the manifest download stops
    /// reconstruction before the first piece is fetched.
    func testOwnerCancellationAfterManifestStopsBeforePieces() async {
        let fixture = makeShardMirrorFixture()
        let token = CancellationToken()
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(.networkFailure(detail: "offline"))),
            .init(match: { $0.lastPathComponent == "archive.zip" },
                  outcome: .failure(.serverUnavailable(status: 502, detail: "busy"))),
            .init(match: { $0.lastPathComponent == LinuxGuestImageShardManifest.assetName },
                  outcome: .payload(fixture.encodedManifest),
                  onRequest: { token.cancel() }),
            .init(match: { $0.lastPathComponent.hasPrefix("part-") },
                  outcome: .failure(.responseInvalid(detail: "piece must never be requested"))),
        ])
        let destination = makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            try await LinuxGuestImageSourceFetch.fetch(
                image: fixture.trusted,
                to: destination,
                maxBytes: 1024,
                downloader: downloader,
                onProgress: { _, _ in },
                isCancelled: { token.isCancelled }
            )
            XCTFail("owner cancellation after the manifest must stop reconstruction")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else { return XCTFail("expected cancelled, got \(error)") }
        } catch let error as LinuxGuestImageTransferError {
            // The post-manifest checkpoint throws the transfer spelling.
            guard case .cancelled = error else { return XCTFail("expected cancelled, got \(error)") }
        } catch {
            return XCTFail("unexpected error \(error)")
        }
        let suffixes = downloader.calls.map(\.url.lastPathComponent)
        XCTAssertFalse(suffixes.contains { $0.hasPrefix("part-") }, "no piece may be fetched after cancellation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: manifest validation

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

    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct DirectFixture {
        let trusted: LinuxGuestTrustedImage
        let archive: Data
    }

    private func makeFixture(mirrorCount: Int) -> DirectFixture {
        let archive = Data("first-piece second-piece".utf8)
        let digest = FloeDigest.sha512Hex(archive)
        let mirrors = (0..<mirrorCount).map { index in
            LinuxGuestImageMirror(
                archiveURL: URL(string: "https://mirror\(index + 1).example/archive.zip")!
            )
        }
        let trusted = LinuxGuestTrustedImage(
            id: "img",
            archiveURL: URL(string: "https://primary.example/archive.zip")!,
            mirrors: mirrors,
            archiveSHA512: digest,
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://primary.example/tag",
                license: "test",
                distributionAllowed: true
            )
        )
        return DirectFixture(trusted: trusted, archive: archive)
    }

    private struct ShardMirrorFixture {
        let trusted: LinuxGuestTrustedImage
        let manifest: LinuxGuestImageShardManifest
        let encodedManifest: Data
        let pieces: [String: Data]
        let pieceNames: [String]
    }

    private func makeShardMirrorFixture() -> ShardMirrorFixture {
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
        let encodedManifest = try! JSONEncoder().encode(manifest)
        let manifestURL = URL(string: "https://shard-mirror.example/tag/shard-manifest.json")!
        let trusted = LinuxGuestTrustedImage(
            id: "img",
            archiveURL: URL(string: "https://primary.example/archive.zip")!,
            mirrors: [
                LinuxGuestImageMirror(
                    archiveURL: URL(string: "https://shard-mirror.example/archive.zip")!,
                    shardManifestURL: manifestURL
                )
            ],
            archiveSHA512: archiveDigest,
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://primary.example/tag",
                license: "test",
                distributionAllowed: true
            )
        )
        return ShardMirrorFixture(
            trusted: trusted,
            manifest: manifest,
            encodedManifest: encodedManifest,
            pieces: Dictionary(uniqueKeysWithValues: zip(pieceNames, pieceBytes)),
            pieceNames: pieceNames
        )
    }

    private func assertNoFallback(primaryFailure: LinuxGuestImageTransferError) async {
        let fixture = makeFixture(mirrorCount: 2)
        let downloader = ScriptedDownloader(rules: [
            .init(match: { $0.host == "primary.example" }, outcome: .failure(primaryFailure)),
            .init(match: { $0.host == "mirror1.example" }, outcome: .payload(fixture.archive)),
            .init(match: { $0.host == "mirror2.example" }, outcome: .payload(fixture.archive)),
        ])
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
        XCTAssertEqual(downloader.calls.map(\.url.host), ["primary.example"], "only the primary is contacted")
    }

    private func makeDestination() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mirror-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("archive.zip")
    }
}

// MARK: - fake downloader

/// Generic scripted downloader. Rules are evaluated in order; the first rule
/// whose predicate matches the URL either writes a payload to the destination
/// or fails with the classified error. An unmatched URL fails closed as an
/// invalid response. `onRequest` lets a rule flip a cancellation token at a
/// precise point in the ordered call sequence. The call log is ordered.
private final class ScriptedDownloader: LinuxGuestImageDownloading, @unchecked Sendable {
    struct Call: Sendable { let url: URL }

    enum Outcome: Sendable {
        case payload(Data)
        case failure(LinuxGuestImageTransferError)
    }

    struct Rule: Sendable {
        let matches: @Sendable (URL) -> Bool
        let outcome: Outcome
        let onRequest: (@Sendable () -> Void)?

        init(
            match: @escaping @Sendable (URL) -> Bool,
            outcome: Outcome,
            onRequest: (@Sendable () -> Void)? = nil
        ) {
            self.matches = match
            self.outcome = outcome
            self.onRequest = onRequest
        }
    }

    private let rules: [Rule]
    private let callLock = OSAllocatedUnfairLock(initialState: [Call]())

    init(rules: [Rule]) {
        self.rules = rules
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
        guard let rule = rules.first(where: { $0.matches(url) }) else {
            throw .responseInvalid(detail: "unexpected request \(url.absoluteString)")
        }
        rule.onRequest?()
        switch rule.outcome {
        case .failure(let error):
            throw error
        case .payload(let payload):
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: destination)
            } catch {
                throw .localRejection(detail: error.localizedDescription)
            }
            onProgress(Int64(payload.count), Int64(payload.count))
        }
    }
}
