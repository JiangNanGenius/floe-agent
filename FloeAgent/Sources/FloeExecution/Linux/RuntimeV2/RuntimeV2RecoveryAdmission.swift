// Fixed legacy-domain participation for synchronous and asynchronous native IO.
// The coordinator remains the authority. This gate merely closes the synchronous
// admission gap before its first await; it never waits for maintenance on the UI.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

public struct RuntimeV2RecoveryAdmissionSnapshot: Sendable, Equatable {
    public let incarnation: String
    public let sourceGeneration: UInt64
    public let liveUses: Int
    public let intentID: String?
    public let coverageComplete: Bool
}

public enum RuntimeV2RecoveryAdmission {
    final class Gate: @unchecked Sendable {
        let lock = NSLock()
        let root: URL
        let lockURL: URL
        let intentURL: URL
        let intentURLs: [URL]
        let historyLayout: RuntimeV2MaintenanceHistoryLayout?
        let incarnation = UUID().uuidString
        var generation: UInt64 = 0
        var liveUses = 0
        var intentID: String?
        var recoveryBlocked: Bool
        var coverageComplete: Bool

        init(root: URL, stateDirectory: URL, recoveryBlocked: Bool, coverageComplete: Bool,
             historyLayout: RuntimeV2MaintenanceHistoryLayout? = nil) {
            self.root = root
            self.historyLayout = historyLayout
            self.lockURL = historyLayout?.anchor ?? stateDirectory.appendingPathComponent("maintenance.lock")
            self.intentURL = stateDirectory.appendingPathComponent("intent.json")
            self.intentURLs = (historyLayout?.directories ?? [stateDirectory]).map { $0.appendingPathComponent("intent.json") }
            self.recoveryBlocked = recoveryBlocked
            self.coverageComplete = coverageComplete
        }

        func snapshot() -> RuntimeV2RecoveryAdmissionSnapshot {
            lock.lock(); defer { lock.unlock() }
            return .init(incarnation: incarnation, sourceGeneration: generation,
                         liveUses: liveUses, intentID: intentID, coverageComplete: coverageComplete)
        }

        func beginExclusive(_ id: String, recovery: Bool) throws {
            lock.lock(); defer { lock.unlock() }
            guard intentID == nil, liveUses == 0, recovery || !recoveryBlocked else {
                throw RuntimeV2MaintenanceError.maintenanceActive("native recovery IO is still owned")
            }
            intentID = id
        }

        /// Atomically switch the active recovery intent while the SAME
        /// all-history lock set remains held. There is no admission-open gap.
        func advanceRecoveryIntent(from previous: String, to next: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard intentID == previous, liveUses == 0 else {
                throw RuntimeV2MaintenanceError.claimInvalidated("native recovery handoff changed")
            }
            if previous != next { intentID = next; generation &+= 1 }
        }

        func endExclusive(_ id: String, converged: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard intentID == id else { return }
            intentID = nil
            recoveryBlocked = !converged
        }

        func sourcesChanged() {
            lock.lock(); defer { lock.unlock() }
            generation &+= 1
        }

        func preserveUnknownNativeOwner() {
            lock.lock(); defer { lock.unlock() }
            coverageComplete = false
            recoveryBlocked = true
            generation &+= 1
        }

        func confirmNoBlockingIntent() {
            lock.lock(); defer { lock.unlock() }
            if intentID == nil { recoveryBlocked = false }
        }

        func acquire() throws -> RuntimeV2RecoveryUse {
            #if canImport(Darwin)
            lock.lock(); defer { lock.unlock() }
            guard intentID == nil, !recoveryBlocked else {
                throw RuntimeV2MaintenanceError.maintenanceActive("legacy maintenance admission is closed")
            }
            if let historyLayout {
                let cohort = try RuntimeV2MaintenanceHistoryLocks.acquire(historyLayout, operation: LOCK_SH)
                let fd = try cohort.duplicateAnchor()
                do { try refuseBlockingIntents() }
                catch { close(fd); throw error }
                liveUses += 1; generation &+= 1
                return RuntimeV2RecoveryUse(gate: self, descriptor: fd, historyLocks: cohort)
            }
            // Same inode/flock as the coordinator; no second lock namespace.
            let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else {
                throw RuntimeV2MaintenanceError.crossProcessOwner("native use lock unavailable")
            }
            var info = stat(); var named = stat()
            guard fstat(fd, &info) == 0, lstat(lockURL.path, &named) == 0,
                  info.st_dev == named.st_dev, info.st_ino == named.st_ino,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  flock(fd, LOCK_SH | LOCK_NB) == 0 else {
                close(fd)
                throw RuntimeV2MaintenanceError.crossProcessOwner("native use lock changed or busy")
            }
            do { try refuseBlockingIntents() }
            catch { close(fd); throw error }
            liveUses += 1
            generation &+= 1
            return RuntimeV2RecoveryUse(gate: self, descriptor: fd)
            #else
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["native_admission_unsupported"])
            #endif
        }

        private func refuseBlockingIntents() throws {
            for url in intentURLs { try refuseBlockingIntent(at: url) }
        }

