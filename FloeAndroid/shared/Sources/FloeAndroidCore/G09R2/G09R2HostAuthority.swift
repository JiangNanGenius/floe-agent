// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — plain trusted-host authority proofs (job-aa95dd9b26044ded).
//
// Platform12's concrete adapter interfaces live in its own (not-yet-registered)
// Gradle module. The App host therefore exposes ONLY plain Swift DTOs and a
// narrow host-only C ABI; the App adapter maps them to `WorkbenchEpochOwner` /
// `WorkbenchLeaseAuthority` in the Main integration. Nothing here imports the
// platform module, invents a Root, constructs a lease by value or reopens a
// mutable "latest" project:
//
//  * epoch/root truth comes from the SAME bound `G09CreativeDomainService`;
//  * a render binding is proven against the native snapshot lease record/file
//    plus the exact owner (session digest), project, revision, digest and
//    storage; the platform's re-proof remains additive;
//  * a probe root is the native-issued per-project media root for that exact
//    context, never a caller path or recorded project JSON;
//  * a ticket proof is the exact native-owned claimed descriptor + claim token.
import Foundation
import FloeCore
import FloeAndroidWorkbench

// MARK: - Plain host proof DTOs

public struct G09R2HostStatusDTO: Encodable, Sendable {
    public var epoch: UInt64
    public var live: Bool
    /// Accepted base root (an ANCESTOR only). Per-project media roots are
    /// always issued by the native snapshot/envelope; journals may use this
    /// base path, never as a renderer root.
    public var baseRootPath: String?
}

public struct G09R2HostGrantDTO: Encodable, Sendable {
    public var epoch: UInt64
    public var mediaRootPath: String
    public var projectID: String?
    public var revision: Int64?
    public var timelineDigest: String?
}

public struct G09R2HostDecisionDTO: Encodable, Sendable {
    public var accepted: Bool
    public var grant: G09R2HostGrantDTO?
    public var error: String?
    public var reason: String?
    public var retryable: Bool
}

public struct G09R2RenderBindingProof: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var mediaRootPath: String
    public var projectRevision: Int64
    public var timelineDigest: String
    public var attemptID: String
    /// Same `snapshot` key as the frozen `G09R2MediaExportBindingDTO`.
    public var snapshot: G09R2RenderSnapshotLeaseDTO
}

public struct G09R2ProbeRootProof: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var mediaRootPath: String
    public var relativePath: String
}

public struct G09R2TicketProof: Decodable, Sendable {
    public var descriptor: G09R2RenderTicketDescriptorDTO
    public var claimToken: String
}

/// Retain one already-prepared binding for a direct platform export/playback/
/// preview. The opaque handle is the only release authority; it is not a
/// project identity and never grants a new Root.
public struct G09R2RetainRenderBindingRequest: Decodable, Sendable {
    public var binding: G09R2MediaExportBindingDTO
    public var ownerOperationID: String
}

public struct G09R2ReleaseRenderBindingPinRequest: Decodable, Sendable {
    public var pinHandle: String
}

public struct G09R2RenderBindingPinDTO: Encodable, Sendable {
    public var pinHandle: String
    public var epoch: UInt64
    public var leaseID: String
    public var mediaRootPath: String
    public var projectID: String
    public var revision: Int64
    public var timelineDigest: String
    public var attemptID: String
    /// `playback` | `export` | `preview` | `operation` (generic retain).
    public var kind: String
    public var expiresAt: Date
}

/// Platform lifecyle pin request: it carries the accepted project/root and the
/// native-prepared attempt identity instead of duplicating a lease by value.
public struct G09R2LifecyclePinRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var kind: String
    public var epoch: UInt64
    public var mediaRootPath: String
    public var attemptID: String
    public var jobID: String?
}

public struct G09R2ResolveProjectMediaRootRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
}

