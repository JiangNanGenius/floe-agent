// FloeAndroidWorkspaceTools — the session engine behind the Binder grant.
//
// Android-owned (job-ade884c46eb84ec1). Synchronous, lock-guarded facade
// (the same shape discipline as `LinuxShellMailbox`: binder/worker threads
// call short methods; nothing here awaits an actor). The engine performs the
// ACTUAL file work inside the Core process:
//
//   import : baselineBegin -> entryHeader(i)/entryOpenData(i)* -> baselineFinish
//   export : exportBegin -> exportStage(header,fd)* -> exportFinish (plan, gate,
//            CAS commit through the original AtomicFileCommitter authority)
//
// and never holds a whole file in memory (64 KiB frames). All Core-side
// durable state (marker, journal, baseline manifest, staging, conflicts,
// index) lives under the transfer root OUTSIDE the workspace.
//
// The engine trusts NEITHER side's claims: digests/bytes are always what the
// engine itself read through no-follow descriptors.

import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Injected authority hooks (installed by FloeAndroidCore; fail closed)

public struct WorkspaceAuthorityHooks: Sendable {
    /// Light revalidation: grant proof + current native root epoch. Cheap,
    /// synchronous; called on EVERY session operation.
    public let revalidateLight: @Sendable (_ binding: WorkspaceGrantBinding) -> Bool
    /// Run currency: the ORIGINAL run store says the run still exists and is
    /// not terminal, and the workspace binding still maps to the same
    /// persisted ownership. Bounded synchronous; called at every phase
    /// boundary and periodically during long loops.
    public let revalidateRun: @Sendable (_ binding: WorkspaceGrantBinding) -> Bool
    /// The REAL commit gate. nil until production installs it; nil or false
    /// means NO commit (fail closed — there is no default-true).
    public let commitGateProvider: @Sendable () -> WorkspaceCommitGate?
    /// Core absolute paths must never reach the runtime wire or ordinary
    /// output; the engine only ever uses this for its own filesystem calls.
    public init(revalidateLight: @escaping @Sendable (WorkspaceGrantBinding) -> Bool,
                revalidateRun: @escaping @Sendable (WorkspaceGrantBinding) -> Bool,
                commitGateProvider: @escaping @Sendable () -> WorkspaceCommitGate?) {
        self.revalidateLight = revalidateLight
        self.revalidateRun = revalidateRun
        self.commitGateProvider = commitGateProvider
    }
}

// MARK: - Session

public final class WorkspaceTransferEngine: @unchecked Sendable {
    public static let shared = WorkspaceTransferEngine()

