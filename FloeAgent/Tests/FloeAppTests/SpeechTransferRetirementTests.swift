#if canImport(UIKit)
import CryptoKit
import XCTest
@testable import FloeApp

@MainActor
final class SpeechTransferRetirementTests: XCTestCase {
    func testRetiredURLRemovesOnlyItsCacheAndRejectsCachedDownload() async throws {
        let url = URL(string: "https://example.invalid/speech-retirement-\(UUID().uuidString)")!
        let key = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/SpeechTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifacts = [".download", ".resume"].map { root.appendingPathComponent(key + $0) }
        let unrelated = root.appendingPathComponent("retirement-sentinel-\(UUID().uuidString)")
        defer {
            for artifact in artifacts + [unrelated] { try? FileManager.default.removeItem(at: artifact) }
        }
        for artifact in artifacts { try Data("old transfer".utf8).write(to: artifact) }
        try Data("other model".utf8).write(to: unrelated)

        await WhisperDownloadCoordinator.shared.cancelAndRemovePendingTransfer(for: url)
        XCTAssertTrue(artifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("other model".utf8))

        let lateTask = URLSession.shared.downloadTask(with: url)
        lateTask.taskDescription = key
        WhisperDownloadCoordinator.shared.urlSession(URLSession.shared, task: lateTask,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                userInfo: [NSURLSessionDownloadTaskResumeData: Data("late resume".utf8)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts[1].path),
            "A delayed cancellation callback must not recreate retired resume data")
        lateTask.cancel()

        // Even a late cached result cannot revive a retired model URL.
        try Data("late cached transfer".utf8).write(to: artifacts[0])
        do {
            _ = try await WhisperDownloadCoordinator.shared.download(url, progress: { _ in })
            XCTFail("A retired URL must never return a cached result or start a network request")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected retirement error: \(error)") }
    }
}
#endif