/// Authorized per-project root proof for recovery. `ownerProof` is stable for
/// the project's durable owner (not the ephemeral editor session digest).
public struct G09R2ProjectMediaRootDTO: Encodable, Sendable {
    public var epoch: UInt64
    public var mediaRootPath: String
    public var projectID: String
    public var revision: Int64
    public var timelineDigest: String
    public var storage: G09StorageLayerDTO
    public var ownerKind: String
    public var ownerID: String?
    public var ownerProof: String
    /// Canonical durable scopes for the platform recovery journal.
    public var storageKey: String
    public var originKey: String?
    public var writable: Bool
}

// MARK: - Native proof implementation

public enum G09R2HostAuthority {
    public static func status(service: G09CreativeDomainService,
                              epoch: UInt64) async -> G09R2HostStatusDTO {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            return G09R2HostStatusDTO(epoch: epoch, live: false,
                                      baseRootPath: nil)
        }
        let generationLive = await service.r2IsGenerationLive(epoch: epoch)
        let live = generationLive &&
            !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch)
        return G09R2HostStatusDTO(
            epoch: epoch, live: live, baseRootPath: cluster.root.path)
    }

    public static func verifyRenderBinding(
        service: G09CreativeDomainService, epoch: UInt64,
        proof: G09R2RenderBindingProof
    ) async throws -> G09R2HostGrantDTO {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard await service.r2IsGenerationLive(epoch: epoch) else {
            throw G09CreativeError.staleGeneration
        }
        guard !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
        guard G09CreativeWire.validSessionToken(proof.context.sessionToken) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
        let record = try G09R2SnapshotLeases.shared.verify(
            proof.snapshot, epoch: epoch,
            projectID: proof.context.projectID,
            revision: proof.projectRevision,
            timelineDigest: proof.timelineDigest,
            storage: proof.context.storage,
            sessionToken: proof.context.sessionToken)
        _ = try G09R2SnapshotLeases.shared.verifyFile(
            leaseID: proof.snapshot.leaseID)
        guard record.mediaRootPath == proof.mediaRootPath,
              Self.rootContained(record.mediaRootPath, under: cluster.root.path),
              proof.snapshot.mediaRootPath == record.mediaRootPath else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseRootMismatch")
        }
        return G09R2HostGrantDTO(
            epoch: epoch, mediaRootPath: record.mediaRootPath,
            projectID: record.projectID.uuidString.lowercased(),
            revision: record.revision,
            timelineDigest: record.timelineDigest)
    }

    public static func verifyProbeRoot(
        service: G09CreativeDomainService, epoch: UInt64,
        proof: G09R2ProbeRootProof
    ) async throws -> G09R2HostGrantDTO {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard await service.r2IsGenerationLive(epoch: epoch) else {
            throw G09CreativeError.staleGeneration
        }
        guard !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
        try await service.r2RequireMediaSession(
            projectID: proof.context.projectID,
            token: proof.context.sessionToken)
        let loaded = try await cluster.media.load(
            id: proof.context.projectID,
            requested: proof.context.storage,
            origin: proof.context.origin)
        guard loaded.storage.rootURL.path == proof.mediaRootPath,
              loaded.storage.rootURL.path.hasPrefix(cluster.root.path + "/") else {
            throw G09R2Error(.renderTicketNotFound, detail: "probeRootMismatch")
        }
        guard G09CreativeAssetHost.safeRelativePath(proof.relativePath),
              !proof.relativePath.isEmpty,
              let url = G09R2MediaFoundation.containedURL(
                root: loaded.storage.rootURL, relativePath: proof.relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            throw G09CreativeError.assetMissing
        }
        let timeline = loaded.project.videoTimeline ?? VideoTimeline()
        return G09R2HostGrantDTO(
            epoch: epoch, mediaRootPath: loaded.storage.rootURL.path,
            projectID: loaded.project.id.uuidString.lowercased(),
            revision: loaded.project.revision,
            timelineDigest: G09R2MediaDigests.timeline(timeline))
    }

    public static func verifyTicket(
        service: G09CreativeDomainService, epoch: UInt64,
        proof: G09R2TicketProof
    ) async throws -> G09R2HostGrantDTO {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard proof.descriptor.epoch == epoch,
              Self.rootContained(proof.descriptor.mediaRootPath,
                                 under: cluster.root.path),
              let native = G09R2MediaRenderHostMailbox.shared.verifyClaim(
                ticketID: proof.descriptor.ticketID,
                claimToken: proof.claimToken,
                descriptor: proof.descriptor) else {
            throw G09R2Error(.renderTicketNotFound, detail: "claimNotNativeOwned")
        }
        return G09R2HostGrantDTO(
            epoch: epoch, mediaRootPath: native.mediaRootPath,
            projectID: native.projectID.uuidString.lowercased(),
            revision: native.projectRevision,
            timelineDigest: native.timelineDigest)
    }

    /// Authorized per-project media root for recovery. The current session,
    /// project identity, storage layer and real origin are re-authorized by
    /// the native media host; the returned root is the trusted per-project
    /// root (never the accepted base ancestor) and `ownerProof` is derived
    /// from the durable project owner, not the ephemeral session token.
    public static func resolveProjectMediaRoot(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO
    ) async throws -> G09R2ProjectMediaRootDTO {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard await service.r2IsGenerationLive(epoch: epoch) else {
            throw G09CreativeError.staleGeneration
        }
        guard !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
        try G09R2HostAuthority.requireSession(context.sessionToken)
        try await service.r2RequireMediaSession(
            projectID: context.projectID, token: context.sessionToken)
        let loaded = try await cluster.media.load(
            id: context.projectID, requested: context.storage,
            origin: context.origin)
        let rootPath = loaded.storage.rootURL.path
        guard rootPath.hasPrefix(cluster.root.path + "/") else {
            throw G09R2Error(.renderTicketNotFound, detail: "projectRootEscape")
        }
        let timeline = loaded.project.videoTimeline ?? VideoTimeline()
        let ownerID = loaded.project.ownerID?.uuidString.lowercased() ?? ""
        let proofText = "floe.g09.project-owner/1|" +
            "\(loaded.project.id.uuidString.lowercased())|" +
            "\(loaded.project.ownerKind)|\(ownerID)"
        return G09R2ProjectMediaRootDTO(
            epoch: epoch, mediaRootPath: rootPath,
            projectID: loaded.project.id.uuidString.lowercased(),
            revision: loaded.project.revision,
            timelineDigest: G09R2MediaDigests.timeline(timeline),
            storage: loaded.storage.storage,
            ownerKind: loaded.project.ownerKind,
            ownerID: loaded.project.ownerID?.uuidString.lowercased(),
            ownerProof: FloeDigest.sha256Hex(Data(proofText.utf8)),
            storageKey: Self.storageKey(loaded.storage.storage),
            originKey: G09R2HostAuthority.originKey(context.origin),
            writable: loaded.writable)
    }

    /// Canonical containment proof for a per-project media root. The platform
    /// ticket consumer canonicalizes the root before echoing a receipt
    /// (`File.canonicalFile`), while the accepted runtime root can be spelled
    /// with a symlinked prefix (`/var`↔`/private/var`, `/data/user/0`↔
    /// `/data/data`). Compare the REAL directory, never a label.
    static func rootContained(_ mediaRootPath: String, under acceptedRootPath: String) -> Bool {
        let media = URL(fileURLWithPath: mediaRootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let accepted = URL(fileURLWithPath: acceptedRootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return media.path.hasPrefix(accepted.path + "/")
    }

    static func storageKey(_ storage: G09StorageLayerDTO) -> String {
        switch storage.kind {
        case .appOwned:
            return "appOwned"
        case .workspace:
            return "workspace:" +
                (storage.workspaceID?.uuidString.lowercased() ?? "")
        }
    }

    static func originKey(_ origin: G09CreativeOriginDTO?) -> String? {
        guard let origin else { return nil }
        return origin.kind.rawValue + "|" +
            (origin.ownerID?.uuidString.lowercased() ?? "") + "|" +
            (origin.environmentID ?? "")
    }

    private static func requireSession(_ token: String) throws {
        guard G09CreativeWire.validSessionToken(token) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
    }

    static func decision(_ error: Error) -> G09R2HostDecisionDTO {
        if let typed = error as? G09R2Error {
            return G09R2HostDecisionDTO(
                accepted: false, grant: nil, error: typed.code,
                reason: typed.detail, retryable: typed.retryable)
        }
        let mapped = G09CreativeError.map(error)
        return G09R2HostDecisionDTO(
            accepted: false, grant: nil, error: mapped.code,
            reason: nil, retryable: mapped.retryable)
    }

    static func decision(_ grant: G09R2HostGrantDTO) -> G09R2HostDecisionDTO {
        G09R2HostDecisionDTO(
            accepted: true, grant: grant, error: nil, reason: nil,
            retryable: false)
    }
}

// MARK: - Direct-operation binding pins

/// Bounded native pin registry for platform direct exports/playback/previews.
/// A mailbox ticket already pins its own lease; this registry covers the
/// other real workers so caller release/expiry can never delete the snapshot
/// under an active codec/IO operation. The hard lifetime is a truthful bound,
/// not an infinite lease: a leaked handle stops owning the file after it.
public final class G09R2RenderBindingPins: @unchecked Sendable {
    public static let shared = G09R2RenderBindingPins()
    public static let maximumPins = 8
    /// Bounded AUTHORITY validity, not ownership expiry. When this deadline
    /// passes the pin is marked overdue/stop-requested (new binds refuse) but
    /// it keeps the exact snapshot/Root ownership until the authenticated
    /// worker releases/acks. Time alone is never proof that codec/IO stopped.
    public static let authorityValiditySeconds: TimeInterval = 60 * 60

    private struct Entry {
        let handle: String
        let epoch: UInt64
        let leaseID: String
        let ownerOperationID: String
        let createdAt: Date
        let expiresAt: Date
        var overdue = false
        var stopRequested = false
    }

    private struct Prepared {
        let binding: G09R2MediaExportBindingDTO
        let createdAt: Date
    }

    private let condition = NSLock()
    private var entries: [String: Entry] = [:]
    private var prepared: [String: Prepared] = [:]
    private var preparedOrder: [String] = []

    public static let maximumPrepared = 32

    public init() {}

    /// Records the native-prepared attempt identity so the platform lifecycle
    /// pin (which intentionally does not carry a lease by value) can pin the
    /// EXACT lease that `prepareRenderBinding` issued. Bounded and replaced
    /// on the same epoch/project/attempt key.
    public func registerPrepared(epoch: UInt64,
                                 binding: G09R2MediaExportBindingDTO) {
        let key = Self.preparedKey(
            epoch: epoch, projectID: binding.context.projectID,
            attemptID: binding.attemptID)
        condition.lock()
        prepared[key] = Prepared(binding: binding, createdAt: Date())
        preparedOrder.removeAll { $0 == key }
        preparedOrder.append(key)
        let excess = preparedOrder.count - Self.maximumPrepared
        if excess > 0 {
            for stale in preparedOrder.prefix(excess) {
                prepared.removeValue(forKey: stale)
                preparedOrder.removeAll { $0 == stale }
            }
        }
        condition.unlock()
    }

    private func preparedEntry(epoch: UInt64, projectID: UUID,
                               attemptID: String) -> G09R2MediaExportBindingDTO? {
        condition.lock(); defer { condition.unlock() }
        return prepared[Self.preparedKey(
            epoch: epoch, projectID: projectID, attemptID: attemptID)]?.binding
    }

    private static func preparedKey(epoch: UInt64, projectID: UUID,
                                    attemptID: String) -> String {
        "\(epoch)|\(projectID.uuidString.lowercased())|\(attemptID)"
    }

    /// Platform lifecycle pin for direct playback/export/preview. It
    /// reauthorizes the CURRENT editor session and then pins the exact
    /// native-prepared lease for this epoch/project/attempt; a caller cannot
    /// supply or retarget a lease.
    public func pinLifecycle(
        service: G09CreativeDomainService, epoch: UInt64,
        request: G09R2LifecyclePinRequest
    ) async throws -> G09R2RenderBindingPinDTO {
        guard request.epoch == epoch,
              ["playback", "export", "preview"].contains(request.kind) else {
            throw G09CreativeError.invalidPayload("invalidLifecyclePin")
        }
        guard !request.attemptID.isEmpty,
              request.attemptID.utf8.count <= 64 else {
            throw G09CreativeError.invalidPayload("invalidAttemptID")
        }
        guard let prepared = preparedEntry(
            epoch: epoch, projectID: request.context.projectID,
            attemptID: request.attemptID) else {
            throw G09R2Error(.renderTicketNotFound,
                             detail: "attemptNotNativelyPrepared")
        }
        guard prepared.mediaRootPath == request.mediaRootPath,
              prepared.context.storage == request.context.storage,
              prepared.context.origin == request.context.origin else {
            throw G09R2Error(.renderTicketNotFound,
                             detail: "lifecyclePinContextMismatch")
        }
        try await service.r2RequireMediaSession(
            projectID: request.context.projectID,
            token: request.context.sessionToken)
        let proof = G09R2RenderBindingProof(
            context: prepared.context,
            mediaRootPath: prepared.mediaRootPath,
            projectRevision: prepared.projectRevision,
            timelineDigest: prepared.timelineDigest,
            attemptID: prepared.attemptID,
            snapshot: prepared.snapshot)
        let grant = try await G09R2HostAuthority.verifyRenderBinding(
            service: service, epoch: epoch, proof: proof)
        purgeExpired(epoch: epoch)
        guard !isOverdue(leaseID: prepared.snapshot.leaseID) else {
            throw G09R2Error(.renderTicketExpired, detail: "authorityOverdue")
        }
        let handle = UUID().uuidString.lowercased()
        let now = Date()
        let expiresAt = now.addingTimeInterval(Self.authorityValiditySeconds)
        guard G09R2SnapshotLeases.shared.pin(
            leaseID: prepared.snapshot.leaseID, owner: handle) else {
            throw G09R2Error(.rendererUnavailable, detail: "leasePinRefused")
        }
        let entry = Entry(
            handle: handle, epoch: epoch,
            leaseID: prepared.snapshot.leaseID,
            ownerOperationID: request.jobID ?? request.attemptID,
            createdAt: now, expiresAt: expiresAt)
        guard insertEntry(entry) else {
            G09R2SnapshotLeases.shared.unpin(
                leaseID: prepared.snapshot.leaseID, owner: handle)
            throw G09R2Error(.rendererUnavailable, detail: "pinTableFull")
        }
        return G09R2RenderBindingPinDTO(
            pinHandle: handle, epoch: epoch,
            leaseID: prepared.snapshot.leaseID,
            mediaRootPath: grant.mediaRootPath,
            projectID: grant.projectID ?? prepared.context.projectID.uuidString.lowercased(),
            revision: grant.revision ?? prepared.projectRevision,
            timelineDigest: grant.timelineDigest ?? prepared.timelineDigest,
            attemptID: prepared.attemptID, kind: request.kind,
            expiresAt: expiresAt)
    }

    public func count(epoch: UInt64) -> Int {
        condition.lock(); defer { condition.unlock() }
        return entries.values.filter { $0.epoch == epoch }.count
    }

    /// Native-record-backed retain: verifies the exact binding against the
    /// bound generation/lease record/file, then pins the lease with the
    /// opaque handle. Refused while the generation is stopping.
    public func retain(service: G09CreativeDomainService, epoch: UInt64,
                       request: G09R2RetainRenderBindingRequest) async throws
        -> G09R2RenderBindingPinDTO {
        guard !request.ownerOperationID.isEmpty,
              request.ownerOperationID.utf8.count <= 128 else {
            throw G09CreativeError.invalidPayload("invalidOwnerOperationID")
        }
        let grant = try await G09R2HostAuthority.verifyRenderBinding(
            service: service, epoch: epoch, proof: G09R2RenderBindingProof(
                context: request.binding.context,
                mediaRootPath: request.binding.mediaRootPath,
                projectRevision: request.binding.projectRevision,
                timelineDigest: request.binding.timelineDigest,
                attemptID: request.binding.attemptID,
                snapshot: request.binding.snapshot))
        purgeExpired(epoch: epoch)
        guard !isOverdue(leaseID: request.binding.snapshot.leaseID) else {
            // The bounded authority already requested the platform to stop
            // this operation; never extend it with another pin.
            throw G09R2Error(.renderTicketExpired, detail: "authorityOverdue")
        }
        let handle = UUID().uuidString.lowercased()
        let now = Date()
        let expiresAt = now.addingTimeInterval(Self.authorityValiditySeconds)
        guard G09R2SnapshotLeases.shared.pin(
            leaseID: request.binding.snapshot.leaseID, owner: handle) else {
            throw G09R2Error(.rendererUnavailable, detail: "leasePinRefused")
        }
        let entry = Entry(
            handle: handle, epoch: epoch,
            leaseID: request.binding.snapshot.leaseID,
            ownerOperationID: request.ownerOperationID,
            createdAt: now, expiresAt: expiresAt)
        guard insertEntry(entry) else {
            G09R2SnapshotLeases.shared.unpin(
                leaseID: request.binding.snapshot.leaseID, owner: handle)
            throw G09R2Error(.rendererUnavailable, detail: "pinTableFull")
        }
        return G09R2RenderBindingPinDTO(
            pinHandle: handle, epoch: epoch,
            leaseID: request.binding.snapshot.leaseID,
            mediaRootPath: grant.mediaRootPath,
            projectID: grant.projectID ?? "",
            revision: grant.revision ?? request.binding.projectRevision,
            timelineDigest: grant.timelineDigest ?? request.binding.timelineDigest,
            attemptID: request.binding.attemptID, kind: "operation",
            expiresAt: expiresAt)
    }

    /// Idempotent release. TRUE also for an already-released/expired handle;
    /// FALSE means the handle belongs to a different generation (never a
    /// cross-root release). The last release of a deferred lease deletes only
    /// the owned verified snapshot bytes.
    @discardableResult
    public func release(epoch: UInt64, handle: String) -> Bool {
        guard !handle.isEmpty, handle.utf8.count <= 128 else { return false }
        condition.lock()
        guard let entry = entries[handle] else {
            condition.unlock()
            return true
        }
        guard entry.epoch == epoch else {
            condition.unlock()
            return false
        }
        entries.removeValue(forKey: handle)
        condition.unlock()
        G09R2SnapshotLeases.shared.unpin(
            leaseID: entry.leaseID, owner: entry.handle)
        return true
    }

    /// TRUE when this exact lease already has an overdue/stop-requested pin.
    /// Such a lease must not gain new work or be extended by another pin.
    private func isOverdue(leaseID: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return entries.values.contains {
            $0.leaseID == leaseID && ($0.overdue || $0.stopRequested)
        }
    }

    private func insertEntry(_ entry: Entry) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard entries.count < Self.maximumPins else { return false }
        entries[entry.handle] = entry
        return true
    }

    /// Marks overdue pins and requests platform cancellation WITHOUT releasing
    /// ownership. The lease/Root pin stays counted until `release(epoch:handle:)`
    /// (authenticated worker ack); process teardown with no workers is the only
    /// non-ack path. A prepared attempt whose lease already expired is dropped
    /// only because it can no longer authorize NEW work; a live pin keeps its
    /// own lease/file independently.
    public func purgeExpired(epoch: UInt64, now: Date = Date()) {
        condition.lock()
        for (id, entry) in entries where entry.epoch == epoch &&
            entry.expiresAt <= now {
            var current = entry
            current.overdue = true
            current.stopRequested = true
            entries[id] = current
        }
        let stalePrepared = prepared.filter {
            $0.value.binding.snapshot.expiresAt <= now
        }.map(\.key)
        for key in stalePrepared {
            prepared.removeValue(forKey: key)
            preparedOrder.removeAll { $0 == key }
        }
        condition.unlock()
    }

    public func overdueCount(epoch: UInt64) -> Int {
        condition.lock(); defer { condition.unlock() }
        return entries.values.filter {
            $0.epoch == epoch && $0.overdue
        }.count
    }
}

