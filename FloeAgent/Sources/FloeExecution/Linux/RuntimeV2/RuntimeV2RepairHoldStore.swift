// FloeExecution — Runtime v2 durable repair exclusion.
//
// A repair hold is the non-expiring sibling of the TTL lease. The lease is a
// cross-process single-writer lock with a TTL so a dead owner can be reclaimed
// after proof; a repair hold is the durable statement "this environment's
// preserved bytes are not yet accounted for — no fresh VM may boot over them
// and no recovery may move them until a human/tool explicitly resolves the
// repair". It exists for exactly the window the lease cannot cover: after the
// holder dies AND its TTL expires, and after a full-disk / IO / DB fault made
// every marker/registry write fail.
//
// Coherent physical-evidence / repair-exclusion protocol:
//   - The marker sidecar (environments/<id>/repair-hold.json) is written
//     BEFORE the lease of a failed capture is released, so the exclusion
//     outlives the process that created it. Checked BEFORE stale-lease
//     reclamation and BEFORE working-disk preparation.
//   - It has no TTL and no pid: it is cleared only by an EXPLICIT resolution —
//     `restoreRepair` (verified restore of the preserved bytes into the
//     delta) or `discardRepair` (deliberate, authorized discard with evidence
//     preservation). Inspection never lifts it.
//   - A corrupt marker sidecar is NEVER moved away: every read re-detects the
//     unreadable file and answers a synthesized unreadable hold, so repeated
//     reads and brand-new store instances fail closed without needing any
//     writable disk to retain the exclusion.
//   - The preserved bytes are themselves durable evidence: an unacknowledged
//     recovery/quarantine/runtime-vm-* entry whose runtime.json names the
//     environment answers a synthesized hold on every read (quarantine
//     evidence), even when no marker write could ever succeed. Resolution
//     records the preservedPath durably so a resolved entry never re-blocks.
//   - The registry's repairRequired state is best-effort bookkeeping for UI;
//     it is NOT the exclusion. The exclusion is filesystem-only.

import Foundation
import FloeCore

