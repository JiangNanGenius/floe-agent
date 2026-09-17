// SPDX-License-Identifier: MPL-2.0
//
// Staging tests for the IDE Run flow. A scripted in-memory transport stands
// in for the daemon so hash equality, conflict ownership, idempotent resume,
// oversized sources and read-back verification are exercised against the
// real production stager — no SSH host or network is touched.

#if canImport(UIKit)
import CryptoKit
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.IDERunSourceStaging")
struct IDERunSourceStagingTests {

    /// In-memory daemon stand-in. Records writes so a test can tamper with
    /// the stored bytes and prove the read-back verification catches it.
    final class FakeTransport: IDERunStagingTransport, @unchecked Sendable {
        struct Write: Equatable {
            let path: String
            let data: Data
        }

        var files: [String: Data] = [:]
        private(set) var writes: [Write] = []
        var failWrites = false
        /// When set, the stored bytes for this path are corrupted after the
        /// write (simulating a remote that acknowledges then serves different
        /// bytes).
        var corruptAfterWrite: String?
        var missingSHAOnWrite = false
        /// Test hook invoked after each successful write, so a cancellation
        /// gate can flip exactly after the ownership marker lands.
        var didWrite: ((String) -> Void)?

        func writeFile(relativePath: String, data: Data) async throws -> String {
            if failWrites { throw FakeError.transportDown }
            files[relativePath] = data
            writes.append(Write(path: relativePath, data: data))
            if let target = corruptAfterWrite, target == relativePath, !data.isEmpty {
                var tampered = data
                tampered[0] ^= 0xFF
                files[relativePath] = tampered
            }
            if missingSHAOnWrite { throw IDERunStagingFailure.writeFailed }
            didWrite?(relativePath)
            return sha256Hex(data)
        }

        func readFile(relativePath: String) async throws -> (sha256: String, data: Data)? {
            guard let data = files[relativePath] else { return nil }
            return (sha256Hex(data), data)
        }
    }

    enum FakeError: Error {
        case transportDown
    }

    /// Mutable cancellation flag shared with a stager's `checkCancellation`
    /// closure. `@unchecked Sendable` is safe here: each test mutates it only
    /// between awaited transport calls, and it is a single Bool flag.
    final class CancellationGate: @unchecked Sendable {
        var cancelled = false
    }

    private func stager(_ transport: FakeTransport, maxBytes: Int = 1_048_576) -> IDERunSourceStager {
        IDERunSourceStager(transport: transport, maximumSourceBytes: maxBytes, sha256: { @Sendable in sha256Hex($0) })
    }

    // MARK: Layout

    @Test func layoutPreservesTheWorkspaceRelativeStructure() {
        let paths = IDERunStagingLayout.stagedPaths(workspaceRelativePath: "src/main.c", runToken: "run123")
        #expect(paths?.stagingRoot == "floe-ide-run/run123")
        #expect(paths?.stagedSourcePath == "floe-ide-run/run123/src/main.c")
        #expect(paths?.markerPath == "floe-ide-run/run123/.floe-run-token")
        #expect(paths?.workingDirectory == "floe-ide-run/run123/src")
        #expect(paths?.sourceFileName == "main.c")

        let root = IDERunStagingLayout.stagedPaths(workspaceRelativePath: "main.rs", runToken: "run123")
        #expect(root?.workingDirectory == "floe-ide-run/run123")

        #expect(IDERunStagingLayout.stagedPaths(workspaceRelativePath: "../x.c", runToken: "t") == nil)
        #expect(IDERunStagingLayout.stagedPaths(workspaceRelativePath: "/abs.c", runToken: "t") == nil)
        #expect(IDERunStagingLayout.stagedPaths(workspaceRelativePath: "a/b.c", runToken: "")?.runToken == "run")
    }

    // MARK: Planning

    @Test func planHashesTheExactSavedBytes() throws {
        let source = Data("fn main() {}\n".utf8)
        let plan = try stager(FakeTransport()).plan(relativePath: "src/main.rs", source: source, runToken: "t1")
        #expect(plan.byteCount == source.count)
        #expect(plan.expectedSHA256 == sha256Hex(source))
        #expect(plan.markerSHA256 == sha256Hex(Data("t1".utf8)))
    }