    private final class Session: @unchecked Sendable {
        enum State {
            case bound
            case baselining
            case baselineReady
            case exporting
            case finished
            case aborted
        }
        let lock = NSLock()
        var state: State = .bound
        let binding: WorkspaceGrantBinding
        let paths: WorkspaceTransferPaths
        let marker: WorkspaceOwnerMarker
        let journal: WorkspaceJournal
        // baseline
        var baseline: WorkspaceBaselineScan?
        var mirroredKeys: [String] = []      // ordered, transferable entries only
        var opsSinceRunRecheck = 0
        // export
        var received: [WorkspaceReceivedEntry] = []
        var receivedBySeq: [Int64: WorkspaceReceivedEntry] = [:]
        var stagingTotalBytes: Int64 = 0
        var nextStagingSeq: Int64 = 1
        var outcomeJSON: String?
        // cooperative abort for the synchronous scan/cancel closures
        var abortRequested = false
        init(binding: WorkspaceGrantBinding, paths: WorkspaceTransferPaths,
             marker: WorkspaceOwnerMarker, journal: WorkspaceJournal) {
            self.binding = binding
            self.paths = paths
            self.marker = marker
            self.journal = journal
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var hooksStorage: WorkspaceAuthorityHooks?
    private var transferRootStorage: String?
    private var counters = ["baselineBegin": 0, "baselineFinish": 0, "entryServed": 0,
                            "entryStaged": 0, "exportFinish": 0, "refused": 0,
                            "sweptSessions": 0]
    private var sweptStagingBytesTotal: Int64 = 0

    public init() {}

    /// Production installation (from LinuxWorkspaceAuthority.install). First
    /// install wins; a repeat with the SAME transfer root is an idempotent
    /// success, anything else is refused — the engine belongs to the one
    /// accepted native generation, exactly like the mailbox bind rule.
    public func install(hooks: WorkspaceAuthorityHooks, transferRoot: String) -> Bool {
        guard transferRoot.hasPrefix("/"), transferRoot.utf8.count <= 4_096 else { return false }
        lock.lock(); defer { lock.unlock() }
        if hooksStorage != nil {
            return transferRootStorage == transferRoot
        }
        hooksStorage = hooks
        transferRootStorage = transferRoot
        return true
    }

    public var isInstalled: Bool {
        lock.lock()
        let installed = hooksStorage != nil
        lock.unlock()
        return installed
    }

    /// Test-only producer cleanup: releases this instance's install slot
    /// (hooks + transfer root), its live session table and its counters,
    /// restoring fresh-instance state. The slot belongs to ONE accepted
    /// generation exactly like the authority install in FloeAndroidCore,
    /// so the host suite's existing reset chain (composition
    /// .resetForTesting -> LinuxWorkspaceAuthority.resetInstallationForTesting)
    /// releases BOTH halves together: without this seam the
    /// first-install-wins rule above would strand every later synthetic-
    /// root generation of a host suite with an authority that is silently
    /// never installed. Production never calls it (one accepted install per
    /// process; same-root rebinds stay idempotent).
    public func resetInstallationForTesting() {
        lock.lock()
        hooksStorage = nil
        transferRootStorage = nil
        sessions.removeAll()
        counters = ["baselineBegin": 0, "baselineFinish": 0, "entryServed": 0,
                    "entryStaged": 0, "exportFinish": 0, "refused": 0,
                    "sweptSessions": 0]
        sweptStagingBytesTotal = 0
        lock.unlock()
    }

    private var hooks: WorkspaceAuthorityHooks? {
        lock.lock()
        let value = hooksStorage
        lock.unlock()
        return value
    }
    private var transferRoot: String? {
        lock.lock()
        let value = transferRootStorage
        lock.unlock()
        return value
    }

    // MARK: - Session lifecycle

    /// Opens (or idempotently re-opens) a session for the grant. The binding
    /// MUST have just been proof-validated by the caller (`openSession`
    /// re-validates anyway) and the workspace root MUST be a real no-follow
    /// directory (the Core resolver guarantees this before calling).
    public func openSession(binding: WorkspaceGrantBinding) throws -> String {
        guard let hooks, let transferRoot else { throw WorkspaceTransferError.notConfigured }
        guard hooks.revalidateLight(binding) else {
            bumpRefused(); throw WorkspaceTransferError.proofRefused(code: "light")
        }
        guard hooks.revalidateRun(binding) else {
            bumpRefused(); throw WorkspaceTransferError.proofRefused(code: "runCurrency")
        }
        let sessionKey = Self.newSessionKey()
        let paths = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: sessionKey)
        // Directory creation is 0o700, Core-only. Marker FIRST (durable owner
        // proof) before any payload effect exists.
        try FileManager.default.createDirectory(atPath: paths.sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: paths.stagingDirectory, withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(sessionKey: sessionKey, grantID: binding.grantID,
                                          projectID: binding.projectID.uuidString, runID: binding.runID.uuidString,
                                          rootEpoch: binding.rootEpoch,
                                          createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: paths.ownerMarker)
        let journal = WorkspaceJournal(path: paths.journal)
        let session = Session(binding: binding, paths: paths, marker: marker, journal: journal)
        try journal.append(["record": "sessionOpen", "grantID": binding.grantID,
                            "projectID": binding.projectID.uuidString, "runID": binding.runID.uuidString,
                            "rootEpoch": binding.rootEpoch, "workspace": binding.workspaceFingerprint])
        lock.lock(); sessions[sessionKey] = session; lock.unlock()
        return sessionKey
    }

    public func closeSession(sessionKey: String, terminal: Bool) {
        guard let session = fetch(sessionKey) else { return }
        session.lock.lock()
        session.abortRequested = true
        let wasTerminal = session.state == .finished || session.state == .aborted
        if terminal, !wasTerminal {
            session.state = .aborted
        }
        session.lock.unlock()
        if terminal, !wasTerminal {
            try? session.journal.append(["record": "grantClosed"])
            try? session.marker.markTerminal(at: session.paths.ownerMarker)
            lock.lock(); sessions.removeValue(forKey: sessionKey); lock.unlock()
        }
    }

    private func fetch(_ sessionKey: String) -> Session? {
        lock.lock()
        let value = sessions[sessionKey]
        lock.unlock()
        return value
    }

    /// The live binding for one session key, or nil (unknown/finished
    /// sessions are never guessed). Used by the Core-side commit gate so it
    /// can bind its decision to the minted grant instead of a caller echo.
    public func binding(forSessionKey sessionKey: String) -> WorkspaceGrantBinding? {
        fetch(sessionKey)?.binding
    }

    private func bump(_ counter: String) {
        // Call with the engine lock held.
        counters[counter, default: 0] += 1
    }

    private func bumpRefused() {
        lock.lock(); bump("refused"); lock.unlock()
    }

    private func isAborted(_ session: Session) -> Bool {
        session.lock.lock()
        let aborted = session.abortRequested
        session.lock.unlock()
        return aborted
    }

    // MARK: - Import (baseline)

    /// Scans the baseline and returns the bounded receipt object. The scan
    /// runs OUTSIDE the session lock (its cancel closure takes the lock), so
    /// a concurrent abort can stop a long scan at frame boundaries.
    public func baselineBegin(sessionKey: String) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        try recheck(session, full: true)
        session.lock.lock()
        guard session.state == .bound else {
            session.lock.unlock(); throw WorkspaceTransferError.malformed
        }
        session.state = .baselining
        session.lock.unlock()
        do {
            // The workspace root must still be a real no-follow directory.
            guard WorkspaceNoFollow.kind(session.binding.workspaceRootPath) == .directory else {
                throw WorkspaceTransferError.pathUnsafe(code: "rootNotDirectory")
            }
            guard WorkspaceNoFollow.meetsFreeReserve(path: session.paths.sessionDirectory,
                                                     reserveBytes: session.binding.budgets.freeDiskReserveBytes,
                                                     projectedBytes: 0) else {
                throw WorkspaceTransferError.diskReserveUnmet
            }
            let scan = try WorkspaceBaselineScanner.scan(workspaceRoot: session.binding.workspaceRootPath,
                                                         manifestPath: session.paths.baselineManifest,
                                                         budgets: session.binding.budgets,
                                                         isCancelled: { [weak session] in
                guard let session else { return true }
                return self.isAborted(session)
            })
            let mirrored = scan.entries.keys.sorted().filter { key in
                scan.entries[key]?.skipped == nil
            }
            session.lock.lock()
            if session.abortRequested {
                session.state = .aborted
                session.lock.unlock()
                throw WorkspaceTransferError.cancelled
            }
            session.baseline = scan
            session.mirroredKeys = mirrored
            session.state = .baselineReady
            try session.journal.append(["record": "baselineReady",
                                        "entries": scan.entries.count,
                                        "mirrored": mirrored.count,
                                        "bytes": scan.totalMirroredBytes])
            session.lock.unlock()
            lock.lock(); bump("baselineBegin"); lock.unlock()
            return ["sessionKey": sessionKey,
                    "entryCount": mirrored.count,
                    "totalBytes": scan.totalMirroredBytes,
                    "skippedCount": scan.skipped.count,
                    "skipped": scan.skipped.prefix(64).map { ["path": $0.path, "reason": $0.reason.rawValue] },
                    "budgets": session.binding.budgets.dictionaryValue]
        } catch {
            session.lock.lock()
            if session.state == .baselining { session.state = .bound }
            session.lock.unlock()
            throw error
        }
    }

