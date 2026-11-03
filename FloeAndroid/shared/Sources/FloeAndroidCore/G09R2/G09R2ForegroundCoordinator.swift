// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — bounded cloud-generation foreground admission and native lease
// proof.
//
// The Android App owns the actual `dataSync` foreground service and its
// notification. This file owns only the bounded native side of that
// ownership:
//
//  * a pending admission record created BEFORE a paid provider request; the
//    worker waits for the App host to confirm that a REAL foreground owner
//    (started for this exact native job + generation) is live;
//  * a bounded lease registry keyed by the actual durable `MediaGenerationJob`
//    UUID and the accepted generation epoch; the host can register/release a
//    lease only through the private trusted-host C ABI below;
//  * an exact job/epoch/token proof used by the host's notification Cancel and
//    timeout pump. A UI editor token, a client path/root or an Intent extra
//    never authorizes a lease;
//  * a lock-only progress/state projection for the notification. No project,
//    task or second job database is introduced here.
//
// Honest admission: a denied foreground start never dispatches the provider
// call. A worker that is cancelled or loses its lease aborts its HTTP/download
// path and never publishes a late candidate after Root stop.
import Foundation
import FloeCore
import FloePersistence

/// Exact native job identity a host foreground lease is bound to.
public struct G09R2ForegroundLease: Sendable, Equatable {
    public var jobID: String
    public var epoch: UInt64
    public var projectID: UUID
    public var token: String
    public var kind: G09R2GenerationKind
    public var progress: Double?
}

public enum G09R2ForegroundAdmission: Sendable, Equatable {
    case confirmed(G09R2ForegroundLease)
    case denied(String)
    case cancelled
    case timedOut

    public var lease: G09R2ForegroundLease? {
        if case .confirmed(let lease) = self { return lease }
        return nil
    }
}

public struct G09R2ForegroundJobSnapshot: Sendable, Equatable {
    public var jobID: String
    public var epoch: UInt64
    public var state: String
    public var terminal: Bool
    public var progress: Double?
    public var hasProviderTask: Bool
}

/// Process-wide bounded foreground proof for the App's generation pump.
/// This is deliberately NOT a job store: the durable truth stays in
/// `MediaGenerationJobStore`; only the live ownership proof lives here.
public final class G09R2ForegroundCoordinator: @unchecked Sendable {
    public static let shared = G09R2ForegroundCoordinator()

    /// Maximum simultaneous live leases mirrors the generation worker cap.
    public static let maximumLeases = 8
    /// Bounded wait for the App host to confirm a real foreground owner.
    /// The worker is already durable and the submit handle is returned before
    /// this wait; a denial/timeout is a definite local precondition failure.
    public static let admissionTimeoutSeconds: TimeInterval = 20
    /// A denial remains readable long enough for the worker to observe it.
    static let denialRetentionSeconds: TimeInterval = 30

    public struct Denial: Sendable {
        var reason: String
        var expiresAt: Date
    }

    private struct Key: Hashable {
        var jobID: String
        var epoch: UInt64
    }

    private let lock = NSLock()
    private var leases: [Key: G09R2ForegroundLease] = [:]
    private var denials: [Key: Denial] = [:]

    public init() {}

    private func key(_ jobID: String, _ epoch: UInt64) -> Key {
        Key(jobID: jobID.lowercased(), epoch: epoch)
    }