    @Test func planRejectsInvalidPathsAndOversizedSources() {
        #expect(throws: IDERunStagingFailure.invalidSourcePath) {
            try stager(FakeTransport()).plan(relativePath: "../escape.rs", source: Data(), runToken: "t")
        }
        #expect(throws: IDERunStagingFailure.sourceTooLarge(limit: 8)) {
            try stager(FakeTransport(), maxBytes: 8).plan(
                relativePath: "big.rs", source: Data(repeating: 0x61, count: 9), runToken: "t")
        }
    }

    // MARK: Staging lifecycle

    @Test func stageWritesMarkerThenSourceAndVerifiesReadBack() async throws {
        let transport = FakeTransport()
        let source = Data("print('hello')\n".utf8)
        let plan = try stager(transport).plan(relativePath: "src/hello.py", source: source, runToken: "abc123")
        let receipt = try await stager(transport).stage(plan: plan, source: source)

        #expect(!receipt.resumed)
        #expect(transport.writes.map(\.path) == [
            "floe-ide-run/abc123/.floe-run-token",
            "floe-ide-run/abc123/src/hello.py",
        ])
        #expect(transport.files["floe-ide-run/abc123/.floe-run-token"] == Data("abc123".utf8))
        #expect(transport.files["floe-ide-run/abc123/src/hello.py"] == source)
    }

    @Test func stageRefusesAForeignMarkerWithoutOverwriting() async throws {
        let transport = FakeTransport()
        transport.files["floe-ide-run/abc123/.floe-run-token"] = Data("other-token".utf8)
        let source = Data("x".utf8)
        let plan = try stager(transport).plan(relativePath: "a.py", source: source, runToken: "abc123")

        await #expect(throws: IDERunStagingFailure.conflict) {
            try await stager(transport).stage(plan: plan, source: source)
        }
        #expect(transport.writes.isEmpty, "a conflict must not clobber anything")
    }

    @Test func stageRefusesUnmarkedForeignContentAtTheRunPath() async throws {
        let transport = FakeTransport()
        // No marker, but bytes already sit at the staged source path.
        transport.files["floe-ide-run/abc123/a.py"] = Data("foreign".utf8)
        let plan = try stager(transport).plan(relativePath: "a.py", source: Data("mine".utf8), runToken: "abc123")

        await #expect(throws: IDERunStagingFailure.conflict) {
            try await stager(transport).stage(plan: plan, source: Data("mine".utf8))
        }
        #expect(transport.writes.isEmpty)
    }

    @Test func stageResumesAnIdenticalEarlierStageWithoutRewriting() async throws {
        let transport = FakeTransport()
        let source = Data("same bytes".utf8)
        let plan = try stager(transport).plan(relativePath: "a.py", source: source, runToken: "abc123")
        _ = try await stager(transport).stage(plan: plan, source: source)
        let writesAfterFirst = transport.writes.count

        let receipt = try await stager(transport).stage(plan: plan, source: source)
        #expect(receipt.resumed)
        #expect(transport.writes.count == writesAfterFirst, "identical re-stage is a resume, not a rewrite")
    }

    @Test func stageDetectsATamperedReadBack() async throws {
        let transport = FakeTransport()
        let source = Data("fn main() {}\n".utf8)
        let plan = try stager(transport).plan(relativePath: "main.rs", source: source, runToken: "abc123")
        transport.corruptAfterWrite = plan.paths.stagedSourcePath

        await #expect(throws: IDERunStagingFailure.verificationFailed) {
            try await stager(transport).stage(plan: plan, source: source)
        }
    }

    @Test func stageFailsWhenTheDaemonAcknowledgesAWrongHash() async throws {
        let transport = FakeTransport()
        transport.missingSHAOnWrite = true
        let source = Data("fn main() {}".utf8)
        let plan = try stager(transport).plan(relativePath: "main.rs", source: source, runToken: "abc123")

        await #expect(throws: IDERunStagingFailure.writeFailed) {
            try await stager(transport).stage(plan: plan, source: source)
        }
    }

    @Test func stagePropagatesTransportOutagesAndCancellation() async throws {
        let transport = FakeTransport()
        transport.failWrites = true
        let source = Data("x".utf8)
        let plan = try stager(transport).plan(relativePath: "a.py", source: source, runToken: "abc123")
        await #expect(throws: FakeError.transportDown) {
            try await stager(transport).stage(plan: plan, source: source)
        }

        struct CancelTransport: IDERunStagingTransport {
            func writeFile(relativePath: String, data: Data) async throws -> String { throw CancellationError() }
            func readFile(relativePath: String) async throws -> (sha256: String, data: Data)? { nil }
        }
        let cancelling = IDERunSourceStager(transport: CancelTransport(), sha256: { @Sendable in sha256Hex($0) })
        await #expect(throws: CancellationError.self) {
            try await cancelling.stage(plan: plan, source: source)
        }
    }

    @Test func stageRejectsBytesThatNoLongerMatchThePlan() async throws {
        let transport = FakeTransport()
        let plan = try stager(transport).plan(relativePath: "a.py", source: Data("saved".utf8), runToken: "abc123")
        // The file changed between planning and staging: refuse instead of
        // transferring an unhashed revision.
        await #expect(throws: IDERunStagingFailure.verificationFailed) {
            try await stager(transport).stage(plan: plan, source: Data("edited".utf8))
        }
    }

    // MARK: Cancellation between transport reads/writes

    @Test func stageCancellationBeforeAnyWriteCreatesNoRemoteData() async throws {
        let transport = FakeTransport()
        let source = Data("x".utf8)
        let stager = IDERunSourceStager(
            transport: transport,
            sha256: { @Sendable in sha256Hex($0) },
            checkCancellation: { throw CancellationError() }
        )
        let plan = try stager.plan(relativePath: "a.py", source: source, runToken: "abc123")

        await #expect(throws: CancellationError.self) {
            try await stager.stage(plan: plan, source: source)
        }
        #expect(transport.writes.isEmpty, "a stop before the marker read must not write the marker")
        #expect(transport.files.isEmpty, "a stop before the marker read must not upload anything")
    }

    @Test func stageCancellationAfterMarkerDoesNotUploadTheSource() async throws {
        let transport = FakeTransport()
        let gate = CancellationGate()
        // Flip the gate the instant the ownership marker lands; the stager's
        // post-write check must abort before the source write.
        transport.didWrite = { path in
            if path.hasSuffix("/\(IDERunStagingLayout.markerName)") { gate.cancelled = true }
        }
        let stager = IDERunSourceStager(
            transport: transport,
            sha256: { @Sendable in sha256Hex($0) },
            checkCancellation: { if gate.cancelled { throw CancellationError() } }
        )
        let source = Data("print('hi')\n".utf8)
        let plan = try stager.plan(relativePath: "src/a.py", source: source, runToken: "abc123")

        await #expect(throws: CancellationError.self) {
            try await stager.stage(plan: plan, source: source)
        }
        #expect(transport.writes.map(\.path) == [plan.paths.markerPath],
                "only the ownership marker may land before the cancellation abort")
        #expect(transport.files[plan.paths.stagedSourcePath] == nil,
                "the source must not be uploaded after a stop between marker and source")
    }

    // MARK: Bounded source read

    @Test func boundedReaderReturnsExactBytesAndRejectsOversize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ide-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exact = directory.appendingPathComponent("exact.py")
        let exactBytes = Data(repeating: 0x61, count: 10)
        try exactBytes.write(to: exact)
        #expect(try IDERunSourceReader.readRegularFile(at: exact, maxBytes: 10) == exactBytes)
    }

    @Test func boundedReaderRejectsAnExternallyGrownFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ide-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let big = directory.appendingPathComponent("big.py")
        try Data(repeating: 0x62, count: 11).write(to: big)
        #expect(throws: IDERunStagingFailure.sourceTooLarge(limit: 10)) {
            _ = try IDERunSourceReader.readRegularFile(at: big, maxBytes: 10)
        }
    }

    @Test func boundedReaderRejectsDirectoryAndMissingTargets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ide-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: IDERunStagingFailure.sourceUnreadable) {
            _ = try IDERunSourceReader.readRegularFile(at: directory, maxBytes: 10)
        }
        #expect(throws: IDERunStagingFailure.sourceUnreadable) {
            _ = try IDERunSourceReader.readRegularFile(at: directory.appendingPathComponent("missing.py"), maxBytes: 10)
        }
    }
}

/// SHA-256 helper shared by the staging tests; identical output format to
/// `FloeDigest.sha256Hex` (lowercase hex).
private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
#endif
