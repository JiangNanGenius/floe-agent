// FloeExecution — direct disposal of verified obsolete RISC-V runtime content.
//
// The user instruction that supersedes earlier preservation for this
// architecture is explicit: no store build shipped RISC-V guest content, so
// the old writable test disks, their deltas and their rollback evidence may
// be deleted DIRECTLY. No archive, copy, restore entry, chunk store or
// full-disk digest is produced for that retired architecture.
//
// What this subsystem therefore does:
//   * reads only bounded sidecars and lstat metadata (runtime.json,
//     environments/<id>/metadata.json, the three delta file names);
//   * requires BOTH the working-directory provenance and the environment
//     sidecar/registry row to identify the SAME authoritative obsolete
//     RISC-V image id;
//   * isolates live ownership: no live/held lease, no active pool slot, no
//     queued/running start and no active/deleting environment state;
//   * stages the owned directory (or the fixed delta files) by atomic rename
//     into `recovery/obsolete-riscv-staging/<recordID>/` — outside the
//     original namespace — then actually unlinks it;
//   * checkpoints every phase in a small durable record under
//     `recovery/obsolete-riscv-records/`, so an interruption resumes the
//     exact remaining phase and an already-finished candidate is not
//     re-read or re-deleted;
//   * resolves a repair hold only when the VALID hold names exactly the
//     preserved path being removed. A corrupt marker is never removed.
//
// What it deliberately does NOT do:
//   * it never traverses workspaces, host projects, environment `data/`
//     directories, images/templates or ARM64 environment runtime state;
//   * it never deletes a non-RISC-V or unknown-origin disk/delta. Those
//     candidates answer `preservationRequired`/`blocked` and remain for the
//     existing restore/migration flows. General ARM64 upgrades must continue
//     to preserve and migrate real user data.
//
// Integration contract (the public methods on RuntimeV2Store):
//   scanObsoleteRISCVRuntime(limits:)
//   disposeObsoleteRISCVRuntime(candidateID:limits:)
//   disposeEligibleObsoleteRISCVRuntime(limits:)
//   resumeObsoleteRISCVRuntimeDisposals(limits:)
//   obsoleteRISCVRuntimeDisposalRecords(limit:)
//
// Candidate ids are stable printable strings:
//   disk:<layout-relative preserved directory>
//   delta:<environmentID>
//   discarded:<layout-relative discarded-evidence directory>
//
// All public methods are metadata/ownership gated. No model-supplied root is
// accepted: the root is the RuntimeV2Store's actual sandbox layout root.

import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The authoritative set of retired RISC-V guest image ids. A disk or delta
/// whose recorded base is not in this catalog (or does not carry the official
/// RISC-V image prefix) is never deleted by the direct-disposal path.
public enum RuntimeV2ObsoleteRISCVCatalog: Sendable {
    public static let officialImagePrefix = "floe-debian13-riscv64-"

    public static let knownImageIDs: Set<String> = [
        "floe-debian13-riscv64-202609202607",
        "floe-debian13-riscv64-20260921.1",
        "floe-debian13-riscv64-20260922.1",
        "floe-debian13-riscv64-20260922.2",
        "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b35928017233",
        "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1",
        "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b37171053949-1",
        "floe-debian13-riscv64-basic-runner210-20261102-r36882693"
    ]

    public static func isObsoleteImageID(_ imageID: String) -> Bool {
        if knownImageIDs.contains(imageID) { return true }
        return imageID.lowercased().hasPrefix(officialImagePrefix)
    }
}

public struct RuntimeV2RecoveredDiskRetirement: Sendable {
    // MARK: public limits

    public struct Limits: Sendable, Equatable {
        /// Maximum candidates examined/appended per scan or disposed per batch.
        public var maximumCandidates: Int
        /// Maximum directory entries visited per scan.
        public var maximumDirectoryEntries: Int
        /// Maximum bytes read from a single metadata sidecar.
        public var maximumMetadataBytes: Int
        /// Wall-clock budget for one scan/batch/resume call.
        public var maximumDuration: TimeInterval
        /// Whether recovered/discarded evidence directories are included.
        public var includeDiscardedEvidence: Bool

        public init(
            maximumCandidates: Int = 64,
            maximumDirectoryEntries: Int = 1024,
            maximumMetadataBytes: Int = 65_536,
            maximumDuration: TimeInterval = 30,
            includeDiscardedEvidence: Bool = true
        ) {
            self.maximumCandidates = max(1, min(maximumCandidates, 256))
            self.maximumDirectoryEntries = max(1, min(maximumDirectoryEntries, 4096))
            self.maximumMetadataBytes = max(1_024, min(maximumMetadataBytes, 1_048_576))
            self.maximumDuration = maximumDuration.isFinite
                ? max(0.1, min(maximumDuration, 300)) : 30
            self.includeDiscardedEvidence = includeDiscardedEvidence
        }
    }

    // MARK: public result types

    public enum CandidateKind: String, Codable, Sendable, Equatable {
        case workingDisk
        case environmentDelta
        case discardedEvidence
    }

    public enum CandidateState: String, Codable, Sendable, Equatable {
        /// Verified obsolete RISC-V content that may be disposed now.
        case eligible
        /// A durable record exists and an interrupted mutation must resume.
        case inProgress
        /// No bytes remain for this candidate/record.
        case alreadyDisposed
        /// Ownership/activity/format is uncertain: nothing was touched.
        case blocked
        /// Non-RISC-V (for example ARM64) or otherwise not authorized for
        /// direct disposal. The existing preserve/migrate/restore flow owns it.
        case preservationRequired
    }

    public enum DisposalOutcome: String, Sendable, Equatable {
        case disposed
        case alreadyDisposed
        case interrupted
        case blocked
        case preservationRequired
    }

    public struct SourceIdentity: Codable, Sendable, Equatable {
        public var device: UInt64
        public var inode: UInt64
        public var logicalBytes: Int64
        public var allocatedBytes: Int64?
        public var linkCount: UInt64
        public var mode: UInt32
        public var modificationSeconds: Int64
        public var modificationNanoseconds: Int64
        public var changeSeconds: Int64
        public var changeNanoseconds: Int64

        public init(
            device: UInt64, inode: UInt64, logicalBytes: Int64,
            allocatedBytes: Int64?, linkCount: UInt64, mode: UInt32,
            modificationSeconds: Int64, modificationNanoseconds: Int64,
            changeSeconds: Int64, changeNanoseconds: Int64
        ) {
            self.device = device
            self.inode = inode
            self.logicalBytes = logicalBytes
            self.allocatedBytes = allocatedBytes
            self.linkCount = linkCount
            self.mode = mode
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
            self.changeSeconds = changeSeconds
            self.changeNanoseconds = changeNanoseconds
        }

        var key: String {
            "\(device):\(inode):\(logicalBytes):\(modificationSeconds):\(modificationNanoseconds):\(changeSeconds):\(changeNanoseconds)"
        }

        var isRegularFile: Bool {
            #if canImport(Darwin) || canImport(Glibc)
            return mode & UInt32(S_IFMT) == UInt32(S_IFREG)
            #else
            return false
            #endif
        }

        var isDirectory: Bool {
            #if canImport(Darwin) || canImport(Glibc)
            return mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
            #else
            return false
            #endif
        }
    }

    public struct Candidate: Codable, Sendable, Equatable {
        public var id: String
        public var kind: CandidateKind
        public var state: CandidateState
        public var environmentID: String?
        public var runtimeID: String?
        public var relativePath: String?
        public var allocatedBytes: Int64?
        public var reasonCode: String?
        public var recordID: String?

        public init(
            id: String, kind: CandidateKind, state: CandidateState,
            environmentID: String? = nil, runtimeID: String? = nil,
            relativePath: String? = nil, allocatedBytes: Int64? = nil,
            reasonCode: String? = nil, recordID: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.state = state
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.relativePath = relativePath
            self.allocatedBytes = allocatedBytes
            self.reasonCode = reasonCode
            self.recordID = recordID
        }
    }

    public struct ScanReport: Sendable, Equatable {
        public var candidates: [Candidate] = []
        public var examinedEntries = 0
        public var alreadyDisposedCount = 0
        public var skippedNonObsoleteCount = 0
        public var eligibleCount = 0
        public var blockedCount = 0
        public var preservationRequiredCount = 0
        public var inProgressCount = 0
        public var truncated = false
        public var notes: [String] = []
    }

    public struct DisposalResult: Sendable, Equatable {
        public var candidateID: String
        public var outcome: DisposalOutcome
        public var environmentID: String?
        public var runtimeID: String?
        public var removedLogicalBytes: Int64
        public var removedAllocatedBytes: Int64?
        public var recordID: String?
        public var reasonCode: String?

        public init(
            candidateID: String, outcome: DisposalOutcome,
            environmentID: String? = nil, runtimeID: String? = nil,
            removedLogicalBytes: Int64 = 0, removedAllocatedBytes: Int64? = nil,
            recordID: String? = nil, reasonCode: String? = nil
        ) {
            self.candidateID = candidateID
            self.outcome = outcome
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.removedLogicalBytes = removedLogicalBytes
            self.removedAllocatedBytes = removedAllocatedBytes
            self.recordID = recordID
            self.reasonCode = reasonCode
        }
    }

    public struct BatchReport: Sendable, Equatable {
        public var results: [DisposalResult] = []
        public var scannedCandidates = 0
        public var eligibleCandidates = 0
        public var disposedCount = 0
        public var skippedCount = 0
        /// RISC-V/unknown-ownership candidates that remain unretired because
        /// ownership, activity or evidence checks blocked them. This is the
        /// count the caller must treat as "old working disks may still need
        /// factory metadata".
        public var blockedCount = 0
        /// Non-RISC-V (ARM64) preserved candidates. Reported independently and
        /// deliberately excluded from the RISC-V blocker/completeness signal.
        public var preservationRequiredCount = 0
        /// Interrupted records that still remain after this call.
        public var inProgressCount = 0
        /// Candidates whose disposal was interrupted in this call and still
        /// need a resume pass.
        public var interruptedCount = 0
        public var alreadyDisposedCount = 0
        public var skippedNonObsoleteCount = 0
        public var scanTruncated = false
        public var scanNotes: [String] = []
        public var limitsReached = false
        /// True only when the scan and every eligible disposal were truthful
        /// AND no RISC-V/unknown candidate remains blocked, in progress or
        /// interrupted. ARM64 `preservationRequired` does not clear or set it.
        public var isComplete = true
        public var notes: [String] = []

