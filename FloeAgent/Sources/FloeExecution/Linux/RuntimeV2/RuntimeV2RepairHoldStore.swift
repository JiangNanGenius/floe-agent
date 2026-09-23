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
//     writable disk to retain the exclusion. The ONLY path that ever removes
//     one is a COMMITTED explicit resolution, and even it removes only the
//     exact corrupt-file instance it observed at the start of its flow: the
//     removal re-verifies the bytes' digest, the monotonic per-environment
//     marker generation (bumped by every `place()`) and the file-instance
//     identity (inode/device/ctime/size) under the mutation lock — a same-
//     bytes temp+rename replacement during the repair (an ABA) is a distinct
//     newer exclusion and fails the re-check, so it can never be erased.
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

    /// Observation of a CORRUPT marker captured at the START of a resolution
    /// flow. A digest alone can never identify a file instance: another store
    /// can temp-file + atomic-rename a marker carrying the EXACT same corrupt
    /// bytes during the repair (an ABA), and byte equality would then let the
    /// stale resolver erase the newer exclusion. The observation therefore
    /// binds to three independent identities, all re-verified inside the
    /// mutation lock at commit time:
    ///   - `digest` — the corrupt bytes' SHA-512 (content identity),
    ///   - `generation` — the monotonic marker generation `place()` bumps on
    ///     every write (nil when no generation sidecar exists, e.g. a marker
    ///     last written before this mechanism shipped),
    ///   - `fileIdentity` — the directory entry's file-instance identity
    ///     (inode / device / ctime / size); a temp+rename replacement is a
    ///     NEW file even when its bytes are identical.
    /// Any mismatch at commit fails closed: the marker stays, the exclusion
    /// stays, and only a NEW explicit flow that re-observes the live marker
    /// can ever lift it.
    public struct CorruptMarkerObservation: Sendable, Equatable {
        public var digest: String
        public var generation: Int64?
        public var fileIdentity: SidecarFileIdentity

        public init(digest: String, generation: Int64?, fileIdentity: SidecarFileIdentity) {
            self.digest = digest
            self.generation = generation
            self.fileIdentity = fileIdentity
        }
    }

    /// File-instance identity of a marker directory entry, read via stat(2).
    /// An atomic rename replaces the entry with a DIFFERENT inode even when
    /// the bytes are identical, so this (unlike a content digest) tells a
    /// temp+rename ABA replacement from the originally observed file.
    public struct SidecarFileIdentity: Sendable, Equatable {
        public var inode: UInt64
        public var device: UInt64
        public var changeTime: Int64
        public var size: Int64

        public init(inode: UInt64, device: UInt64, changeTime: Int64, size: Int64) {
            self.inode = inode
            self.device = device
            self.changeTime = changeTime
            self.size = size
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
    /// stale resolution's cleanup. Throws — writing NEITHER marker NOR
    /// generation — when the cross-process mutation lock cannot be opened or
    /// acquired (an unlocked atomic publish could race a locked resolver and
    /// be unlinked), or when the marker itself cannot be persisted (full disk /
    /// IO fault). On any such throw callers keep every other surviving
    /// exclusion (the lease) and rely on the preserved bytes as the durable
    /// evidence.
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
            // Atomic temp+rename publish, THEN the generation bump. Any crash
            // between the two leaves a live marker with the previous
            // generation, which only makes the identity checks stricter.
            try Self.encoder.encode(hold).write(to: url, options: .atomic)
            try bumpMarkerGeneration(environmentID: environmentID)
        }
    }

    /// The marker sidecar's CORRUPT-FILE OBSERVATION when the sidecar exists
    /// but does not decode as a hold (a corrupt marker), or nil when there is
    /// no sidecar / it is a valid marker / its file identity cannot be read.
    /// A resolver captures this at the START of a resolution flow and hands
    /// it to `recordResolution`. The observation is NOT just a digest: it
    /// additionally binds to the monotonic `place()` generation and to the
    /// file-instance identity (inode/device/ctime/size), so a newer marker
    /// that temp+rename replaced the entry with the EXACT same corrupt bytes
    /// during the repair (an ABA) is a different file instance and is not
    /// removed by the stale resolver. The guarantee covers cooperating
    /// writers (every `place()`/resolver takes the flock) and path-rename
    /// splices (bytes and inode are read through one fd); it does not stop
    /// a non-cooperating process with directory access that bypasses the
    /// lock — see `recordResolution` for the stated boundary.
    public func corruptMarkerObservation(environmentID: String) -> CorruptMarkerObservation? {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID) else {
            return nil
        }
        // Observed under the mutation lock via a SINGLE fd (open+fstat+read):
        // a cooperating writer that temp+renames during a resolution is
        // serialized, and even a non-cooperating rename cannot splice one
        // file's bytes onto another file's inode inside this observation.
        // If the lock cannot be taken this answers nil (no observation → no
        // removable identity), i.e. it fails closed.
        do {
            return try withMarkerMutationLock(environmentID: environmentID) {
                guard fileManager.fileExists(atPath: url.path),
                      let snapshot = readSidecarInstanceBound(at: url),
                      (try? Self.decoder.decode(Hold.self, from: snapshot.data)) == nil
                else { return nil }
                let digest = try FloeDigest.sha512Hex(snapshot.data)
                return CorruptMarkerObservation(
                    digest: digest,
                    generation: readMarkerGeneration(environmentID: environmentID),
                    fileIdentity: snapshot.identity
                )
            }
        } catch {
            return nil
        }
    }

    /// Per-environment sidecar recording how many times `place()` published a
    /// marker. A monotonic, separately-named file: a temp+rename replacement
    /// of the marker that repeats the identical corrupt bytes cannot repeat a
    /// past generation, because every legitimate `place()` advances it under
    /// the same mutation lock.
    private func markerGenerationURL(environmentID: String) throws -> URL {
        try layout.environmentDirectory(environmentID: environmentID)
            .appendingPathComponent("repair-hold.generation")
    }

    private func readMarkerGeneration(environmentID: String) -> Int64? {
        guard let url = try? markerGenerationURL(environmentID: environmentID),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return value
    }

    private func bumpMarkerGeneration(environmentID: String) throws {
        let url = try markerGenerationURL(environmentID: environmentID)
        let next = (readMarkerGeneration(environmentID: environmentID) ?? 0) &+ 1
        try String(next).data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Serializes every mutation of the marker sidecar (place / guarded
    /// corrupt-marker removal) across store instances AND processes: an
    /// flock(2) exclusive lock on a per-environment lock file, held only for
    /// the tiny critical section. The body runs ONLY when the lock is
    /// actually held; if the lock file cannot be opened or flock fails the
    /// call THROWS before the body runs. This is deliberate: an unlocked
    /// `place()` could rename a new marker over the sidecar while a resolver
    /// (holding the lock) has only just re-checked the old corrupt instance,
    /// after which the resolver's by-path unlink would erase the brand-new
    /// exclusion. Placement therefore fails loudly and writes NOTHING (no
    /// marker, no generation) when the lock is unavailable, and the read-side
    /// observation answers nil. Callers that only remove markers treat the
    /// throw as fail-closed (leave the marker in place).
    private func withMarkerMutationLock<T>(
        environmentID: String, _ body: () throws -> T
    ) throws -> T {
        let directory: URL
        do {
            directory = try layout.environmentDirectory(environmentID: environmentID)
        } catch {
            throw RuntimeV2Error.layoutCorrupt(
                "the repair-hold mutation lock directory for \(environmentID) cannot be resolved; the marker was left untouched"
            )
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".repair-hold.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd != -1 else {
            throw RuntimeV2Error.layoutCorrupt(
                "the repair-hold mutation lock at \(lockPath) cannot be opened; no marker mutation is permitted while the lock is unavailable"
            )
        }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            throw RuntimeV2Error.layoutCorrupt(
                "the repair-hold mutation lock at \(lockPath) cannot be acquired; no marker mutation is permitted without it"
            )
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    /// Bytes + file-instance identity of the marker read through ONE open
    /// file descriptor (`open` → `fstat` → `read` loop). Reading the bytes
    /// by path and stating the path in two steps could splice two file
    /// generations when a temp+rename lands between them (A's bytes paired
    /// with B's inode); the fd binds bytes and stat to the SAME file
    /// instance atomically. This is instance-bound observation, not
    /// path-bound: it cannot be confused by a rename after `open`.
    private struct SidecarSnapshot {
        let data: Data
        let identity: SidecarFileIdentity
    }

    private func readSidecarInstanceBound(at url: URL) -> SidecarSnapshot? {
        let fd = open(url.path, O_RDONLY)
        guard fd != -1 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { return nil }
        // A real marker sidecar is a small JSON document. Bound the read so a
        // corrupt/oversized marker can never become an unbounded allocation:
        // beyond the cap we answer nil (no observation → no removal; the
        // ordinary read path still fails closed on the raw file).
        let maximumMarkerBytes = 1 << 20
        guard status.st_size <= maximumMarkerBytes else { return nil }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let readCount = read(fd, &buffer, chunk)
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readCount == 0 { break }
            data.append(buffer, count: readCount)
            if data.count > maximumMarkerBytes { return nil }
        }
        #if canImport(Darwin)
        let changeTime = Int64(status.st_ctimespec.tv_sec)
        #else
        let changeTime = Int64(status.st_ctim.tv_sec)
        #endif
        return SidecarSnapshot(
            data: data,
            identity: SidecarFileIdentity(
                inode: UInt64(status.st_ino),
                device: UInt64(status.st_dev),
                changeTime: changeTime,
                size: Int64(status.st_size)
            )
        )
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
        observedCorruptMarker: CorruptMarkerObservation? = nil
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
        //   OBSERVED at the start of this very flow, re-verified INSIDE THE
        //   LOCK against THREE identities read through one fd (so bytes and
        //   inode can never be spliced by an intervening rename): byte
        //   digest, the monotonic marker generation, and the file-instance
        //   identity (inode/device/ctime/size). Digest alone cannot do this:
        //   a racing `place()` may temp+rename the entry with byte-identical
        //   corrupt contents (an ABA), which is nevertheless a newer
        //   exclusion with a newer generation and a different inode — any
        //   mismatch leaves it untouched. Removal additionally REQUIRES the
        //   cross-process lock: when it cannot be taken nothing corrupt is
        //   ever deleted (strict fail closed), and without an observation
        //   nothing is removed, since a corrupt marker carries no holdID.
        // - When the live marker is the resolved instance A itself, a
        //   best-effort COPY to the evidence archive is made (never a move).
        //
        // Honest boundary: flock is cooperative. The single-fd observation
        // and the generation/inode/digest re-check are atomic against every
        // cooperating `place()`/resolver (all take this lock), but a
        // non-cooperating writer with directory access that bypasses the
        // lock and renames over the entry in the tiny window between the
        // locked re-check and the unlink cannot be excluded by userspace
        // alone; such a writer already owns the on-disk exclusion. This is
        // documented, not claimed as provably impossible.
        // The resolution record above is already the durable commit; the
        // marker handling below is best effort and must never un-commit it.
        // The helper only runs the body while holding the flock (it throws
        // otherwise), and a throw here simply leaves the corrupt marker in
        // place — the read side keeps excluding and a later retry lifts it.
        try? withMarkerMutationLock(environmentID: environmentID) {
            guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
                  fileManager.fileExists(atPath: url.path),
                  let snapshot = readSidecarInstanceBound(at: url)
            else { return }
            if let marker = try? Self.decoder.decode(Hold.self, from: snapshot.data) {
                if let resolvedHoldID, !resolvedHoldID.isEmpty, marker.holdID == resolvedHoldID {
                    let destination = archive.appendingPathComponent(
                        "repair-hold-\(environmentID)-\(stamp).json"
                    )
                    try? snapshot.data.write(to: destination, options: .atomic)
                }
                return
            }
            // The body only ever runs while the flock is held, so a corrupt
            // marker is removed solely when the observed instance is proven
            // still live via digest + generation + inode.
            guard let observed = observedCorruptMarker else { return }
            let liveGeneration = readMarkerGeneration(environmentID: environmentID)
            let liveDigest = try? FloeDigest.sha512Hex(snapshot.data)
            guard liveDigest == observed.digest,
                  liveGeneration == observed.generation,
                  snapshot.identity == observed.fileIdentity
            else { return }
            // The flock excludes every cooperating replacement and the
            // single-fd re-check binds these exact bytes to this inode; the
            // remaining non-cooperating window is documented above.
            try? fileManager.removeItem(at: url)
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
