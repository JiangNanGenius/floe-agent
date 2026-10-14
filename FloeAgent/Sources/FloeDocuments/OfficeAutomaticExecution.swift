// FloeDocuments — service-owned automatic Office copy execution.
//
// Authorized automatic tasks (a runtime-approved `document.office.edit`
// apply call, never a model flag) may propose → apply → reopen-verify without
// a per-edit UI confirmation. This file owns that path with hard boundaries:
//
//   * the ORIGINAL document is never modified: the engine session works on an
//     isolated staging copy and the verified result is committed as a NEW
//     output copy; the original's digest is re-checked before the output is
//     published, and a mismatch aborts without publishing;
//   * the session is SERVICE-OWNED: open (explicit engine session on the
//     working copy) → readiness status → execute → save → release. A session
//     that is not verifiably editable, or a save that does not settle, fails
//     closed. No live-editor session is stolen and no user selection is used:
//     selection-relative commands are refused outright for automatic
//     execution.
//   * the saved copy is REOPENED with the bounded OOXML reader and checked
//     against the command expectations, including persisted formula
//     cached-value/type/error verification for workbooks;
//   * output is committed atomically only after verification, never
//     overwrites an existing different file, and an already-published
//     identical result is reported as a replay rather than recomputed.
//
// The interactive editor path (`grant_id` from the UI) is untouched and still
// commits the user's own document through the live session CAS.

import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

// MARK: - Service-owned engine session boundary

/// Live readiness of one service-owned engine session.
public struct OfficeServiceSessionStatus: Sendable, Equatable {
    public var editable: Bool
    /// Engine-reported reason editing is unavailable, when known.
    public var unavailableReason: String?
    /// True when this fresh session unexpectedly holds unsaved edits.
    public var hasUnsavedChanges: Bool

    public init(editable: Bool, unavailableReason: String? = nil, hasUnsavedChanges: Bool = false) {
        self.editable = editable
        self.unavailableReason = unavailableReason
        self.hasUnsavedChanges = hasUnsavedChanges
    }
}

/// One service-owned engine session over an isolated working copy. The
/// implementation lives in the app (`FloeOfficeNative`); tests provide a fake.
public protocol OfficeServiceEngineSession: AnyObject, Sendable {
    var workingCopyURL: URL { get }
    /// Engine label used in receipts (e.g. "floe-office-native").
    var engineLabel: String { get }
    func status() async throws -> OfficeServiceSessionStatus
    /// Dispatch a validated command batch. Must not save.
    func apply(commands: [OfficeEngineCommand], batchID: String) async throws
    /// Flush the engine's working copy to `workingCopyURL`.
    func save() async throws
    /// Release the session (idempotent). Must not modify the working copy.
    func close() async throws
}

/// Engine-level reopen evidence for the saved copy, when the host can provide
/// it. Absence is reported honestly; it never blocks package-level verification.
public enum OfficeEngineReopenEvidence: Sendable, Equatable {
    case engineOpened
    case unavailable(reason: String)

    public var receiptValue: String {
        switch self {
        case .engineOpened: return "engine-opened"
        case .unavailable(let reason): return "package-only: \(reason)"
        }
    }
}

