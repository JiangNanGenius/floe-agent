// SPDX-License-Identifier: MPL-2.0
//
// Authored-only test support for the FloeAndroidShellTools closure
// (job-1bd4fcce5eca4856). This file is NOT executed by the source-authoring
// job; it is host-runnable when Main adds the `FloeAndroidShellToolsTests`
// target to shared/Package.swift and compiles the cohort. All fixtures are
// synthetic: no device, no runtime component, no real engine, no provider
// key, no model call. The fake transport below is the ONLY engine stand-in;
// production code paths always consume the typed injected transport, so a
// fake here cannot weaken the real fail-closed routing.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

/// Deterministic synthetic workspace root (exists on disk under the test
/// temporary directory so the ORIGINAL ShellInputValidation.directory
/// checks behave exactly like production).
enum ShellTestRoot {
    static func make(name: String = "workspace") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-shell-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Fixed-qualification readiness for tests (production default stays the
/// compiled fail-closed `UnqualifiedLinuxShellReadiness`).
struct StaticLinuxShellReadiness: LinuxShellReadiness {
    let qualified: Bool
    var isQualifiedForLinuxShell: Bool { qualified }
    var refusalGuidance: String { "test-guidance" }
}

/// Scripted fake of the typed engine transport. Mirrors the frozen RuntimeWire
/// v1 semantics ONLY as data (merged output pages, cursor monotonicity,
/// leaseReleased after terminal, stop-request-then-release ordering).
/// Nothing here executes anything.
final class FakeLinuxShellTransport: LinuxShellTransport, @unchecked Sendable {
    private let lock = NSLock()

    // Recorded calls (typed; never string commands parsed back).
    private(set) var starts: [LinuxShellStartRequest] = []
    private(set) var cancels: [LinuxShellCancelRequest] = []
    private(set) var written: [(sessionID: String, bytes: Data)] = []
    private(set) var resizes: [LinuxShellResizeRequest] = []
    private(set) var pollCount = 0

    // Scripting hooks (called under the lock; must be pure/fast).
    /// nth == 1-based poll index for this session. Returning nil keeps
    /// `defaultPoll` (running with no data) semantics.
    var pollScript: ((_ sessionID: String, _ cursor: UInt64, _ nth: Int) -> LinuxShellPollReply?)?
    var startReply: ((_ request: LinuxShellStartRequest) -> LinuxShellStartReply?)?
    var startError: Error?
    var inputError: Error?
    var releaseAfterCancel = true

    func recordStart(_ request: LinuxShellStartRequest) {
        lock.lock(); starts.append(request); lock.unlock()
    }

    var recordedStartCount: Int { lock.lock(); defer { lock.unlock() }; return starts.count }
    var recordedCancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancels.count }
    var recordedPollCount: Int { lock.lock(); defer { lock.unlock() }; return pollCount }
    /// Lock-guarded (Swift 6 race-safe) view of the LAST recorded stop
    /// request's engine session, for target-only cancellation proofs.
    var lastCancelSessionID: String? { lock.lock(); defer { lock.unlock() }; return cancels.last?.sessionID }

    private var perSessionPolls: [String: Int] = [:]
    private var released: Set<String> = []

    func markReleased(_ sessionID: String) {
        lock.lock(); released.insert(sessionID); lock.unlock()
    }

    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        let (error, scripted) = startStepLocked(request)
        if let error { throw error }
        if let scripted, let reply = scripted(request) { return reply }
        let index = recordedStartCount
        return LinuxShellStartReply(sessionID: "lease-\(index)-\(request.runID.uuidString)",
                                    environmentID: request.environmentID ?? "linux.local")
    }

    /// Swift 6 noasync-safe synchronous critical sections (same repair class
    /// as the Job lane support double): async transport methods may not touch
    /// NSLock lexically, so every locked region is a sync helper.
    private func startStepLocked(_ request: LinuxShellStartRequest) -> (Error?, ((LinuxShellStartRequest) -> LinuxShellStartReply?)?) {
        lock.lock(); defer { lock.unlock() }
        starts.append(request)
        return (startError, startReply)
    }