// MARK: - Bounded host-only C ABI

private func g09r2HostToken(_ pointer: UnsafePointer<CChar>?,
                            limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit + 1)
    guard length > 0, length <= limit else { return nil }
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    guard let text = String(
        bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
    else { return nil }
    return text
}

private func g09r2HostCopy(_ data: Data,
                           _ buffer: UnsafeMutablePointer<CChar>?,
                           _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return -106 }
    guard data.count + 1 <= Int(capacity) else { return -106 }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(buffer, base, data.count)
    }
    buffer[data.count] = 0
    return Int32(data.count)
}

private func g09r2HostEncode(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else { return nil }
    return data
}

private final class G09R2HostBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

private func g09r2HostBlocking<T>(_ body: @escaping @Sendable () async -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = G09R2HostBox<T>()
    Task {
        box.set(await body())
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()
}

private func g09r2HostRequestData(_ pointer: UnsafePointer<CChar>?,
                                  limit: Int) -> Data? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit + 1)
    guard length > 0, length <= limit else { return nil }
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return Data(bytes: bytes, count: length)
}

/// Native bound-generation status. `live` is TRUE only while this exact epoch
/// is the bound creative authority and no Root stop was requested.
@_cdecl("floe_media_foundation_status")
public func floeMediaFoundationStatus(
    _ epoch: UInt64,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0 else { return -105 }
    guard let status = g09r2HostBlocking({
        await G09R2HostAuthority.status(service: BridgeV5.service, epoch: epoch)
    }) else { return -105 }
    guard var object = try? G09CreativeWire.object(status) else { return -108 }
    object["ok"] = true
    guard let data = g09r2HostEncode(object) else { return -108 }
    return g09r2HostCopy(data, buffer, capacity)
}