    /// Ordered header for one mirrored baseline entry; nil at end-of-table.
    public func baselineHeader(sessionKey: String, index: Int64) throws -> [String: Any]? {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        session.lock.lock()
        guard session.state == .baselineReady, index >= 0 else {
            session.lock.unlock(); throw WorkspaceTransferError.malformed
        }
        guard index < Int64(session.mirroredKeys.count) else {
            session.lock.unlock(); return nil
        }
        let key = session.mirroredKeys[Int(index)]
        let entry = session.baseline?.entries[key]
        session.opsSinceRunRecheck += 1
        let needsFull = session.opsSinceRunRecheck >= 256
        if needsFull { session.opsSinceRunRecheck = 0 }
        session.lock.unlock()
        try recheck(session, full: needsFull)
        guard let entry else { throw WorkspaceTransferError.malformed }
        lock.lock(); bump("entryServed"); lock.unlock()
        return entry.dictionaryValue
    }

    /// Opens the ACTUAL file bytes for one baseline entry (no-follow) and
    /// hands the descriptor to the caller (the grant wraps it for Binder).
    public func baselineOpenData(sessionKey: String, index: Int64) throws -> (fd: Int32, entry: WorkspaceBaselineEntry) {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        session.lock.lock()
        guard session.state == .baselineReady, index >= 0, index < Int64(session.mirroredKeys.count) else {
            session.lock.unlock(); throw WorkspaceTransferError.malformed
        }
        let key = session.mirroredKeys[Int(index)]
        let entry = session.baseline?.entries[key]
        session.lock.unlock()
        try recheck(session, full: false)
        guard let entry, entry.kind == .file, entry.skipped == nil else {
            throw WorkspaceTransferError.pathUnsafe(code: "entryNotFile")
        }
        let absolute = session.binding.workspaceRootPath + "/" + entry.relativePath
        switch WorkspaceNoFollow.openRegularNoFollow(absolute) {
        case .failure(let error):
            throw error
        case .success(let fd):
            return (fd, entry)
        }
    }

    public func baselineFinish(sessionKey: String, appliedCount: Int64, appliedBytes: Int64) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        try recheck(session, full: true)
        session.lock.lock()
        guard session.state == .baselineReady else {
            session.lock.unlock(); throw WorkspaceTransferError.malformed
        }
        try session.journal.append(["record": "importApplied", "appliedCount": appliedCount,
                                    "appliedBytes": appliedBytes])
        session.lock.unlock()
        lock.lock(); bump("baselineFinish"); lock.unlock()
        return ["state": "ready"]
    }

    // MARK: - Export