    private struct PollStep {
        let nth: Int
        let scripted: ((String, UInt64, Int) -> LinuxShellPollReply?)?
        let isReleased: Bool
        let stopRequested: Bool
        let releaseAfterCancel: Bool
    }

    private func pollStepLocked(_ request: LinuxShellPollRequest) -> PollStep {
        lock.lock(); defer { lock.unlock() }
        pollCount += 1
        let nth = (perSessionPolls[request.sessionID] ?? 0) + 1
        perSessionPolls[request.sessionID] = nth
        return PollStep(nth: nth, scripted: pollScript,
                        isReleased: released.contains(request.sessionID),
                        stopRequested: cancels.contains { $0.sessionID == request.sessionID },
                        releaseAfterCancel: releaseAfterCancel)
    }

    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        let step = pollStepLocked(request)
        let nth = step.nth
        let scripted = step.scripted
        let isReleased = step.isReleased
        let stopRequested = step.stopRequested
        if let scripted, let reply = scripted(request.sessionID, request.cursor, nth) {
            return reply
        }
        if isReleased || (stopRequested && step.releaseAfterCancel) {
            markReleased(request.sessionID)
            // A stop-driven default release carries the engine truth:
            // cancelled, with the fixed user-stop service code.
            return LinuxShellPollReply(sessionID: request.sessionID, mergedOutput: Data(),
                                       cursor: request.cursor, gapBytes: 0, more: false,
                                       droppedBytes: 0, state: .terminated, leaseReleased: true,
                                       cancelled: true, stopReason: "user-stop",
                                       exitCode: 0, termSig: 0, waitErrno: 0,
                                       // Positive synthetic fixture default: the same
                                       // explicit synced proof `page()` already carries.
                                       // Unknown/conflict negatives build their own
                                       // pages inline; the production rule
                                       // (unknown never yields success) stays tested.
                                       workspaceStatus: "synced")
        }
        return LinuxShellPollReply(sessionID: request.sessionID, mergedOutput: Data(),
                                   cursor: request.cursor, gapBytes: 0, more: false,
                                   droppedBytes: 0, state: .running, leaseReleased: false)
    }

    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        let error = inputStepLocked(request)
        if let error { throw error }
        return LinuxShellInputReply(acceptedBytes: request.bytes.count)
    }

    private func inputStepLocked(_ request: LinuxShellInputRequest) -> Error? {
        lock.lock(); defer { lock.unlock() }
        written.append((request.sessionID, request.bytes))
        return inputError
    }

    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        recordResizeLocked(request)
        return LinuxShellResizeReply(resized: true)
    }

    private func recordResizeLocked(_ request: LinuxShellResizeRequest) {
        lock.lock(); resizes.append(request); lock.unlock()
    }

    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        recordCancelLocked(request)
        return LinuxShellCancelReply(state: "stop_requested")
    }

    private func recordCancelLocked(_ request: LinuxShellCancelRequest) {
        lock.lock(); cancels.append(request); lock.unlock()
    }

    // MARK: helpers for scripts

    static func page(session: String, cursor: UInt64, text: String,
                     more: Bool = false, state: LinuxShellSessionState = .running,
                     released: Bool = false, cancelled: Bool = false, stopReason: String? = nil,
                     exit: Int32? = nil, termSig: Int32? = nil,
                     gap: Int = 0, dropped: Int = 0,
                     workspaceStatus: String? = "synced", workspaceRecoveryRef: String? = nil) -> LinuxShellPollReply {
        let bytes = Data(text.utf8)
        return LinuxShellPollReply(sessionID: session, mergedOutput: bytes,
                                   cursor: cursor + UInt64(bytes.count),
                                   gapBytes: gap, more: more, droppedBytes: dropped,
                                   state: state, leaseReleased: released,
                                   cancelled: cancelled, stopReason: stopReason,
                                   exitCode: exit, termSig: termSig, waitErrno: nil,
                                   workspaceStatus: workspaceStatus, workspaceRecoveryRef: workspaceRecoveryRef)
    }
}

/// Wait until a condition holds, polling cooperatively (bounded).
func shellWaitUntil(timeoutMillis: Int = 2_000, _ condition: () async -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(timeoutMillis) &* 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