        /// The App's retry rule: only let a truncated scan continue when this
        /// tap actually retired something. A wholly blocked truncated result
        /// must stop instead of spinning on the same blocked head forever.
        public var shouldContinue: Bool {
            scanTruncated && disposedCount > 0 && !notes.contains("cancelled")
        }
    }

    /// Durable phase record. The tiny JSON file is the checkpoint AND the
    /// audit record: no disk bytes or full-disk digest are ever stored.
    public struct DisposalRecord: Codable, Sendable, Equatable {
        public enum Phase: String, Codable, Sendable, Equatable {
            case discovered
            case staged
            case deleted
            case resolved
            case done
        }

        public var version: Int
        public var recordID: String
        public var candidateID: String
        public var kind: CandidateKind
        public var environmentID: String
        public var runtimeID: String?
        public var relativePath: String?
        public var sourceIdentity: SourceIdentity?
        public var sourceDirectoryIdentity: SourceIdentity?
        public var deltaFiles: [String: SourceIdentity]?
        public var stagedRelativePath: String
        public var phase: Phase
        public var imageID: String
        public var removedLogicalBytes: Int64
        public var removedAllocatedBytes: Int64?
        public var resolutionNote: String?
        public var createdAt: Date
        public var updatedAt: Date

        public static let currentVersion = 1
    }

    /// Deterministic fault seams for interruption/restart tests. Production
    /// uses `.production` (all nil).
    public struct Seams: Sendable {
        public var afterStage: (@Sendable (String) throws -> Void)?
        public var afterDelete: (@Sendable (String) throws -> Void)?
        public var afterDeltaHeaderStage: (@Sendable (String) throws -> Void)?
        public var beforeResolution: (@Sendable (String) throws -> Void)?
        public var afterResolution: (@Sendable (String) throws -> Void)?

        public init(
            afterStage: (@Sendable (String) throws -> Void)? = nil,
            afterDelete: (@Sendable (String) throws -> Void)? = nil,
            afterDeltaHeaderStage: (@Sendable (String) throws -> Void)? = nil,
            beforeResolution: (@Sendable (String) throws -> Void)? = nil,
            afterResolution: (@Sendable (String) throws -> Void)? = nil
        ) {
            self.afterStage = afterStage
            self.afterDelete = afterDelete
            self.afterDeltaHeaderStage = afterDeltaHeaderStage
            self.beforeResolution = beforeResolution
            self.afterResolution = afterResolution
        }

        public static let production = Seams()
    }

    // MARK: storage

    public let store: RuntimeV2Store
    private let seams: Seams
    private var fileManager: FileManager { .default }

    // A historical environment row can still say "active" after an iPad
    // transfer even though no guest process, lease, queue entry or pool slot
    // exists. "active" alone is therefore NOT current ownership; the live
    // lease/held-row/queue/slot checks below are authoritative. States that
    // name an in-flight transition remain blockers.
    private static let activeEnvironmentStates: Set<String> = [
        "starting", "preparing", "running", "deleting"
    ]
    private static let allowedDiskEntryNames: Set<String> = ["disk.img", "runtime.json"]
    private static let recordsDirectoryName = "obsolete-riscv-records"
    private static let stagingDirectoryName = "obsolete-riscv-staging"
    private static let lockFileName = "obsolete-riscv.lock"

    public init(store: RuntimeV2Store, seams: Seams = .production) {
        self.store = store
        self.seams = seams
    }

