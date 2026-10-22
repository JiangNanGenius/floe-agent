// FloeAndroidWorkspaceToolsTests — engine end-to-end focused suites on the
// REAL filesystem (temporary directories; host-runnable; authored, not
// executed in this source lane — Main's unified cohort runs them).
//
// Every gate used here is an EXPLICIT test-installed callback
// (TestCommitGate): the same tests assert the engine refuses everything when
// the gate is absent, proving the production fail-closed default has no
// hidden "true".

import XCTest
import FloeCore
@testable import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class WorkspaceTransferEngineTests: XCTestCase {
    private var root: URL!
    private var workspace: String { root.appendingPathComponent("Workspace").path }
    private var transferRoot: String { root.appendingPathComponent("WorkspaceTransfers").path }
    private var hooks: TestHooks!

    override func setUpWithError() throws {
        root = try WorkspaceTestSupport.makeTempRoot(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        hooks = TestHooks()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func newEngine() throws -> WorkspaceTransferEngine {
        let engine = WorkspaceTransferEngine()
        XCTAssertTrue(engine.install(hooks: hooks.hooks(), transferRoot: transferRoot))
        return engine
    }

    private func binding() -> WorkspaceGrantBinding {
        hooks.mint(runID: UUID(), conversationID: UUID(), workspaceID: UUID(), rootPath: workspace)
    }

    private func makeFD(_ file: String) -> Int32 {
        open(file, O_RDONLY)
    }

    // MARK: - Fail-closed basics

    func testUninstalledEngineRefusesEverything() {
        let engine = WorkspaceTransferEngine()
        XCTAssertFalse(engine.isInstalled)
        XCTAssertThrowsError(try engine.baselineBegin(sessionKey: "0123456789abcdef0123456789abcdef"))
    }

    func testBadProofBindingIsRefusedBeforeAnyFileTouch() throws {
        let engine = try newEngine()
        hooks.lightAlwaysTrue = false
        var forged = binding()
        forged.proof = String(repeating: "0", count: 64)
        try WorkspaceTestSupport.write("secret", to: workspace + "/private.txt")
        XCTAssertThrowsError(try engine.openSession(binding: forged)) { error in
            XCTAssertEqual(error as? WorkspaceTransferError, .proofRefused(code: "light"))
        }
    }

    func testAbsentCommitGateMeansNoWorkspaceChange() throws {
        let engine = try newEngine()
        hooks.gate = nil
        try WorkspaceTestSupport.write("base", to: workspace + "/a.txt")
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        _ = try engine.exportBegin(sessionKey: key)
        // The runtime-side source file lives OUTSIDE the Core workspace
        // target (a real export copies IN from elsewhere; staging reads a
        // borrowed fd). Asserting the TARGET stays untouched is meaningful
        // only when the source is not itself inside the target.
        let runtimeDir = root.appendingPathComponent("RuntimeOut").path
        let file = runtimeDir + "/incoming.txt"
        try WorkspaceTestSupport.write("runtime output", to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/incoming.txt"))
        let fd = makeFD(file)
        defer { close(fd) }
        _ = try engine.exportStage(sessionKey: key, header: ["seq": 1, "path": "incoming.txt",
                                                             "kind": "file", "size": 14, "mode": 420],
                                   dataFd: fd)
        XCTAssertThrowsError(try engine.exportFinish(sessionKey: key)) { error in
            guard case .commitRefused(let code)? = error as? WorkspaceTransferError else {
                return XCTFail("expected commitRefused, got \(error)")
            }
            XCTAssertEqual(code, "gateAbsent")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/incoming.txt"),
                       "absent commit gate must leave the Core workspace untouched")
        let baseBytes = FileManager.default.contents(atPath: workspace + "/a.txt") ?? Data()
        XCTAssertEqual(String(decoding: baseBytes, as: UTF8.self), "base",
                       "pre-existing Core content must be unchanged on refusal")
    }

    // MARK: - Import

    func testImportRoundTripServesActualBytesAndDigests() throws {
        let engine = try newEngine()
        try WorkspaceTestSupport.write("hello core", to: workspace + "/docs/a.txt")
        try FileManager.default.createDirectory(atPath: workspace + "/emptydir", withIntermediateDirectories: true)
        let key = try engine.openSession(binding: binding())
        let receipt = try engine.baselineBegin(sessionKey: key)
        XCTAssertEqual(receipt["entryCount"] as? Int, 3) // docs, docs/a.txt, emptydir
        var index = 0
        var sawFile = false
        while let header = try engine.baselineHeader(sessionKey: key, index: Int64(index)) {
            if header["kind"] as? String == "file" {
                let opened = try engine.baselineOpenData(sessionKey: key, index: Int64(index))
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 1)
                defer { buffer.deallocate() }
                let count = read(opened.fd, buffer, 64)
                close(opened.fd)
                let bytes = Data(bytes: buffer, count: max(0, count))
                XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello core")
                XCTAssertEqual(header["digest"] as? String, opened.entry.digest)
                sawFile = true
            }
            index += 1
        }
        XCTAssertTrue(sawFile)
        _ = try engine.baselineFinish(sessionKey: key, appliedCount: Int64(index), appliedBytes: 10)
    }

    // MARK: - Export happy path

    func testSyncedExportAppliesCreateModifyAndDelete() throws {
        let engine = try newEngine()
        try WorkspaceTestSupport.write("old", to: workspace + "/keep.txt")
        try WorkspaceTestSupport.write("gone", to: workspace + "/remove.txt")
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        _ = try engine.exportBegin(sessionKey: key)

        let newFile = workspace + "/.newsrc"
        try WorkspaceTestSupport.write("created by runtime", to: newFile)
        let modified = workspace + "/.modsrc"
        try WorkspaceTestSupport.write("edited output", to: modified)
        let fd1 = makeFD(newFile); defer { close(fd1) }
        let fd2 = makeFD(modified); defer { close(fd2) }
        _ = try engine.exportStage(sessionKey: key,
                                   header: ["seq": 1, "path": "out/new.txt", "kind": "file",
                                            "size": 18, "mode": 420], dataFd: fd1)
        _ = try engine.exportStage(sessionKey: key,
                                   header: ["seq": 2, "path": "keep.txt", "kind": "file",
                                            "size": 11, "mode": 493], dataFd: fd2)
        // remove.txt deliberately ABSENT => deletion intent.
        let outcome = try engine.exportFinish(sessionKey: key)
        XCTAssertEqual(outcome["result"] as? String, "synced")
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: workspace + "/out/new.txt")),
                             encoding: .utf8), "created by runtime")
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: workspace + "/keep.txt")),
                             encoding: .utf8), "edited output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/remove.txt"))
    }

    // MARK: - Conflict preservation (the core safety property)

    func testConcurrentUserEditBecomesConflictAndKeepsBothVersions() throws {
        let engine = try newEngine()
        try WorkspaceTestSupport.write("original", to: workspace + "/a.txt")
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        // User edits Core-side AFTER the baseline was captured:
        try WorkspaceTestSupport.write("user edit wins?", to: workspace + "/a.txt")
        _ = try engine.exportBegin(sessionKey: key)
        let staged = workspace + "/.runtime"
        try WorkspaceTestSupport.write("runtime edit", to: staged)
        let fd = makeFD(staged); defer { close(fd) }
        _ = try engine.exportStage(sessionKey: key,
                                   header: ["seq": 1, "path": "a.txt", "kind": "file",
                                            "size": 12, "mode": 420], dataFd: fd)
        let outcome = try engine.exportFinish(sessionKey: key)
        XCTAssertEqual(outcome["result"] as? String, "conflict")
        // BOTH versions survive: the user's bytes stay in the workspace...
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: workspace + "/a.txt")),
                             encoding: .utf8), "user edit wins?")
        // ...and the runtime bytes are preserved as a conflict artifact.
        let preview = outcome["preview"] as? [String: Any]
        let conflicts = preview?["conflicts"] as? [[String: Any]]
        XCTAssertEqual(conflicts?.first?["kind"] as? String, "userEditedVsRuntimeEdited")
        let recovered = transferRoot + "/recovered/\(key)"
        let artifacts = (try? FileManager.default.contentsOfDirectory(atPath: recovered)) ?? []
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(String(data: try Data(contentsOf: URL(fileURLWithPath: recovered + "/" + artifacts[0])),
                             encoding: .utf8), "runtime edit")
    }

    func testDirectoryDeletionNeverRemovesNewUserDescendants() throws {
        let engine = try newEngine()
        try WorkspaceTestSupport.write("child", to: workspace + "/dir/old.txt")
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        // User adds a NEW descendant before the guest deletion settles:
        try WorkspaceTestSupport.write("precious", to: workspace + "/dir/new-from-user.txt")
        _ = try engine.exportBegin(sessionKey: key)
        // Runtime deleted dir (old.txt + dir absent from staged set).
        let outcome = try engine.exportFinish(sessionKey: key)
        // old.txt (present in baseline, absent from runtime view, unchanged
        // on disk) is deleted; the directory survives because rmdir cannot
        // remove non-empty trees:
        XCTAssertEqual(outcome["result"] as? String, "conflict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/dir/new-from-user.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/dir/old.txt"))
        let preview = outcome["preview"] as? [String: Any]
        let conflicts = preview?["conflicts"] as? [[String: Any]]
        XCTAssertEqual(conflicts?.first?["kind"] as? String, "directoryNotEmptyKept")
    }

    // MARK: - Trust discipline

    func testStagedDigestIsWhatTheEngineActuallyReadNotTheClaim() throws {
        let engine = try newEngine()
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        _ = try engine.exportBegin(sessionKey: key)
        let src = workspace + "/.lie"
        try WorkspaceTestSupport.write("actual bytes are different", to: src)
        let fd = makeFD(src); defer { close(fd) }
        let result = try engine.exportStage(sessionKey: key,
                                            header: ["seq": 1, "path": "x.txt", "kind": "file",
                                                     "size": 3, "mode": 420],
                                            dataFd: fd)
        XCTAssertEqual(result["state"] as? String, "staged")
        XCTAssertEqual(result["recordedSize"] as? Int64, 26) // actual, not the claimed 3
        let digest = try XCTUnwrap(result["recordedDigest"] as? String)
        XCTAssertEqual(digest, FloeDigest.sha256Hex(Data("actual bytes are different".utf8)))
    }

    // MARK: - Idempotent terminal receipt

    func testExportFinishReReadReturnsIdenticalReceiptWithoutEffects() throws {
        let engine = try newEngine()
        try WorkspaceTestSupport.write("data", to: workspace + "/a.txt")
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        _ = try engine.exportBegin(sessionKey: key)
        let src = workspace + "/.b"
        try WorkspaceTestSupport.write("fresh", to: src)
        let fd = makeFD(src); defer { close(fd) }
        _ = try engine.exportStage(sessionKey: key, header: ["seq": 1, "path": "b.txt", "kind": "file",
                                                             "size": 5, "mode": 420], dataFd: fd)
        let first = try engine.exportFinish(sessionKey: key)
        let second = try engine.exportFinish(sessionKey: key)
        XCTAssertEqual(first["result"] as? String, "synced")
        XCTAssertEqual(second["result"] as? String, "synced")
        XCTAssertEqual(second["planDigest"] as? String, first["planDigest"] as? String)
        // Re-read does NOT re-run effects: remove the applied file then ask
        // again — the receipt is the recorded one, the workspace stays as-is.
        try FileManager.default.removeItem(atPath: workspace + "/b.txt")
        let third = try engine.exportFinish(sessionKey: key)
        XCTAssertEqual(third["result"] as? String, "synced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/b.txt"))
    }

    // MARK: - Sweep ownership rules

    func testSweepPreservesUnknownAndLiveOwnersCleansProvenStale() throws {
        let engine = try newEngine()
        let key = try engine.openSession(binding: binding())
        _ = try engine.baselineBegin(sessionKey: key)
        _ = try engine.exportBegin(sessionKey: key)
        // A staged file owned by this LIVE session:
        let src = workspace + "/.staged"
        try WorkspaceTestSupport.write("payload", to: src)
        let fd = makeFD(src); defer { close(fd) }
        _ = try engine.exportStage(sessionKey: key, header: ["seq": 1, "path": "s.txt", "kind": "file",
                                                             "size": 7, "mode": 420], dataFd: fd)
        // Unknown foreign directory (no marker) + invalid marker directory.
        let transfer = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: String(repeating: "f", count: 32))
        try FileManager.default.createDirectory(atPath: transfer.sessionDirectory + "/staging",
                                                withIntermediateDirectories: true)
        try WorkspaceTestSupport.write("foreign", to: transfer.sessionDirectory + "/staging/data")
        let bogus = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: String(repeating: "e", count: 32))
        try FileManager.default.createDirectory(atPath: bogus.sessionDirectory + "/staging",
                                                withIntermediateDirectories: true)
        try WorkspaceTestSupport.write("{ not a marker }", to: bogus.ownerMarker)

        var report = try engine.sweepStaleStaging(nowSeconds: Int64(Date().timeIntervalSince1970),
                                                  runProof: { _ in 0 })
        XCTAssertEqual(report["cleanedSessions"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(report["preservedUnknown"] as? Int ?? 0, 1)
        XCTAssertEqual(report["preservedActive"] as? Int ?? 0, 1) // live key preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: transfer.sessionDirectory + "/staging/data"))

        // Prove the FOREIGN marker's run terminal + aged past grace => its
        // staging is reclaimed, journal/marker stay for audit.
        let aged = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: String(repeating: "d", count: 32))
        try FileManager.default.createDirectory(atPath: aged.sessionDirectory + "/staging",
                                                withIntermediateDirectories: true)
        try WorkspaceTestSupport.write("x", to: aged.sessionDirectory + "/staging/blob")
        let marker = WorkspaceOwnerMarker(sessionKey: aged.sessionKey, grantID: "deadbeefdeadbeef",
                                          projectID: UUID().uuidString, runID: UUID().uuidString,
                                          rootEpoch: 7, createdAtSeconds: 1_000)
        try marker.writeDurable(to: aged.ownerMarker)
        report = try engine.sweepStaleStaging(nowSeconds: Int64(Date().timeIntervalSince1970),
                                              runProof: { _ in 1 }, graceSeconds: 60)
        XCTAssertEqual(report["cleanedSessions"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aged.sessionDirectory + "/staging"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aged.ownerMarker))
    }
}
