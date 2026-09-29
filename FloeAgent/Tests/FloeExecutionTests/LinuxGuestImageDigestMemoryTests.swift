// FloeExecutionTests — Build 235: bounded-memory verified hashing.
//
// The device reported `image verification failed: cannot hash disk
// stage=read errno=12` (ENOMEM) while the UI showed a 587.2 MB image
// download archive. The former streaming hash read through
// `FileHandle.read(upToCount:)`; on Darwin every returned Foundation buffer is
// autoreleased and a long synchronous loop never drains the pool, so resident
// memory grew with the file. Host benchmark (macOS, 1 GiB sparse file, 1 MiB
// chunks): the former loop sampled 383-704 MiB resident versus a flat ~7 MiB
// for the fixed-buffer replacement. The device's expanded/disk size was not
// measured, so this is a bounded source-level diagnosis of the read failure,
// not a device-proven memory figure. These tests pin the replacement contract:
//
//   * the digest is byte-for-byte the same as the one-shot reference for
//     every chunk size (no size shortcut, no cached verdict),
//   * hashing a large sparse file stays within a small, flat memory envelope,
//   * progress is reported for every chunk with the real total,
//   * cancellation throws before producing any digest,
//   * ENOMEM is classified as a transient local read condition, so recovery
//     offers "re-verify" (no download) instead of pretending the bytes are
//     corrupt.

import Foundation
import XCTest
import Darwin
import FloeCore
@testable import FloeExecution

final class LinuxGuestImageDigestMemoryTests: XCTestCase {
    private var workRoot: URL!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workRoot)
    }

    // MARK: - Reference digests

    /// A deterministic pseudo-random payload, written to disk, must hash
    /// identically through the one-shot in-memory reference and through the
    /// streaming file hasher at a tiny and a large chunk size.
    func testStreamingDigestMatchesOneShotReferenceAcrossChunkSizes() throws {
        let data = Self.deterministicBytes(count: 6 << 20)
        let url = workRoot.appendingPathComponent("payload.bin")
        try data.write(to: url)

        let expected512 = FloeDigest.sha512Hex(data)
        let expected256 = FloeDigest.sha256Hex(data)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: url), expected512)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 4096), expected512)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 1 << 20), expected512)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: url, chunkSize: 4096), expected256)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: url, chunkSize: 1 << 20), expected256)
    }

    /// Published NIST vectors: the streaming file hasher returns exactly the
    /// standard digest of the bytes, so the memory fix changed nothing about
    /// the trust decision (no size shortcut, no cached verdict).
    func testStreamingDigestMatchesPublishedVectors() throws {
        let empty = workRoot.appendingPathComponent("empty.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: nil))
        let abc = workRoot.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: abc)

        XCTAssertEqual(
            try FloeDigest.sha512Hex(ofFileAt: empty),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        )
        XCTAssertEqual(
            try FloeDigest.sha512Hex(ofFileAt: abc),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
        XCTAssertEqual(
            try FloeDigest.sha256Hex(ofFileAt: abc),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// Progress is emitted per chunk, the hashed total reaches the real size,
    /// and the reported total is the file size from the open descriptor.
    func testStreamingProgressAndCancellation() throws {
        let size = 3 << 20
        let data = Self.deterministicBytes(count: size)
        let url = workRoot.appendingPathComponent("payload-progress.bin")
        try data.write(to: url)

        var samples: [(hashed: Int64, total: Int64)] = []
        let digest = try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 64 * 1024) { hashed, total in
            samples.append((hashed, total))
        }
        XCTAssertEqual(digest, FloeDigest.sha512Hex(data))
        XCTAssertEqual(samples.count, size / (64 * 1024))
        XCTAssertEqual(samples.last?.hashed, Int64(size))
        XCTAssertEqual(samples.last?.total, Int64(size))
        XCTAssertTrue(
            zip(samples, samples.dropFirst()).allSatisfy { $0.0.hashed < $0.1.hashed },
            "progress must advance monotonically for every chunk"
        )

        // Cancellation is observed before every read and never yields a digest.
        var checks = 0
        XCTAssertThrowsError(
            try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 4096, isCancelled: {
                checks += 1
                return checks > 3
            })
        ) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    #if canImport(Darwin)
    /// Host-level regression detector for the retained-buffer mechanism: the
    /// former FileHandle loop sampled hundreds of MiB for a file this size;
    /// the fixed-buffer stream must stay at one chunk. This is host evidence
    /// for the source fix, not a device measurement.
    func testLargeSparseFileHashingIsMemoryBounded() throws {
        let size: Int64 = 768 << 20
        let url = workRoot.appendingPathComponent("sparse-disk.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        // Give the image real (non-hole) content at intervals so the read is
        // not only zeros.
        for offset in stride(from: 0, to: Int(size), by: 64 << 20) {
            try handle.seek(toOffset: UInt64(offset))
            var block = Data(count: 2 << 20)
            block.withUnsafeMutableBytes { buffer in
                for index in 0..<buffer.count {
                    buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ offset)
                }
            }
            try handle.write(contentsOf: block)
        }
        try handle.close()

        let before = Self.residentBytes()
        var peak = before
        var samples = 0
        let digest = try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 1 << 20) { hashed, total in
            samples += 1
            peak = max(peak, Self.residentBytes())
            XCTAssertEqual(total, size)
            XCTAssertLessThanOrEqual(hashed, size)
        }
        XCTAssertGreaterThan(samples, 700, "one progress report per 1 MiB chunk")
        XCTAssertEqual(digest.count, 128)
        // Chunk-size independence over the same large stream.
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: url, chunkSize: 64 * 1024), digest)
        let growth = Int64(bitPattern: peak) - Int64(bitPattern: before)
        XCTAssertLessThan(
            growth, 192 << 20,
            "verified hashing must keep resident memory near one chunk; grew \(growth) bytes "
                + "(the FileHandle loop this replaced retained hundreds of MiB at this size)"
        )
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    #endif

    // MARK: - Failure classification

    /// ENOMEM from read(2) is a local, retryable condition: the derivation
    /// must offer the no-download re-verify path and must not present it as
    /// content corruption. EACCES stays permanent, and errno 0 never becomes
    /// transient by default.
    func testENOMEMIsTransientWhilePermissionDenialIsNot() {
        let memoryPressure = FloeFileIOError(
            stage: .read, posixErrno: ENOMEM, detail: "Cannot allocate memory",
            domain: NSPOSIXErrorDomain, code: Int(ENOMEM)
        )
        XCTAssertTrue(memoryPressure.isTransientAccessFailure)

        let denied = FloeFileIOError(
            stage: .read, posixErrno: EACCES, detail: "Permission denied",
            domain: NSPOSIXErrorDomain, code: Int(EACCES)
        )
        XCTAssertFalse(denied.isTransientAccessFailure)
        XCTAssertFalse(FloeFileIOError(stage: .read, posixErrno: 0, detail: "unknown").isTransientAccessFailure)

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.imageVerificationIssue = .ioFailure(role: "disk", error: memoryPressure)
        guard case .imageRepairRequired(let transient, let message) =
            LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected imageRepairRequired")
        }
        XCTAssertTrue(transient, "ENOMEM must be offered the cheap re-verify recovery")
        XCTAssertTrue(message.contains("cannot hash disk"))
        XCTAssertTrue(message.contains("errno=\(ENOMEM)"))
    }

    /// One phase's fraction never moves backwards and never leaves 0...1;
    /// a new phase clears it in the app's jobs object instead of reusing the
    /// previous phase's percentage.
    func testProgressMonotonicClamp() {
        XCTAssertEqual(LinuxGuestImageProgress.monotonic(previous: nil, next: 0.25), 0.25)
        XCTAssertEqual(LinuxGuestImageProgress.monotonic(previous: 0.6, next: 0.2), 0.6)
        XCTAssertEqual(LinuxGuestImageProgress.monotonic(previous: 0.6, next: 0.9), 0.9)
        XCTAssertEqual(LinuxGuestImageProgress.monotonic(previous: 0.9, next: 1.7), 1.0)
        XCTAssertEqual(LinuxGuestImageProgress.monotonic(previous: nil, next: -3), 0.0)
    }

    // MARK: - Helpers

    /// Deterministic bytes with no Foundation RNG dependency.
    static func deterministicBytes(count: Int) -> Data {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        return data
    }
}

