// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — native media foundation (job-b72b2978320e484e).
//
// This is the ADDITIVE R2 layer on top of the accepted R1 creative authority:
//
//  * typed `floe.creative/6` video load/apply routed through the EXISTING
//    shared `MediaTransactions` engine (one revision CAS + one undo step per
//    batch, durable opID intent/receipt);
//  * native-issued immutable render snapshots + bounded leases;
//  * native-owned render-ticket descriptors for the bounded CABI/JNI transport;
//  * exact-epoch root stop that refuses new work and retires owned snapshots
//    without deleting original project assets.
//
// It binds to the SAME `G09CreativeDomainService` cluster (root + media host +
// asset host); there is no second database, project store or fallback root.
// Generation and design actions are protocol-known but NOT implemented here:
// the bridge answers them with typed `generationUnavailable` /
// `designTargetUnavailable`, never a fabricated result.
import Foundation
import FloeCore
import FloeAndroidWorkbench
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Typed failures

/// R2 wire error with the frozen `G09R2WireError` code vocabulary. R1 codes
/// (`invalidPayload`, `staleSession`, `revisionConflict`, `projectTooLarge`,
/// `storageUnavailable`, `writeFailed`, `outcomeUnknown`, ...) stay on
/// `G09CreativeError` and are reused verbatim.
public struct G09R2Error: Error, Sendable, Equatable {
    public let wire: G09R2WireError
    public let detail: String?

    public init(_ wire: G09R2WireError, detail: String? = nil) {
        self.wire = wire
        self.detail = detail
    }

    public var code: String { wire.code }
    public var retryable: Bool { wire.retryable }
}

/// Deterministic wire digests. The digest is computed by the native side and
/// is the only render-snapshot input the platform may compare; Kotlin never
/// re-derives a canonical project.
public enum G09R2MediaDigests {
    public static let timelineScheme = "floe.g09.timeline/1"

    public static func timeline(_ timeline: VideoTimeline) -> String {
        let encoder = G09CreativeWire.encoder()
        let data = (try? encoder.encode(timeline)) ?? Data()
        return FloeDigest.sha256Hex(Data("\(timelineScheme)|".utf8) + data)
    }
}

// MARK: - Foundation service