    private var recordsDirectory: URL {
        store.layout.recoveryDirectory.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    private var stagingRoot: URL {
        store.layout.recoveryDirectory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    // MARK: public entry points

    /// Fast metadata-only scan. No disk/delta byte is opened or hashed.
    public func scan(limits: Limits = .init()) async -> ScanReport {
        var report = ScanReport()
        do {
            try await store.registry.open()
        } catch {
            report.notes.append("registryUnavailable")
            return report
        }
        let loadedRecords = loadRecordsWithDiagnostics(limit: limits.maximumDirectoryEntries)
        let records = loadedRecords.records
        report.notes.append(contentsOf: loadedRecords.notes)
        report.truncated = report.truncated || loadedRecords.truncated
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumDuration

        func budgetExpired() -> Bool {
            ProcessInfo.processInfo.systemUptime >= deadline
        }

        func apply(_ item: ScannedItem, to report: inout ScanReport) -> Bool {
            switch item {
            case .candidate(let candidate):
                report.candidates.append(candidate)
                if candidate.state == .eligible || candidate.state == .inProgress {
                    report.eligibleCount += 1
                }
                if candidate.state == .blocked { report.blockedCount += 1 }
                if candidate.state == .preservationRequired { report.preservationRequiredCount += 1 }
                if candidate.state == .inProgress { report.inProgressCount += 1 }
                return true
            case .alreadyDisposed:
                report.alreadyDisposedCount += 1
                return true
            case .skippedNonObsolete:
                report.skippedNonObsoleteCount += 1
                return true
            case .ignored:
                return true
            case .budgetReached(let note):
                report.truncated = true
                report.notes.append(note)
                return false
            }
        }

        // Recovered quarantine evidence.
        if let entries = listDirectory(
            store.layout.quarantineDirectory, label: "quarantineDirectory",
            missingIsEmpty: false, report: &report
        ) {
            for entry in entries.sorted() where entry.hasPrefix("runtime-vm-") {
                guard report.examinedEntries < limits.maximumDirectoryEntries else {
                    report.truncated = true; break
                }
                report.examinedEntries += 1
                if Task.isCancelled { report.truncated = true; report.notes.append("cancelled"); break }
                if budgetExpired() { report.truncated = true; report.notes.append("timeBudget"); break }
                let relative = "recovery/quarantine/\(entry)"
                let item = await scanDisk(relative: relative, kind: .workingDisk, records: records)
                guard apply(item, to: &report) else { break }
            }
        }

        // In-place preserved runtime/vm evidence.
        if let entries = listDirectory(
            store.layout.runtimeVMDirectory, label: "runtimeDirectory",
            missingIsEmpty: false, report: &report
        ) {
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                guard report.examinedEntries < limits.maximumDirectoryEntries else {
                    report.truncated = true; break
                }
                report.examinedEntries += 1
                if Task.isCancelled { report.truncated = true; report.notes.append("cancelled"); break }
                if budgetExpired() { report.truncated = true; report.notes.append("timeBudget"); break }
                guard (try? RuntimeV2Identifier.validate(entry, kind: .runtime)) != nil else { continue }
                let relative = "runtime/vm/\(entry)"
                let item = await scanDisk(relative: relative, kind: .workingDisk, records: records)
                guard apply(item, to: &report) else { break }
            }
        }

        // Environment deltas, metadata only. Never the environment data dir.
        if let entries = listDirectory(
            store.layout.environmentsDirectory, label: "environmentsDirectory",
            missingIsEmpty: false, report: &report
        ) {
            for entry in entries.sorted() {
                guard report.examinedEntries < limits.maximumDirectoryEntries else {
                    report.truncated = true; break
                }
                guard (try? RuntimeV2Identifier.validate(entry, kind: .environment)) != nil else { continue }
                let observation = await store.deltas.observeObsoleteDisposal(environmentID: entry)
                guard !observation.files.isEmpty else { continue }
                report.examinedEntries += 1
                if Task.isCancelled { report.truncated = true; report.notes.append("cancelled"); break }
                if budgetExpired() { report.truncated = true; report.notes.append("timeBudget"); break }
                let item = await scanDelta(environmentID: entry, observation: observation, records: records)
                guard apply(item, to: &report) else { break }
            }
        }

        // Discarded rollback evidence produced by earlier explicit discards.
        if limits.includeDiscardedEvidence {
            let discarded = store.layout.recoveryMigrationsDirectory
                .appendingPathComponent("discarded", isDirectory: true)
            if let entries = listDirectory(
                discarded, label: "discardedDirectory",
                missingIsEmpty: true, report: &report
            ) {
                for entry in entries.sorted() where entry.hasPrefix("runtime-vm-") {
                    guard report.examinedEntries < limits.maximumDirectoryEntries else {
                        report.truncated = true; break
                    }
                    report.examinedEntries += 1
                    if Task.isCancelled { report.truncated = true; report.notes.append("cancelled"); break }
                    if budgetExpired() { report.truncated = true; report.notes.append("timeBudget"); break }
                    let relative = "recovery/migrations/discarded/\(entry)"
                    let item = await scanDisk(relative: relative, kind: .discardedEvidence, records: records)
                    guard apply(item, to: &report) else { break }
                }
            }
        }

        // Actionable work first, then blocked/preserved observations. The
        // returned list is bounded, but the counts above describe every
        // discovered candidate so a truncated scan can still make a truthful
        // "old RISC-V disks remain" statement. A caller that passes a smaller
        // limit still reaches new eligible candidates on each tap because
        // eligible/in-progress items sort ahead of every blocked item.
        let priority: [CandidateState: Int] = [
            .eligible: 0, .inProgress: 1, .blocked: 2, .preservationRequired: 3
        ]
        let ordered = report.candidates.sorted {
            let left = priority[$0.state] ?? 4
            let right = priority[$1.state] ?? 4
            if left != right { return left < right }
            return $0.id < $1.id
        }
        if ordered.count > limits.maximumCandidates {
            report.candidates = Array(ordered.prefix(limits.maximumCandidates))
            report.truncated = true
            report.notes.append("candidateBudget")
        } else {
            report.candidates = ordered
        }
        return report
    }

    /// Dispose exactly one scanned candidate. The fresh metadata/lease checks
    /// run again inside the disposal lock; a stale scan result cannot delete.
    public func dispose(candidateID: String, limits: Limits = .init()) async -> DisposalResult {
        let key: CandidateKey
        do {
            key = try CandidateKey.parse(candidateID)
        } catch {
            return DisposalResult(
                candidateID: candidateID, outcome: .blocked,
                reasonCode: "invalidCandidateID"
            )
        }
        if Task.isCancelled {
            return DisposalResult(candidateID: candidateID, outcome: .interrupted, reasonCode: "cancelled")
        }
        let loaded = loadRecordsWithDiagnostics(limit: 512)
        if !loaded.notes.isEmpty {
            return DisposalResult(
                candidateID: candidateID, outcome: .blocked,
                reasonCode: "recordIndexUnavailable"
            )
        }
        do {
            return try await withDisposalLock {
                try await performDisposal(key: key, limits: limits)
            }
        } catch DisposalLockError.busy {
            return DisposalResult(candidateID: candidateID, outcome: .blocked, reasonCode: "disposalBusy")
        } catch {
            return DisposalResult(candidateID: candidateID, outcome: .blocked, reasonCode: "ioError")
        }
    }

    /// Scan and dispose the currently eligible candidates within bounds.
    /// The returned counts are deliberately truthful: a blocked or
    /// in-progress old working disk makes `isComplete` false, so a caller
    /// must not retire factory metadata it may still need. ARM64 preserved
    /// content is reported separately and never counts as a RISC-V blocker.
    public func disposeEligible(limits: Limits = .init()) async -> BatchReport {
        var batch = BatchReport()
        let report = await scan(limits: limits)
        batch.scannedCandidates = report.candidates.count
        batch.eligibleCandidates = report.eligibleCount
        batch.alreadyDisposedCount = report.alreadyDisposedCount
        batch.skippedNonObsoleteCount = report.skippedNonObsoleteCount
        batch.blockedCount = report.blockedCount
        batch.preservationRequiredCount = report.preservationRequiredCount
        batch.scanTruncated = report.truncated
        batch.scanNotes = report.notes
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumDuration
        var unresolvedInProgress = report.inProgressCount
        var index = 0

        while index < report.candidates.count {
            let candidate = report.candidates[index]
            index += 1
            if Task.isCancelled {
                batch.notes.append("cancelled")
                break
            }
            guard candidate.state == .eligible || candidate.state == .inProgress else {
                // Scan counts already include every blocked/preserved entry,
                // including those beyond a truncated candidate list.
                batch.skippedCount += 1
                continue
            }
            guard batch.results.count < limits.maximumCandidates else {
                batch.limitsReached = true
                break
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                batch.limitsReached = true
                batch.notes.append("timeBudget")
                break
            }
            // No allocated-byte admission cap: a direct unlink is O(1) in the
            // file's logical/allocated size, and a fixed byte budget would
            // permanently strand an indivisible large disk behind it.
            let result = await dispose(candidateID: candidate.id, limits: limits)
            batch.results.append(result)
            switch result.outcome {
            case .disposed:
                batch.disposedCount += 1
                if candidate.state == .inProgress {
                    unresolvedInProgress = max(0, unresolvedInProgress - 1)
                }
            case .alreadyDisposed:
                batch.alreadyDisposedCount += 1
                if candidate.state == .inProgress {
                    unresolvedInProgress = max(0, unresolvedInProgress - 1)
                }
            case .preservationRequired:
                if candidate.state == .eligible || candidate.state == .inProgress {
                    batch.preservationRequiredCount += 1
                }
            case .blocked:
                if candidate.state == .eligible || candidate.state == .inProgress {
                    batch.blockedCount += 1
                }
            case .interrupted:
                batch.interruptedCount += 1
            }
            if result.outcome == .blocked && result.reasonCode == "disposalBusy" {
                batch.limitsReached = true
                break
            }
        }

        // Remaining candidates that were not attempted still determine
        // truthfulness.
        while index < report.candidates.count {
            batch.skippedCount += 1
            index += 1
        }
        batch.inProgressCount = unresolvedInProgress
        batch.isComplete = batch.scanNotes.isEmpty && !batch.scanTruncated
            && batch.blockedCount == 0 && batch.inProgressCount == 0
            && batch.interruptedCount == 0 && !batch.limitsReached
            && !batch.notes.contains("cancelled") && !batch.notes.contains("timeBudget")
        return batch
    }

    /// Complete any durable record that is not in its terminal phase. This is
    /// the interruption/restart entry point; it never discovers new work.
    public func resumeInterrupted(limits: Limits = .init()) async -> BatchReport {
        var batch = BatchReport()
        let loaded = loadRecordsWithDiagnostics(limit: limits.maximumDirectoryEntries)
        batch.scanNotes = loaded.notes
        batch.scanTruncated = loaded.truncated
        let pending = loaded.records.filter { $0.phase != .done }
        batch.scannedCandidates = pending.count
        batch.eligibleCandidates = pending.count
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumDuration
        var processed = 0
        for record in pending {
            if Task.isCancelled {
                batch.notes.append("cancelled")
                break
            }
            guard batch.results.count < limits.maximumCandidates else {
                batch.limitsReached = true
                break
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                batch.limitsReached = true
                batch.notes.append("timeBudget")
                break
            }
            processed += 1
            do {
                let result = try await withDisposalLock {
                    try await resume(record: record, limits: limits)
                }
                batch.results.append(result)
                switch result.outcome {
                case .disposed, .alreadyDisposed:
                    batch.disposedCount += 1
                case .preservationRequired:
                    batch.preservationRequiredCount += 1
                case .blocked:
                    batch.blockedCount += 1
                case .interrupted:
                    batch.interruptedCount += 1
                }
            } catch DisposalLockError.busy {
                batch.results.append(DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "disposalBusy"
                ))
                batch.blockedCount += 1
            } catch {
                batch.results.append(DisposalResult(
                    candidateID: record.candidateID, outcome: .interrupted,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "ioError"
                ))
                batch.interruptedCount += 1
            }
        }
        batch.inProgressCount = max(0, pending.count - processed)
        batch.isComplete = batch.scanNotes.isEmpty && !batch.scanTruncated
            && batch.blockedCount == 0 && batch.inProgressCount == 0
            && batch.interruptedCount == 0 && !batch.limitsReached
            && !batch.notes.contains("cancelled") && !batch.notes.contains("timeBudget")
        return batch
    }

    /// Bounded record listing for maintenance/status surfaces. Records contain
    /// ids and metadata only, never disk bytes or a full-disk digest.
    public func records(limit: Int = 128) -> [DisposalRecord] {
        loadRecords(limit: max(1, min(limit, 512)))
    }

    // MARK: scan helpers

    private enum ScannedItem {
        case candidate(Candidate)
        case alreadyDisposed
        case skippedNonObsolete
        case ignored
        case budgetReached(String)
    }

