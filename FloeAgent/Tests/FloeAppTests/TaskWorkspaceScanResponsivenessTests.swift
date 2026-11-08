import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@MainActor private final class ScanHeartbeat {
    var ticks = 0
}

@MainActor @Suite("Owned task workspace scans", .serialized)
struct TaskWorkspaceScanResponsivenessTests {
    @Test func fullFileDigestDoesNotOccupyTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large-source.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()
        let heartbeat = ScanHeartbeat()
        let progress = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.ticks += 1
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
        defer { progress.cancel() }
        let files = try await TaskWorkspaceMirror.filesOffMain(root: root)
        let ticksDuringScan = heartbeat.ticks
        progress.cancel()
        await progress.value
        #expect(ticksDuringScan > 0)
        #expect(files.count == 1 && files[0].path == "large-source.bin")
        #expect(files[0].bytes == 128 * 1_024 * 1_024 && files[0].digest.count == 64)
    }

    @Test func offMainInventoryPreservesDigestsAndDependencyExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-inventory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("original source\n".utf8)
        try bytes.write(to: root.appendingPathComponent("source.txt"))
        let excluded = root.appendingPathComponent(".venv")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("package files".utf8).write(to: excluded.appendingPathComponent("package.py"))
        let files = try await TaskWorkspaceMirror.filesOffMain(root: root)
        #expect(files.count == 1 && files[0].path == "source.txt")
        #expect(files[0].bytes == bytes.count && files[0].digest == FloeDigest.sha256Hex(bytes))
    }

    @Test func cancelledScanAndSymlinkStillFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-cancelled-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("retained".utf8).write(to: root.appendingPathComponent("source.txt"))
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try await TaskWorkspaceMirror.filesOffMain(root: root, cancellation: cancellation)
            Issue.record("A cancelled scan returned a successful inventory")
        } catch {}
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path,
                                                 withDestinationPath: "source.txt")
        do {
            _ = try await TaskWorkspaceMirror.filesOffMain(root: root)
            Issue.record("An aliased task file passed the existing path boundary")
        } catch {}
        #expect(try Data(contentsOf: root.appendingPathComponent("source.txt")) == Data("retained".utf8))
    }
}