    public func exportBegin(sessionKey: String) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        try recheck(session, full: true)
        guard WorkspaceNoFollow.meetsFreeReserve(path: session.paths.sessionDirectory,
                                                 reserveBytes: session.binding.budgets.freeDiskReserveBytes,
                                                 projectedBytes: 0) else {
            throw WorkspaceTransferError.diskReserveUnmet
        }
        session.lock.lock()
        defer { session.lock.unlock() }
        guard session.state == .baselineReady else { throw WorkspaceTransferError.malformed }
        session.state = .exporting
        session.received.removeAll()
        session.receivedBySeq.removeAll()
        session.stagingTotalBytes = 0
        session.nextStagingSeq = 1
        try session.journal.append(["record": "exportBegin"])
        return ["state": "staging", "budgets": session.binding.budgets.dictionaryValue]
    }

    /// Stages ONE received entry. The data fd (for `.file`) is read to EOF
    /// with frame streaming; the engine records the bytes it ACTUALLY read.
    public func exportStage(sessionKey: String, header: [String: Any], dataFd: Int32?) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else { throw WorkspaceTransferError.noSession }
        guard let sequence = (header["seq"] as? NSNumber)?.int64Value,
              let pathRaw = header["path"] as? String,
              let kindRaw = header["kind"] as? String else {
            throw WorkspaceTransferError.malformed
        }
        session.lock.lock()
        let duplicateSeq = session.receivedBySeq[sequence] != nil
        let entryBudgetReached = session.received.count >= session.binding.budgets.entryCount
        let stateOK = session.state == .exporting
        session.lock.unlock()
        guard stateOK else { throw WorkspaceTransferError.malformed }
        guard !duplicateSeq, !entryBudgetReached else {
            throw WorkspaceTransferError.budgetExceeded(code: duplicateSeq ? "duplicateSeq" : "entryCount")
        }
        let budgets = session.binding.budgets
        try recheck(session, full: false)

        // Build the candidate entry with STRICT validation before any write.
        var refusal: String?
        var recordedSize: Int64?
        var recordedDigest: String?
        var stagingPath: String?
        var linkTarget: String?
        var claimedSize: Int64 = 0
        var claimedMode: Int32 = 0o644
        var failureToReport: WorkspaceTransferError?
        do {
            let components = try WorkspaceRelativePath.validate(pathRaw, budgets: budgets)
            guard !components.isEmpty else { throw WorkspaceTransferError.pathUnsafe(code: "empty") }
            switch kindRaw {
            case "file":
                guard let sourceFd = dataFd else { throw WorkspaceTransferError.malformed }
                if let size = header["size"] as? NSNumber { claimedSize = size.int64Value }
                if let mode = header["mode"] as? NSNumber { claimedMode = Int32(truncatingIfNeeded: mode.int64Value) & 0o755 }
                // ACTUAL fstat proof before any planning/IO: a pipe/socket is
                // refused immediately (never read, never blocked, the caller
                // keeps its fd), and the disk reserve is projected from the
                // REAL size, not only the attacker-supplied claim. The
                // streamed digest/count remains the entry authority.
                let actualSize: Int64
                switch WorkspaceNoFollow.regularFileProof(sourceFd) {
                case .success(let size): actualSize = size
                case .failure(let proofFailure): throw proofFailure
                }
                guard actualSize <= budgets.maximumEntryBytes else {
                    throw WorkspaceTransferError.budgetExceeded(code: "entryBytes")
                }
                session.lock.lock()
                let remaining = budgets.totalBytes - session.stagingTotalBytes
                let seq = session.nextStagingSeq
                session.nextStagingSeq += 1
                session.lock.unlock()
                guard claimedSize <= budgets.maximumEntryBytes else {
                    throw WorkspaceTransferError.budgetExceeded(code: "entryBytes")
                }
                guard remaining > 0 else { throw WorkspaceTransferError.budgetExceeded(code: "totalBytes") }
                guard WorkspaceNoFollow.meetsFreeReserve(path: session.paths.stagingDirectory,
                                                         reserveBytes: budgets.freeDiskReserveBytes,
                                                         projectedBytes: max(actualSize, max(claimedSize, 0))) else {
                    throw WorkspaceTransferError.diskReserveUnmet
                }
                let staged = session.paths.stagingDirectory + "/\(seq)"
                let outFd = open(staged, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                guard outFd >= 0 else {
                    throw WorkspaceTransferError.ioFailed(stage: "stageOpen", errnoCode: Int32(errno))
                }
                let copy = WorkspaceStreamCopier.copy(fromFd: sourceFd, toFd: outFd,
                                                      frameBytes: budgets.frameBytes,
                                                      maximumBytes: min(budgets.maximumEntryBytes, remaining),
                                                      isCancelled: { [weak session] in
                    guard let session else { return true }
                    return self.isAborted(session)
                }, reserveGate: { _ in
                    // Bounded-growth / per-frame reserve (Main review
                    // 20261022): the initial projection used the ACTUAL
                    // fstat size (and the claim only for the max), but a
                    // concurrently grown regular file can consume up to
                    // min(maximumEntryBytes, remaining). Re-measure the real
                    // destination free space against the reserve as staging
                    // grows; a breach refuses with diskReserveUnmet and the
                    // engine's existing failure path keeps the session
                    // journal/recovery (only this entry's torn partial is
                    // removed, the source is untouched, fds stay caller-owned
                    // by the copier contract).
                    WorkspaceNoFollow.meetsFreeReserve(path: session.paths.stagingDirectory,
                                                       reserveBytes: budgets.freeDiskReserveBytes,
                                                       projectedBytes: 0)
                        ? nil : WorkspaceTransferError.diskReserveUnmet
                })
                close(outFd)
                switch copy {
                case .success(let outcome):
                    // Claim vs actual mismatch is recorded honestly: the
                    // engine's OWN digest/size decide the entry; the claim is
                    // only annotated in the journal. Nothing here trusts it.
                    recordedSize = outcome.bytes
                    recordedDigest = outcome.sha256
                    stagingPath = staged
                    try? Data((outcome.sha256 + "\n").utf8).write(to: URL(fileURLWithPath: staged + ".digest"),
                                                                  options: .atomic)
                    session.lock.lock()
                    session.stagingTotalBytes += outcome.bytes
                    session.lock.unlock()
                case .failure(.cancelled):
                    try? FileManager.default.removeItem(atPath: staged)
                    throw WorkspaceTransferError.cancelled
                case .failure(.overflow):
                    try? FileManager.default.removeItem(atPath: staged)
                    throw WorkspaceTransferError.budgetExceeded(code: "entryBytes")
                case .failure(.transfer(let error)):
                    try? FileManager.default.removeItem(atPath: staged)
                    throw error
                }
            case "directory":
                if let mode = header["mode"] as? NSNumber { claimedMode = Int32(truncatingIfNeeded: mode.int64Value) & 0o755 }
            case "symlink":
                guard let target = header["linkTarget"] as? String else {
                    throw WorkspaceTransferError.pathUnsafe(code: "linkTargetMissing")
                }
                // (was a `guard ... else` whose body intentionally fell
                // through — a compiler error; the documented semantics are a
                // recorded recoverable refusal, not a scope exit.)
                if WorkspaceRelativePath.classifyLinkTarget(target, linkComponents: components, budgets: budgets)
                        != .relativeContained {
                    // External/absolute link: refused; never followed into
                    // Core, recorded in the outcome as recoverable refusal.
                    refusal = "linkEscape"
                }
                linkTarget = refusal == nil ? target : nil
            default:
                throw WorkspaceTransferError.pathUnsafe(code: "unknownKind")
            }
        } catch let error as WorkspaceTransferError {
            refusal = error.wireCode
            if case .cancelled = error { failureToReport = error }
        }
        if let failureToReport { throw failureToReport }

        let entry = WorkspaceReceivedEntry(sequence: sequence, relativePath: pathRaw,
                                           kind: (kindRaw == "file" ? .file : kindRaw == "symlink" ? .symlink : .directory),
                                           claimedSize: claimedSize, claimedMode: claimedMode,
                                           linkTarget: linkTarget,
                                           recordedSize: recordedSize, recordedDigest: recordedDigest,
                                           stagingPath: stagingPath, refusal: refusal)
        session.lock.lock()
        session.received.append(entry)
        session.receivedBySeq[sequence] = entry
        let receivedCount = session.received.count
        session.opsSinceRunRecheck += 1
        let needsFull = session.opsSinceRunRecheck >= 256
        if needsFull { session.opsSinceRunRecheck = 0 }
        session.lock.unlock()
        if needsFull { try recheck(session, full: true) }
        try session.journal.append(["record": "staged", "seq": sequence, "path": pathRaw,
                                    "kind": kindRaw,
                                    "bytes": recordedSize ?? 0,
                                    "digest": recordedDigest ?? "",
                                    "refusal": refusal ?? ""])
        lock.lock(); bump("entryStaged"); lock.unlock()
        return ["seq": sequence,
                "state": refusal == nil ? "staged" : "refused",
                "code": refusal ?? "",
                "recordedSize": recordedSize ?? 0,
                "recordedDigest": recordedDigest ?? "",
                "receivedCount": receivedCount]
    }

    /// Preflight + CAS commit. This is the ONLY path that mutates the Core
    /// workspace, and it mutates exclusively through the plan executor.
    public func exportFinish(sessionKey: String) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else {
            // Idempotent re-read from the durable terminal receipt after an
            // uncertain Binder reply (unknown/lost EXPORT_FINISH answer).
            if let receipt = finishedReceipt(sessionKey: sessionKey) { return receipt }
            throw WorkspaceTransferError.noSession
        }
        try recheck(session, full: true)
        session.lock.lock()
        if session.state == .finished, let stored = session.outcomeJSON,
           let data = stored.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            session.lock.unlock()
            return object
        }
        guard session.state == .exporting else {
            session.lock.unlock(); throw WorkspaceTransferError.malformed
        }
        let binding = session.binding
        let received = session.received
        let baseline = session.baseline
        session.lock.unlock()
        guard let baseline else { throw WorkspaceTransferError.malformed }

        // Re-scan the CURRENT Core state (fresh, actual bytes, no-follow).
        let currentScan = try WorkspaceBaselineScanner.scan(
            workspaceRoot: binding.workspaceRootPath,
            manifestPath: session.paths.sessionDirectory + "/current.jsonl",
            budgets: binding.budgets,
            isCancelled: { [weak session] in
                guard let session else { return true }
                return self.isAborted(session)
            })
        var current: [String: WorkspaceBaselineEntry] = [:]
        for (key, entry) in currentScan.entries { current[key] = entry }

        let actions = try WorkspaceCommitPlanner.plan(baseline: baseline, received: received,
                                                      current: current, budgets: binding.budgets)
        let planDigest = Self.planDigest(of: actions)

        guard let hooks else { throw WorkspaceTransferError.notConfigured }
        guard let gate = hooks.commitGateProvider() else {
            // REAL callback required: absent gate means NO commit.
            session.lock.lock()
            session.abortRequested = true
            session.state = .aborted
            session.lock.unlock()
            try? session.journal.append(["record": "commitRefused", "reason": "gateAbsent"])
            try? session.marker.markTerminal(at: session.paths.ownerMarker)
            throw WorkspaceTransferError.commitRefused(code: "gateAbsent")
        }
        let summary = WorkspaceCommitter(workspaceRoot: binding.workspaceRootPath,
                                         budgets: binding.budgets,
                                         journal: session.journal,
                                         conflictsDirectory: session.paths.conflictsDirectory,
                                         revalidate: { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.lightCheck(session)
        }, gate: gate,
                                         isCancelled: { [weak session] in
            guard let session else { return true }
            session.lock.lock(); defer { session.lock.unlock() }
            return session.abortRequested
        }).execute(actions, planDigest: planDigest,
                    identity: (binding.projectID, binding.runID, binding.rootEpoch, sessionKey))

        let conflictedPaths = Set(summary.conflicts.map { $0.path })
        let synced = summary.conflicts.isEmpty && summary.failedEffects.isEmpty && !summary.partialAbort
        var outcome: [String: Any] = [
            "result": synced ? "synced" : (summary.partialAbort ? "aborted" : "conflict"),
            "applied": [
                "created": summary.appliedCreates,
                "replaced": summary.appliedReplaces,
                "directories": summary.appliedDirectories,
                "deleted": summary.appliedDeletions,
                "links": summary.appliedLinks,
            ],
            "conflicts": summary.conflicts.map { conflict in
                var object: [String: Any] = ["path": conflict.path, "kind": conflict.kind.rawValue]
                if let artifact = conflict.artifactRef { object["artifact"] = artifact }
                return object
            },
            "failed": summary.failedEffects.map { ["path": $0.path, "code": $0.code] },
            "planDigest": planDigest,
        ]
        // Durable FULL detail lands in the task-owned terminal index
        // (never size-capped, reconcilable offline). The WIRE reply is a
        // FIXED-BOUNDED receipt: explicit status + totals + counts + small
        // preview + opaque recovery reference (sessionKey + index digest —
        // no Core paths), so a legitimate 10000-conflict export can always
        // answer "synced=false / conflict / partial" with a usable receipt
        // after the effects settle. Effects are NEVER re-run to fit the
        // reply, and a bounded preview is NEVER allowed to read as success.
        outcome["counts"] = [
            "conflicts": summary.conflicts.count,
            "failed": summary.failedEffects.count,
            "stagedRefusals": received.filter { $0.refusal != nil }.count,
        ]
        outcome["preview"] = [
            "conflicts": summary.conflicts.prefix(16).map { conflict in
                var object: [String: Any] = ["path": conflict.path, "kind": conflict.kind.rawValue]
                if conflict.artifactRef != nil { object["artifact"] = true }
                return object
            },
            "failed": summary.failedEffects.prefix(16).map { ["path": $0.path, "code": $0.code] },
        ]
        outcome["partial"] = (outcome["result"] as? String) != "synced"
        // Terminal index + durable recovered conflicts (reachable by Core via
        // the transfer root, never leaked as host absolute paths in output).
        let recoveredCount = relocateRecoveredConflicts(session: session)
        if recoveredCount > 0 { outcome["recoveredArtifacts"] = recoveredCount }
        // The FULL detail lands on disk under a FILE-sized path (never the
        // Binder 64 KiB control cap) with tmp+fsync+rename and read-back
        // verification. A failed index persistence can never yield a
        // "complete" receipt: staging/recovery stay preserved (the sweep
        // requires a valid index to collect anything) and the wire answers
        // result="receiptIncomplete".
        let indexState = writeTerminalIndex(session: session, outcome: outcome,
                                            conflictedPaths: Array(conflictedPaths))
        var persistedOutcome = outcome
        persistedOutcome["indexPersisted"] = indexState.persisted
        if !indexState.persisted {
            persistedOutcome["result"] = "receiptIncomplete"
            persistedOutcome["partial"] = true
        }
        try? session.marker.markTerminal(at: session.paths.ownerMarker)
        let receipt = boundedWireReceipt(from: persistedOutcome, sessionKey: sessionKey,
                                         indexDigest: indexState.digest)
        // The session caches the EXACT bounded wire form (String bytes, as
        // `finishedReceipt` re-parses it) for idempotent EXPORT_FINISH
        // re-reads — the same receipt whether or not the durable index
        // persisted; boundedWireReceipt only ever returns an object that
        // encodes under the control cap, so the cache is never silently nil.
        var receiptJSON: String?
        if let stored = try? WorkspaceWireJSON.encodeBounded(receipt,
                limit: WorkspaceWireLimits.maximumControlBytes) {
            receiptJSON = String(decoding: stored, as: UTF8.self)
        }
        session.lock.lock()
        session.state = .finished
        session.outcomeJSON = receiptJSON
        session.lock.unlock()
        // The finished session stays addressable (idempotent re-read from the
        // actual terminal receipt after an uncertain Binder reply); the grant
        // close or the sweep removes it.
        lock.lock(); bump("exportFinish"); lock.unlock()
        return receipt
    }

    /// Re-read path: EXPORT_FINISH called again for an already-finished
    /// session returns the IDENTICAL bounded receipt (no effects, no replay).
    /// If the in-memory entry is gone (process restart), the durable terminal
    /// index is rebuilt into a receipt of the same shape — the status fields
    /// are recovered from actual evidence, never guessed.
    public func finishedReceipt(sessionKey: String) -> [String: Any]? {
        if let session = fetch(sessionKey) {
            session.lock.lock()
            let state = session.state
            let stored = session.outcomeJSON
            session.lock.unlock()
            guard state == .finished, let stored,
                  let data = stored.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
        guard let transferRoot else { return nil }
        let paths = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: sessionKey)
        guard FileManager.default.fileExists(atPath: paths.ownerMarker),
              let marker = WorkspaceOwnerMarker.load(path: paths.ownerMarker),
              marker.state == "terminal",
              let indexData = try? Data(floeContentsOf: URL(fileURLWithPath: paths.terminalIndex)),
              indexData.count <= 4_194_304,
              let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              (index["record"] as? String) == "terminalIndex",
              (index["sessionKey"] as? String) == sessionKey else {
            return nil
        }
        return boundedWireReceipt(from: index, sessionKey: sessionKey,
                                  indexDigest: digestOfFile(at: paths.terminalIndex))
    }

    /// Fixed-bounded projection of the full outcome onto the wire. Shrinks
    /// the preview (never the STATUS/counts) until the JSON fits.
    private func boundedWireReceipt(from outcome: [String: Any], sessionKey: String,
                                    indexDigest: String?) -> [String: Any] {
        let status = outcome["result"] as? String ?? "failed"
        var receipt: [String: Any] = [
            "ok": true,
            "result": status,
            "partial": outcome["partial"] as? Bool ?? (status != "synced"),
            "applied": outcome["applied"] ?? [:],
            "counts": outcome["counts"] ?? [:],
            "planDigest": outcome["planDigest"] ?? "",
            "recovery": ["sessionKey": sessionKey, "indexDigest": indexDigest ?? "unavailable"],
        ]
        var preview = outcome["preview"] as? [String: Any] ?? [:]
        let cap = WorkspaceWireLimits.maximumControlBytes - 2048
        while true {
            receipt["preview"] = preview
            if let data = try? WorkspaceWireJSON.encodeBounded(receipt, limit: cap) {
                _ = data
                return receipt
            }
            let conflicts = (preview["conflicts"] as? [[String: Any]]) ?? []
            let failed = (preview["failed"] as? [[String: Any]]) ?? []
            guard !conflicts.isEmpty || !failed.isEmpty else {
                // Cannot encode even a preview-less receipt (pathologically
                // long status strings): emit the minimum honest receipt.
                return ["ok": true, "result": status, "partial": true,
                        "counts": receipt["counts"] ?? [:],
                        "previewTruncated": true,
                        "recovery": ["sessionKey": sessionKey,
                                     "indexDigest": indexDigest ?? "unavailable"]]
            }
            if conflicts.count >= failed.count {
                preview["conflicts"] = Array(conflicts.dropLast(max(1, conflicts.count / 2)))
            } else {
                preview["failed"] = Array(failed.dropLast(max(1, failed.count / 2)))
            }
            preview["truncated"] = true
        }
    }

    private func digestOfFile(at path: String) -> String? {
        switch WorkspaceNoFollow.openRegularNoFollow(path) {
        case .failure:
            return nil
        case .success(let fd):
            defer { close(fd) }
            switch WorkspaceDigest.sha256Hex(fromFd: fd, frameBytes: 65_536, isCancelled: { false }) {
            case .success(let outcome): return outcome.0
            case .failure: return nil
            }
        }
    }

    /// Moves the session's conflict artifacts from the (sweep-eligible)
    /// session directory into the durable `recovered/<sessionKey>` namespace
    /// of the transfer root. Returns the number of artifacts relocated.
    private func relocateRecoveredConflicts(session: Session) -> Int {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: session.paths.conflictsDirectory)) ?? [])
            .filter { $0 != "." && $0 != ".." }
            .sorted()
        guard !files.isEmpty else { return 0 }
        let target = session.paths.recoveredDirectory
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        var moved = 0
        for name in files {
            if rename(session.paths.conflictsDirectory + "/" + name, target + "/" + name) == 0 {
                moved += 1
            }
        }
        _ = WorkspaceNoFollow.fsyncDirectory(target)
        try? session.journal.append(["record": "recovered", "artifacts": moved])
        return moved
    }

    // MARK: - Abort / stats / sweep

    public func abort(sessionKey: String, reason: String) throws -> [String: Any] {
        guard let session = fetch(sessionKey) else { return ["state": "alreadyGone"] }
        session.lock.lock()
        let wasTerminal = session.state == .finished || session.state == .aborted
        session.abortRequested = true
        session.state = .aborted
        session.lock.unlock()
        if wasTerminal {
            // Terminal entries are no longer needed once the grant aborts;
            // the durable index/marker stay for audit and re-read fallback.
            lock.lock(); sessions.removeValue(forKey: sessionKey); lock.unlock()
            return ["state": "alreadyTerminal"]
        }
        try? session.journal.append(["record": "aborted", "reason": String(reason.prefix(48))])
        // Staged bytes stay recoverable until the sweep proves them stale;
        // they were NEVER applied, so the workspace itself is untouched.
        try? session.marker.markTerminal(at: session.paths.ownerMarker)
        lock.lock(); sessions.removeValue(forKey: sessionKey); lock.unlock()
        return ["state": "aborted", "stagedPreserved": true]
    }

    public func statsJSON() -> String {
        lock.lock(); defer { lock.unlock() }
        var object: [String: Any] = ["sessions": sessions.count,
                                     "sweptStagingBytesTotal": sweptStagingBytesTotal]
        for (key, value) in counters.sorted(by: { $0.key < $1.key }) { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Sweep stale TASK-OWNED staging only. Requires a run-proof callback
    /// (Core side): a session's run is provable `terminal` / `active` /
    /// `unknown`. Missing proof = unknown owner = PRESERVE, always. Marker,
    /// journal and terminal index stay for audit; only the payload subtree is
    /// reclaimed.
    public func sweepStaleStaging(nowSeconds: Int64, runProof: @escaping @Sendable (String) -> Int,
                                  graceSeconds: Int64 = Int64(WorkspaceTransferBudgets.defaults.staleSweepGraceSeconds),
                                  maximumReclaimBytes: Int64 = Int64.max) throws -> [String: Any] {
        guard let transferRoot else { throw WorkspaceTransferError.notConfigured }
        let sessionsRoot = transferRoot + "/sessions"
        var cleanedSessions = 0
        var cleanedBytes: Int64 = 0
        var preservedUnknown = 0
        var preservedActive = 0
        let keys = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot)) ?? []
        for key in keys.sorted() {
            guard WorkspaceTransferPaths.isValidSessionKey(key) else { preservedUnknown += 1; continue }
            let paths = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: key)
            guard let marker = WorkspaceOwnerMarker.load(path: paths.ownerMarker),
                  marker.sessionKey == key else {
                preservedUnknown += 1
                continue
            }
            // Never touch a directory tree that contains a LIVE in-memory session.
            if fetch(key) != nil { preservedActive += 1; continue }
            let age = nowSeconds - marker.createdAtSeconds
            let terminalMarker = marker.state == "terminal"
            if !terminalMarker {
                guard age > graceSeconds else { preservedActive += 1; continue }
                // 1 = terminal, 0 = active, -1 = unknown/unprovable.
                switch runProof(marker.runID) {
                case 1: break
                default: preservedActive += 1; continue
                }
            }
            let stagingBytes = directoryBytes(paths.stagingDirectory)
            guard stagingBytes <= maximumReclaimBytes else { preservedActive += 1; continue }
            removeDirectoryTaskOwned(paths.stagingDirectory)
            cleanedSessions += 1
            cleanedBytes += stagingBytes
            lock.lock(); bump("sweptSessions"); sweptStagingBytesTotal += stagingBytes; lock.unlock()
        }
        return ["cleanedSessions": cleanedSessions, "cleanedBytes": cleanedBytes,
                "preservedUnknown": preservedUnknown, "preservedActive": preservedActive]
    }

    private func directoryBytes(_ path: String) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        for case let name as String in enumerator {
            let absolute = path + "/" + name
            if let meta = WorkspaceNoFollow.metadata(absolute), meta.kind == .file {
                total += meta.size
            }
        }
        return total
    }

    /// Removes ONLY our own task-owned directory tree: lstat-guarded, never
    /// following links (FileManager.removeItem unlinks embedded symlinks
    /// without following them; the tree root itself must be a real directory
    /// owned by this process's layout — an unknown entry is preserved).
    private func removeDirectoryTaskOwned(_ path: String) {
        switch WorkspaceNoFollow.kind(path) {
        case .directory:
            try? FileManager.default.removeItem(atPath: path)
        default:
            return
        }
    }

    // MARK: - Internals

    private func recheck(_ session: Session, full: Bool) throws {
        guard let hooks else { throw WorkspaceTransferError.notConfigured }
        guard hooks.revalidateLight(session.binding) else {
            throw WorkspaceTransferError.proofRefused(code: "light")
        }
        if full {
            guard hooks.revalidateRun(session.binding) else {
                throw WorkspaceTransferError.proofRefused(code: "runCurrency")
            }
        }
    }

    private func lightCheck(_ session: Session) -> Bool {
        hooks?.revalidateLight(session.binding) ?? false
    }

    private static func planDigest(of actions: [WorkspacePlannedAction]) -> String {
        let joined = actions.compactMap { action -> String? in
            guard action.effect != nil else { return nil }
            return action.relativePath
        }.joined(separator: "\n")
        return FloeDigest.sha256Hex(Data(joined.utf8))
    }

    private static func newSessionKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Durable terminal index. FILE-sized bound (128 MiB sanity ceiling,
    /// independent of the Binder control cap), tmp + fsync + rename +
    /// directory fsync, then READ-BACK digest verification. Any failure is
    /// returned honestly so the wire receipt becomes `receiptIncomplete`
    /// instead of a false-complete; staging/recovery remain preserved for
    /// reconciliation because the sweep only collects valid-index sessions.
    private static let maximumIndexBytes = 128 * 1_048_576

    private func writeTerminalIndex(session: Session, outcome: [String: Any],
                                    conflictedPaths: [String]) -> (persisted: Bool, digest: String?) {
        var index = outcome
        index["record"] = "terminalIndex"
        index["sessionKey"] = session.paths.sessionKey
        index["projectID"] = session.binding.projectID.uuidString
        index["runID"] = session.binding.runID.uuidString
        index["rootEpoch"] = session.binding.rootEpoch
        index["grantID"] = session.binding.grantID
        index["conflictedPathCount"] = conflictedPaths.count
        guard JSONSerialization.isValidJSONObject(index),
              let data = try? JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]),
              data.count <= Self.maximumIndexBytes else {
            try? session.journal.append(["record": "indexFailed", "reason": "encode"])
            return (false, nil)
        }
        let staged = session.paths.terminalIndex + ".tmp"
        let fd = open(staged, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else {
            try? session.journal.append(["record": "indexFailed", "reason": "open\(errno)"])
            return (false, nil)
        }
        var wrote: WorkspaceTransferError?
        data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    wrote = .ioFailed(stage: "indexWrite", errnoCode: Int32(code))
                    return
                }
                written += count
            }
            if fsync(fd) != 0 {
                wrote = .ioFailed(stage: "indexFsync", errnoCode: Int32(errno))
            }
        }
        close(fd)
        if let wrote {
            unlink(staged)
            try? session.journal.append(["record": "indexFailed", "reason": wrote.wireCode])
            return (false, nil)
        }
        if rename(staged, session.paths.terminalIndex) != 0 {
            let code = errno
            unlink(staged)
            try? session.journal.append(["record": "indexFailed", "reason": "rename\(code)"])
            return (false, nil)
        }
        _ = WorkspaceNoFollow.fsyncDirectory(session.paths.sessionDirectory)
        // Read-back verification: the durable digest the receipt advertises
        // must equal the bytes actually on disk.
        guard let digest = digestOfFile(at: session.paths.terminalIndex) else {
            try? session.journal.append(["record": "indexFailed", "reason": "readback"])
            return (false, nil)
        }
        try? session.journal.append(["record": "indexWritten", "bytes": data.count, "digest": digest])
        return (true, digest)
    }
}