    public static func validToken(_ raw: String) -> Bool {
        guard (1...64).contains(raw.utf8.count) else { return false }
        return raw.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_"
                || $0 == "-"
        }
    }

    public static func validJobID(_ raw: String) -> UUID? {
        guard raw.utf8.count == 36, let id = UUID(uuidString: raw) else {
            return nil
        }
        return id
    }

    // MARK: - Pending admission (worker side)

    /// Waits for the host's confirmed foreground lease for this EXACT durable
    /// job + epoch. Called before the paid provider request. Root-stop
    /// cancellation wins over a late host confirmation.
    public func awaitAdmission(
        jobID: String, epoch: UInt64, projectID: UUID,
        kind: G09R2GenerationKind,
        timeout: TimeInterval = G09R2ForegroundCoordinator.admissionTimeoutSeconds
    ) async -> G09R2ForegroundAdmission {
        let normalized = jobID.lowercased()
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while true {
            if Task.isCancelled {
                return .cancelled
            }
            if G09R2GenerationService.shared.isRootStopping(epoch: epoch) {
                return .cancelled
            }
            let (lease, denial) = admissionState(
                jobID: normalized, epoch: epoch)
            if let lease, lease.projectID == projectID, lease.kind == kind {
                return .confirmed(lease)
            }
            if let denial, denial.expiresAt > Date() {
                return .denied(denial.reason)
            }
            if Date() >= deadline {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func admissionState(
        jobID: String, epoch: UInt64
    ) -> (G09R2ForegroundLease?, Denial?) {
        lock.lock(); defer { lock.unlock() }
        return (leases[key(jobID, epoch)], denials[key(jobID, epoch)])
    }

    // MARK: - Host registration (validated by the caller)

    /// Registers a confirmed host lease after the App service reported a real
    /// `startForeground` success. `validateForHost` below is the DB-backed
    /// proof used by the trusted C ABI; tests may call this directly with a
    /// fixture job.
    @discardableResult
    public func registerLease(
        jobID: String, epoch: UInt64, projectID: UUID, token: String,
        kind: G09R2GenerationKind
    ) -> Bool {
        guard epoch > 0, Self.validJobID(jobID) != nil,
              Self.validToken(token) else { return false }
        lock.lock(); defer { lock.unlock() }
        let normalized = jobID.lowercased()
        guard leases.count < Self.maximumLeases else { return false }
        let now = Date()
        denials = denials.filter { $0.value.expiresAt > now }
        leases[key(normalized, epoch)] = G09R2ForegroundLease(
            jobID: normalized, epoch: epoch, projectID: projectID,
            token: token, kind: kind, progress: nil)
        denials.removeValue(forKey: key(normalized, epoch))
        return true
    }

    /// Registers a definite foreground admission denial. The pending worker
    /// fails without dispatching a provider call.
    public func denyAdmission(
        jobID: String, epoch: UInt64, reason: String
    ) {
        guard epoch > 0, Self.validJobID(jobID) != nil else { return }
        let bounded = String(reason.prefix(32))
        lock.lock()
        let now = Date()
        denials = denials.filter { $0.value.expiresAt > now }
        denials[key(jobID, epoch)] = Denial(
            reason: bounded.isEmpty ? "foregroundUnavailable" : bounded,
            expiresAt: now.addingTimeInterval(Self.denialRetentionSeconds))
        lock.unlock()
    }

    /// Releases one exact host lease. Returns false when the token does not
    /// own that job/epoch (a stale or foreign notification cannot release it).
    @discardableResult
    public func releaseLease(
        jobID: String, epoch: UInt64, token: String
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let lookup = key(jobID, epoch)
        guard let lease = leases[lookup], lease.token == token else {
            return false
        }
        leases.removeValue(forKey: lookup)
        return true
    }

    @discardableResult
    public func releaseAll(epoch: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        let matches = leases.keys.filter { $0.epoch == epoch }
        for lookup in matches { leases.removeValue(forKey: lookup) }
        let denied = denials.keys.filter { $0.epoch == epoch }
        for lookup in denied { denials.removeValue(forKey: lookup) }
        return matches.count
    }

    public func leaseCount(epoch: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return leases.keys.filter { $0.epoch == epoch }.count
    }

    public func hasLease(jobID: String, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return leases[key(jobID, epoch)] != nil
    }

    public func lease(jobID: String, epoch: UInt64, token: String)
        -> G09R2ForegroundLease? {
        lock.lock(); defer { lock.unlock() }
        guard let lease = leases[key(jobID, epoch)],
              lease.token == token else { return nil }
        return lease
    }

    public func noteProgress(jobID: String, epoch: UInt64, fraction: Double?) {
        lock.lock(); defer { lock.unlock() }
        let lookup = key(jobID, epoch)
        guard var lease = leases[lookup] else { return }
        if let fraction, fraction.isFinite {
            lease.progress = min(1, max(0, fraction))
        } else {
            lease.progress = nil
        }
        leases[lookup] = lease
    }

    public func pendingLeaseDebugCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return leases.count
    }

    // MARK: - DB-backed host validation

    /// Proves the captured job is the ACTUAL durable record owned by the
    /// claimed project and the accepted generation, and is still non-terminal.
    /// No session token, client root or Intent owner is accepted as proof.
    public static func validateForHost(
        jobID: String, epoch: UInt64, projectID: UUID
    ) async -> G09R2GenerationKind? {
        guard epoch > 0, let uuid = validJobID(jobID) else { return nil }
        guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
            epoch: epoch) else { return nil }
        let store = MediaGenerationJobStore(database: cluster.database)
        guard let owned = try? await store.ownedJob(id: uuid),
              owned.owner == .document(projectID),
              !owned.job.state.isTerminal else { return nil }
        guard let payload = try? G09CreativeWire.decoder().decode(
            G09R2GenerationJobPayload.self, from: owned.job.requestJSON),
              payload.epoch == epoch,
              payload.projectID == projectID,
              payload.kind == (owned.job.mediaKind == .image ? .image : .video)
        else { return nil }
        return payload.kind
    }

    /// Reads the durable state + live progress for the host notification pump.
    /// Returns nil when the lease is not exact or the generation/job is gone;
    /// the host must then release the lease and stop the service.
    public static func snapshot(
        jobID: String, epoch: UInt64, token: String
    ) async -> G09R2ForegroundJobSnapshot? {
        guard let lease = G09R2ForegroundCoordinator.shared.lease(
            jobID: jobID, epoch: epoch, token: token) else { return nil }
        guard epoch > 0, let uuid = validJobID(jobID) else { return nil }
        guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
            epoch: epoch) else { return nil }
        let store = MediaGenerationJobStore(database: cluster.database)
        guard let owned = try? await store.ownedJob(id: uuid) else { return nil }
        return G09R2ForegroundJobSnapshot(
            jobID: lease.jobID, epoch: epoch,
            state: owned.job.state.rawValue,
            terminal: owned.job.state.isTerminal,
            progress: lease.progress,
            hasProviderTask: owned.job.providerTaskID != nil)
    }
}