public protocol OfficeServiceEngineSessionFactory: Sendable {
    func openServiceSession(workingCopyURL: URL,
                            format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession
    func verifyEngineReopen(savedCopyURL: URL,
                            format: OfficeDocumentFormat,
                            access: OfficeCommandAccess) async -> OfficeEngineReopenEvidence
}

public extension OfficeServiceEngineSessionFactory {
    func verifyEngineReopen(savedCopyURL: URL, format: OfficeDocumentFormat,
                            access: OfficeCommandAccess) async -> OfficeEngineReopenEvidence {
        .unavailable(reason: "no engine reopen probe in this host")
    }
}

// MARK: - Authorization proof

/// Where an automatic execution authorization came from. Both cases are
/// Runtime-issued: `.approvedToolCall` is built by `OfficeEditTool.apply`
/// after consuming the authority for the exact `document.office.edit` apply
/// call; `.approvedBackgroundJob` is built by the job preparation path after
/// `BackgroundJobService.submit` consumed the authority for the exact approved
/// `jobs.submit` call that carried this frozen proposal. A model field never
/// produces either case.
public enum OfficeAutomaticAuthorizationOrigin: Sendable, Equatable {
    /// The inline `document.office.edit` apply call consumed its own authority.
    case approvedToolCall
    /// The submitting `jobs.submit` call consumed its authority and prepared
    /// this operation. `submitBinding` is that consumed runtime binding.
    case approvedBackgroundJob(submitBinding: RuntimeAuthorityBinding)
}

/// Proof that the runtime approved this exact operation and the consumer
/// claimed its single-use authority. Built ONLY after
/// `RuntimeAuthorityStore.consume` returned `.valid`; never from model input.
public struct OfficeAutomaticAuthorization: Sendable, Equatable {
    public var runID: UUID
    public var taskID: UUID?
    public var operationID: String
    public var idempotencyKey: String
    public var approvalGrantID: UUID?
    public var binding: RuntimeAuthorityBinding
    public var consumedAt: Date
    public var origin: OfficeAutomaticAuthorizationOrigin

    public init(runID: UUID, taskID: UUID?, operationID: String, idempotencyKey: String,
                approvalGrantID: UUID?, binding: RuntimeAuthorityBinding, consumedAt: Date = Date(),
                origin: OfficeAutomaticAuthorizationOrigin = .approvedToolCall) {
        self.runID = runID
        self.taskID = taskID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.approvalGrantID = approvalGrantID
        self.binding = binding
        self.consumedAt = consumedAt
        self.origin = origin
    }
}

// MARK: - Receipts and errors

public struct OfficeAutomaticReceipt: Codable, Sendable, Equatable {
    public var documentID: String
    public var format: String
    public var baseSHA256: String
    /// The original's digest after the run; equals `baseSHA256` when unchanged.
    public var sourceSHA256: String
    public var sourceUnchanged: Bool
    public var outputRelativePath: String
    public var outputSHA256: String
    public var outputByteCount: Int
    public var commands: [String]
    public var verified: [String]
    /// Bounded formula-check summary for workbooks, when one ran.
    public var formulaSummary: String?
    /// "engine-opened" or "package-only: <reason>".
    public var engineReopen: String
    public var sessionEngine: String
    public var saved: Bool
    public var replay: Bool
    public var runID: String?
    public var taskID: String?
    public var operationID: String?
    public var note: String?

    public init(documentID: String, format: String, baseSHA256: String, sourceSHA256: String,
                sourceUnchanged: Bool, outputRelativePath: String, outputSHA256: String,
                outputByteCount: Int, commands: [String], verified: [String],
                formulaSummary: String? = nil, engineReopen: String, sessionEngine: String,
                saved: Bool, replay: Bool = false, runID: String? = nil, taskID: String? = nil,
                operationID: String? = nil, note: String? = nil) {
        self.documentID = documentID
        self.format = format
        self.baseSHA256 = baseSHA256
        self.sourceSHA256 = sourceSHA256
        self.sourceUnchanged = sourceUnchanged
        self.outputRelativePath = outputRelativePath
        self.outputSHA256 = outputSHA256
        self.outputByteCount = outputByteCount
        self.commands = commands
        self.verified = verified
        self.formulaSummary = formulaSummary
        self.engineReopen = engineReopen
        self.sessionEngine = sessionEngine
        self.saved = saved
        self.replay = replay
        self.runID = runID
        self.taskID = taskID
        self.operationID = operationID
        self.note = note
    }
}

public enum OfficeAutomaticExecutionError: LocalizedError, Equatable, UnsafeResourceStateError {
    /// Shared contract: only the two unsafe lifecycle failures leave native
    /// resources that may still be live and must outrank cancellation. The
    /// whole enum conforms for the reason/description plumbing, so consumers
    /// read `isUnsafeResourceState` (below) — never bare conformance.
    public var unsafeResourceReason: String {
        switch self {
        case .sessionCloseUnacknowledged(let reason):
            return "the engine did not acknowledge its close (\(reason))"
        case .sessionOpenUnsafe(let reason):
            return "opening the engine session left native resources (\(reason))"
        default:
            return errorDescription ?? "\(self)"
        }
    }