public actor RuntimeV2RepairHoldStore {
    public struct Hold: Codable, Sendable, Equatable {
        public var version: Int
        /// Instance identity: a fresh UUID on every `place()`. Resolutions
        /// bind to THIS id, never to the environment globally — a historical
        /// resolution can never suppress a future, distinct hold (multi-
        /// repair cycles stay excluded until each is explicitly resolved).
        /// Synthesized holds (corrupt marker, physical evidence) use "".
        public var holdID: String
        public var environmentID: String
        /// The runtime whose preserved bytes motivated the hold ("" when
        /// unknown, e.g. an unreadable sidecar).
        public var runtimeID: String
        /// Human-readable truthful reason the environment is excluded.
        public var reason: String
        /// Layout-relative path of the preserved bytes (quarantine or runtime
        /// directory), nil when unknown or nothing remains.
        public var preservedPath: String?
        public var createdAt: Date

        public static let currentVersion = 2

        public init(
            environmentID: String, runtimeID: String, reason: String,
            preservedPath: String? = nil, createdAt: Date = Date(),
            holdID: String = UUID().uuidString
        ) {
            self.version = Hold.currentVersion
            self.holdID = holdID
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.reason = reason
            self.preservedPath = preservedPath
            self.createdAt = createdAt
        }
    }

    /// Outcome of verifying the recoverable state before a resolution.
    public enum RecoverableState: Sendable, Equatable {
        /// Preserved bytes exist at the layout-relative path.
        case recoverable(preservedPath: String)
        /// No preserved bytes remain (already restored or discarded): the
        /// exclusion can be cleared without destroying anything.
        case nothingToRecover
    }

    /// Durable record of an explicit repair resolution (restore or discard).
    /// Written next to the archived hold sidecars so the physical evidence
    /// scan can skip an already-resolved entry on every future launch, and
    /// consulted by the marker read so a lingering stale marker stays dead.
    /// The record binds to the SPECIFIC hold instance it resolved
    /// (`resolvedHoldID`) plus the preserved evidence identity
    /// (`preservedPath` basename and, when bytes existed, their digest) —
    /// never to the environment's history: resolving repair A can never
    /// neutralize a later, distinct repair B.
    public struct ResolutionRecord: Codable, Sendable, Equatable {
        public var version: Int
        public var environmentID: String
        /// "restored" or "discarded" — the deliberate named resolution.
        public var resolution: String
        /// The exact hold instance this resolution accounted for (the marker
        /// holdID, or "" when the exclusion was physical evidence only). A
        /// marker is superseded only by a record naming ITS holdID.
        public var resolvedHoldID: String?
        /// Layout-relative path of the preserved bytes the resolution
        /// accounted for (nil when there was nothing to recover).
        public var preservedPath: String?
        /// SHA-512 of the preserved disk (evidence) when bytes existed, nil
        /// for a discard or when nothing remained.
        public var diskDigestSHA512: String?
        public var resolvedAt: Date

        public static let currentVersion = 1

        public init(
            environmentID: String, resolution: String, preservedPath: String? = nil,
            diskDigestSHA512: String? = nil, resolvedAt: Date = Date(),
            resolvedHoldID: String? = nil
        ) {
            self.version = ResolutionRecord.currentVersion
            self.environmentID = environmentID
            self.resolution = resolution
            self.resolvedHoldID = resolvedHoldID
            self.preservedPath = preservedPath
            self.diskDigestSHA512 = diskDigestSHA512
            self.resolvedAt = resolvedAt
        }
    }

    private let layout: RuntimeV2Layout
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.layout = layout
    }

    // MARK: reading (all read-only, all fail closed)

    /// The marker sidecar hold, or nil when no marker exists. A corrupt
    /// sidecar is NEVER moved or deleted: it stays exactly where it is and
    /// every read answers a synthesized unreadable hold, so the exclusion
    /// survives arbitrary repeated reads, brand-new store instances and a
    /// fully read-only disk. Fail closed, never fail open.
    ///
    /// A COMMITTED resolution record lifts the exclusion even when a stale
    /// marker lingers on disk: the marker is retired only AFTER the
    /// resolution commits (best effort), and the read side consults
    /// resolutions first, so no crash window can resurrect or lose the
    /// exclusion.
    public func hold(environmentID: String) -> Hold? {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
              fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let hold = try? Self.decoder.decode(Hold.self, from: data),
              hold.version == Hold.currentVersion,
              hold.environmentID == environmentID else {
            // The unreadable marker itself is the durable fail-closed state:
            // leave it in place so this answer repeats on every future read.
            // A synthesized hold carries no instance id and can never be
            // superseded by ANY historical resolution: fail closed forever.
            return Hold(
                environmentID: environmentID, runtimeID: "",
                reason: "the repair hold sidecar is unreadable; the environment stays excluded until repair is explicitly resolved",
                preservedPath: nil, createdAt: .distantPast, holdID: ""
            )
        }
        // Only a resolution that bound to THIS EXACT hold instance (its
        // holdID) supersedes it: a repaired-then-refailed environment's new
        // hold is a different instance and is never neutralized by history.
        if hasCommittedResolution(resolvingHoldID: hold.holdID) { return nil }
        return hold
    }

    /// The marker sidecar hold only (never synthesized): used by the startup
    /// re-derivation pass to decide whether the durable marker already exists.
    /// Like `hold`, a committed resolution wins over a stale lingering
    /// marker.
    public func markerHold(environmentID: String) -> Hold? {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let hold = try? Self.decoder.decode(Hold.self, from: data),
              hold.version == Hold.currentVersion,
              hold.environmentID == environmentID else { return nil }
        if hasCommittedResolution(resolvingHoldID: hold.holdID) { return nil }
        return hold
    }

    public func hasHold(environmentID: String) -> Bool {
        hold(environmentID: environmentID) != nil
    }

    /// Synthesized hold from durable PHYSICAL evidence: an unacknowledged
    /// recovery/quarantine/runtime-vm-* entry whose runtime.json names this
    /// environment. Read-only; never requires a writable disk, a registry or
    /// any marker — so it keeps the environment excluded across process
    /// death, TTL expiry and sustained IO/DB faults even when every write
    /// path is dead.
    public func quarantineEvidence(environmentID: String) -> Hold? {
        guard (try? RuntimeV2Identifier.validate(environmentID, kind: .environment)) != nil,
              let entries = try? fileManager.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
        else { return nil }
        let acknowledged = acknowledgedQuarantineEntryNames()
        for entry in entries where entry.hasPrefix("runtime-vm-") {
            if acknowledged.contains(entry) { continue }
            let directory = layout.quarantineDirectory.appendingPathComponent(entry, isDirectory: true)
            guard let meta = RuntimeV2WorkingDirectory.readMeta(from: directory),
                  meta.environmentID == environmentID,
                  (try? RuntimeV2Identifier.validate(meta.environmentID, kind: .environment)) != nil
            else { continue }
            return Hold(
                environmentID: environmentID, runtimeID: meta.runtimeID,
                reason: "preserved working disk is the durable evidence at recovery/quarantine/\(entry); an earlier stop or recovery could not persist its repair marker, so the bytes themselves keep this environment excluded until repair is explicitly resolved",
                preservedPath: "recovery/quarantine/\(entry)", createdAt: .distantPast, holdID: ""
            )
        }
        return nil
    }

    /// The effective exclusion: a VALID marker sidecar first, then the
    /// physical-evidence hold, then the corrupt-marker answer. (A valid
    /// marker always outranks physical evidence; a corrupt marker never
    /// hides resolvable evidence — resolution needs the evidence's path.)
    public func effectiveHold(environmentID: String) -> Hold? {
        if let marker = markerHold(environmentID: environmentID) { return marker }
        if let evidence = quarantineEvidence(environmentID: environmentID) { return evidence }
        return hold(environmentID: environmentID)
    }

    /// Verifies the recoverable state a resolution would account for.
    /// Inspection only: never changes any state, never lifts the exclusion.
    /// The preserved path comes from a sidecar (untrusted content): anything
    /// that is not a supported, symlink-contained runtime/quarantine path
    /// answers `.nothingToRecover` — it can never authorize a move.
    public func verifyRecoverable(environmentID: String) -> RecoverableState {
        guard let hold = effectiveHold(environmentID: environmentID) else { return .nothingToRecover }
        guard let preservedPath = hold.preservedPath else { return .nothingToRecover }
        guard let url = try? layout.preservedRuntimeDirectory(preservedPath) else {
            return .nothingToRecover
        }
        let disk = url.appendingPathComponent("disk.img")
        guard fileManager.fileExists(atPath: disk.path),
              ((try? fileManager.attributesOfItem(atPath: disk.path)[.size] as? Int64) ?? 0) > 0
        else { return .nothingToRecover }
        return .recoverable(preservedPath: preservedPath)
    }

    // MARK: writing

    /// Places (or refreshes) the durable marker exclusion. The write happens
    /// under the shared marker-mutation lock: serialized against the resolver
    /// side, so a `place()` can never interleave with (and be erased by) a
    /// stale resolution's cleanup. Throws when the marker itself cannot be
    /// persisted (full disk / IO fault): callers must then keep every other
    /// surviving exclusion (the lease) and rely on the preserved bytes as the
    /// durable evidence.
    public func place(
        environmentID: String, runtimeID: String, reason: String, preservedPath: String? = nil
    ) throws {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        let url = try layout.environmentRepairHoldURL(environmentID: environmentID)
        try withMarkerMutationLock(environmentID: environmentID) {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hold = Hold(
                environmentID: environmentID, runtimeID: runtimeID,
                reason: reason, preservedPath: preservedPath
            )
            try Self.encoder.encode(hold).write(to: url, options: .atomic)
        }
    }

    /// The SHA-512 of the marker sidecar bytes WHEN the sidecar exists but
    /// does not decode as a valid current-version hold for this environment
    /// (a corrupt marker). nil when there is no sidecar or it is a valid
    /// marker. A resolver captures this at the START of a resolution flow and
    /// hands it to `recordResolution`, which may then remove the corrupt
    /// marker under the mutation lock with a byte-identity re-check — a
    /// racing newer marker (valid, or different corrupt bytes) is never
    /// touched, so a stale resolution can never erase a live exclusion.
    public func corruptMarkerDigest(environmentID: String) -> String? {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              (try? Self.decoder.decode(Hold.self, from: data)) == nil
        else { return nil }
        return (try? FloeDigest.sha512Hex(data)) ?? ""
    }

    /// Serializes every mutation of the marker sidecar (place / guarded
    /// corrupt-marker removal) across store instances AND processes: an
    /// flock(2) exclusive lock on a per-environment lock file, held only for
    /// the tiny critical section. Best-effort: when the lock cannot be taken
    /// (unwritable directory) the body still runs — removal then fails
    /// closed (bytes stay, exclusion stays) and placement uses the atomic
    /// rename it already used.
    private func withMarkerMutationLock<T>(
        environmentID: String, _ body: () throws -> T
    ) rethrows -> T {
        guard let directory = try? layout.environmentDirectory(environmentID: environmentID)
        else { return try body() }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".repair-hold.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd != -1 else { return try body() }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    /// The basenames of every quarantine entry whose repair was explicitly
    /// RESOLVED. Only COMMITTED resolution records count — an archived raw
    /// hold sidecar is evidence, never an acknowledgement, so a failed or
    /// interrupted resolution (which never commits its record) can never make
    /// the physical evidence scan skip an entry. The record names the exact
    /// preservedPath the resolution verified and accounted for, so preserved
    /// bytes kept for evidence can never re-block a correctly repaired
    /// environment on a later recovery pass.
    public func acknowledgedQuarantineEntryNames() -> Set<String> {
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("repair-holds", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: archive.path) else { return [] }
        var names = Set<String>()
        for entry in entries where entry.hasPrefix("resolution-") {
            guard let data = try? Data(contentsOf: archive.appendingPathComponent(entry)),
                  let record = try? Self.decoder.decode(ResolutionRecord.self, from: data),
                  let preservedPath = record.preservedPath else { continue }
            names.insert((preservedPath as NSString).lastPathComponent)
        }
        return names
    }

    /// True when a COMMITTED resolution record binds to the EXACT hold
    /// instance (`resolvingHoldID`). Instance-bound, never environment-bound:
    /// resolving one repair can never suppress a later, distinct hold. The
    /// read side consults this, so a stale marker that lingered after its own
    /// resolution (retirement is best-effort) stays dead, while every future
    /// hold instance still fails closed until ITS resolution commits.
    private func hasCommittedResolution(resolvingHoldID: String) -> Bool {
        guard !resolvingHoldID.isEmpty else { return false }
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("repair-holds", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: archive.path) else { return false }
        for entry in entries where entry.hasPrefix("resolution-") {
            guard let data = try? Data(contentsOf: archive.appendingPathComponent(entry)),
                  let record = try? Self.decoder.decode(ResolutionRecord.self, from: data),
                  record.resolvedHoldID == resolvingHoldID else { continue }
            return true
        }
        return false
    }

    /// Durable completion of an EXPLICIT repair resolution (restore or
    /// discard), called only after every byte-moving and registry-committing
    /// stage succeeded. Crash-safe and race-safe protocol:
    ///   1. The resolution record is written ATOMICALLY — this single durable
    ///      file IS the commit. There is no "prepared" state that anything
    ///      could mistake for a resolution.
    ///   2. The LIVE MARKER IS NEVER MOVED OR REMOVED HERE. By the time a
    ///      resolution commits, the sidecar may already be a NEWER hold
    ///      instance B (placed by another store/resolver); deleting "the
    ///      marker" would erase B's exclusion. The read side already
    ///      neutralizes the resolved instance A (a marker whose holdID has a
    ///      committed resolution answers nil), so A's lingering sidecar is an
    ///      inert tombstone that a later `place()` atomically replaces — it
    ///      can never resurrect (no resolution binds to it) and can never be
    ///      erased by a stale A. When the on-disk marker happens to be A's
    ///      own instance, a best-effort COPY to the evidence archive is made
    ///      (never a move).
    /// If step 1 throws, nothing on disk has changed: the exclusion (and the
    /// preserved physical evidence) remains fully in place and the resolution
    /// can be retried idempotently after the fault heals.
    public func recordResolution(
        environmentID: String, preservedPath: String?, resolution: String,
        diskDigestSHA512: String? = nil, resolvedHoldID: String? = nil,
        observedCorruptMarkerDigest: String? = nil
    ) throws {
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("repair-holds", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let record = ResolutionRecord(
            environmentID: environmentID, resolution: resolution,
            preservedPath: preservedPath, diskDigestSHA512: diskDigestSHA512,
            resolvedHoldID: resolvedHoldID
        )
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let recordURL = archive.appendingPathComponent(
            "resolution-\(environmentID)-\(stamp).json"
        )
        try Self.encoder.encode(record).write(to: recordURL, options: .atomic)
        // Marker handling, under the shared mutation lock:
        // - A VALID live marker is NEVER moved or removed. By commit time the
        //   sidecar may already be a NEWER hold instance B (placed by another
        //   store/resolver); touching it could erase B's exclusion. The
        //   resolved instance A is already an inert tombstone — the read side
        //   neutralizes any marker whose holdID has a committed resolution —
        //   and a later `place()` atomically replaces it.
        // - The only bytes ever removed are a CORRUPT marker the resolver
        //   OBSERVED at the start of this very flow (byte-identical re-check
        //   inside the lock): without this, a corrupt marker could never be
        //   lifted at all, since it carries no holdID to suppress. A racing
        //   newer marker — valid, or corrupt with different bytes — fails the
        //   re-check and is left untouched (fail closed).
        // - When the live marker is the resolved instance A itself, a
        //   best-effort COPY to the evidence archive is made (never a move).
        try withMarkerMutationLock(environmentID: environmentID) {
            guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
                  let data = try? Data(contentsOf: url) else { return }
            if let marker = try? Self.decoder.decode(Hold.self, from: data) {
                if let resolvedHoldID, !resolvedHoldID.isEmpty, marker.holdID == resolvedHoldID {
                    let destination = archive.appendingPathComponent(
                        "repair-hold-\(environmentID)-\(stamp).json"
                    )
                    try? data.write(to: destination, options: .atomic)
                }
                return
            }
            if let observedCorruptMarkerDigest, !observedCorruptMarkerDigest.isEmpty,
               (try? FloeDigest.sha512Hex(data)) == observedCorruptMarkerDigest {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