// MARK: - Trusted-host C ABI (Kotlin GenerationForegroundNative only)

private final class G09R2ForegroundBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ next: T?) { lock.lock(); value = next; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

private func g09r2ForegroundBlocking<T: Sendable>(
    timeoutSeconds: TimeInterval = 5,
    _ body: @escaping @Sendable () async -> T?
) -> T? {
    let box = G09R2ForegroundBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.set(await body())
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        return nil
    }
    return box.get()
}

private func g09r2ForegroundString(
    _ pointer: UnsafePointer<CChar>?, maximum: Int
) -> String? {
    guard let pointer, maximum > 0 else { return nil }
    var count = 0
    while count <= maximum, pointer[count] != 0 { count += 1 }
    guard count > 0, count <= maximum else { return nil }
    return String(validatingCString: pointer)
}

private func g09r2ForegroundWrite(
    _ text: String, _ outBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32
) -> Int32 {
    guard let outBuffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity), bytes.count <= 256 else {
        return -106
    }
    for (index, byte) in bytes.enumerated() {
        outBuffer[index] = CChar(bitPattern: byte)
    }
    outBuffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// `floe_generation_foreground_register(jobID, epoch, projectID, token)`
/// Registers a confirmed App foreground lease after DB-backed job/epoch/owner
/// validation. `0` success, `-101` invalid arguments, `-102` stale/foreign
/// job or epoch, `-103` lease table full, `-104` job already terminal.
@_cdecl("floe_generation_foreground_register")
public func floeGenerationForegroundRegister(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ projectID: UnsafePointer<CChar>?,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          let projectText = g09r2ForegroundString(projectID, maximum: 36),
          let tokenText = g09r2ForegroundString(token, maximum: 64),
          G09R2ForegroundCoordinator.validJobID(jobText) != nil,
          let projectUUID = UUID(uuidString: projectText),
          G09R2ForegroundCoordinator.validToken(tokenText),
          epoch > 0 else { return -101 }
    guard let kind = g09r2ForegroundBlocking({
        await G09R2ForegroundCoordinator.validateForHost(
            jobID: jobText, epoch: epoch, projectID: projectUUID)
    }) else { return -102 }
    guard G09R2ForegroundCoordinator.shared.registerLease(
        jobID: jobText, epoch: epoch, projectID: projectUUID,
        token: tokenText, kind: kind) else { return -103 }
    return 0
}

