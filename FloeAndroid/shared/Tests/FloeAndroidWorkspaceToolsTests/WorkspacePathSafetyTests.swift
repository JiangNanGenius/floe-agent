// FloeAndroidWorkspaceToolsTests — path/budget/proof focused suites.
// Authored (job-ade884c46eb84ec1) but NOT executed in this source lane;
// Main's unified workspace cohort runs them (host-runnable: no UIKit, no
// networking, no device).

import XCTest
import FloeCore
@testable import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

final class WorkspacePathSafetyTests: XCTestCase {
    private var budgets = WorkspaceTransferBudgets.defaults

    /// Descriptor/IO contract (coordinator steer 20261022, Main review): the
    /// streamer and the engine stage path require ACTUAL S_IFREG `fstat`
    /// proof BEFORE any read. A pipe held open by a writer must be refused
    /// IMMEDIATELY (no read, no block), with the caller's fd untouched and
    /// still owned. A real regular file proves through with its ACTUAL size.
    func testStreamerRejectsPipeBeforeAnyReadAndProofsRegularFile() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]; let writeFD = fds[1]
        defer { close(readFD); close(writeFD) }
        // Keep the WRITE end open: if the copier read blindly it would block
        // forever. The result must come back synchronously as a typed refusal.
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-pipe-proof-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: target.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: target) }
        let outFD = open(target.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(outFD, 0)
        defer { close(outFD) }
        let started = Date()
        let result = WorkspaceStreamCopier.copy(fromFd: readFD, toFd: outFD,
                                                frameBytes: 65_536, maximumBytes: 1 << 20,
                                                isCancelled: { false })
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "pipe rejection must not block Core IO")
        guard case .failure(.transfer(.pathUnsafe(let code))) = result else {
            return XCTFail("pipe source must be refused as a typed pathUnsafe, got \(result)")
        }
        XCTAssertEqual(code, "sourceNotRegular")
        // The caller still owns the fd: fstat has not been closed by us.
        var info = stat()
        XCTAssertEqual(fstat(readFD, &info), 0)
        XCTAssertEqual((info.st_mode & mode_t(S_IFMT)), mode_t(S_IFIFO))
        // Positive control: a real regular file proofs with its ACTUAL size.
        let regular = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-regular-proof-\(UUID().uuidString)")
        let payload = Data(repeating: 0x41, count: 1_234)
        FileManager.default.createFile(atPath: regular.path, contents: payload)
        defer { try? FileManager.default.removeItem(at: regular) }
        let rfd = open(regular.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(rfd, 0)
        defer { close(rfd) }
        guard case let .success(size) = WorkspaceNoFollow.regularFileProof(rfd) else {
            return XCTFail("regular file must proof through")
        }
        XCTAssertEqual(size, 1_234)
    }

    /// Bounded-growth / per-frame reserve guard (Main review steer 20261022):
    /// the copier re-checks destination free space as staging grows. A caller
    /// gate reporting exhaustion must refuse with the CALLER's typed error,
    /// close NEITHER descriptor, and leave the torn partial bytes in place
    /// (the engine's failure path owns cleanup; the source stays untouched).
    func testReserveGateRefusesMidCopyKeepingFDsAndPartialBytes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-reserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src")
        try Data(repeating: 0x5A, count: 4_096 * 3).write(to: source)
        let dest = dir.appendingPathComponent("dst")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let srcFD = open(source.path, O_RDONLY)
        let dstFD = open(dest.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(srcFD, 0)
        XCTAssertGreaterThanOrEqual(dstFD, 0)
        defer { close(srcFD); close(dstFD) }
        var observed: [Int64] = []
        let result = WorkspaceStreamCopier.copy(fromFd: srcFD, toFd: dstFD,
                                                frameBytes: 4_096, maximumBytes: 1 << 20,
                                                isCancelled: { false },
                                                reserveGate: { moved in
            observed.append(moved)
            return moved >= 4_096 ? WorkspaceTransferError.diskReserveUnmet : nil
        })
        guard case .failure(.transfer(.diskReserveUnmet)) = result else {
            return XCTFail("mid-copy exhaustion must refuse with diskReserveUnmet, got \(result)")
        }
        XCTAssertEqual(observed.first, 4_096,
                       "the gate runs against ACTUAL grown staging, not the claim")
        let partial = FileManager.default.contents(atPath: dest.path) ?? Data()
        XCTAssertEqual(partial.count, 4_096,
                       "torn partial stays for the engine's failure path; copier never deletes")
        var info = stat()
        XCTAssertEqual(fstat(srcFD, &info), 0, "source fd remains caller-owned")
        XCTAssertEqual(fstat(dstFD, &info), 0, "destination fd remains caller-owned")
    }

    func testOrdinaryRelativePathsPass() throws {
        XCTAssertEqual(try WorkspaceRelativePath.validate("a.txt", budgets: budgets), ["a.txt"])
        XCTAssertEqual(try WorkspaceRelativePath.validate("src/main/App.swift", budgets: budgets),
                       ["src", "main", "App.swift"])
        XCTAssertNoThrow(try WorkspaceRelativePath.validate("node_modules/.bin/tsc", budgets: budgets))
    }

    func testTraversalAbsoluteAndShapeAttacksRefuse() {
        for bad in ["/abs", "~/home", "a/../../b", "a/./b", "a//b", "", "a\u{0000}b",
                    "line\u{000A}break", "a/" + String(repeating: "x", count: 300)] {
            XCTAssertThrowsError(try WorkspaceRelativePath.validate(bad, budgets: budgets), bad)
        }
    }

    func testReservedTransferPrefixesRefuse() {
        for bad in [".floe-commit-abc", ".floe-wt-x/y", ".workspace-bridge/z"] {
            XCTAssertThrowsError(try WorkspaceRelativePath.validate(bad, budgets: budgets), bad)
        }
    }

    func testLinkClassificationKeepsContainedRefusesEscape() {
        XCTAssertEqual(WorkspaceRelativePath.classifyLinkTarget("../../pkg/.bin/tsc",
                     linkComponents: ["node_modules", ".bin", "tsc"], budgets: budgets), .relativeContained)
        XCTAssertEqual(WorkspaceRelativePath.classifyLinkTarget("b.txt",
                     linkComponents: ["a", "x"], budgets: budgets), .relativeContained)
        XCTAssertEqual(WorkspaceRelativePath.classifyLinkTarget("/etc/passwd",
                     linkComponents: ["x"], budgets: budgets), .external)
        XCTAssertEqual(WorkspaceRelativePath.classifyLinkTarget("../../escape",
                     linkComponents: ["only"], budgets: budgets), .external)
    }

    func testBudgetParseIsStrictAndBounded() {
        let good = WorkspaceTransferBudgets.defaults.dictionaryValue
        XCTAssertNotNil(WorkspaceTransferBudgets.from(dictionary: good))
        var widened = good
        widened["totalBytes"] = Int64(16) << 30 // over the 8 GiB outer ceiling
        XCTAssertNil(WorkspaceTransferBudgets.from(dictionary: widened))
        var boolean = good
        boolean["entryCount"] = true
        XCTAssertNil(WorkspaceTransferBudgets.from(dictionary: boolean))
        var extra = good
        extra["surprise"] = 1
        XCTAssertNil(WorkspaceTransferBudgets.from(dictionary: extra))
    }

    func testBindingParseCanonicalIdsAndJobShape() throws {
        let projectID = UUID()
        let runID = UUID()
        let workspaceID = UUID()
        let base: [String: Any] = [
            "version": 1,
            "projectID": projectID.uuidString,
            "runID": runID.uuidString,
            "workspaceID": workspaceID.uuidString,
            "rootEpoch": UInt64(7),
            "grantID": "0123456789abcdef",
            "workspaceFingerprint": "abcd1234ab",
            "proof": String(repeating: "a", count: 64),
            "budgets": WorkspaceTransferBudgets.defaults.dictionaryValue,
        ]
        XCTAssertNotNil(WorkspaceGrantBinding.from(dictionary: base, workspaceRootPath: "/p"))
        var lower = base
        lower["runID"] = runID.uuidString.lowercased()
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: lower, workspaceRootPath: "/p"),
                     "owner UUID strings must ride UNCHANGED (canonical uppercase)")
        // job fields: both or neither
        var loneJob = base
        loneJob["jobID"] = UUID().uuidString
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: loneJob, workspaceRootPath: "/p"))
        let jobID = UUID()
        var pair = base
        pair["toolCallID"] = "jobs.\(jobID.uuidString)"
        pair["jobID"] = jobID.uuidString
        let parsed = try XCTUnwrap(WorkspaceGrantBinding.from(dictionary: pair, workspaceRootPath: "/p"))
        XCTAssertEqual(parsed.jobID, jobID)
        var mismatched = pair
        mismatched["toolCallID"] = "jobs.\(UUID().uuidString)"
        XCTAssertNil(WorkspaceGrantBinding.from(dictionary: mismatched, workspaceRootPath: "/p"))
    }

    func testProofTamperDetectionAcrossEveryBoundField() {
        let support = WorkspaceGrantProof.random()
        let binding = WorkspaceGrantBinding(
            projectID: UUID(), runID: UUID(), conversationID: nil, workspaceID: UUID(),
            rootEpoch: 7, grantID: "abcdef0123456789",
            workspaceRootPath: "/srv/app/Workspace/PrivateTasks/X",
            workspaceFingerprint: "abcd1234ab",
            proof: support.compute(projectID: UUID(), runID: UUID(), conversationID: nil,
                                   workspaceID: UUID(), rootEpoch: 7, grantID: "x",
                                   workspaceRootPath: "/y", budgetsJSON: "{}"),
            budgets: .defaults)
        // Recomputed over its own fields it must match:
        let good = WorkspaceGrantBinding(
            projectID: binding.projectID, runID: binding.runID, conversationID: binding.conversationID,
            workspaceID: binding.workspaceID, toolCallID: binding.toolCallID, jobID: binding.jobID,
            rootEpoch: binding.rootEpoch, grantID: binding.grantID,
            workspaceRootPath: binding.workspaceRootPath, workspaceFingerprint: binding.workspaceFingerprint,
            proof: support.compute(projectID: binding.projectID, runID: binding.runID,
                                   conversationID: binding.conversationID, workspaceID: binding.workspaceID,
                                   rootEpoch: binding.rootEpoch, grantID: binding.grantID,
                                   workspaceRootPath: binding.workspaceRootPath,
                                   budgetsJSON: WorkspaceGrantProof.canonicalBudgets(binding.budgets)),
            budgets: binding.budgets)
        XCTAssertTrue(support.matches(good))
        var tamperedBudget = good
        var tighter = WorkspaceTransferBudgets.defaults
        tighter.totalBytes = (1 << 30) - 1
        tamperedBudget.budgets = tighter
        XCTAssertFalse(support.matches(tamperedBudget), "budget changes must invalidate the proof")
        var tamperedPath = good
        tamperedPath.workspaceRootPath = "/elsewhere"
        XCTAssertFalse(support.matches(tamperedPath))
        var tamperedJob = good
        tamperedJob.jobID = UUID()
        XCTAssertFalse(support.matches(tamperedJob))
    }
}
