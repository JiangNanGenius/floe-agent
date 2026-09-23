// FloeExecution — Runtime v2 durable single-writer leases.
//
// A lease is the single writable ownership of one environment's system delta
// and working disk. It is NOT an "activeVMID is truth" flag: runtime truth
// always comes from the live engine (isRunning); the lease only decides who
// may write. Each lease records the owning runtimeID, the process incarnation
// (a boot token unique to this app launch), a per-session token, the holder
// pid and renewal timestamps with a TTL.
//
// Durability: the lease is a repairable sidecar (environments/<id>/lease.json)
// mirrored in the registry's leases table. Reclaiming a stale lease requires
// proof the old owner is gone — the recorded pid is dead AND the lease is
// past its TTL without renewal AND the caller supplies a host-side proof that
// no live session/thread/disk handle still references the environment. A
// corrupt lease file is quarantined (never parsed partially, never deleted),
// and recovery scans at app start mark leftover leases interrupted instead of
// silently adopting them.

import Foundation
import FloeCore

public actor RuntimeV2LeaseStore {
    public struct Lease: Codable, Sendable, Equatable {
        public var version: Int
        public var environmentID: String
        public var runtimeID: String
        /// Boot token of the holding process incarnation (new per app launch).
        public var incarnation: String
        /// Unique token of this particular run/session of the environment.
        public var sessionToken: String
        public var pid: Int64
        public var acquiredAt: Date
        public var renewedAt: Date
        public var ttlSeconds: Int64

        public static let currentVersion = 1

        public init(
            environmentID: String, runtimeID: String, incarnation: String,
            sessionToken: String, pid: Int64, acquiredAt: Date, renewedAt: Date, ttlSeconds: Int64
        ) {
            self.version = Lease.currentVersion
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.incarnation = incarnation
            self.sessionToken = sessionToken
            self.pid = pid
            self.acquiredAt = acquiredAt
            self.renewedAt = renewedAt
            self.ttlSeconds = ttlSeconds
        }

        public func isExpired(now: Date) -> Bool {
            now.timeIntervalSince(renewedAt) > TimeInterval(ttlSeconds)
        }
    }

    public struct HeldLease: Sendable {
        public let lease: Lease
        private let releaseClosure: @Sendable () async -> Void
        private let renewClosure: @Sendable () async -> Void

        init(lease: Lease, release: @escaping @Sendable () async -> Void, renew: @escaping @Sendable () async -> Void) {
            self.lease = lease
            self.releaseClosure = release
            self.renewClosure = renew
        }

        public func renew() async { await renewClosure() }
        public func release() async { await releaseClosure() }
    }

    /// Proof that the previous holder of a lease is really gone: no live VM,
    /// no run thread, no open disk handle. The production integration answers
    /// this from the guest registry's session state plus pid liveness; tests
    /// inject scripted answers.
    public typealias StaleProof = @Sendable (Lease) async -> Bool

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private let repairHolds: RuntimeV2RepairHoldStore
    private let seams: Seams
    private var fileManager: FileManager { .default }
    /// This process's boot token; leases from other incarnations are
    /// reclaimable only with stale proof.
    public let incarnation: String
    public var defaultTTL: Int64 = 30

    /// Injectable fault seams for the durability-critical paths.
    public struct Seams: Sendable {
        /// Replaces the durable registry release (throw to inject a
        /// full-disk / IO / DB fault at exactly that stage). nil = normal.
        public var releaseInRegistry: (@Sendable (String, String) async throws -> Void)?

        public init(releaseInRegistry: (@Sendable (String, String) async throws -> Void)? = nil) {
            self.releaseInRegistry = releaseInRegistry
        }

        public static let production = Seams()
    }

    public init(
        layout: RuntimeV2Layout,
        registry: RuntimeV2Registry,
        incarnation: String = UUID().uuidString,
        seams: Seams = .production,
        repairHolds: RuntimeV2RepairHoldStore? = nil
    ) {
        self.layout = layout
        self.registry = registry
        self.incarnation = incarnation
        self.seams = seams
        self.repairHolds = repairHolds ?? RuntimeV2RepairHoldStore(layout: layout)
    }

    // MARK: acquire / renew / release

    /// Acquires the single-writer lease for an environment. Re-entrant for the
    /// same runtimeID. Refuses while a live holder exists; reclaims a stale
    /// holder only when `staleProof` confirms the old VM/thread/disk handle
    /// is gone.
    @discardableResult
    public func acquire(
        environmentID: String,
        runtimeID: String,
        staleProof: StaleProof? = nil
    ) async throws -> HeldLease {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        try RuntimeV2Identifier.validate(runtimeID, kind: .runtime)

        // The durable repair exclusion is consulted BEFORE any lease logic,
        // including stale-lease reclamation: the exclusion never expires and
        // names preserved bytes a fresh start must never overwrite, so the
        // TTL-based reclaim below can never clear it. The consult is the
        // coherent physical-evidence one (marker sidecar — valid or corrupt —
        // or the preserved bytes themselves), not the marker alone, so a
        // sustained full-disk/IO fault that killed the original marker write
        // can still never make the environment reclaimable.
        if let hold = await effectiveExclusion(environmentID: environmentID) {
            throw RuntimeV2Error.environmentRepairRequired(
                environmentID: environmentID, reason: hold.reason
            )
        }

        if let existing = try loadLease(environmentID: environmentID) {
            if existing.runtimeID == runtimeID {
                let renewed = touch(existing)
                try await persist(renewed)
                return handle(for: renewed)
            }
            // Reclaim requires proof the old VM/thread/disk handle is gone.
            // A caller proof (registry: no live session for this environment)
            // is decisive; without one, the default proof requires BOTH a
            // dead recorded pid AND an expired TTL.
            let holderGone = await (staleProof?(existing) ?? false)
                || (existing.isExpired(now: Date()) && Self.processLiveness(lease: existing))
            guard holderGone else {
                throw RuntimeV2Error.leaseHeld(environmentID: environmentID, runtimeID: existing.runtimeID)
            }
            // Proven stale: archive the old lease (bounded recovery evidence),
            // then take ownership. Never deleted outright.
            try await registry.markLeaseStale(environmentID: environmentID)
            archiveLease(existing, environmentID: environmentID)
        }

        let lease = Lease(
            environmentID: environmentID,
            runtimeID: runtimeID,
            incarnation: incarnation,
            sessionToken: UUID().uuidString,
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            acquiredAt: Date(),
            renewedAt: Date(),
            ttlSeconds: defaultTTL
        )
        try await persist(lease)
        return handle(for: lease)
    }

    private func handle(for lease: Lease) -> HeldLease {
        HeldLease(
            lease: lease,
            release: { [weak self] in
                await self?.release(environmentID: lease.environmentID, runtimeID: lease.runtimeID)
            },
            renew: { [weak self] in
                try? await self?.renew(environmentID: lease.environmentID, runtimeID: lease.runtimeID)
            }
        )
    }

    public func renew(environmentID: String, runtimeID: String) async throws {
        guard let lease = try loadLease(environmentID: environmentID),
              lease.runtimeID == runtimeID else {
            throw RuntimeV2Error.leaseNotHeld(environmentID: environmentID)
        }
        try await persist(touch(lease))
    }

    /// Durable-first release: the sidecar is the surviving exclusion record,
    /// so it is removed ONLY after the registry release commits. When the
    /// durable release fails (full disk / IO / DB fault), the sidecar stays:
    /// a failed or partial release can never clear the sole exclusion that
    /// keeps a new start from overwriting preserved state. The registry row
    /// keeps naming this runtime as its holder, and a later launch re-proves
    /// staleness before any reclaim.
    public func release(environmentID: String, runtimeID: String) async {
        guard let lease = try? loadLease(environmentID: environmentID),
              lease.runtimeID == runtimeID else { return }
        do {
            if let releaseInRegistry = seams.releaseInRegistry {
                try await releaseInRegistry(environmentID, runtimeID)
            } else {
                try await registry.releaseLease(environmentID: environmentID, runtimeID: runtimeID)
            }
        } catch {
            return
        }
        if let url = try? layout.environmentLeaseURL(environmentID: environmentID) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Current holder, if any.
    public func holder(environmentID: String) throws -> Lease? {
        try loadLease(environmentID: environmentID)
    }

    /// True while the environment's lease cannot be proven stale: a lease
    /// sidecar exists whose recorded pid is still alive OR whose TTL has not
    /// expired. Recovery MUST NOT capture, move or delete that environment's
    /// working disk while this is true — the owner is a live process (another
    /// app instance, or a session of this one), and the only safe action is
    /// to leave every byte untouched. A dead pid past TTL is provably stale
    /// and answers false.
    public func hasLiveOwnership(environmentID: String) async -> Bool {
        guard let lease = try? loadLease(environmentID: environmentID) else { return false }
        return !(lease.isExpired(now: Date()) && Self.processLiveness(lease: lease))
    }

    // MARK: coherent repair-exclusion consult
    //
    // One physical-evidence / repair-exclusion protocol, answered the same way
    // at every decision point (acquire, stale-lease reclamation, salvage,
    // working-disk preparation, legacy migration). The consult is read-only
    // and answers from the filesystem alone: it stays true across process
    // death, TTL expiry and sustained IO/DB faults even when no new marker or
    // registry write can succeed.

    /// True while ANY durable evidence excludes the environment from fresh
    /// boots, lease reclamation and salvage: the marker sidecar (valid or
    /// corrupt), preserved quarantine bytes, or an untracked working disk.
    /// `ignoringRuntimeEntry` excludes one runtime/vm directory name from the
    /// working-disk scan: recovery uses it while evaluating that very
    /// directory, which can never be evidence against itself.
    public func excludes(
        environmentID: String, ignoringRuntimeEntry: String? = nil
    ) async -> Bool {
        await effectiveExclusion(environmentID: environmentID, ignoringRuntimeEntry: ignoringRuntimeEntry) != nil
    }

    /// The excluding hold, or nil: the marker sidecar first (a corrupt one
    /// answers a synthesized unreadable hold and STAYS in place), then the
    /// durable physical evidence.
    public func effectiveExclusion(
        environmentID: String, ignoringRuntimeEntry: String? = nil
    ) async -> RuntimeV2RepairHoldStore.Hold? {
        if let hold = await repairHolds.effectiveHold(environmentID: environmentID) { return hold }
        if await untrackedWorkingDirectoryEvidence(
            environmentID: environmentID, ignoring: ignoringRuntimeEntry
        ) {
            return RuntimeV2RepairHoldStore.Hold(
                environmentID: environmentID, runtimeID: "",
                reason: "an untracked working disk for this environment exists under runtime/vm while no live lease accounts for it; the environment stays excluded until repair is explicitly resolved",
                preservedPath: nil, createdAt: .distantPast, holdID: ""
            )
        }
        return nil
    }

    /// Physical working-directory evidence: a runtime/vm directory that names
    /// this environment (through its ownership record, or through a lease
    /// trace when the record is unreadable) while the environment has no live
    /// lease is a disk whose latest state recovery could not account for — a
    /// fresh boot would silently lose its newest writes. Directories owned by
    /// a live lease (the normal in-flight session) are never evidence.
    private func untrackedWorkingDirectoryEvidence(
        environmentID: String, ignoring: String?
    ) async -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: layout.runtimeVMDirectory.path)
        else { return false }
        for entry in entries where !entry.hasPrefix(".") && entry != ignoring {
            let directory = layout.runtimeVMDirectory.appendingPathComponent(entry, isDirectory: true)
            let owner: String?
            if let meta = RuntimeV2WorkingDirectory.readMeta(from: directory) {
                owner = meta.environmentID
            } else {
                // Unreadable ownership record: attribute by directory
                // runtimeID through the same lease sidecars / registry /
                // archive trace recovery uses.
                owner = await lease(forRuntimeID: entry)?.environmentID
            }
            guard let owner, owner == environmentID,
                  (try? RuntimeV2Identifier.validate(owner, kind: .environment)) != nil,
                  await !hasLiveOwnership(environmentID: environmentID)
            else { continue }
            return true
        }
        return false
    }

    /// Ownership lookup BY RUNTIME id (the runtime/vm directory name), for
    /// recovery of a working disk whose own runtime.json is missing or
    /// unparseable: the lease sidecars and the registry lease table are the
    /// only durable links from a runtime id back to its environment. Sidecars
    /// are authoritative (they survive a registry fault); a sidecar that
    /// cannot be decoded is quarantined like any corrupt lease, never
    /// half-trusted. nil means no ownership trace exists anywhere.
    public func lease(forRuntimeID runtimeID: String) async -> Lease? {
        let root = layout.environmentsDirectory
        if let entries = try? fileManager.contentsOfDirectory(atPath: root.path) {
            for entry in entries {
                let url = root.appendingPathComponent(entry, isDirectory: true)
                    .appendingPathComponent("lease.json")
                guard fileManager.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let lease = try? Self.decoder.decode(Lease.self, from: data),
                      lease.version == Lease.currentVersion else { continue }
                if lease.runtimeID == runtimeID { return lease }
            }
        }
        // The registry lease table is the secondary trace (e.g. the sidecar
        // was lost but the durable row survived).
        if let rows = try? await registry.heldLeases() {
            for row in rows where row.runtimeID == runtimeID {
                return Lease(
                    environmentID: row.environmentID, runtimeID: row.runtimeID,
                    incarnation: row.incarnation, sessionToken: row.sessionToken,
                    pid: row.pid, acquiredAt: row.acquiredAt, renewedAt: row.renewedAt,
                    ttlSeconds: row.ttlSeconds
                )
            }
        }
        // Reclaimed stale leases are archived, never deleted — the archive is
        // the durable attribution trace for a runtime whose sidecar was
        // already reclaimed by an earlier recovery pass.
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("stale-leases", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(atPath: archive.path) {
            for entry in entries where entry.hasPrefix("lease-") {
                guard let data = try? Data(contentsOf: archive.appendingPathComponent(entry)),
                      let lease = try? Self.decoder.decode(Lease.self, from: data),
                      lease.version == Lease.currentVersion,
                      lease.runtimeID == runtimeID else { continue }
                return lease
            }
        }
        return nil
    }

    // MARK: startup recovery

    /// Scans every lease sidecar after an app restart. Leases from a dead
    /// incarnation with a dead pid past TTL are reclaimed (archived, row
    /// marked stale, file removed); leases that cannot be proven stale stay
    /// and their environments are reported so the caller can mark them
    /// interrupted/quarantined. Corrupt files are quarantined.
    @discardableResult
    public func recoverOnLaunch(staleProof: StaleProof? = nil) async throws -> [String] {
        var unresolved: [String] = []
        let root = layout.environmentsDirectory
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        for entry in entries {
            let leaseURL = root.appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent("lease.json")
            guard fileManager.fileExists(atPath: leaseURL.path) else { continue }
            let environmentID = entry
            let lease: Lease
            do {
                lease = try Self.decoder.decode(Lease.self, from: Data(contentsOf: leaseURL))
                guard lease.version == Lease.currentVersion, lease.environmentID == environmentID else {
                    throw RuntimeV2Error.registryCorrupt("lease environment mismatch")
                }
            } catch {
                let quarantine = layout.quarantineDirectory
                    .appendingPathComponent("lease-\(environmentID)-\(UUID().uuidString).json")
                try? fileManager.moveItem(at: leaseURL, to: quarantine)
                try? await registry.markLeaseStale(environmentID: environmentID)
                continue
            }
            if lease.incarnation == incarnation {
                continue // our own live lease (re-attach path)
            }
            // The coherent physical-evidence repair exclusion outranks even a
            // provably stale lease: the exclusion names preserved bytes whose
            // owner is NOT proven accounted for, so the lease sidecar stays as
            // evidence and the environment is reported unresolved instead of
            // being reclaimed. This scan runs at the reclaim decision point,
            // BEFORE any reclamation, and answers from the filesystem alone —
            // a sustained IO/DB fault that keeps the marker/registry writes
            // dead can never make the environment reclaimable while the
            // preserved bytes (or an untracked working disk) exist.
            if await excludes(environmentID: environmentID) {
                unresolved.append(environmentID)
                continue
            }
            let gone = await (staleProof?(lease) ?? false)
                || (lease.isExpired(now: Date()) && Self.processLiveness(lease: lease))
            if gone {
                try? await registry.markLeaseStale(environmentID: environmentID)
                archiveLease(lease, environmentID: environmentID)
                try? fileManager.removeItem(at: leaseURL)
            } else {
                unresolved.append(environmentID)
            }
        }
        return unresolved
    }

    // MARK: persistence

    private func loadLease(environmentID: String) throws -> Lease? {
        let url = try layout.environmentLeaseURL(environmentID: environmentID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let lease = try Self.decoder.decode(Lease.self, from: Data(contentsOf: url))
            guard lease.version == Lease.currentVersion else { return nil }
            return lease
        } catch {
            // Repairable sidecar: a corrupt lease is never half-trusted.
            let quarantine = layout.quarantineDirectory
                .appendingPathComponent("lease-\(environmentID)-\(UUID().uuidString).json")
            try? fileManager.moveItem(at: url, to: quarantine)
            return nil
        }
    }

    private func touch(_ lease: Lease) -> Lease {
        var copy = lease
        copy.renewedAt = Date()
        return copy
    }

    private func persist(_ lease: Lease) async throws {
        let url = try layout.environmentLeaseURL(environmentID: lease.environmentID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(lease).write(to: url, options: .atomic)
        try await registry.recordLease(
            RuntimeV2Registry.LeaseRow(
                environmentID: lease.environmentID,
                runtimeID: lease.runtimeID,
                incarnation: lease.incarnation,
                sessionToken: lease.sessionToken,
                pid: lease.pid,
                acquiredAt: lease.acquiredAt,
                renewedAt: lease.renewedAt,
                ttlSeconds: lease.ttlSeconds,
                state: "held"
            )
        )
    }

    private func archiveLease(_ lease: Lease, environmentID: String) {
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("stale-leases", isDirectory: true)
        try? fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let destination = archive.appendingPathComponent(
            "lease-\(environmentID)-\(lease.runtimeID)-\(Int(lease.acquiredAt.timeIntervalSince1970)).json"
        )
        try? Self.encoder.encode(lease).write(to: destination, options: .atomic)
    }

    /// Default cross-process liveness proof: the recorded pid must be dead.
    /// In-process proofs (no live session/thread/handle) are supplied by the
    /// integration through StaleProof; both must hold before reclaim.
    public static func processLiveness(lease: Lease) -> Bool {
        kill(pid_t(lease.pid), 0) != 0 && errno == ESRCH
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