        private func refuseBlockingIntent(at intentURL: URL) throws {
            #if canImport(Darwin)
            let fd = open(intentURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0 {
                if errno == ENOENT {
                    guard historyLayout?.historicalDirectories.contains(intentURL.deletingLastPathComponent()) != true else {
                        throw RuntimeV2MaintenanceError.recoveryPending("retained historical intent disappeared")
                    }
                    return
                }
                throw RuntimeV2MaintenanceError.recoveryPending("durable intent unreadable")
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= 65_536 else {
                throw RuntimeV2MaintenanceError.recoveryPending("durable intent shape unknown")
            }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let count = bytes.withUnsafeMutableBytes {
                    read(fd, $0.baseAddress!.advanced(by: offset), remaining)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw RuntimeV2MaintenanceError.recoveryPending("durable intent changed")
                }
                offset += count
            }
            if let historyLayout {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let record = try? decoder.decode(RuntimeV2MaintenanceIntentRecord.self, from: Data(bytes)),
                      record.version == RuntimeV2MaintenanceIntentRecord.currentVersion,
                      historyLayout.domain.matchesRecordedRoot(record.domainRoot,
                        device: record.domainDevice, inode: record.domainInode) else {
                    throw RuntimeV2MaintenanceError.recoveryPending("historical intent identity is unverified")
                }
            }
            struct Header: Decodable { let phase: RuntimeV2MaintenanceIntentRecord.Phase }
            guard let header = try? JSONDecoder().decode(Header.self, from: Data(bytes)),
                  !header.phase.isBlocking else {
                throw RuntimeV2MaintenanceError.recoveryPending("durable intent blocks native use")
            }
            #endif
        }

        func released() {
            lock.lock(); defer { lock.unlock() }
            liveUses -= 1
            generation &+= 1
        }
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var gates: [String: Gate] = [:]
        var rootsObservedBeforeInstall: Set<String> = []
    }
    private static let registry = Registry()

    static func key(_ root: URL) -> String {
        #if canImport(Darwin)
        if let resolved = root.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        #endif
        return root.standardizedFileURL.path
    }

    static func gate(_ root: URL) -> Gate? {
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.gates[key(root)]
    }

    /// Called when a layout capability is constructed. This is a discovery
    /// epoch only, never a live-use count and never an inferred worker close.
    static func observeLayout(_ root: URL) {
        let path = key(root)
        guard RuntimeV2MaintenanceDomain.trustedLegacyRoot().map({ key($0) }) == path else { return }
        registry.lock.lock(); defer { registry.lock.unlock() }
        if registry.gates[path] == nil { registry.rootsObservedBeforeInstall.insert(path) }
    }

    static func install(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL, recoveryBlocked: Bool,
                        historyLayout: RuntimeV2MaintenanceHistoryLayout? = nil) {
        guard RuntimeV2MaintenanceDomain.trustedLegacyRoot().map({ key($0) }) == key(domain.root) else { return }
        installBoundDomain(domain: domain, stateDirectory: stateDirectory, recoveryBlocked: recoveryBlocked, historyLayout: historyLayout)
    }

    #if DEBUG
    static func installSyntheticDomainForTests(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL,
                                              historyLayout: RuntimeV2MaintenanceHistoryLayout? = nil) {
        installBoundDomain(domain: domain, stateDirectory: stateDirectory, recoveryBlocked: false, historyLayout: historyLayout)
    }
    #endif

    private static func installBoundDomain(domain: RuntimeV2MaintenanceDomain, stateDirectory: URL,
                                          recoveryBlocked: Bool, historyLayout: RuntimeV2MaintenanceHistoryLayout? = nil) {
        let path = key(domain.root)
        registry.lock.lock(); defer { registry.lock.unlock() }
        if registry.gates[path] != nil { return }
        registry.gates[path] = Gate(root: domain.root, stateDirectory: stateDirectory,
                                   recoveryBlocked: recoveryBlocked,
                                   coverageComplete: !registry.rootsObservedBeforeInstall.contains(path), historyLayout: historyLayout)
    }

    public static func snapshot(root: URL) throws -> RuntimeV2RecoveryAdmissionSnapshot {
        guard let gate = gate(root) else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["native_admission_not_installed"])
        }
        return gate.snapshot()
    }

    public static func ownerSourcesChanged(root: URL) { gate(root)?.sourcesChanged() }

    /// No legacy use can silently bypass a missing registration. Other roots
    /// (production arm64-v1 and resident ARM64) have no gate and are unaffected.
    static func acquire(root: URL) throws -> RuntimeV2RecoveryUse? {
        if let gate = gate(root) { return try gate.acquire() }
        if RuntimeV2MaintenanceDomain.trustedLegacyRoot().map({ key($0) }) == key(root) {
            throw RuntimeV2MaintenanceError.recoveryPending("legacy bootstrap not installed")
        }
        return nil
    }
}

/// Held from before the native operation opens anything until every handle in
/// its body has closed. It has no TTL; a real VM uses the coordinator's longer
/// session claim, which is retained through failed-stop quarantine and join.
final class RuntimeV2RecoveryUse: @unchecked Sendable {
    private let gate: RuntimeV2RecoveryAdmission.Gate
    private let lock = NSLock()
    private var descriptor: Int32
    private var historyLocks: RuntimeV2MaintenanceHistoryLocks?
    init(gate: RuntimeV2RecoveryAdmission.Gate, descriptor: Int32, historyLocks: RuntimeV2MaintenanceHistoryLocks? = nil) {
        self.gate = gate; self.descriptor = descriptor; self.historyLocks = historyLocks
    }
    deinit { release() }
    func release() {
        lock.lock()
        let fd = descriptor; descriptor = -1
        historyLocks = nil
        lock.unlock()
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        close(fd)
        #endif
        gate.released()
    }
    func preserveUnknownNativeOwner() {
        gate.preserveUnknownNativeOwner()
        release()
    }
}

extension RuntimeV2Layout {
    func beginNativeRecoveryUse() throws -> RuntimeV2RecoveryUse? {
        try RuntimeV2RecoveryAdmission.acquire(root: root)
    }
}