/// Definite admission denial from the App host (start denied, notifications
/// blocked, service unavailable). No provider dispatch is permitted after it.
@_cdecl("floe_generation_foreground_deny")
public func floeGenerationForegroundDeny(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ reason: UnsafePointer<CChar>?
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          G09R2ForegroundCoordinator.validJobID(jobText) != nil,
          epoch > 0 else { return -101 }
    let reasonText = g09r2ForegroundString(reason, maximum: 32)
        ?? "foregroundUnavailable"
    G09R2ForegroundCoordinator.shared.denyAdmission(
        jobID: jobText, epoch: epoch, reason: reasonText)
    return 0
}

@_cdecl("floe_generation_foreground_release")
public func floeGenerationForegroundRelease(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          let tokenText = g09r2ForegroundString(token, maximum: 64),
          epoch > 0 else { return -101 }
    return G09R2ForegroundCoordinator.shared.releaseLease(
        jobID: jobText, epoch: epoch, token: tokenText) ? 0 : -107
}

/// Notification Cancel / host stop request for the EXACT leased native job.
/// This is a cancellation REQUEST: the worker owns the terminal truth and
/// provider billing cancellation remains honestly unsupported where absent.
@_cdecl("floe_generation_foreground_cancel")
public func floeGenerationForegroundCancel(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          let tokenText = g09r2ForegroundString(token, maximum: 64),
          epoch > 0,
          G09R2ForegroundCoordinator.shared.lease(
            jobID: jobText, epoch: epoch, token: tokenText) != nil
    else { return -107 }
    _ = G09R2GenerationService.shared.requestCancel(
        jobID: jobText.lowercased(), epoch: epoch)
    return 0
}

/// Bounded background pump step for the exact leased video job. The host-only
/// C ABI validates the lease, then the native service reuses the durable
/// payload/task/backoff and its ordinary `runVideoPoll` worker. No session
/// token is accepted and no second scheduler exists.
@_cdecl("floe_generation_foreground_poll")
public func floeGenerationForegroundPoll(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          let tokenText = g09r2ForegroundString(token, maximum: 64),
          epoch > 0,
          G09R2ForegroundCoordinator.shared.lease(
            jobID: jobText, epoch: epoch, token: tokenText) != nil
    else { return -107 }
    let accepted = g09r2ForegroundBlocking {
        await G09R2GenerationService.shared.foregroundPoll(
            epoch: epoch, jobID: jobText)
    }
    return accepted == true ? 0 : 1
}

/// Reads the exact durable job state for the notification pump. ASCII:
/// `state=running;terminal=0;progress=0.4200;task=1;epoch=7000`
@_cdecl("floe_generation_foreground_snapshot")
public func floeGenerationForegroundSnapshot(
    _ jobID: UnsafePointer<CChar>?,
    _ epoch: UInt64,
    _ token: UnsafePointer<CChar>?,
    _ outBuffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let jobText = g09r2ForegroundString(jobID, maximum: 36),
          let tokenText = g09r2ForegroundString(token, maximum: 64),
          epoch > 0 else { return -101 }
    guard let snapshot = g09r2ForegroundBlocking({
        await G09R2ForegroundCoordinator.snapshot(
            jobID: jobText, epoch: epoch, token: tokenText)
    }) else { return -108 }
    let progress = snapshot.progress.map {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0)
    } ?? "-1"
    let text = "state=\(snapshot.state);terminal=\(snapshot.terminal ? 1 : 0);"
        + "progress=\(progress);task=\(snapshot.hasProviderTask ? 1 : 0);"
        + "epoch=\(snapshot.epoch)"
    return g09r2ForegroundWrite(text, outBuffer, capacity)
}

/// Leases still held for one generation. Used by Root-drain diagnostics. The
/// owner releases an exact lease only after its real service/notification was
/// stopped, so a non-zero count correctly keeps Root pending.
@_cdecl("floe_generation_foreground_count")
public func floeGenerationForegroundCount(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return 0 }
    return Int32(G09R2ForegroundCoordinator.shared.leaseCount(epoch: epoch))
}

/// Host-initiated release of every lease for a retired generation. This is
/// only called by the App host AFTER it stopped the foreground service / every
/// claimed notification for that epoch; it never grants new work.
@_cdecl("floe_generation_foreground_release_all")
public func floeGenerationForegroundReleaseAll(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return 0 }
    return Int32(G09R2ForegroundCoordinator.shared.releaseAll(epoch: epoch))
}