    private func scanDisk(
        relative: String, kind: CandidateKind, records: [DisposalRecord]
    ) async -> ScannedItem {
        guard let runtimeID = Self.runtimeID(relative: relative, kind: kind),
              let directoryURL = try? Self.directoryURL(relative: relative, layout: store.layout),
              let directoryIdentity = Self.identity(at: directoryURL) else {
            return .ignored
        }
        let key = kind == .discardedEvidence
            ? CandidateKey.discarded(relative: relative)
            : CandidateKey.disk(relative: relative)
        guard directoryIdentity.isDirectory else {
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .blocked,
                runtimeID: runtimeID, relativePath: relative,
                reasonCode: "unsupportedEvidence"
            ))
        }
        let diskURL = directoryURL.appendingPathComponent("disk.img")
        guard let diskIdentity = Self.identity(at: diskURL) else {
            if let record = records.first(where: { $0.candidateID == key.id && $0.phase == .done }) {
                _ = record
                return .alreadyDisposed
            }
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .blocked,
                runtimeID: runtimeID, relativePath: relative,
                reasonCode: "diskMissing"
            ))
        }
        guard diskIdentity.isRegularFile, diskIdentity.linkCount == 1,
              diskIdentity.logicalBytes > 0 else {
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .blocked,
                runtimeID: runtimeID, relativePath: relative,
                allocatedBytes: diskIdentity.allocatedBytes,
                reasonCode: diskIdentity.isRegularFile ? "linkedDisk" : "unsupportedEvidence"
            ))
        }
        let recordID = Self.recordID(candidateID: key.id, identityKey: diskIdentity.key)
        let existing = records.first { $0.recordID == recordID }
        let inspection = await inspectDisk(
            key: key, kind: kind, runtimeID: runtimeID,
            directoryURL: directoryURL, directoryIdentity: directoryIdentity,
            diskIdentity: diskIdentity, existingRecord: existing
        )
        return candidate(from: inspection, key: key, kind: kind, relative: relative)
    }

    private func scanDelta(
        environmentID: String,
        observation: RuntimeV2DeltaStore.ObsoleteDisposalObservation,
        records: [DisposalRecord]
    ) async -> ScannedItem {
        let key = CandidateKey.delta(environmentID: environmentID)
        let identityKey = Self.deltaIdentityKey(observation.files)
        let recordID = Self.recordID(candidateID: key.id, identityKey: identityKey)
        let existing = records.first { $0.recordID == recordID }
        let inspection = await inspectDelta(
            environmentID: environmentID, observation: observation, existingRecord: existing
        )
        switch inspection {
        case .eligible(let context):
            return .candidate(Candidate(
                id: key.id, kind: .environmentDelta, state: .eligible,
                environmentID: environmentID,
                allocatedBytes: context.allocatedBytes,
                recordID: existing?.recordID
            ))
        case .inProgress(let record):
            return .candidate(Candidate(
                id: key.id, kind: .environmentDelta, state: .inProgress,
                environmentID: environmentID,
                allocatedBytes: record.removedAllocatedBytes,
                reasonCode: nil, recordID: record.recordID
            ))
        case .alreadyDisposed:
            return .alreadyDisposed
        case .skippedNonObsolete:
            return .skippedNonObsolete
        case .blocked(let reason, let environmentID):
            return .candidate(Candidate(
                id: key.id, kind: .environmentDelta, state: .blocked,
                environmentID: environmentID, reasonCode: reason
            ))
        case .preservationRequired:
            // Environment deltas are internal runtime state. A non-RISC-V
            // delta is simply not part of this scan: it is preserved by the
            // existing ARM64 migration/upgrade path and never surfaced as a
            // disposal candidate.
            return .skippedNonObsolete
        }
    }

    private func candidate(
        from inspection: DiskInspection, key: CandidateKey,
        kind: CandidateKind, relative: String
    ) -> ScannedItem {
        switch inspection {
        case .eligible(let context):
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .eligible,
                environmentID: context.environmentID,
                runtimeID: context.runtimeID,
                relativePath: relative,
                allocatedBytes: context.diskIdentity.allocatedBytes,
                recordID: context.existingRecord?.recordID
            ))
        case .inProgress(let record):
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .inProgress,
                environmentID: record.environmentID,
                runtimeID: record.runtimeID,
                relativePath: relative,
                allocatedBytes: record.removedAllocatedBytes,
                recordID: record.recordID
            ))
        case .alreadyDisposed:
            return .alreadyDisposed
        case .blocked(let reason, let environmentID, let runtimeID):
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .blocked,
                environmentID: environmentID, runtimeID: runtimeID,
                relativePath: relative, reasonCode: reason
            ))
        case .preservationRequired(let reason, let environmentID, let runtimeID):
            return .candidate(Candidate(
                id: key.id, kind: kind, state: .preservationRequired,
                environmentID: environmentID, runtimeID: runtimeID,
                relativePath: relative, reasonCode: reason
            ))
        }
    }

    // MARK: inspection

    private struct HoldEvidence {
        var hold: RuntimeV2RepairHoldStore.Hold?
        var corruptMarker: Bool
    }

    private struct DiskContext {
        var key: CandidateKey
        var kind: CandidateKind
        var environmentID: String
        var runtimeID: String
        var relativePath: String
        var directoryURL: URL
        var directoryIdentity: SourceIdentity
        var diskIdentity: SourceIdentity
        var imageID: String
        var existingRecord: DisposalRecord?
    }

    private enum DiskInspection {
        case eligible(DiskContext)
        case inProgress(DisposalRecord)
        case alreadyDisposed
        case blocked(String, String?, String?)
        case preservationRequired(String, String?, String?)
    }

    private struct DeltaContext {
        var environmentID: String
        var observation: RuntimeV2DeltaStore.ObsoleteDisposalObservation
        var imageID: String
        var allocatedBytes: Int64?
        var existingRecord: DisposalRecord?
    }

    private enum DeltaInspection {
        case eligible(DeltaContext)
        case inProgress(DisposalRecord)
        case alreadyDisposed
        case skippedNonObsolete
        case blocked(String, String?)
        case preservationRequired(String, String?)
    }

    private func inspectDisk(
        key: CandidateKey, kind: CandidateKind, runtimeID: String,
        directoryURL: URL, directoryIdentity: SourceIdentity,
        diskIdentity: SourceIdentity, existingRecord: DisposalRecord?
    ) async -> DiskInspection {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return .blocked("directoryUnavailable", nil, runtimeID)
        }
        guard names.allSatisfy({ Self.allowedDiskEntryNames.contains($0) }) else {
            return .blocked("unsupportedEvidence", nil, runtimeID)
        }
        guard names.contains("disk.img") else {
            return .blocked("diskMissing", nil, runtimeID)
        }
        guard names.contains("runtime.json") else {
            return .blocked("unknownOwnership", nil, runtimeID)
        }

        // A durable non-terminal record is already past the ownership checks;
        // re-confirm current activity only. This intentionally avoids reading
        // the same sidecars again on a repeated maintenance tap.
        if let existingRecord, existingRecord.phase != .done {
            switch await readRow(existingRecord.environmentID) {
            case .unavailable:
                return .blocked("registryUnavailable", existingRecord.environmentID, existingRecord.runtimeID)
            case .row(let row):
                if let blocker = await activityBlocker(
                    environmentID: existingRecord.environmentID, row: row
                ) {
                    return .blocked(blocker, existingRecord.environmentID, existingRecord.runtimeID)
                }
            }
            if existingRecord.sourceIdentity == diskIdentity,
               existingRecord.sourceDirectoryIdentity == directoryIdentity {
                return .inProgress(existingRecord)
            }
        }

        let runtimeRead = Self.readBoundedRegularFile(
            at: directoryURL.appendingPathComponent("runtime.json"),
            maximumBytes: 65_536
        )
        guard case .data(let runtimeData) = runtimeRead else {
            return .blocked("unknownOwnership", nil, runtimeID)
        }
        let runtimeMeta: RuntimeV2WorkingDirectory.Meta
        do {
            runtimeMeta = try Self.metadataDecoder.decode(
                RuntimeV2WorkingDirectory.Meta.self, from: runtimeData
            )
        } catch {
            return .blocked("unknownOwnership", nil, runtimeID)
        }
        guard runtimeMeta.version == 1 || runtimeMeta.version == 2,
              runtimeMeta.runtimeID == runtimeID,
              (try? RuntimeV2Identifier.validate(runtimeMeta.environmentID, kind: .environment)) != nil,
              Self.preservedEntryIdentityMatches(meta: runtimeMeta, relative: key.relativePath) else {
            return .blocked("unknownOwnership", nil, runtimeID)
        }
        let environmentID = runtimeMeta.environmentID

        let sidecar = readEnvironmentSidecar(environmentID: environmentID)
        let row = await readRow(environmentID)
        let classification = classifyRISCVMetadata(
            environmentID: environmentID,
            runtimeBaseImageID: runtimeMeta.baseImageID,
            executionImageID: runtimeMeta.executionImageID,
            sidecar: sidecar,
            row: row
        )
        switch classification {
        case .blocked(let reason):
            return .blocked(reason, environmentID, runtimeID)
        case .preservation(let reason):
            return .preservationRequired(reason, environmentID, runtimeID)
        case .riscv(let imageID):
            let rowValue: RuntimeV2Registry.EnvironmentRow?
            switch row {
            case .row(let value): rowValue = value
            case .unavailable: return .blocked("registryUnavailable", environmentID, runtimeID)
            }
            if let blocker = await activityBlocker(environmentID: environmentID, row: rowValue) {
                return .blocked(blocker, environmentID, runtimeID)
            }
            return .eligible(DiskContext(
                key: key, kind: kind, environmentID: environmentID,
                runtimeID: runtimeID, relativePath: key.relativePath,
                directoryURL: directoryURL, directoryIdentity: directoryIdentity,
                diskIdentity: diskIdentity, imageID: imageID,
                existingRecord: existingRecord
            ))
        }
    }

    private func inspectDelta(
        environmentID: String,
        observation: RuntimeV2DeltaStore.ObsoleteDisposalObservation,
        existingRecord: DisposalRecord?
    ) async -> DeltaInspection {
        if observation.files.isEmpty { return .alreadyDisposed }
        guard observation.files.allSatisfy({ $0.isRegularFile && $0.linkCount == 1 }) else {
            return .blocked("unsupportedDeltaFile", environmentID)
        }

        if let existingRecord, existingRecord.phase != .done {
            switch await readRow(environmentID) {
            case .unavailable:
                return .blocked("registryUnavailable", environmentID)
            case .row(let row):
                if let blocker = await activityBlocker(environmentID: environmentID, row: row) {
                    return .blocked(blocker, environmentID)
                }
            }
            return .inProgress(existingRecord)
        }

        let sidecar = readEnvironmentSidecar(environmentID: environmentID)
        let row = await readRow(environmentID)
        let classification = classifyRISCVMetadata(
            environmentID: environmentID,
            runtimeBaseImageID: sidecar.baseImageID ?? row.baseImageID ?? "",
            executionImageID: nil,
            sidecar: sidecar,
            row: row
        )
        switch classification {
        case .blocked(let reason):
            return .blocked(reason, environmentID)
        case .preservation(let reason):
            return .preservationRequired(reason, environmentID)
        case .riscv(let imageID):
            let rowValue: RuntimeV2Registry.EnvironmentRow?
            switch row {
            case .row(let value): rowValue = value
            case .unavailable: return .blocked("registryUnavailable", environmentID)
            }
            if let blocker = await activityBlocker(environmentID: environmentID, row: rowValue) {
                return .blocked(blocker, environmentID)
            }
            return .eligible(DeltaContext(
                environmentID: environmentID, observation: observation,
                imageID: imageID, allocatedBytes: observation.totalAllocatedBytes,
                existingRecord: existingRecord
            ))
        }
    }

    // MARK: disposal

    private func performDisposal(key: CandidateKey, limits: Limits) async throws -> DisposalResult {
        switch key {
        case .disk(let relative):
            return try await disposeDisk(
                key: key, relative: relative, kind: .workingDisk, limits: limits
            )
        case .discarded(let relative):
            return try await disposeDisk(
                key: key, relative: relative, kind: .discardedEvidence, limits: limits
            )
        case .delta(let environmentID):
            return try await disposeDelta(environmentID: environmentID, limits: limits)
        }
    }

    private func disposeDisk(
        key: CandidateKey, relative: String, kind: CandidateKind, limits: Limits
    ) async throws -> DisposalResult {
        guard let runtimeID = Self.runtimeID(relative: relative, kind: kind),
              let directoryURL = try? Self.directoryURL(relative: relative, layout: store.layout),
              let directoryIdentity = Self.identity(at: directoryURL) else {
            return DisposalResult(candidateID: key.id, outcome: .alreadyDisposed)
        }
        guard let diskIdentity = Self.identity(at: directoryURL.appendingPathComponent("disk.img")) else {
            return DisposalResult(
                candidateID: key.id, outcome: .blocked,
                runtimeID: runtimeID, reasonCode: "diskMissing"
            )
        }
        let records = loadRecords(limit: 512)
        let recordID = Self.recordID(candidateID: key.id, identityKey: diskIdentity.key)
        let existing = records.first { $0.recordID == recordID }
        let inspection = await inspectDisk(
            key: key, kind: kind, runtimeID: runtimeID,
            directoryURL: directoryURL, directoryIdentity: directoryIdentity,
            diskIdentity: diskIdentity, existingRecord: existing
        )
        switch inspection {
        case .alreadyDisposed:
            return DisposalResult(candidateID: key.id, outcome: .alreadyDisposed,
                                  recordID: recordID)
        case .blocked(let reason, let environmentID, let runtimeID):
            return DisposalResult(
                candidateID: key.id, outcome: .blocked,
                environmentID: environmentID, runtimeID: runtimeID,
                recordID: existing?.recordID, reasonCode: reason
            )
        case .preservationRequired(let reason, let environmentID, let runtimeID):
            return DisposalResult(
                candidateID: key.id, outcome: .preservationRequired,
                environmentID: environmentID, runtimeID: runtimeID,
                reasonCode: reason
            )
        case .inProgress(let record):
            return try await resume(record: record, limits: limits)
        case .eligible(let context):
            return try await performDiskDisposal(context: context, recordID: recordID)
        }
    }

    private func performDiskDisposal(
        context: DiskContext, recordID: String
    ) async throws -> DisposalResult {
        var record = context.existingRecord ?? DisposalRecord(
            version: DisposalRecord.currentVersion, recordID: recordID,
            candidateID: context.key.id, kind: context.kind,
            environmentID: context.environmentID, runtimeID: context.runtimeID,
            relativePath: context.relativePath,
            sourceIdentity: context.diskIdentity,
            sourceDirectoryIdentity: context.directoryIdentity,
            deltaFiles: nil,
            stagedRelativePath: Self.stagedRelativePath(recordID: recordID),
            phase: .discovered, imageID: context.imageID,
            removedLogicalBytes: context.diskIdentity.logicalBytes,
            removedAllocatedBytes: context.diskIdentity.allocatedBytes,
            resolutionNote: nil, createdAt: Date(), updatedAt: Date()
        )
        record.phase = .discovered
        record.updatedAt = Date()
        do {
            try writeRecord(record)
        } catch {
            return DisposalResult(
                candidateID: context.key.id, outcome: .blocked,
                environmentID: context.environmentID, runtimeID: context.runtimeID,
                recordID: recordID, reasonCode: "recordWriteFailed"
            )
        }

        do {
            // Revalidate the exact objects and current ownership immediately
            // before the first mutation. A fresh scan is not a permit.
            guard let currentDirectory = Self.identity(at: context.directoryURL),
                  currentDirectory == context.directoryIdentity else {
                return DisposalResult(
                    candidateID: context.key.id, outcome: .blocked,
                    environmentID: context.environmentID, runtimeID: context.runtimeID,
                    recordID: recordID, reasonCode: "sourceChanged"
                )
            }
            guard let currentDisk = Self.identity(
                at: context.directoryURL.appendingPathComponent("disk.img")
            ), currentDisk == context.diskIdentity else {
                return DisposalResult(
                    candidateID: context.key.id, outcome: .blocked,
                    environmentID: context.environmentID, runtimeID: context.runtimeID,
                    recordID: recordID, reasonCode: "sourceChanged"
                )
            }
            guard let names = try? fileManager.contentsOfDirectory(atPath: context.directoryURL.path),
                  names.allSatisfy({ Self.allowedDiskEntryNames.contains($0) }),
                  names.contains("disk.img"), names.contains("runtime.json") else {
                return DisposalResult(
                    candidateID: context.key.id, outcome: .blocked,
                    environmentID: context.environmentID, runtimeID: context.runtimeID,
                    recordID: recordID, reasonCode: "unsupportedEvidence"
                )
            }
            switch await readRow(context.environmentID) {
            case .unavailable:
                return DisposalResult(
                    candidateID: context.key.id, outcome: .blocked,
                    environmentID: context.environmentID, runtimeID: context.runtimeID,
                    recordID: recordID, reasonCode: "registryUnavailable"
                )
            case .row(let row):
                if let blocker = await activityBlocker(environmentID: context.environmentID, row: row) {
                    return DisposalResult(
                        candidateID: context.key.id, outcome: .blocked,
                        environmentID: context.environmentID, runtimeID: context.runtimeID,
                        recordID: recordID, reasonCode: blocker
                    )
                }
            }

            if Task.isCancelled {
                return DisposalResult(
                    candidateID: context.key.id, outcome: .interrupted,
                    environmentID: context.environmentID, runtimeID: context.runtimeID,
                    recordID: recordID, reasonCode: "cancelled"
                )
            }
            // Bind the exclusion that exists BEFORE any byte moves. A hold
            // placed later is a distinct repair instance and must never be
            // silently resolved by this disposal.
            let holdEvidence = HoldEvidence(
                hold: await store.repairHolds.hold(
                    matchingPreservedPath: context.relativePath,
                    environmentID: context.environmentID
                ),
                corruptMarker: await store.repairHolds.corruptMarkerObservation(
                    environmentID: context.environmentID
                ) != nil
            )
            let staging = stagingURL(recordID: recordID)
            if fileManager.fileExists(atPath: context.directoryURL.path) {
                guard !fileManager.fileExists(atPath: staging.path) else {
                    return DisposalResult(
                        candidateID: context.key.id, outcome: .blocked,
                        environmentID: context.environmentID, runtimeID: context.runtimeID,
                        recordID: recordID, reasonCode: "stagingConflict"
                    )
                }
                try ensureStagingRoot()
                guard rename(context.directoryURL.path, staging.path) == 0 else {
                    return DisposalResult(
                        candidateID: context.key.id, outcome: .interrupted,
                        environmentID: context.environmentID, runtimeID: context.runtimeID,
                        recordID: recordID, reasonCode: "stageFailed"
                    )
                }
            } else if !fileManager.fileExists(atPath: staging.path) {
                // Both names are already gone; the durable record still
                // accounts for the exact bytes that were removed earlier.
            }
            record.phase = .staged
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterStage?(context.key.id)

            if fileManager.fileExists(atPath: staging.path) {
                try Self.removeDirectoryRecursively(staging, fileManager: fileManager)
            }
            record.phase = .deleted
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterDelete?(context.key.id)

            try seams.beforeResolution?(context.key.id)
            let note = try await resolveHold(
                environmentID: context.environmentID,
                relativePath: context.relativePath,
                evidence: holdEvidence
            )
            record.resolutionNote = note
            record.phase = .resolved
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterResolution?(context.key.id)

            record.phase = .done
            record.updatedAt = Date()
            try writeRecord(record)
            // Counts only: environment/runtime identities stay in the durable
            // record, never in the exported log stream.
            await store.logs.log(
                "runtime v2 obsolete RISC-V disk disposed logicalBytes=\(record.removedLogicalBytes)"
            )
            return DisposalResult(
                candidateID: context.key.id, outcome: .disposed,
                environmentID: context.environmentID, runtimeID: context.runtimeID,
                removedLogicalBytes: record.removedLogicalBytes,
                removedAllocatedBytes: record.removedAllocatedBytes,
                recordID: recordID, reasonCode: note
            )
        } catch {
            return DisposalResult(
                candidateID: context.key.id, outcome: .interrupted,
                environmentID: context.environmentID, runtimeID: context.runtimeID,
                removedLogicalBytes: record.removedLogicalBytes,
                removedAllocatedBytes: record.removedAllocatedBytes,
                recordID: recordID, reasonCode: "interrupted"
            )
        }
    }

    private func disposeDelta(
        environmentID: String, limits: Limits
    ) async throws -> DisposalResult {
        let key = CandidateKey.delta(environmentID: environmentID)
        let observation = await store.deltas.observeObsoleteDisposal(environmentID: environmentID)
        guard !observation.files.isEmpty else {
            return DisposalResult(candidateID: key.id, outcome: .alreadyDisposed,
                                  environmentID: environmentID)
        }
        let identityKey = Self.deltaIdentityKey(observation.files)
        let recordID = Self.recordID(candidateID: key.id, identityKey: identityKey)
        let existing = loadRecords(limit: 512).first { $0.recordID == recordID }
        let inspection = await inspectDelta(
            environmentID: environmentID, observation: observation, existingRecord: existing
        )
        switch inspection {
        case .alreadyDisposed:
            return DisposalResult(candidateID: key.id, outcome: .alreadyDisposed,
                                  environmentID: environmentID, recordID: recordID)
        case .skippedNonObsolete:
            return DisposalResult(candidateID: key.id, outcome: .preservationRequired,
                                  environmentID: environmentID, reasonCode: "notRiscV")
        case .blocked(let reason, let environmentID):
            return DisposalResult(
                candidateID: key.id, outcome: .blocked,
                environmentID: environmentID, recordID: existing?.recordID,
                reasonCode: reason
            )
        case .preservationRequired(let reason, let environmentID):
            return DisposalResult(
                candidateID: key.id, outcome: .preservationRequired,
                environmentID: environmentID, reasonCode: reason
            )
        case .inProgress(let record):
            return try await resume(record: record, limits: limits)
        case .eligible(let context):
            return try await performDeltaDisposal(
                context: context, recordID: recordID,
                observation: observation
            )
        }
    }

    private func performDeltaDisposal(
        context: DeltaContext, recordID: String,
        observation: RuntimeV2DeltaStore.ObsoleteDisposalObservation
    ) async throws -> DisposalResult {
        var deltaIdentities: [String: SourceIdentity] = [:]
        for file in observation.files {
            deltaIdentities[file.name] = SourceIdentity(
                device: file.device, inode: file.inode,
                logicalBytes: file.logicalBytes, allocatedBytes: file.allocatedBytes,
                linkCount: file.linkCount, mode: file.mode,
                modificationSeconds: file.modificationSeconds,
                modificationNanoseconds: file.modificationNanoseconds,
                changeSeconds: file.changeSeconds,
                changeNanoseconds: file.changeNanoseconds
            )
        }
        var record = context.existingRecord ?? DisposalRecord(
            version: DisposalRecord.currentVersion, recordID: recordID,
            candidateID: CandidateKey.delta(environmentID: context.environmentID).id,
            kind: .environmentDelta,
            environmentID: context.environmentID, runtimeID: nil,
            relativePath: nil, sourceIdentity: nil, sourceDirectoryIdentity: nil,
            deltaFiles: deltaIdentities,
            stagedRelativePath: Self.stagedRelativePath(recordID: recordID),
            phase: .discovered, imageID: context.imageID,
            removedLogicalBytes: observation.files.reduce(0) { $0 + $1.logicalBytes },
            removedAllocatedBytes: context.allocatedBytes,
            resolutionNote: nil, createdAt: Date(), updatedAt: Date()
        )
        record.phase = .discovered
        record.updatedAt = Date()
        do {
            try writeRecord(record)
        } catch {
            return DisposalResult(
                candidateID: record.candidateID, outcome: .blocked,
                environmentID: context.environmentID, recordID: recordID,
                reasonCode: "recordWriteFailed"
            )
        }

        do {
            // Reconfirm this is still the same authoritative obsolete RISC-V
            // environment AND still idle immediately before the mutation.
            let freshSidecar = readEnvironmentSidecar(environmentID: context.environmentID)
            let freshRow = await readRow(context.environmentID)
            let classification = classifyRISCVMetadata(
                environmentID: context.environmentID,
                runtimeBaseImageID: freshSidecar.baseImageID ?? freshRow.baseImageID ?? "",
                executionImageID: nil, sidecar: freshSidecar, row: freshRow
            )
            switch classification {
            case .blocked(let reason):
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: context.environmentID, recordID: recordID,
                    reasonCode: reason
                )
            case .preservation(let reason):
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .preservationRequired,
                    environmentID: context.environmentID, recordID: recordID,
                    reasonCode: reason
                )
            case .riscv:
                break
            }
            let rowValue: RuntimeV2Registry.EnvironmentRow?
            switch freshRow {
            case .row(let value): rowValue = value
            case .unavailable:
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: context.environmentID, recordID: recordID,
                    reasonCode: "registryUnavailable"
                )
            }
            if let blocker = await activityBlocker(
                environmentID: context.environmentID, row: rowValue
            ) {
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: context.environmentID, recordID: recordID,
                    reasonCode: blocker
                )
            }

            if Task.isCancelled {
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .interrupted,
                    environmentID: context.environmentID, recordID: recordID,
                    reasonCode: "cancelled"
                )
            }
            let staging = stagingURL(recordID: recordID)
            try ensureStagingRoot()
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
                _ = try await store.deltas.stageObsoleteDeltaFileForDisposal(
                    environmentID: context.environmentID,
                    name: name, stagingDirectory: staging
                )
                if name == "delta.header" {
                    try seams.afterDeltaHeaderStage?(record.candidateID)
                }
            }
            record.phase = .staged
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterStage?(record.candidateID)

            for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
                try await store.deltas.removeStagedObsoleteDeltaFile(
                    name: name, in: staging
                )
            }
            try? fileManager.removeItem(at: staging)
            record.phase = .deleted
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterDelete?(record.candidateID)

            record.phase = .resolved
            record.updatedAt = Date()
            try writeRecord(record)
            try seams.afterResolution?(record.candidateID)

            record.phase = .done
            record.updatedAt = Date()
            try writeRecord(record)
            await store.logs.log(
                "runtime v2 obsolete RISC-V delta disposed logicalBytes=\(record.removedLogicalBytes)"
            )
            return DisposalResult(
                candidateID: record.candidateID, outcome: .disposed,
                environmentID: context.environmentID,
                removedLogicalBytes: record.removedLogicalBytes,
                removedAllocatedBytes: record.removedAllocatedBytes,
                recordID: recordID
            )
        } catch {
            return DisposalResult(
                candidateID: record.candidateID, outcome: .interrupted,
                environmentID: context.environmentID,
                removedLogicalBytes: record.removedLogicalBytes,
                removedAllocatedBytes: record.removedAllocatedBytes,
                recordID: recordID, reasonCode: "interrupted"
            )
        }
    }

    // MARK: resume

    private func resume(record: DisposalRecord, limits: Limits) async throws -> DisposalResult {
        guard record.phase != .done else {
            return DisposalResult(
                candidateID: record.candidateID, outcome: .alreadyDisposed,
                environmentID: record.environmentID, runtimeID: record.runtimeID,
                removedLogicalBytes: record.removedLogicalBytes,
                removedAllocatedBytes: record.removedAllocatedBytes,
                recordID: record.recordID
            )
        }
        switch record.kind {
        case .environmentDelta:
            return try await resumeDelta(record: record, limits: limits)
        case .workingDisk, .discardedEvidence:
            return try await resumeDisk(record: record, limits: limits)
        }
    }

    private func resumeDisk(record: DisposalRecord, limits: Limits) async throws -> DisposalResult {
        guard let relative = record.relativePath,
              let directoryURL = try? Self.directoryURL(relative: relative, layout: store.layout)
        else {
            return DisposalResult(
                candidateID: record.candidateID, outcome: .blocked,
                environmentID: record.environmentID, runtimeID: record.runtimeID,
                recordID: record.recordID, reasonCode: "sourceChanged"
            )
        }
        let staging = stagingURL(recordID: record.recordID)
        let holdEvidence = HoldEvidence(
            hold: await store.repairHolds.hold(
                matchingPreservedPath: relative, environmentID: record.environmentID
            ),
            corruptMarker: await store.repairHolds.corruptMarkerObservation(
                environmentID: record.environmentID
            ) != nil
        )
        var mutable = record

        if let sourceIdentity = record.sourceIdentity,
           fileManager.fileExists(atPath: directoryURL.path) {
            guard let current = Self.identity(at: directoryURL.appendingPathComponent("disk.img")),
                  current == sourceIdentity,
                  let currentDirectory = Self.identity(at: directoryURL),
                  currentDirectory == record.sourceDirectoryIdentity else {
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "sourceChanged"
                )
            }
            switch await readRow(record.environmentID) {
            case .unavailable:
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "registryUnavailable"
                )
            case .row(let row):
                if let blocker = await activityBlocker(environmentID: record.environmentID, row: row) {
                    return DisposalResult(
                        candidateID: record.candidateID, outcome: .blocked,
                        environmentID: record.environmentID, runtimeID: record.runtimeID,
                        recordID: record.recordID, reasonCode: blocker
                    )
                }
            }
            guard !fileManager.fileExists(atPath: staging.path) else {
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .blocked,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "stagingConflict"
                )
            }
            try ensureStagingRoot()
            guard rename(directoryURL.path, staging.path) == 0 else {
                return DisposalResult(
                    candidateID: record.candidateID, outcome: .interrupted,
                    environmentID: record.environmentID, runtimeID: record.runtimeID,
                    recordID: record.recordID, reasonCode: "stageFailed"
                )
            }
            mutable.phase = .staged
            mutable.updatedAt = Date()
            try writeRecord(mutable)
        } else if !fileManager.fileExists(atPath: staging.path) {
            mutable.phase = .deleted
            mutable.updatedAt = Date()
            try writeRecord(mutable)
        }

        if fileManager.fileExists(atPath: staging.path) {
            try Self.removeDirectoryRecursively(staging, fileManager: fileManager)
        }
        mutable.phase = .deleted
        mutable.updatedAt = Date()
        try writeRecord(mutable)

        if mutable.phase != .resolved {
            let note = try await resolveHold(
                environmentID: record.environmentID, relativePath: relative,
                evidence: holdEvidence
            )
            mutable.resolutionNote = note
            mutable.phase = .resolved
            mutable.updatedAt = Date()
            try writeRecord(mutable)
        }
        mutable.phase = .done
        mutable.updatedAt = Date()
        try writeRecord(mutable)
        return DisposalResult(
            candidateID: record.candidateID, outcome: .disposed,
            environmentID: record.environmentID, runtimeID: record.runtimeID,
            removedLogicalBytes: record.removedLogicalBytes,
            removedAllocatedBytes: record.removedAllocatedBytes,
            recordID: record.recordID, reasonCode: mutable.resolutionNote
        )
    }

    private func resumeDelta(record: DisposalRecord, limits: Limits) async throws -> DisposalResult {
        let sidecar = readEnvironmentSidecar(environmentID: record.environmentID)
        let row = await readRow(record.environmentID)
        let classification = classifyRISCVMetadata(
            environmentID: record.environmentID,
            runtimeBaseImageID: sidecar.baseImageID ?? row.baseImageID ?? "",
            executionImageID: nil, sidecar: sidecar, row: row
        )
        switch classification {
        case .blocked(let reason):
            return DisposalResult(
                candidateID: record.candidateID, outcome: .blocked,
                environmentID: record.environmentID, recordID: record.recordID,
                reasonCode: reason
            )
        case .preservation(let reason):
            return DisposalResult(
                candidateID: record.candidateID, outcome: .preservationRequired,
                environmentID: record.environmentID, recordID: record.recordID,
                reasonCode: reason
            )
        case .riscv:
            break
        }
        let rowValue: RuntimeV2Registry.EnvironmentRow?
        switch row {
        case .row(let value): rowValue = value
        case .unavailable:
            return DisposalResult(
                candidateID: record.candidateID, outcome: .blocked,
                environmentID: record.environmentID, recordID: record.recordID,
                reasonCode: "registryUnavailable"
            )
        }
        if let blocker = await activityBlocker(environmentID: record.environmentID, row: rowValue) {
            return DisposalResult(
                candidateID: record.candidateID, outcome: .blocked,
                environmentID: record.environmentID, recordID: record.recordID,
                reasonCode: blocker
            )
        }
        var mutable = record
        let staging = stagingURL(recordID: record.recordID)
        try ensureStagingRoot()
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
            _ = try await store.deltas.stageObsoleteDeltaFileForDisposal(
                environmentID: record.environmentID,
                name: name, stagingDirectory: staging
            )
        }
        mutable.phase = .staged
        mutable.updatedAt = Date()
        try writeRecord(mutable)
        for name in RuntimeV2DeltaStore.obsoleteDisposalFileNames {
            try await store.deltas.removeStagedObsoleteDeltaFile(name: name, in: staging)
        }
        try? fileManager.removeItem(at: staging)
        mutable.phase = .deleted
        mutable.updatedAt = Date()
        try writeRecord(mutable)
        mutable.phase = .resolved
        mutable.updatedAt = Date()
        try writeRecord(mutable)
        mutable.phase = .done
        mutable.updatedAt = Date()
        try writeRecord(mutable)
        return DisposalResult(
            candidateID: record.candidateID, outcome: .disposed,
            environmentID: record.environmentID,
            removedLogicalBytes: record.removedLogicalBytes,
            removedAllocatedBytes: record.removedAllocatedBytes,
            recordID: record.recordID
        )
    }

    // MARK: environment / metadata checks

    private struct EnvironmentSidecar: Decodable {
        var version: Int
        var environmentID: String
        var baseImageID: String
        var baseRootfsSHA512: String?
        var templateID: String?
        var templateVersion: Int?
        var templateDigest: String?
    }

    private enum EnvironmentSidecarResult {
        case absent
        case data(EnvironmentSidecar)
        case unreadable

        var baseImageID: String? {
            if case .data(let value) = self { return value.baseImageID }
            return nil
        }
    }

    private enum RowRead {
        case row(RuntimeV2Registry.EnvironmentRow?)
        case unavailable

        var baseImageID: String? {
            if case .row(let row) = self { return row?.baseImageID }
            return nil
        }
    }

    private enum MetadataClassification {
        case riscv(String)
        case blocked(String)
        case preservation(String)
    }

    private func readRow(_ environmentID: String) async -> RowRead {
        do {
            return .row(try await store.registry.environment(id: environmentID))
        } catch {
            return .unavailable
        }
    }

    private func readEnvironmentSidecar(environmentID: String) -> EnvironmentSidecarResult {
        guard let url = try? store.layout.environmentMetadataURL(environmentID: environmentID) else {
            return .unreadable
        }
        switch Self.readBoundedRegularFile(at: url, maximumBytes: 65_536) {
        case .missing:
            return .absent
        case .data(let data):
            do {
                return .data(try Self.sidecarDecoder.decode(EnvironmentSidecar.self, from: data))
            } catch {
                return .unreadable
            }
        case .unreadable, .tooLarge, .notRegular:
            return .unreadable
        }
    }

    private func classifyRISCVMetadata(
        environmentID: String,
        runtimeBaseImageID: String,
        executionImageID: String?,
        sidecar: EnvironmentSidecarResult,
        row: RowRead
    ) -> MetadataClassification {
        guard !runtimeBaseImageID.isEmpty else {
            return .blocked("baseMetadataMissing")
        }
        if case .unavailable = row {
            return .blocked("registryUnavailable")
        }
        guard RuntimeV2ObsoleteRISCVCatalog.isObsoleteImageID(runtimeBaseImageID) else {
            return .preservation("notRiscV")
        }
        if let executionImageID, !executionImageID.isEmpty,
           !RuntimeV2ObsoleteRISCVCatalog.isObsoleteImageID(executionImageID) {
            return .preservation("executionImageNotRiscV")
        }

        let sidecarValue: EnvironmentSidecar?
        switch sidecar {
        case .absent:
            sidecarValue = nil
        case .unreadable:
            return .blocked("environmentMetadataUnreadable")
        case .data(let value):
            guard value.version == 1, value.environmentID == environmentID else {
                return .blocked("environmentMetadataMismatch")
            }
            guard !value.baseImageID.isEmpty else {
                return .blocked("baseMetadataMissing")
            }
            guard value.baseImageID == runtimeBaseImageID else {
                return .blocked("baseMismatch")
            }
            if !RuntimeV2ObsoleteRISCVCatalog.isObsoleteImageID(value.baseImageID) {
                return .preservation("notRiscV")
            }
            sidecarValue = value
        }

        let rowValue: RuntimeV2Registry.EnvironmentRow?
        switch row {
        case .row(let value): rowValue = value
        case .unavailable: return .blocked("registryUnavailable")
        }
        if let rowValue, let base = rowValue.baseImageID, !base.isEmpty {
            guard base == runtimeBaseImageID else {
                return .blocked("baseMismatch")
            }
            guard RuntimeV2ObsoleteRISCVCatalog.isObsoleteImageID(base) else {
                return .preservation("notRiscV")
            }
        }
        if sidecarValue == nil && rowValue == nil {
            return .blocked("environmentMetadataMissing")
        }
        return .riscv(runtimeBaseImageID)
    }

    private func activityBlocker(
        environmentID: String, row: RuntimeV2Registry.EnvironmentRow?
    ) async -> String? {
        if let row, Self.activeEnvironmentStates.contains(row.state) {
            return "activeEnvironmentState"
        }
        if let sidecarLease = try? await store.leases.holder(environmentID: environmentID),
           sidecarLease.pid > 0,
           RuntimeV2LeaseStore.blocksRetirement(sidecarLease) {
            return "liveLease"
        }
        do {
            // A historical registry row may remain state='held' after its
            // process died and its TTL expired (the real 57-old-lease case).
            // Only a live or unexpired row is current ownership; an expired
            // dead row must not block disposal of an otherwise proved disk.
            let now = Date()
            for leaseRow in try await store.registry.heldLeases()
                where leaseRow.environmentID == environmentID {
                // pid 0/negative is malformed historical metadata, not a live
                // process (kill(0, 0) targets a process group).
                guard leaseRow.pid > 0 else { continue }
                let lease = RuntimeV2LeaseStore.Lease(
                    environmentID: leaseRow.environmentID,
                    runtimeID: leaseRow.runtimeID,
                    incarnation: leaseRow.incarnation,
                    sessionToken: leaseRow.sessionToken,
                    pid: leaseRow.pid,
                    acquiredAt: leaseRow.acquiredAt,
                    renewedAt: leaseRow.renewedAt,
                    ttlSeconds: leaseRow.ttlSeconds
                )
                if RuntimeV2LeaseStore.blocksRetirement(lease, now: now) {
                    return "heldLease"
                }
            }
            if try await store.registry.queueEntries(state: "queued").contains(where: { $0.environmentID == environmentID }) {
                return "queuedStart"
            }
            if try await store.registry.queueEntries(state: "running").contains(where: { $0.environmentID == environmentID }) {
                return "queuedStart"
            }
        } catch {
            return "registryUnavailable"
        }
        if await store.pool.slot(environmentID: environmentID) != nil {
            return "activeSlot"
        }
        return nil
    }

    /// Resolve exactly one matching valid hold after the preserved directory
    /// was removed. The hold evidence was captured before bytes moved, so a
    /// newer distinct repair instance is never resolved by this disposal. A
    /// corrupt marker is left untouched; a marker for another path is left
    /// untouched. No disk digest is computed.
    private func resolveHold(
        environmentID: String, relativePath: String, evidence: HoldEvidence
    ) async throws -> String? {
        if evidence.corruptMarker { return "corruptMarkerKept" }
        guard let hold = evidence.hold else { return nil }
        try await store.repairHolds.recordObsoleteDisposalResolution(
            environmentID: environmentID, preservedPath: relativePath,
            resolvedHoldID: hold.holdID.isEmpty ? nil : hold.holdID
        )
        if let row = try? await store.registry.environment(id: environmentID), row.state != "deleting" {
            if await !store.leases.excludes(environmentID: environmentID) {
                try? await store.registry.setEnvironmentState(
                    id: environmentID, state: "stopped", repairReason: nil
                )
            }
        }
        return "holdRetired"
    }

    // MARK: durable records / staging

    /// The staging directory can briefly contain one full obsolete disk.
    /// It is a transient rename target, never a durable copy, so exclude it
    /// from cloud backup while it exists. (Records are tiny metadata-only
    /// checkpoints and remain ordinary recovery files.)
    private func ensureStagingRoot() throws {
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? (stagingRoot as NSURL).setResourceValue(
            values.isExcludedFromBackup, forKey: .isExcludedFromBackupKey
        )
        #endif
    }

    private func recordURL(recordID: String) -> URL {
        recordsDirectory.appendingPathComponent("\(recordID).json")
    }

    private func stagingURL(recordID: String) -> URL {
        stagingRoot.appendingPathComponent(recordID, isDirectory: true)
    }

    private static func stagedRelativePath(recordID: String) -> String {
        "recovery/\(stagingDirectoryName)/\(recordID)"
    }

    private static func recordID(candidateID: String, identityKey: String) -> String {
        let digest = FloeDigest.sha256Hex(Data((candidateID + "|" + identityKey).utf8))
        return "obsolete-" + String(digest.prefix(24))
    }

    private static func deltaIdentityKey(
        _ files: [RuntimeV2DeltaStore.ObsoleteDisposalFile]
    ) -> String {
        files.sorted { $0.name < $1.name }.map {
            "\($0.name):\($0.logicalBytes):\($0.modificationSeconds):\($0.modificationNanoseconds):\($0.changeSeconds):\($0.changeNanoseconds)"
        }.joined(separator: "|")
    }

    private struct LoadedRecords {
        var records: [DisposalRecord]
        var notes: [String]
        var truncated: Bool
    }

    private func loadRecords(limit: Int) -> [DisposalRecord] {
        loadRecordsWithDiagnostics(limit: limit).records
    }

    private func loadRecordsWithDiagnostics(limit: Int) -> LoadedRecords {
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: recordsDirectory.path)
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile {
                return LoadedRecords(records: [], notes: [], truncated: false)
            }
            return LoadedRecords(records: [], notes: ["recordIndexUnavailable"], truncated: true)
        }
        var records: [DisposalRecord] = []
        var notes: [String] = []
        var truncated = false
        for entry in entries.sorted() where entry.hasSuffix(".json") {
            guard records.count < limit else { truncated = true; break }
            guard entry.hasPrefix("obsolete-") else { continue }
            let url = recordsDirectory.appendingPathComponent(entry)
            guard case .data(let data) = Self.readBoundedRegularFile(
                at: url, maximumBytes: 65_536
            ) else {
                notes.append("recordUnreadable")
                continue
            }
            guard let record = try? Self.recordDecoder.decode(DisposalRecord.self, from: data),
                  record.version == DisposalRecord.currentVersion,
                  record.recordID + ".json" == entry else {
                notes.append("recordUnreadable")
                continue
            }
            records.append(record)
        }
        return LoadedRecords(records: records, notes: notes, truncated: truncated)
    }

    private func listDirectory(
        _ url: URL, label: String, missingIsEmpty: Bool, report: inout ScanReport
    ) -> [String]? {
        do {
            return try fileManager.contentsOfDirectory(atPath: url.path)
        } catch {
            if missingIsEmpty, (error as? CocoaError)?.code == .fileReadNoSuchFile {
                return []
            }
            report.notes.append("\(label)Unavailable")
            report.truncated = true
            return nil
        }
    }

    private func writeRecord(_ record: DisposalRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try fileManager.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        try Self.writeAtomic(data, to: recordURL(recordID: record.recordID), fileManager: fileManager)
    }

    // MARK: bounded file / POSIX helpers

    private enum SmallFileResult {
        case data(Data)
        case missing
        case unreadable
        case tooLarge
        case notRegular
    }

    private static var metadataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var sidecarDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var recordDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func readBoundedRegularFile(
        at url: URL, maximumBytes: Int
    ) -> SmallFileResult {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { return .unreadable }
        guard before.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { return .tooLarge }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4096, max(1, maximumBytes)))
        while data.count < Int(before.st_size) {
            let wanted = min(buffer.count, Int(before.st_size) - data.count)
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, wanted)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable
            }
            guard count > 0 else { return .unreadable }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { return .unreadable }
        #if canImport(Darwin)
        let unchangedTimes = after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            && after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
            && after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        #else
        let unchangedTimes = after.st_mtim.tv_sec == before.st_mtim.tv_sec
            && after.st_mtim.tv_nsec == before.st_mtim.tv_nsec
            && after.st_ctim.tv_sec == before.st_ctim.tv_sec
            && after.st_ctim.tv_nsec == before.st_ctim.tv_nsec
        #endif
        guard after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              unchangedTimes else {
            return .unreadable
        }
        return .data(data)
        #else
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard data.count <= maximumBytes else { return .tooLarge }
        return .data(data)
        #endif
    }

    private static func identity(at url: URL) -> SourceIdentity? {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let blocks = Int64(info.st_blocks)
        let allocated: Int64? = blocks >= 0 ? blocks * 512 : nil
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        let device = UInt64(bitPattern: Int64(info.st_dev))
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        let device = UInt64(info.st_dev)
        #endif
        return SourceIdentity(
            device: device, inode: UInt64(info.st_ino),
            logicalBytes: Int64(info.st_size), allocatedBytes: allocated,
            linkCount: UInt64(info.st_nlink), mode: UInt32(info.st_mode),
            modificationSeconds: Int64(modified.tv_sec),
            modificationNanoseconds: Int64(modified.tv_nsec),
            changeSeconds: Int64(changed.tv_sec),
            changeNanoseconds: Int64(changed.tv_nsec)
        )
        #else
        return nil
        #endif
    }

    private static func writeAtomic(
        _ data: Data, to url: URL, fileManager: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin) || canImport(Glibc)
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [])
        let fd = open(temporary.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeV2Error.layoutCorrupt("record temporary open failed") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RuntimeV2Error.layoutCorrupt("record fsync failed") }
        guard rename(temporary.path, url.path) == 0 else {
            throw RuntimeV2Error.layoutCorrupt("record rename failed")
        }
        let dfd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private static func removeDirectoryRecursively(
        _ url: URL, fileManager: FileManager
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeV2Error.layoutCorrupt("disposal staging is not a directory")
        }
        let names = try fileManager.contentsOfDirectory(atPath: url.path)
        guard names.count <= 64 else {
            throw RuntimeV2Error.layoutCorrupt("disposal staging has an unexpected number of entries")
        }
        for name in names {
            let child = url.appendingPathComponent(name)
            var childInfo = stat()
            guard lstat(child.path, &childInfo) == 0 else { continue }
            if childInfo.st_mode & S_IFMT == S_IFDIR {
                try removeDirectoryRecursively(child, fileManager: fileManager)
            } else {
                guard unlink(child.path) == 0 else {
                    throw RuntimeV2Error.layoutCorrupt("disposal unlink failed (errno \(errno))")
                }
            }
        }
        guard rmdir(url.path) == 0 else {
            throw RuntimeV2Error.layoutCorrupt("disposal directory removal failed (errno \(errno))")
        }
        #else
        try fileManager.removeItem(at: url)
        #endif
    }

    private enum DisposalLockError: Error {
        case busy
        case unavailable
    }

    private func withDisposalLock<T>(_ body: () async throws -> T) async throws -> T {
        #if canImport(Darwin) || canImport(Glibc)
        try? fileManager.createDirectory(
            at: store.layout.recoveryDirectory, withIntermediateDirectories: true
        )
        let lockURL = store.layout.recoveryDirectory.appendingPathComponent(Self.lockFileName)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DisposalLockError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw DisposalLockError.busy
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try await body()
        #else
        throw DisposalLockError.unavailable
        #endif
    }

    // MARK: path / identity helpers

    private enum CandidateKey: Equatable {
        case disk(relative: String)
        case delta(environmentID: String)
        case discarded(relative: String)

        var id: String {
            switch self {
            case .disk(let relative): return "disk:\(relative)"
            case .delta(let environmentID): return "delta:\(environmentID)"
            case .discarded(let relative): return "discarded:\(relative)"
            }
        }

        var kind: CandidateKind {
            switch self {
            case .disk: return .workingDisk
            case .delta: return .environmentDelta
            case .discarded: return .discardedEvidence
            }
        }

        var relativePath: String {
            switch self {
            case .disk(let relative), .discarded(let relative): return relative
            case .delta: return ""
            }
        }

        static func parse(_ raw: String) throws -> CandidateKey {
            if raw.hasPrefix("disk:") {
                let relative = String(raw.dropFirst("disk:".count))
                guard Self.safeRelative(relative),
                      relative.hasPrefix("runtime/vm/")
                        || relative.hasPrefix("recovery/quarantine/runtime-vm-") else {
                    throw RuntimeV2Error.pathEscapesRoot(raw)
                }
                return .disk(relative: relative)
            }
            if raw.hasPrefix("discarded:") {
                let relative = String(raw.dropFirst("discarded:".count))
                guard Self.safeRelative(relative),
                      relative.hasPrefix("recovery/migrations/discarded/runtime-vm-") else {
                    throw RuntimeV2Error.pathEscapesRoot(raw)
                }
                return .discarded(relative: relative)
            }
            if raw.hasPrefix("delta:") {
                let environmentID = String(raw.dropFirst("delta:".count))
                try RuntimeV2Identifier.validate(environmentID, kind: .environment)
                return .delta(environmentID: environmentID)
            }
            throw RuntimeV2Error.pathEscapesRoot(raw)
        }

        private static func safeRelative(_ value: String) -> Bool {
            guard !value.isEmpty, !value.hasPrefix("/"), !value.utf8.contains(0) else { return false }
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
    }

    private static func directoryURL(relative: String, layout: RuntimeV2Layout) throws -> URL {
        if relative.hasPrefix("recovery/migrations/discarded/") {
            let remainder = String(relative.dropFirst("recovery/migrations/discarded/".count))
            guard !remainder.isEmpty, !remainder.contains("/"),
                  remainder.hasPrefix("runtime-vm-") else {
                throw RuntimeV2Error.pathEscapesRoot(relative)
            }
            let url = layout.root.appendingPathComponent(relative, isDirectory: true)
            guard let identity = Self.identity(at: url), identity.isDirectory else {
                throw RuntimeV2Error.repairResolutionUnavailable(
                    environmentID: remainder,
                    reason: "the discarded-evidence directory is unavailable"
                )
            }
            return try layout.contain(url)
        }
        return try layout.preservedRuntimeDirectory(relative)
    }

    private static func runtimeID(relative: String, kind: CandidateKind) -> String? {
        let last = (relative as NSString).lastPathComponent
        if relative.hasPrefix("runtime/vm/") {
            return (try? RuntimeV2Identifier.validate(last, kind: .runtime)) == nil ? nil : last
        }
        let prefix = "runtime-vm-"
        guard last.hasPrefix(prefix), last.count > prefix.count + 37,
              UUID(uuidString: String(last.suffix(36))) != nil,
              last.dropLast(36).last == "-" else {
            return nil
        }
        let runtime = String(last.dropFirst(prefix.count).dropLast(37))
        return (try? RuntimeV2Identifier.validate(runtime, kind: .runtime)) == nil ? nil : runtime
    }

    private static func preservedEntryIdentityMatches(
        meta: RuntimeV2WorkingDirectory.Meta, relative: String
    ) -> Bool {
        let last = (relative as NSString).lastPathComponent
        if relative.hasPrefix("runtime/vm/") {
            return last == meta.runtimeID
        }
        let base = "runtime-vm-\(meta.runtimeID)"
        return last == base || last.hasPrefix(base + "-")
    }
}