public actor G09R2MediaFoundation {
    public static let shared = G09R2MediaFoundation()

    public struct VideoLoadResult: Sendable {
        public let envelope: G09R2VideoEnvelopeDTO
        public let timelineDigest: String
    }

    public init() {}

    // MARK: Video (typed R2 projection over the shared engine)

    /// `media.video.load`: trusted typed read projection for one exact
    /// project/storage/origin context, registering the media editor session
    /// with the same rules as `media.project.load`.
    public func loadVideo(service: G09CreativeDomainService, epoch: UInt64,
                          request: G09R2VideoLoadRequest) async throws
        -> VideoLoadResult {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireSessionToken(request.context.sessionToken)
        let loaded: G09MediaProjectHost.Loaded
        do {
            loaded = try await cluster.media.load(
                id: request.context.projectID,
                requested: request.context.storage,
                origin: request.context.origin)
        } catch let typed as G09CreativeError {
            throw typed
        }
        let timeline = loaded.project.videoTimeline ?? VideoTimeline()
        try await service.r2RegisterMediaSession(
            projectID: request.context.projectID,
            token: request.context.sessionToken)
        let envelope = G09R2VideoEnvelopeDTO(
            project: loaded.project,
            timeline: timeline,
            mediaRootPath: loaded.storage.rootURL.path,
            storage: loaded.storage.storage,
            writable: loaded.writable,
            warnings: loaded.warnings)
        return VideoLoadResult(
            envelope: envelope,
            timelineDigest: G09R2MediaDigests.timeline(timeline))
    }

    /// `media.video.apply`: decodes the closed typed command vocabulary and
    /// executes ONE durable batch on the existing media host (revision CAS,
    /// durable intent, one undo step, stable opID receipt). No DTO is written
    /// back wholesale, so unknown project subtrees are preserved.
    public func applyVideo(service: G09CreativeDomainService, epoch: UInt64,
                           request: G09R2VideoApplyRequest) async throws
        -> G09MediaProjectReceiptDTO {
        _ = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireSessionToken(request.context.sessionToken)
        try await service.r2RequireMediaSession(
            projectID: request.context.projectID,
            token: request.context.sessionToken)
        guard !request.opID.isEmpty, G09CreativeWire.safeOperationID(request.opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard !request.commands.isEmpty,
              request.commands.count <= G09R2CreativeLimits.mediaCommands else {
            throw G09CreativeError.invalidPayload("invalidCommandCount")
        }
        if let receipt = try? await mediaReadReceipt(service, opID: request.opID) {
            guard receipt.projectID == request.context.projectID else {
                throw G09CreativeError.invalidPayload("receiptProjectMismatch")
            }
            return G09MediaProjectReceiptDTO(
                projectID: receipt.projectID, revision: receipt.revision,
                canUndo: receipt.canUndo, canRedo: receipt.canRedo,
                opID: receipt.opID, idempotent: true)
        }
        let shared = request.commands.map { $0.sharedCommand() }
        let loaded = try await mediaApply(
            service,
            projectID: request.context.projectID,
            expectedRevision: request.expectedRevision,
            sessionToken: request.context.sessionToken,
            storage: request.context.storage,
            origin: request.context.origin,
            opID: request.opID,
            commands: shared)
        let receipt = G09MediaWriteReceipt(
            opID: request.opID, projectID: loaded.project.id,
            sessionDigest: G09CreativeAssetHost.sessionDigest(request.context.sessionToken),
            expectedRevision: request.expectedRevision,
            revision: loaded.project.revision,
            canUndo: MediaTransactions.canUndo(loaded.project),
            canRedo: MediaTransactions.canRedo(loaded.project))
        return G09MediaProjectReceiptDTO(
            projectID: receipt.projectID, revision: receipt.revision,
            canUndo: receipt.canUndo, canRedo: receipt.canRedo,
            opID: receipt.opID, idempotent: false)
    }

    // MARK: Render snapshot leases

    /// Writes ONE immutable, bounded project snapshot under the trusted media
    /// root and returns the native-issued lease. The snapshot file is the only
    /// project input a renderer may open; it is never the mutable latest file.
    public func acquireSnapshot(
        service: G09CreativeDomainService, epoch: UInt64,
        request: G09R2RenderSnapshotRequestDTO
    ) async throws -> G09R2RenderSnapshotLeaseDTO {
        _ = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireSessionToken(request.context.sessionToken)
        try await service.r2RequireMediaSession(
            projectID: request.context.projectID,
            token: request.context.sessionToken)
        G09R2SnapshotLeases.shared.purgeExpired()

        let loaded = try await mediaLoad(
            service, projectID: request.context.projectID,
            storage: request.context.storage, origin: request.context.origin)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == request.expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        let timeline = loaded.project.videoTimeline ?? VideoTimeline()
        let actualDigest = G09R2MediaDigests.timeline(timeline)
        guard actualDigest.caseInsensitiveCompare(request.expectedTimelineDigest)
                == .orderedSame else {
            throw G09R2Error(.renderTicketExpired, detail: "timelineDigestMismatch")
        }

        let rootPath = loaded.storage.rootURL.path
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
        // Pin every referenced asset by verifying it is inside the trusted
        // root and present. Nothing is copied or rewritten.
        var pinned: [String] = []
        for asset in loaded.project.assets {
            guard G09CreativeAssetHost.safeRelativePath(asset.relativePath),
                  let url = Self.containedURL(root: rootURL,
                                         relativePath: asset.relativePath) else {
                throw G09CreativeError.assetReferenceInvalid
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw G09CreativeError.assetMissing
            }
            pinned.append(url.path)
        }

        // Snapshot is the exact current project state (bounded by the frozen
        // 8 MiB project cap); no history is rewritten or appended.
        let encoder = G09CreativeWire.encoder()
        var data: Data
        do {
            data = try encoder.encode(loaded.project)
        } catch {
            throw G09CreativeError.storageUnavailable
        }
        guard data.count <= G09CreativeLimits.mediaProjectBytes else {
            throw G09CreativeError.projectTooLarge
        }
        let leaseID = UUID().uuidString.lowercased()
        let relativePath = "Workbench/Snapshots/\(leaseID).json"
        guard let target = Self.containedURL(root: rootURL, relativePath: relativePath) else {
            throw G09CreativeError.storageUnavailable
        }
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw G09CreativeError.storageUnavailable
        }
        let temporary = directory.appendingPathComponent(
            ".\(leaseID).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [])
            try Self.flushFile(temporary)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw G09CreativeError.storageUnavailable
            }
            try FileManager.default.moveItem(at: temporary, to: target)
            try Self.flushDirectory(directory)
        } catch let typed as G09CreativeError {
            try? FileManager.default.removeItem(at: temporary)
            throw typed
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw G09CreativeError.writeFailed
        }
        guard let sha = try? FloeDigest.sha256Hex(ofFileAt: target) else {
            try? FileManager.default.removeItem(at: target)
            throw G09CreativeError.writeFailed
        }
        let createdAt = Date()
        let record = G09R2SnapshotLeaseRecord(
            leaseID: leaseID,
            epoch: epoch,
            projectID: loaded.project.id,
            revision: loaded.project.revision,
            timelineDigest: actualDigest,
            mediaRootPath: rootPath,
            relativePath: relativePath,
            sha256: sha,
            byteCount: Int64(data.count),
            storage: loaded.storage.storage,
            origin: request.context.origin,
            ownerReference: G09CreativeAssetHost.sessionDigest(
                request.context.sessionToken),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(
                G09R2SnapshotLeases.lifetimeSeconds),
            pinnedAssets: pinned)
        do {
            try G09R2SnapshotLeases.shared.insert(record, snapshotURL: target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return G09R2RenderSnapshotLeaseDTO(
            leaseID: leaseID,
            mediaRootPath: rootPath,
            relativePath: relativePath,
            sha256: sha,
            byteCount: Int64(data.count),
            expiresAt: record.expiresAt)
    }

    /// Idempotent lease release. Rejects a foreign epoch; recovers ONLY the
    /// owned snapshot temp and never an original project asset.
    public func releaseSnapshot(
        service: G09CreativeDomainService, epoch: UInt64,
        lease: G09R2RenderSnapshotLeaseDTO
    ) async throws {
        _ = try await requireCluster(service, epoch: epoch)
        guard G09R2SnapshotLeases.shared.release(lease, epoch: epoch) else {
            // Either the record/fields/epoch do not match, or a live native
            // ticket pin owns the snapshot. The unconditional file delete is
            // deferred to the last unpin; this call never removes it.
            throw G09R2Error(.renderTicketExpired, detail: "leasePinnedOrMismatch")
        }
    }

    /// Exact-epoch root stop cleanup (called by the creative close gate).
    /// Best-effort and synchronous so root retirement is never blocked on an
    /// actor hop; only digest-verified owned snapshots are deleted.
    public nonisolated static func retireSnapshots(epoch: UInt64) {
        G09R2SnapshotLeases.shared.retire(epoch: epoch)
    }

    // MARK: Prepared render binding (plain App host seam)

    /// One native call that resolves the ACTUAL canonical project digest and
    /// writes the immutable snapshot lease for either an image or a video
    /// project. The UI/App never reconstructs canonical Swift JSON and never
    /// reopens the mutable latest project. The returned object is exactly the
    /// frozen `G09R2MediaExportBindingDTO`, ready to be mapped by the Main
    /// adapter to `MediaExportBinding`.
    ///
    /// For a pure image project the timeline component is empty, so the
    /// digest is the canonical empty-timeline digest; image-state immutability
    /// is bound by the native project id + exact revision + snapshot SHA-256/
    /// size in the lease, not by any caller-derived value.
    public func prepareRenderBinding(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, expectedRevision: Int64,
        attemptID: String
    ) async throws -> G09R2MediaExportBindingDTO {
        _ = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireSessionToken(context.sessionToken)
        guard Self.safeToken(attemptID, limit: 64) else {
            throw G09CreativeError.invalidPayload("invalidAttemptID")
        }
        let loaded = try await mediaLoad(
            service, projectID: context.projectID,
            storage: context.storage, origin: context.origin)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        guard loaded.project.revision == expectedRevision else {
            throw G09CreativeError.revisionConflict
        }
        try await service.r2RegisterMediaSession(
            projectID: context.projectID, token: context.sessionToken)
        let timeline = loaded.project.videoTimeline ?? VideoTimeline()
        let digest = G09R2MediaDigests.timeline(timeline)
        let lease = try await acquireSnapshot(
            service: service, epoch: epoch,
            request: G09R2RenderSnapshotRequestDTO(
                context: context, expectedRevision: expectedRevision,
                expectedTimelineDigest: digest))
        guard lease.mediaRootPath == loaded.storage.rootURL.path else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseRootMismatch")
        }
        let binding = G09R2MediaExportBindingDTO(
            context: context,
            mediaRootPath: lease.mediaRootPath,
            projectRevision: expectedRevision,
            timelineDigest: digest,
            attemptID: attemptID,
            snapshot: lease)
        // Remember the exact native attempt -> lease identity so the plain
        // platform lifecycle pin can pin THIS lease without receiving one by
        // value (bounded; replaced on the same attempt key).
        G09R2RenderBindingPins.shared.registerPrepared(
            epoch: epoch, binding: binding)
        return binding
    }

    // MARK: Render ticket production (native side of the bounded transport)

    /// Creates ONE bounded render ticket for an already-acquired snapshot
    /// lease. The descriptor references the snapshot FILE, never inline 8 MiB
    /// project JSON, and is native-issued: the caller cannot invent a root,
    /// path, digest or owner.
    public func submitRenderTicket(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO,
        projectRevision: Int64, timelineDigest: String,
        attemptID: String, kind: G09R2MediaExportKind,
        lease: G09R2RenderSnapshotLeaseDTO,
        videoSettings: G09R2VideoExportSettingsDTO? = nil,
        imageSettings: G09R2ImageExportSettingsDTO? = nil,
        previewWindow: G09R2PreviewWindowDTO? = nil
    ) async throws -> G09R2RenderTicketDescriptorDTO {
        _ = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireSessionToken(context.sessionToken)
        guard Self.safeToken(attemptID, limit: 64) else {
            throw G09CreativeError.invalidPayload("invalidAttemptID")
        }
        let record = try G09R2SnapshotLeases.shared.verify(
            lease, epoch: epoch, projectID: context.projectID,
            revision: projectRevision, timelineDigest: timelineDigest,
            storage: context.storage, sessionToken: context.sessionToken)
        _ = try G09R2SnapshotLeases.shared.verifyFile(leaseID: lease.leaseID)

        guard let outputExtension = try Self.outputExtension(
            kind: kind, video: videoSettings, image: imageSettings) else {
            throw G09R2Error(.renderUnsupported, detail: "invalidExportSettings")
        }
        let outputRelativePath = "Workbench/Exports/\(attemptID).\(outputExtension)"
        let now = Date()
        guard record.expiresAt > now.addingTimeInterval(60) else {
            throw G09R2Error(.renderTicketExpired, detail: "leaseExpiring")
        }
        var descriptor = G09R2RenderTicketDescriptorDTO(
            ticketID: UUID().uuidString.lowercased(),
            descriptorVersion: 1,
            kind: kind,
            projectID: context.projectID,
            attemptID: attemptID,
            mediaRootPath: record.mediaRootPath,
            storage: record.storage,
            origin: context.origin,
            projectRevision: projectRevision,
            timelineDigest: timelineDigest,
            leaseID: lease.leaseID,
            ownerReference: record.ownerReference,
            epoch: epoch,
            snapshotRelativePath: record.relativePath,
            snapshotSHA256: record.sha256,
            snapshotByteCount: record.byteCount,
            snapshotLeaseExpiresAt: record.expiresAt,
            outputRelativePath: outputRelativePath,
            videoSettings: videoSettings,
            imageSettings: imageSettings,
            previewWindow: previewWindow,
            expiresAt: min(record.expiresAt, now.addingTimeInterval(300)),
            descriptorByteCount: 0)
        let data = try Self.encodeDescriptor(&descriptor)
        guard data.count <= G09R2CreativeLimits.renderDescriptorBytes else {
            throw G09R2Error(.renderTicketExpired, detail: "descriptorTooLarge")
        }
        // Native pin: the exact immutable snapshot stays owned while this
        // ticket may still read it, even if the caller releases or the lease
        // expires before host settlement.
        guard G09R2SnapshotLeases.shared.pin(
            leaseID: lease.leaseID, owner: descriptor.ticketID) else {
            throw G09R2Error(.rendererUnavailable, detail: "leasePinRefused")
        }
        do {
            try G09R2MediaRenderHostMailbox.shared.submit(
                descriptor: descriptor, descriptorData: data, epoch: epoch)
        } catch {
            G09R2SnapshotLeases.shared.unpin(
                leaseID: lease.leaseID, owner: descriptor.ticketID)
            throw error
        }
        return descriptor
    }

    /// Waits for one terminal settlement outside the creative exchange. A
    /// bounded poll timeout returns nil (the ticket remains owned).
    public func awaitRenderReply(ticketID: String,
                                 timeoutMillis: Int) async throws
        -> G09R2RenderTicketReplyDTO? {
        try await G09R2MediaRenderHostMailbox.shared.awaitReply(
            ticketID: ticketID, timeoutMillis: timeoutMillis)
    }

    /// Honest tool-export capability: the route is the real render-ticket
    /// transport, but registration is deliberately deferred to the later
    /// packaged tool owner. No fake exporter and no success string.
    public nonisolated func exportCapability()
        -> G09R2MediaProjectToolExportCapabilityDTO {
        G09R2MediaProjectToolExportCapabilityDTO(
            route: .renderTicket,
            registered: false,
            reason: "toolRegistrationDeferred",
            supportedActions: ["read", "propose", "apply", "export"])
    }

    // MARK: - Helpers

    private func requireCluster(_ service: G09CreativeDomainService,
                                epoch: UInt64) async throws -> G09R2BoundCluster {
        guard let cluster = await service.r2BoundCluster(), cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        return cluster
    }

    private func requireNoRootStop(_ service: G09CreativeDomainService,
                                   epoch: UInt64) async throws {
        guard !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch),
              !(await service.r2IsRootStopping(epoch: epoch)) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
    }

    private func requireSessionToken(_ token: String) throws {
        guard G09CreativeWire.validSessionToken(token) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
    }

    private func mediaLoad(_ service: G09CreativeDomainService, projectID: UUID,
                           storage: G09StorageLayerDTO,
                           origin: G09CreativeOriginDTO?) async throws
        -> G09MediaProjectHost.Loaded {
        guard let cluster = await service.r2BoundCluster() else {
            throw G09CreativeError.staleGeneration
        }
        return try await cluster.media.load(
            id: projectID, requested: storage, origin: origin)
    }

    private func mediaApply(_ service: G09CreativeDomainService,
                            projectID: UUID, expectedRevision: Int64,
                            sessionToken: String,
                            storage: G09StorageLayerDTO,
                            origin: G09CreativeOriginDTO?, opID: String,
                            commands: [MediaEditCommand]) async throws
        -> G09MediaProjectHost.Loaded {
        guard let cluster = await service.r2BoundCluster() else {
            throw G09CreativeError.staleGeneration
        }
        return try await cluster.media.applyShared(
            projectID: projectID, expectedRevision: expectedRevision,
            sessionToken: sessionToken, storage: storage, origin: origin,
            opID: opID, commands: commands)
    }

    private func mediaReadReceipt(_ service: G09CreativeDomainService, opID: String)
        async throws -> G09MediaWriteReceipt {
        guard let cluster = await service.r2BoundCluster() else {
            throw G09CreativeError.staleGeneration
        }
        return try await cluster.media.readReceipt(opID)
    }

    nonisolated static func containedURL(root: URL,
                                         relativePath: String) -> URL? {
        guard G09CreativeAssetHost.safeRelativePath(relativePath),
              !relativePath.isEmpty else { return nil }
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }

    nonisolated static func safeToken(_ value: String, limit: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= limit,
              !value.hasPrefix(".") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ||
                $0 == "."
        }
    }

    nonisolated static func outputExtension(
        kind: G09R2MediaExportKind,
        video: G09R2VideoExportSettingsDTO?,
        image: G09R2ImageExportSettingsDTO?) throws -> String? {
        switch kind {
        case .video:
            guard let video else {
                throw G09R2Error(.renderUnsupported, detail: "missingVideoSettings")
            }
            let mime = video.codecMime.lowercased()
            guard mime == "video/avc" || mime == "video/hevc" else {
                throw G09R2Error(.unsupportedCodec, detail: "unsupportedCodec")
            }
            guard (2...8192).contains(video.width),
                  (2...8192).contains(video.height),
                  video.frameRate.isFinite, video.frameRate >= 1,
                  video.frameRate <= 240,
                  video.quality.isFinite, video.quality >= 0, video.quality <= 1,
                  safeToken(video.fileName, limit: 96), image == nil else {
                throw G09R2Error(.renderUnsupported, detail: "invalidVideoSettings")
            }
            return "mp4"
        case .image:
            guard let image else {
                throw G09R2Error(.renderUnsupported, detail: "missingImageSettings")
            }
            let format = image.format.lowercased()
            guard ["png", "jpeg", "heic"].contains(format),
                  image.quality.isFinite, image.quality >= 0, image.quality <= 1,
                  safeToken(image.fileName, limit: 96), video == nil else {
                throw G09R2Error(.renderUnsupported, detail: "invalidImageSettings")
            }
            if let width = image.width, !(2...8192).contains(width) {
                throw G09R2Error(.renderUnsupported, detail: "invalidImageWidth")
            }
            if let height = image.height, !(2...8192).contains(height) {
                throw G09R2Error(.renderUnsupported, detail: "invalidImageHeight")
            }
            if format == "jpeg", image.preserveTransparency {
                throw G09R2Error(.renderUnsupported,
                                 detail: "jpegTransparencyUnsupported")
            }
            return format == "jpeg" ? "jpg" : format
        case .preview:
            guard video == nil, image == nil else {
                throw G09R2Error(.renderUnsupported, detail: "previewSettingsNotAllowed")
            }
            return "png"
        }
    }

    nonisolated static func encodeDescriptor(
        _ descriptor: inout G09R2RenderTicketDescriptorDTO) throws -> Data {
        var value = descriptor
        value.descriptorByteCount = 0
        var data = try G09CreativeWire.encoder().encode(value)
        value.descriptorByteCount = data.count
        data = try G09CreativeWire.encoder().encode(value)
        if data.count != value.descriptorByteCount {
            value.descriptorByteCount = data.count
            data = try G09CreativeWire.encoder().encode(value)
        }
        descriptor = value
        return data
    }

    private nonisolated static func flushFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw G09CreativeError.writeFailed }
    }

    private nonisolated static func flushDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}
