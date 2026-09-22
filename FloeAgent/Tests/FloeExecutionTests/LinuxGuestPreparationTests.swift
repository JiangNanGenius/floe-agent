// FloeExecutionTests — Linux image installation state and the explicit
// environment preparation capability.
//
// These checks pin the device-facing promises: a truthful space/digest/cancel
// failure, byte progress from the downloader, and the preparation tool that
// model execution calls before resuming a Linux-dependent command. No network
// and no guest image are required.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

final class LinuxGuestImageInstallStateTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-images-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testFreeSpaceCheckReportsTheRequiredAndAvailableBytes() throws {
        let root = makeRoot()
        do {
            try LinuxGuestVolumeSpace.requireAvailable(at: root, required: Int64.max)
            XCTFail("an impossible requirement must not be accepted")
        } catch let error as LinuxGuestImageInstallError {
            guard case .insufficientSpace(let required, let available) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(required, Int64.max)
            XCTAssertGreaterThanOrEqual(available, 0)
        }
        // A tiny requirement passes on any real volume.
        XCTAssertNoThrow(try LinuxGuestVolumeSpace.requireAvailable(at: root, required: 1))
    }

    func testDownloadCancellationIsReportedAsCancellation() async {
        let service = LinuxGuestImageInstallationService(root: makeRoot())
        do {
            _ = try await service.installTrustedImage(
                id: LinuxGuestImageDistributionCatalog.defaultImageID,
                downloader: CancellingImageDownloader()
            )
            XCTFail("a cancelled download must not install")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Progress must reach the caller while the transfer runs, and a
    /// completed transfer must continue into digest verification rather than
    /// reporting success on its own.
    func testDownloadProgressReachesCallerBeforeVerification() async {
        let service = LinuxGuestImageInstallationService(root: makeRoot())
        let recorder = ProgressRecorder()
        do {
            _ = try await service.installTrustedImage(
                id: LinuxGuestImageDistributionCatalog.defaultImageID,
                downloader: ScriptedImageDownloader(bytes: 4_096),
                onProgress: { received, expected in
                    recorder.record(received: received, expected: expected)
                }
            )
            XCTFail("an archive that does not match the pinned digest must not install")
        } catch let error as LinuxGuestImageInstallError {
            guard case .archiveDigestMismatch = error else {
                return XCTFail("expected digest verification, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let samples = recorder.samples
        XCTAssertFalse(samples.isEmpty, "the downloader reported no progress")
        XCTAssertEqual(samples.last?.received, 4_096)
        XCTAssertEqual(samples.last?.expected, 4_096)
    }

    func testInsufficientSpaceBeforeImportIsReportedWithoutWriting() async {
        // The import path checks free space before extraction; an archive
        // whose declared extraction need exceeds the volume is refused with
        // the concrete requirement instead of an I/O failure. The check is
        // exercised directly because a real device cannot be filled in a test.
        let root = makeRoot()
        let available = LinuxGuestVolumeSpace.availableImportantBytes(for: root)
        guard available > 0 else { return } // capacity unavailable: check is a no-op
        XCTAssertThrowsError(
            try LinuxGuestVolumeSpace.requireAvailable(at: root, required: available + 1)
        ) { error in
            guard case LinuxGuestImageInstallError.insufficientSpace = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}

final class PrepareLinuxEnvironmentToolTests: XCTestCase {
    private func context() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    func testToolHasNoImageURLOrScriptParameter() {
        let schema = PrepareLinuxEnvironmentTool.parametersJSON
        XCTAssertFalse(schema.lowercased().contains("url"), "the tool must never accept an image URL")
        XCTAssertFalse(schema.lowercased().contains("script"), "the tool must never accept an install script")
        XCTAssertTrue(schema.contains("\"additionalProperties\":false"))
        XCTAssertTrue(PrepareLinuxEnvironmentTool.toolDescription.contains("App-provided"))
    }

    func testSuccessfulPreparationReportsPrepared() async throws {
        let tool = PrepareLinuxEnvironmentTool { _ in "Linux image floe-test installed and verified" }
        let output = try await tool.execute(PrepareLinuxEnvironmentTool.Arguments(), context: context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("status=prepared"))
    }

    func testSpaceFailureIsReportedTruthfully() async throws {
        let tool = PrepareLinuxEnvironmentTool { _ in
            throw LinuxGuestImageInstallError.insufficientSpace(required: 500, available: 100)
        }
        let output = try await tool.execute(PrepareLinuxEnvironmentTool.Arguments(), context: context())
        XCTAssertEqual(output.exitStatus, 125)
        XCTAssertTrue(output.summary.contains("status=prepareFailed"))
        XCTAssertTrue(output.summary.contains("not enough free space"))
        XCTAssertFalse(output.summary.contains("prepared\n"), "a failure must never look prepared")
    }

    func testDigestFailureIsReportedTruthfully() async throws {
        let tool = PrepareLinuxEnvironmentTool { _ in
            throw LinuxGuestImageInstallError.archiveDigestMismatch(expected: "aa", actual: "bb")
        }
        let output = try await tool.execute(PrepareLinuxEnvironmentTool.Arguments(), context: context())
        XCTAssertEqual(output.exitStatus, 125)
        XCTAssertTrue(output.summary.contains("digest mismatch"))
    }

    func testCancellationIsNotReportedAsFailure() async throws {
        let tool = PrepareLinuxEnvironmentTool { _ in
            throw LinuxGuestImageInstallError.cancelled
        }
        let output = try await tool.execute(PrepareLinuxEnvironmentTool.Arguments(), context: context())
        XCTAssertEqual(output.exitStatus, 130)
        XCTAssertTrue(output.summary.contains("status=cancelled"))
    }

    func testCancelledTokenStopsBeforePreparation() async {
        let tool = PrepareLinuxEnvironmentTool { _ in
            XCTFail("a cancelled request must not start a download")
            return "unreachable"
        }
        let token = CancellationToken()
        token.cancel()
        let context = ToolContext(runID: UUID(), cancellation: token)
        do {
            _ = try await tool.execute(.init(), context: context)
            XCTFail("expected cancellation")
        } catch FloeError.cancelled {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - Fakes

/// Fails immediately with a cancellation, like a user cancel in the UI.
private struct CancellingImageDownloader: LinuxGuestImageDownloading {
    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        throw .cancelled
    }
}

/// Writes a bounded payload and reports progress, so the installer proceeds
/// into digest verification (which refuses the unpinned bytes).
private struct ScriptedImageDownloader: LinuxGuestImageDownloading {
    let bytes: Int

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        let chunk = 1_024
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var written = 0
            while written < bytes {
                let size = min(chunk, bytes - written)
                try handle.write(contentsOf: Data(repeating: 0x41, count: size))
                written += size
                onProgress(Int64(written), Int64(bytes))
            }
        } catch {
            throw .localRejection(detail: error.localizedDescription)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Sample { var received: Int64; var expected: Int64 }
    private let lock = NSLock()
    private var storage: [Sample] = []

    func record(received: Int64, expected: Int64) {
        lock.lock()
        storage.append(Sample(received: received, expected: expected))
        lock.unlock()
    }

    var samples: [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