/// One bounded authority proof. `action` is one of `renderBinding`,
/// `probeRoot`, `ticket`; the reply is a decision object (never a bare bool).
@_cdecl("floe_media_authority_verify")
public func floeMediaAuthorityVerify(
    _ epoch: UInt64,
    _ action: UnsafePointer<CChar>?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0,
          let action = g09r2HostToken(action, limit: 32) else { return -105 }
    guard let requestData = g09r2HostRequestData(requestJSON, limit: 16_384) else {
        return -107
    }
    let decision: G09R2HostDecisionDTO
    do {
        switch action {
        case "renderBinding":
            let proof = try G09CreativeWire.decoder().decode(
                G09R2RenderBindingProof.self, from: requestData)
            let grant = try g09r2HostBlockingResult {
                try await G09R2HostAuthority.verifyRenderBinding(
                    service: BridgeV5.service, epoch: epoch, proof: proof)
            }
            decision = G09R2HostAuthority.decision(grant)
        case "probeRoot":
            let proof = try G09CreativeWire.decoder().decode(
                G09R2ProbeRootProof.self, from: requestData)
            let grant = try g09r2HostBlockingResult {
                try await G09R2HostAuthority.verifyProbeRoot(
                    service: BridgeV5.service, epoch: epoch, proof: proof)
            }
            decision = G09R2HostAuthority.decision(grant)
        case "ticket":
            let proof = try G09CreativeWire.decoder().decode(
                G09R2TicketProof.self, from: requestData)
            let grant = try g09r2HostBlockingResult {
                try await G09R2HostAuthority.verifyTicket(
                    service: BridgeV5.service, epoch: epoch, proof: proof)
            }
            decision = G09R2HostAuthority.decision(grant)
        case "retainBinding":
            let request = try G09CreativeWire.decoder().decode(
                G09R2RetainRenderBindingRequest.self, from: requestData)
            let pin = try g09r2HostBlockingResult {
                try await G09R2RenderBindingPins.shared.retain(
                    service: BridgeV5.service, epoch: epoch, request: request)
            }
            var object = try G09CreativeWire.object(pin)
            object["ok"] = true
            guard let encoded = g09r2HostEncode(object) else { return -108 }
            return g09r2HostCopy(encoded, buffer, capacity)
        case "pinLifecycle":
            let request = try G09CreativeWire.decoder().decode(
                G09R2LifecyclePinRequest.self, from: requestData)
            let pin = try g09r2HostBlockingResult {
                try await G09R2RenderBindingPins.shared.pinLifecycle(
                    service: BridgeV5.service, epoch: epoch, request: request)
            }
            var object = try G09CreativeWire.object(pin)
            object["ok"] = true
            guard let encoded = g09r2HostEncode(object) else { return -108 }
            return g09r2HostCopy(encoded, buffer, capacity)
        case "releasePin":
            let request = try G09CreativeWire.decoder().decode(
                G09R2ReleaseRenderBindingPinRequest.self, from: requestData)
            let released = G09R2RenderBindingPins.shared.release(
                epoch: epoch, handle: request.pinHandle)
            guard released else {
                throw G09CreativeError.staleGeneration
            }
            let object: [String: Any] = ["ok": true, "released": true]
            guard let encoded = g09r2HostEncode(object) else { return -108 }
            return g09r2HostCopy(encoded, buffer, capacity)
        case "resolveRoot":
            let request = try G09CreativeWire.decoder().decode(
                G09R2ResolveProjectMediaRootRequest.self, from: requestData)
            let root = try g09r2HostBlockingResult {
                try await G09R2HostAuthority.resolveProjectMediaRoot(
                    service: BridgeV5.service, epoch: epoch,
                    context: request.context)
            }
            var object = try G09CreativeWire.object(root)
            object["ok"] = true
            guard let encoded = g09r2HostEncode(object) else { return -108 }
            return g09r2HostCopy(encoded, buffer, capacity)
        default:
            decision = G09R2HostDecisionDTO(
                accepted: false, grant: nil, error: "invalidPayload",
                reason: "unknownAuthorityAction", retryable: false)
        }
    } catch {
        var object = (try? G09CreativeWire.object(
            G09R2HostAuthority.decision(error))) ?? [:]
        object["ok"] = false
        guard let data = g09r2HostEncode(object) else { return -108 }
        return g09r2HostCopy(data, buffer, capacity)
    }
    var object = (try? G09CreativeWire.object(decision)) ?? [:]
    object["ok"] = true
    guard let data = g09r2HostEncode(object) else { return -108 }
    return g09r2HostCopy(data, buffer, capacity)
}

