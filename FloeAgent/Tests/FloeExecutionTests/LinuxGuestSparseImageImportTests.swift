// FloeExecutionTests — sparse extraction and bounded budgets for the
// catalog-pinned 16 GiB-class Linux guest image.
//
// The fixtures are small on purpose: hundreds of MiB of *logical* zeros
// compress to a few MiB and exercise exactly the same code paths as the real
// image (sparse writes, catalog-bound budget, CRC and cancellation) without
// ever expanding a 16 GiB disk on the test machine.

import Foundation
import XCTest
import CryptoKit
import FloeCore
import FloeTools
import ZIPFoundation
@testable import FloeExecution

final class LinuxGuestSparseImageImportTests: XCTestCase {
    private var workRoot: URL!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-sparse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LinuxGuestImageDistributionCatalog.clearTestEntries()
        try? FileManager.default.removeItem(at: workRoot)
    }

    // MARK: - Fixture archive

    private struct FixtureImage {
        var archiveURL: URL
        var manifest: LinuxGuestImage
        var diskLogicalBytes: Int64
        /// Non-zero 4 KiB blocks keyed by their logical offset.
        var diskBlocks: [UInt64: Data]
    }

    /// Builds a real zip archive: manifest.json + bbl64.bin + kernel +
    /// a large `disk.img` whose content is zeros except the given 4 KiB blocks.
    private func makeFixture(
        id: String,
        diskLogicalBytes: Int64,
        diskBlocks: [UInt64: Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FixtureImage {
        let bbl = Data("fake-bbl".utf8)
        let kernel = Data("fake-kernel".utf8)
        var manifest = LinuxGuestImage(
            id: id,
            biosPath: "bbl64.bin",
            kernelPath: "kernel-riscv64.bin",
            diskPath: "disk.img",
            diskReadWrite: true,
            cmdline: "console=hvc0",
            qualified: true,
            qualificationEvidence: "sparse fixture",
            qualificationRun: "run-sparse-fixture",
            artifacts: [
                .init(role: .bios, path: "bbl64.bin", sha512: FloeDigest.sha512Hex(bbl), bytes: Int64(bbl.count)),
                .init(role: .kernel, path: "kernel-riscv64.bin", sha512: FloeDigest.sha512Hex(kernel), bytes: Int64(kernel.count)),
            ]
        )
        // Full-disk digest: stream 4 KiB blocks through an incremental hasher
        // so a multi-GiB logical disk never materializes in memory.
        var hasher = SHA512()
        let zeroBlock = Data(count: 4096)
        var cursor: Int64 = 0
        while cursor < diskLogicalBytes {
            hasher.update(data: diskBlocks[UInt64(cursor)] ?? zeroBlock)
            cursor += Int64(zeroBlock.count)
        }
        manifest.artifacts?.append(.init(
            role: .disk, path: "disk.img",
            sha512: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            bytes: diskLogicalBytes
        ))

        let archiveURL = workRoot.appendingPathComponent("\(id).zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let manifestData = try JSONEncoder().encode(manifest)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifestData.count)) { position, size in
            let start = Int(position)
            return manifestData.subdata(in: start..<min(start + size, manifestData.count))
        }
        for (name, data) in [("bbl64.bin", bbl), ("kernel-riscv64.bin", kernel)] {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        try archive.addEntry(
            with: "disk.img", type: .file,
            uncompressedSize: diskLogicalBytes,
            compressionMethod: .deflate
        ) { position, size in
            var chunk = Data(count: size)
            for (blockOffset, block) in diskBlocks {
                let relative = Int64(blockOffset) - position
                guard relative >= 0, relative < Int64(size) else { continue }
                let start = Int(relative)
                let end = min(start + block.count, size)
                chunk.replaceSubrange(start..<end, with: block[0..<(end - start)])
            }
            return chunk
        }
        return FixtureImage(archiveURL: archiveURL, manifest: manifest, diskLogicalBytes: diskLogicalBytes, diskBlocks: diskBlocks)
    }

    /// Registers the fixture as a catalog-pinned image for this test process
    /// (id + archive SHA-512 + published provenance, the same trust shape as
    /// the production catalog).
    private func makeService(fixture: FixtureImage) throws -> LinuxGuestImageInstallationService {
        LinuxGuestImageDistributionCatalog.registerTestEntry(LinuxGuestTrustedImage(
            id: fixture.manifest.id,
            archiveURL: URL(string: "https://example.invalid/floe-sparse-fixture/\(fixture.manifest.id).zip")!,
            mirrors: [],
            archiveSHA512: try FloeDigest.sha512Hex(ofFileAt: fixture.archiveURL),
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://example.invalid/floe-sparse-fixture",
                buildConfigurationURL: nil,
                license: "test fixture",
                distributionAllowed: true
            )
        ))
        let root = workRoot.appendingPathComponent("store-\(fixture.manifest.id)", isDirectory: true)
        return LinuxGuestImageInstallationService(root: root)
    }

    private func allocatedBytes(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    // MARK: - Tests

    /// The pinned-catalog path must accept a logical disk far beyond the
    /// 4 GiB unknown-archive limit, and the zeros must not consume blocks.
    func testCatalogPinnedSparseDiskInstallsWithoutRealBlocks() async throws {
        // 512 MiB logical, two non-zero 4 KiB blocks (offset 4 MiB and the tail).
        let logical: Int64 = 512 * 1024 * 1024
        var tail = Data(count: 4096)
        for index in tail.indices { tail[index] = UInt8(index % 251) }
        let blocks: [UInt64: Data] = [
            4 * 1024 * 1024: Data(repeating: 0x5A, count: 4096),
            UInt64(logical) - 4096: tail,
        ]
        let fixture = try makeFixture(id: "floe-sparse-test-1", diskLogicalBytes: logical, diskBlocks: blocks)
        let service = try makeService(fixture: fixture)
        let image = try await service.installTrustedImage(
            id: fixture.manifest.id,
            downloader: CopyingImageDownloader(archiveURL: fixture.archiveURL)
        )
        XCTAssertEqual(image.id, fixture.manifest.id)

        let diskURL = service.imagesDirectory
            .appendingPathComponent(fixture.manifest.id, isDirectory: true)
            .appendingPathComponent("disk.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
        XCTAssertEqual((attributes[.size] as? Int64), logical, "logical size must equal the declared disk size")
        let allocated = allocatedBytes(of: diskURL)
        // APFS allocates in multi-MiB extents, so assert sparsity by ratio:
        // 8 MiB for a 512 MiB logical disk is the granularity floor, not a leak.
        XCTAssertLessThan(allocated * 32, logical, "mostly-zero disk must stay sparse (allocated \(allocated))")

        // Non-zero content survived, including the tail block.
        let handle = try FileHandle(forReadingFrom: diskURL)
        defer { try? handle.close() }
        for (offset, expected) in blocks {
            try handle.seek(toOffset: offset)
            let read = try handle.read(upToCount: expected.count) ?? Data()
            XCTAssertEqual(read, expected, "content at offset \(offset) must round-trip")
        }
        // A zero region reads back as zeros.
        try handle.seek(toOffset: 64 * 1024 * 1024)
        let zeros = try handle.read(upToCount: 4096) ?? Data()
        XCTAssertEqual(zeros, Data(count: 4096))
    }

    /// An all-zero large member stays fully sparse: the logical length is
    /// kept, the allocation is near zero, and the manifest digest (of zeros)
    /// verifies during promotion.
    func testAllZeroMemberStaysSparse() async throws {
        let logical: Int64 = 128 * 1024 * 1024
        let fixture = try makeFixture(id: "floe-sparse-test-2", diskLogicalBytes: logical, diskBlocks: [:])
        let service = try makeService(fixture: fixture)
        _ = try await service.installTrustedImage(
            id: fixture.manifest.id,
            downloader: CopyingImageDownloader(archiveURL: fixture.archiveURL)
        )
        let diskURL = service.imagesDirectory
            .appendingPathComponent(fixture.manifest.id, isDirectory: true)
            .appendingPathComponent("disk.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
        XCTAssertEqual((attributes[.size] as? Int64), logical)
        let allocated = allocatedBytes(of: diskURL)
        XCTAssertLessThan(allocated, 1024 * 1024, "an all-zero member must allocate almost nothing (allocated \(allocated))")
    }

    /// Unknown archives keep the bounded default: a 5 GiB logical member is
    /// refused, and naming an id that is not pinned must not unlock the budget.
    func testUnknownArchiveKeepsBoundedExtractionLimit() async throws {
        let logical: Int64 = 5 * 1024 * 1024 * 1024
        let fixture = try makeFixture(id: "floe-sparse-test-3", diskLogicalBytes: logical, diskBlocks: [:])
        let service = LinuxGuestImageInstallationService(root: workRoot.appendingPathComponent("store", isDirectory: true))
        do {
            _ = try await service.importArchive(
                at: fixture.archiveURL,
                expectedSHA512: FloeDigest.sha512Hex(ofFileAt: fixture.archiveURL)
            )
            XCTFail("a 5 GiB unknown archive must exceed the standard extraction limit")
        } catch let error as LinuxGuestImageInstallError {
            guard case .extractionLimitExceeded = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        do {
            _ = try await service.importArchive(
                at: fixture.archiveURL,
                expectedSHA512: FloeDigest.sha512Hex(ofFileAt: fixture.archiveURL),
                expectedImageID: "floe-not-in-catalog"
            )
            XCTFail("a non-catalog id must not raise the extraction budget")
        } catch let error as LinuxGuestImageInstallError {
            guard case .noDistributableImage = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    /// A catalog-bound import of the same 5 GiB archive succeeds sparsely.
    func testCatalogBindingRaisesBudgetForSparseDisk() async throws {
        let logical: Int64 = 5 * 1024 * 1024 * 1024
        var block = Data(count: 4096)
        for index in block.indices { block[index] = UInt8(255 - index % 13) }
        let fixture = try makeFixture(id: "floe-sparse-test-4", diskLogicalBytes: logical, diskBlocks: [2 * 1024 * 1024: block])
        let service = try makeService(fixture: fixture)
        _ = try await service.installTrustedImage(
            id: fixture.manifest.id,
            downloader: CopyingImageDownloader(archiveURL: fixture.archiveURL)
        )
        let diskURL = service.imagesDirectory
            .appendingPathComponent(fixture.manifest.id, isDirectory: true)
            .appendingPathComponent("disk.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
        XCTAssertEqual((attributes[.size] as? Int64), logical)
        XCTAssertLessThan(allocatedBytes(of: diskURL) * 1024, logical, "5 GiB logical disk must stay sparse")
    }

    /// Cooperative cancellation aborts the sparse write and leaves no
    /// installed image or staging leftovers behind.
    func testCancellationDuringSparseWrite() async throws {
        let logical: Int64 = 512 * 1024 * 1024
        let fixture = try makeFixture(
            id: "floe-sparse-test-5",
            diskLogicalBytes: logical,
            diskBlocks: [8 * 1024 * 1024: Data(repeating: 0x77, count: 4096)]
        )
        let service = LinuxGuestImageInstallationService(root: workRoot.appendingPathComponent("store", isDirectory: true))
        do {
            _ = try await service.importArchive(
                at: fixture.archiveURL,
                expectedSHA512: FloeDigest.sha512Hex(ofFileAt: fixture.archiveURL),
                isCancelled: { true }
            )
            XCTFail("a cancelled extraction must not install")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        // Cancellation is observed inside the archive hash now, before the
        // import writes anything: either the images directory was never
        // created (nothing was written at all) or it exists and must contain
        // no staging/installed leftovers.
        let contents: [URL]
        if FileManager.default.fileExists(atPath: service.imagesDirectory.path) {
            contents = try FileManager.default.contentsOfDirectory(
                at: service.imagesDirectory, includingPropertiesForKeys: nil
            )
        } else {
            contents = []
        }
        XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".import-") },
                       "staging directories must be removed after cancellation")
        XCTAssertFalse(contents.contains { $0.lastPathComponent == fixture.manifest.id },
                       "a cancelled import must not leave an installed image")
    }

    /// A catalog id whose pinned digest does not match the verified archive
    /// digest must fail closed (no budget raise, no install).
    func testCatalogDigestMismatchFailsClosed() async throws {
        let logical: Int64 = 128 * 1024 * 1024
        let fixture = try makeFixture(id: "floe-sparse-test-6", diskLogicalBytes: logical, diskBlocks: [:])
        LinuxGuestImageDistributionCatalog.registerTestEntry(LinuxGuestTrustedImage(
            id: fixture.manifest.id,
            archiveURL: URL(string: "https://example.invalid/floe-sparse-fixture/mismatch.zip")!,
            mirrors: [],
            archiveSHA512: String(repeating: "a", count: 128),
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://example.invalid/floe-sparse-fixture",
                license: "test fixture",
                distributionAllowed: true
            )
        ))
        let service = LinuxGuestImageInstallationService(root: workRoot.appendingPathComponent("store", isDirectory: true))
        do {
            _ = try await service.importArchive(
                at: fixture.archiveURL,
                expectedSHA512: FloeDigest.sha512Hex(ofFileAt: fixture.archiveURL),
                expectedImageID: fixture.manifest.id
            )
            XCTFail("a catalog digest mismatch must not install")
        } catch let error as LinuxGuestImageInstallError {
            guard case .noDistributableImage = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}

// MARK: - Fixture downloader

private final class CopyingImageDownloader: LinuxGuestImageDownloading, @unchecked Sendable {
    let archiveURL: URL
    init(archiveURL: URL) { self.archiveURL = archiveURL }

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        do {
            let data = try Data(contentsOf: archiveURL)
            guard Int64(data.count) <= maxBytes else {
                throw LinuxGuestImageTransferError.responseInvalid(detail: "fixture archive exceeds the download bound")
            }
            try data.write(to: destination)
            onProgress(Int64(data.count), Int64(data.count))
        } catch let error as LinuxGuestImageTransferError {
            throw error
        } catch {
            throw LinuxGuestImageTransferError.responseInvalid(detail: "fixture copy failed: \(error.localizedDescription)")
        }
    }
}
