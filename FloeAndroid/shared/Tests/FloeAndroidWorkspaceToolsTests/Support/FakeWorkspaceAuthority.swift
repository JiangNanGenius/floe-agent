// FloeAndroidWorkspaceToolsTests — test fakes (authored 2026-10-22,
// job-ade884c46eb84ec1; NOT executed in this source lane — the first real
// module compile/test run belongs to Main's workspace cohort).
//
// The production code has NO default-true gate; these fixtures supply an
// EXPLICIT, clearly-labelled test gate/callback so the engine's fail-closed
// behaviour can be asserted both ways. Nothing here reaches production.

import Foundation
import FloeCore
import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TestHooks: @unchecked Sendable {
    let proof = WorkspaceGrantProof.random()
    var epochProvider: @Sendable () -> UInt64? = { 7 }
    var runActive = true
    var lightAlwaysTrue = true
    var gate: WorkspaceCommitGate? = TestCommitGate()

    func hooks() -> WorkspaceAuthorityHooks {
        WorkspaceAuthorityHooks(
            revalidateLight: { [weak self] binding in
                guard let self else { return false }
                if self.epochProvider() != binding.rootEpoch { return false }
                if self.lightAlwaysTrue { return true }
                return self.proof.matches(binding)
            },
            revalidateRun: { [weak self] _ in self?.runActive ?? false },
            commitGateProvider: { [weak self] in self?.gate }
        )
    }

    func mint(runID: UUID, conversationID: UUID?, workspaceID: UUID, rootPath: String,
              rootEpoch: UInt64? = nil, budgets: WorkspaceTransferBudgets = .defaults,
              toolCallID: String? = nil, jobID: UUID? = nil) -> WorkspaceGrantBinding {
        let epoch = rootEpoch ?? epochProvider() ?? 7
        let projectID = WorkspaceTestSupport.projectID(for: rootPath)
        let grantID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        return WorkspaceGrantBinding(
            projectID: projectID, runID: runID, conversationID: conversationID, workspaceID: workspaceID,
            toolCallID: toolCallID, jobID: jobID,
            rootEpoch: epoch, grantID: String(grantID),
            workspaceRootPath: rootPath,
            workspaceFingerprint: String(FloeDigest.sha256Hex(Data(rootPath.utf8)).prefix(12)),
            proof: proof.compute(projectID: projectID, runID: runID, conversationID: conversationID,
                                 workspaceID: workspaceID, toolCallID: toolCallID, jobID: jobID,
                                 rootEpoch: epoch, grantID: String(grantID),
                                 workspaceRootPath: rootPath,
                                 budgetsJSON: WorkspaceGrantProof.canonicalBudgets(budgets)),
            budgets: budgets)
    }
}

/// TEST-ONLY explicit-true commit gate (fixtures proving the engine commits
/// when a REAL callback is installed; production absence stays fail-closed).
final class TestCommitGate: WorkspaceCommitGate, @unchecked Sendable {
    var allowValue = true
    private(set) var requests: [WorkspaceCommitRequest] = []
    private let lock = NSLock()
    func allow(_ request: WorkspaceCommitRequest) -> Bool {
        lock.lock(); requests.append(request); lock.unlock()
        return allowValue
    }
}

enum WorkspaceTestSupport {
    /// Deterministic fixture project mapping mirroring LinuxShellProjectMapping's
    /// SHA256-of-canonical-root contract without importing the shell module
    /// into test fixtures (the engine test does not assert identity equality
    /// with the shell mapping; that cross-module assertion belongs to Main's
    /// unified cohort).
    static func projectID(for rootPath: String) -> UUID {
        let hex = FloeDigest.sha256Hex(Data(rootPath.utf8))
        func group(_ start: Int, _ count: Int) -> UInt32 {
            var value: UInt32 = 0
            let digits = Array(hex)
            for character in digits[start..<min(start + count, digits.count)] {
                value = value &<< 4
                if let nibble = character.hexDigitValue { value |= UInt32(nibble) }
            }
            return value
        }
        // Byte-exact 32-nibble → 16-byte mapping (same class as the accepted
        // LinuxShellTransport repair-1: a truncated tuple is both a type
        // error and silently loses entropy).
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: group(0, 2)), UInt8(truncatingIfNeeded: group(2, 2)),
            UInt8(truncatingIfNeeded: group(4, 2)), UInt8(truncatingIfNeeded: group(6, 2)),
            UInt8(truncatingIfNeeded: group(8, 2)), UInt8(truncatingIfNeeded: group(10, 2)),
            UInt8(truncatingIfNeeded: group(12, 2)), UInt8(truncatingIfNeeded: group(14, 2)),
            UInt8(truncatingIfNeeded: group(16, 2)), UInt8(truncatingIfNeeded: group(18, 2)),
            UInt8(truncatingIfNeeded: group(20, 2)), UInt8(truncatingIfNeeded: group(22, 2)),
            UInt8(truncatingIfNeeded: group(24, 2)), UInt8(truncatingIfNeeded: group(26, 2)),
            UInt8(truncatingIfNeeded: group(28, 2)), UInt8(truncatingIfNeeded: group(30, 2))
        ))
    }

    static func makeTempRoot(_ name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workspace-tests-\(ProcessInfo.processInfo.arguments.first?.sha16 ?? "x")", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
}

private extension String {
    var sha16: String { String(FloeDigest.sha256Hex(Data(utf8)).prefix(16)) }
}