private func g09r2HostBlockingResult<T>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let outcome: Result<T, Error>? = g09r2HostBlocking {
        do { return .success(try await body()) }
        catch { return .failure(error) }
    }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    case .none: throw G09CreativeError.storageUnavailable
    }
}

/// Returns 0 when the exact generation is drained (safe to free Root), 1 when
/// owned import/render/pinned-lease work remains, negative when fenced/refused.
/// It NEVER frees Root on a cancel request alone.
@_cdecl("floe_media_foundation_root_stop")
public func floeMediaFoundationRootStop(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return -105 }
    let status: Int32? = g09r2HostBlocking {
        guard let current = await BridgeV5.service.r2BoundCluster() else {
            return 0
        }
        guard current.epoch == epoch else { return -102 }
        let released = await BridgeV5.service.close(epoch: epoch)
        if released { return 0 }
        let stillBound = await BridgeV5.service.r2BoundCluster()
        return stillBound == nil ? 0 : 1
    }
    return status ?? -105
}

/// Owned work for the exact generation: render mailbox queued/claimed +
/// streamed import workers/records + live snapshot pins. 0 = drained.
@_cdecl("floe_media_foundation_drain_pending")
public func floeMediaFoundationDrainPending(_ epoch: UInt64) -> Int32 {
    guard epoch > 0 else { return 0 }
    G09R2RenderBindingPins.shared.purgeExpired(epoch: epoch)
    let render = G09R2MediaRenderHostMailbox.shared.drainStatus(epoch: epoch)
    let imports = G09R2LargeImportService.shared.pendingCount(epoch: epoch)
    let pins = G09R2SnapshotLeases.shared.pinnedCount(epoch: epoch)
    // A live App foreground lease is REAL ownership: the notification service
    // has not stopped, so Root must stay bound until the host releases it.
    let foreground = G09R2ForegroundCoordinator.shared.leaseCount(epoch: epoch)
    return Int32(render.queued + render.claimed + imports + pins + foreground)
}