/// The UI mirrors phase/progress reports that arrive through independent
/// MainActor hops; these tests pin the gate that makes order irrelevant.
final class LinuxGuestImageJobProgressTests: XCTestCase {
    func testLateReportsCannotRegressPhaseOrResurrectAFinishedJob() {
        let epoch = UUID()
        var state = LinuxGuestImageJobProgress(epoch: epoch)
        XCTAssertTrue(state.apply(epoch: epoch, sequence: 1, phase: .downloading, fraction: 0.2))
        XCTAssertTrue(state.apply(epoch: epoch, sequence: 2, phase: .verifyingArchive, fraction: nil))
        XCTAssertEqual(state.phase, .verifyingArchive)
        XCTAssertNil(state.fraction, "a new phase starts a fresh 0...1 scale")

        // A download-progress hop delayed past the phase change must be
        // dropped, not move the UI back to "downloading 90%".
        XCTAssertFalse(state.apply(epoch: epoch, sequence: 1, phase: .downloading, fraction: 0.9))
        XCTAssertEqual(state.phase, .verifyingArchive)

        // Same-sequence archive-verification progress applies and stays
        // monotonic inside the phase.
        XCTAssertTrue(state.apply(epoch: epoch, sequence: 2, phase: .verifyingArchive, fraction: 0.5))
        XCTAssertEqual(state.fraction, 0.5)
        XCTAssertTrue(state.apply(epoch: epoch, sequence: 3, phase: .verifyingArchive, fraction: 0.3))
        XCTAssertEqual(state.fraction, 0.5, "a phase's fraction never moves backwards")

        // A report from a different epoch (a newer job) is refused.
        XCTAssertFalse(state.apply(epoch: UUID(), sequence: 4, phase: .downloading, fraction: 0.1))

        // Terminal state: nothing can bring the job back.
        state.finish()
        XCTAssertFalse(state.apply(epoch: epoch, sequence: 5, phase: .downloading, fraction: 0.1))
        XCTAssertNil(state.phase)
        XCTAssertNil(state.fraction)
    }

    func testNewEpochRejectsInFlightReportsFromThePreviousJob() {
        let firstEpoch = UUID()
        var state = LinuxGuestImageJobProgress(epoch: firstEpoch)
        XCTAssertTrue(state.apply(epoch: firstEpoch, sequence: 7, phase: .finalizing, fraction: nil))

        // The job ended and a new one for the same image id began: its state
        // carries a different epoch, so the old report is stale forever.
        var nextJob = LinuxGuestImageJobProgress(epoch: UUID())
        XCTAssertFalse(nextJob.apply(epoch: firstEpoch, sequence: 8, phase: .downloading, fraction: 0.4))
        XCTAssertNil(nextJob.phase)
        XCTAssertNil(nextJob.fraction)
        XCTAssertTrue(nextJob.apply(epoch: nextJob.epoch, sequence: 1, phase: .checking, fraction: nil))
        XCTAssertEqual(nextJob.phase, .checking)
    }
}