    case notFound(String)
    case sourceChanged
    case outputConflict(String)
    case commandFormatMismatch(command: String, format: String)
    case selectionDependent(command: String)
    case sessionUnavailable(String)
    case sessionNotEditable(String)
    case sessionNotReady(String)
    case saveFailed(String)
    case verificationFailed(String)
    /// The engine session did not acknowledge its close (or a resource check
    /// failed), so its native resources may still be live. The working copy is
    /// RETAINED for recovery and no success may be claimed.
    case sessionCloseUnacknowledged(String)
    /// Opening the session failed after native resources were created and
    /// their cleanup could not be acknowledged; the working copy is retained
    /// and no success may be claimed.
    case sessionOpenUnsafe(String)
    case cancelled

    /// True when this failure leaves engine/native resources that may still be
    /// live, so the working copy must not be deleted and shared engine work
    /// must be suspended.
    public var isUnsafeResourceState: Bool {
        switch self {
        case .sessionCloseUnacknowledged, .sessionOpenUnsafe: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Office document does not exist: \(path)"
        case .sourceChanged:
            return "The source document changed after the proposal was approved; automatic execution was refused and no output was written."
        case .outputConflict(let path):
            return "An existing file with different content is already at \(path); automatic execution never overwrites it. Choose a different output name."
        case .commandFormatMismatch(let command, let format):
            return "\(command) is not available for \(format) documents"
        case .selectionDependent(let command):
            return "\(command) acts on the live editor selection and cannot run automatically; use an explicit cell-addressed command or the interactive editor."
        case .sessionUnavailable(let reason):
            return "The service-owned Office engine session is unavailable: \(reason)"
        case .sessionNotEditable(let reason):
            return "The service-owned Office session is not editable: \(reason)"
        case .sessionNotReady(let reason):
            return "The service-owned Office session is not ready: \(reason)"
        case .saveFailed(let reason):
            return "The service-owned Office session could not save the working copy: \(reason)"
        case .verificationFailed(let detail):
            return "The saved copy failed reopened verification: \(detail)"
        case .sessionCloseUnacknowledged(let reason):
            return "The Office engine session did not acknowledge its close (\(reason)); its working copy was retained for recovery and further shared-engine work is suspended until the app restarts."
        case .sessionOpenUnsafe(let reason):
            return "Opening the Office engine session failed after native resources were created (\(reason)); its working copy was retained for recovery and further shared-engine work is suspended until the app restarts."
        case .cancelled:
            return "Automatic Office execution was cancelled; the source document is unchanged and no output was written."
        }
    }
}

// MARK: - Executor

/// Orchestrates one authorized automatic copy execution. All file mutation is
/// confined to the task workspace; the source document is only read.
public actor OfficeAutomaticExecutor {
    private struct ReplayRecord {
        var key: String
        var receipt: OfficeAutomaticReceipt
        var recordedAt: Date
    }

    private let factory: any OfficeServiceEngineSessionFactory
    private let fileManager: FileManager
    private let maximumDocumentBytes = 128 * 1_024 * 1_024
    private let maximumReceiptRecords = 64
    private var receipts: [String: ReplayRecord] = [:]

    public init(factory: any OfficeServiceEngineSessionFactory,
                fileManager: FileManager = .default) {
        self.factory = factory
        self.fileManager = fileManager
    }

    public func execute(
        proposal: OfficeCommandProposal,
        authorization: OfficeAutomaticAuthorization,
        relativeOutput: String?,
        requestID: String,
        access: OfficeCommandAccess,
        verifyFormulas: Bool = true,
        cancellation: CancellationToken? = nil
    ) async throws -> OfficeAutomaticReceipt {
        try throwIfCancelled(cancellation)
        guard let workspacePath = access.workspacePath, !workspacePath.isEmpty else {
            throw OfficeAutomaticExecutionError.sessionUnavailable("no task workspace")
        }
        // The proof must be for this tool's apply operation; a mismatched
        // authorization is refused before any resolution. A prepared job
        // proves the exact approved jobs.submit call instead.
        switch authorization.origin {
        case .approvedToolCall:
            guard authorization.binding.toolName == "document.office.edit",
                  authorization.binding.operation == "apply" else {
                throw OfficeAutomaticExecutionError.sessionUnavailable(
                    "authorization is not bound to document.office.edit apply")
            }
        case .approvedBackgroundJob(let submitBinding):
            guard submitBinding.toolName == "jobs.submit",
                  submitBinding.operation == "job.submit" else {
                throw OfficeAutomaticExecutionError.sessionUnavailable(
                    "the prepared-job authorization is not bound to an approved jobs.submit call")
            }
            guard submitBinding.runID == authorization.runID else {
                throw OfficeAutomaticExecutionError.sessionUnavailable(
                    "the prepared-job authorization belongs to a different run")
            }
            guard authorization.binding == submitBinding else {
                throw OfficeAutomaticExecutionError.sessionUnavailable(
                    "the prepared-job authorization does not carry the consumed submission binding")
            }
        }
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath()
        let documentURL = try resolveDocument(proposal.documentID, root: root)
        guard let format = OfficeDocumentFormat(fileExtension: documentURL.pathExtension) else {
            throw OfficeAutomaticExecutionError.notFound(proposal.documentID)
        }
        let commands = try OfficeCommandCodec.decode(proposal.commandsJSON)
        guard !commands.isEmpty else {
            throw OfficeAutomaticExecutionError.verificationFailed("the proposal contains no commands")
        }
        for command in commands where command.format != format {
            throw OfficeAutomaticExecutionError.commandFormatMismatch(command: command.id,
                                                                      format: format.rawValue)
        }
        // Automatic execution never depends on a user's live selection.
        if let selectionDependent = commands.first(where: \.requiresSelectionFingerprint) {
            throw OfficeAutomaticExecutionError.selectionDependent(command: selectionDependent.id)
        }
        let outputRelative = try outputRelativePath(for: proposal, format: format,
                                                    requested: relativeOutput,
                                                    root: root, documentURL: documentURL)
        let replayKey = [requestID, proposal.id.uuidString, proposal.baseSHA256,
                         canonicalCommands(commands), outputRelative].joined(separator: "|")
        if let replay = receipts[replayKey] {
            var receipt = replay.receipt
            receipt.replay = true
            return receipt
        }
        // CAS: the approved base revision must still be the file on disk.
        let sourceBefore = try FloeDigest.sha256Hex(ofFileAt: documentURL)
        guard sourceBefore.lowercased() == proposal.baseSHA256.lowercased() else {
            throw OfficeAutomaticExecutionError.sourceChanged
        }
        let outputURL = root.appendingPathComponent(outputRelative)
        let outputParent = outputURL.deletingLastPathComponent()
        guard outputParent.standardizedFileURL.path.hasPrefix(root.path + "/")
            || outputParent.standardizedFileURL.path == root.path else {
            throw OfficeAutomaticExecutionError.outputConflict(outputRelative)
        }
        try fileManager.createDirectory(at: outputParent, withIntermediateDirectories: true)

        let stagingRoot = root.appendingPathComponent(".floe-automation", isDirectory: true)
            .appendingPathComponent(proposal.id.uuidString, isDirectory: true)
        let workingURL = stagingRoot.appendingPathComponent("working.\(format.rawValue)")
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw OfficeAutomaticExecutionError.verificationFailed(
                "could not create staging: \(error.localizedDescription)")
        }
        // Staging may only be removed once no engine session can still hold
        // the working copy. An unacknowledged close (or an open that failed
        // after native resources were created) retains it for recovery.
        var stagingSafeToClean = true
        defer { if stagingSafeToClean { cleanupStaging(stagingRoot) } }
        try copyVerified(from: documentURL, to: workingURL)

        var sessionOpen = false
        /// Set when a close attempt was not acknowledged: unsafe state wins
        /// over a plain cancellation so a cancelled run is never reported as
        /// cleanly cancelled while the engine may still hold the working copy.
        var closeFailureReason: String?
        let session: any OfficeServiceEngineSession
        do {
            session = try await factory.openServiceSession(workingCopyURL: workingURL,
                                                           format: format,
                                                           originalURL: documentURL,
                                                           access: access)
            sessionOpen = true
        } catch let error as OfficeAutomaticExecutionError where error.isUnsafeResourceState {
            // Native resources may still be live: retain the working copy.
            stagingSafeToClean = false
            throw error
        } catch {
            throw OfficeAutomaticExecutionError.sessionUnavailable(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        var saved = false
        do {
            try throwIfCancelled(cancellation)
            let status = try await session.status()
            guard status.editable else {
                throw OfficeAutomaticExecutionError.sessionNotEditable(
                    status.unavailableReason ?? "the engine reports the working copy read-only")
            }
            guard !status.hasUnsavedChanges else {
                throw OfficeAutomaticExecutionError.sessionNotReady(
                    "the fresh working copy unexpectedly holds unsaved edits")
            }
            try throwIfCancelled(cancellation)
            do {
                try await session.apply(commands: commands, batchID: proposal.id.uuidString)
            } catch {
                throw OfficeAutomaticExecutionError.sessionNotReady(
                    "command dispatch failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            try throwIfCancelled(cancellation)
            do {
                try await session.save()
            } catch {
                throw OfficeAutomaticExecutionError.saveFailed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            saved = true
            do {
                try await closeSession(session)
                sessionOpen = false
            } catch {
                // The engine may still hold the working copy: retain it and
                // refuse to verify/publish/claim success.
                stagingSafeToClean = false
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                closeFailureReason = reason
                throw OfficeAutomaticExecutionError.sessionCloseUnacknowledged(reason)
            }

            // REOPEN the saved copy and verify the exact promises.
            let after = try OfficeOutputSnapshot.capture(url: workingURL)
            let before = try OfficeOutputSnapshot.capture(url: documentURL)
            var expectations: [OfficeOutputExpectation] = []
            for command in commands {
                expectations.append(contentsOf: OfficeOutputExpectation.forCommand(command, before: before))
            }
            let facts: [String]
            do {
                facts = try OfficeOutputValidator.verify(before: before, after: after,
                                                         expectations: expectations)
            } catch {
                throw OfficeAutomaticExecutionError.verificationFailed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            var formulaSummary: String?
            if verifyFormulas, format == .xlsx {
                let report = OfficeFormulaVerifier.verify(snapshot: after)
                guard report.isClean else {
                    throw OfficeAutomaticExecutionError.verificationFailed(
                        "formula cache check: " + report.failures.prefix(6).joined(separator: "; "))
                }
                formulaSummary = report.summary
            }
            let engineReopen = await factory.verifyEngineReopen(savedCopyURL: workingURL,
                                                                format: format,
                                                                access: access)
            // The source must still be the exact approved revision before any
            // output is published.
            let sourceAfter = try FloeDigest.sha256Hex(ofFileAt: documentURL)
            guard sourceAfter.lowercased() == proposal.baseSHA256.lowercased() else {
                throw OfficeAutomaticExecutionError.sourceChanged
            }
            let savedSHA = after.sha256
            let savedBytes = Int((try? workingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fileManager.fileExists(atPath: outputURL.path) {
                let existing = try? FloeDigest.sha256Hex(ofFileAt: outputURL)
                guard existing?.lowercased() == savedSHA.lowercased() else {
                    throw OfficeAutomaticExecutionError.outputConflict(outputRelative)
                }
                // An identical published result: idempotent completion.
                let receipt = OfficeAutomaticReceipt(
                    documentID: proposal.documentID, format: format.rawValue,
                    baseSHA256: proposal.baseSHA256, sourceSHA256: sourceAfter, sourceUnchanged: true,
                    outputRelativePath: outputRelative, outputSHA256: savedSHA,
                    outputByteCount: savedBytes, commands: commands.map(\.id),
                    verified: facts, formulaSummary: formulaSummary,
                    engineReopen: engineReopen.receiptValue, sessionEngine: session.engineLabel,
                    saved: saved, replay: true, runID: authorization.runID.uuidString,
                    taskID: authorization.taskID?.uuidString,
                    operationID: authorization.operationID,
                    note: "identical verified copy was already published")
                record(receipt, key: replayKey)
                return receipt
            }
            try publish(from: workingURL, to: outputURL, expectedSHA: savedSHA)
            let receipt = OfficeAutomaticReceipt(
                documentID: proposal.documentID, format: format.rawValue,
                baseSHA256: proposal.baseSHA256, sourceSHA256: sourceAfter, sourceUnchanged: true,
                outputRelativePath: outputRelative, outputSHA256: savedSHA,
                outputByteCount: savedBytes, commands: commands.map(\.id),
                verified: facts, formulaSummary: formulaSummary,
                engineReopen: engineReopen.receiptValue, sessionEngine: session.engineLabel,
                saved: saved, runID: authorization.runID.uuidString,
                taskID: authorization.taskID?.uuidString,
                operationID: authorization.operationID,
                note: "Source document unchanged; verified copy written separately.")
            record(receipt, key: replayKey)
            return receipt
        } catch {
            if sessionOpen {
                do {
                    try await closeSession(session)
                } catch {
                    // Unacknowledged close: keep the working copy for recovery.
                    stagingSafeToClean = false
                    closeFailureReason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            if stagingSafeToClean { cleanupStaging(stagingRoot) }
            // An unacknowledged/unsafe close outranks cancellation: the run is
            // NOT a clean cancellation while native workers may still be alive.
            if let closeFailureReason {
                throw OfficeAutomaticExecutionError.sessionCloseUnacknowledged(closeFailureReason)
            }
            if error is CancellationError { throw OfficeAutomaticExecutionError.cancelled }
            if let error = error as? FloeError, case .cancelled = error {
                throw OfficeAutomaticExecutionError.cancelled
            }
            throw error
        }
    }

    /// Receipts for completed automatic executions (debug/UI inspection only).
    public var recordedReceipts: [OfficeAutomaticReceipt] {
        receipts.values.sorted { $0.recordedAt > $1.recordedAt }.map(\.receipt)
    }

    // MARK: - Helpers

    private func throwIfCancelled(_ token: CancellationToken?) throws {
        // Both the operation token and Task cancellation are honored at every
        // safe pre-effect boundary; an unacknowledged close still outranks a
        // cancellation in the outer handler.
        if token?.isCancelled == true || Task.isCancelled {
            throw OfficeAutomaticExecutionError.cancelled
        }
    }

    /// Removes the per-run staging directory and the shared parent when it is
    /// empty (never a forced recursive removal of unrelated entries).
    private func cleanupStaging(_ stagingRoot: URL) {
        try? fileManager.removeItem(at: stagingRoot)
        let parent = stagingRoot.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
            try? fileManager.removeItem(at: parent)
        }
    }

    /// Closes the session and PROPAGATES an unacknowledged close. A close
    /// failure is not a save failure, but the saved bytes have NOT been
    /// verified yet (the reopen/verification step happens after this call):
    /// the caller must retain the working copy and must not publish or claim
    /// success while the engine may still hold it.
    private func closeSession(_ session: any OfficeServiceEngineSession) async throws {
        try await session.close()
    }

    private func record(_ receipt: OfficeAutomaticReceipt, key: String) {
        receipts[key] = ReplayRecord(key: key, receipt: receipt, recordedAt: Date())
        if receipts.count > maximumReceiptRecords {
            let oldest = receipts.values.sorted { $0.recordedAt < $1.recordedAt }
                .prefix(receipts.count - maximumReceiptRecords)
            for entry in oldest { receipts.removeValue(forKey: entry.key) }
        }
    }

    private func canonicalCommands(_ commands: [OfficeEngineCommand]) -> String {
        (try? OfficeCommandCodec.encode(commands)) ?? commands.map(\.id).joined(separator: ",")
    }

    private func resolveDocument(_ documentID: String, root: URL) throws -> URL {
        let guardResolver = WorkspacePathGuard(rootURL: root,
                                               maxReadBytes: maximumDocumentBytes,
                                               maxWriteBytes: maximumDocumentBytes)
        let url: URL
        if documentID.hasPrefix("/") {
            let canonical = URL(fileURLWithPath: documentID).standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/") else {
                throw OfficeAutomaticExecutionError.notFound(documentID)
            }
            url = canonical
        } else {
            url = try guardResolver.resolve(documentID)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw OfficeAutomaticExecutionError.notFound(documentID)
        }
        return url
    }

    private func outputRelativePath(for proposal: OfficeCommandProposal,
                                    format: OfficeDocumentFormat,
                                    requested: String?,
                                    root: URL,
                                    documentURL: URL) throws -> String {
        var relative = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if relative.isEmpty {
            let base = (proposal.documentID as NSString).deletingPathExtension
            relative = "\(base).edited.\(format.rawValue)"
        }
        var url: URL
        if relative.hasPrefix("/") {
            url = URL(fileURLWithPath: relative)
        } else {
            url = root.appendingPathComponent(relative)
        }
        url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.path != root.path else {
            throw OfficeAutomaticExecutionError.outputConflict(relative)
        }
        guard url.standardizedFileURL != documentURL.standardizedFileURL else {
            throw OfficeAutomaticExecutionError.outputConflict(relative)
        }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    private func copyVerified(from source: URL, to destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw OfficeAutomaticExecutionError.verificationFailed(
                "could not stage the working copy: \(error.localizedDescription)")
        }
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let copySHA = try FloeDigest.sha256Hex(ofFileAt: destination)
        guard sourceSHA == copySHA else {
            throw OfficeAutomaticExecutionError.verificationFailed(
                "the staged working copy does not match the source")
        }
    }

    private func publish(from working: URL, to output: URL, expectedSHA: String) throws {
        let parent = output.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".floe-automatic-\(UUID().uuidString).\(output.pathExtension)")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: working, to: staged)
        let stagedSHA = try FloeDigest.sha256Hex(ofFileAt: staged)
        guard stagedSHA.lowercased() == expectedSHA.lowercased() else {
            throw OfficeAutomaticExecutionError.verificationFailed(
                "the staged output digest does not match the verified saved copy")
        }
        if fileManager.fileExists(atPath: output.path) {
            // Checked by the caller; without an approval only an identical
            // result is acceptable, which the caller handled already.
            throw OfficeAutomaticExecutionError.outputConflict(output.lastPathComponent)
        }
        try fileManager.moveItem(at: staged, to: output)
        let finalSHA = try FloeDigest.sha256Hex(ofFileAt: output)
        guard finalSHA.lowercased() == expectedSHA.lowercased() else {
            try? fileManager.removeItem(at: output)
            throw OfficeAutomaticExecutionError.verificationFailed(
                "the published output digest does not match the verified saved copy")
        }
    }
}
