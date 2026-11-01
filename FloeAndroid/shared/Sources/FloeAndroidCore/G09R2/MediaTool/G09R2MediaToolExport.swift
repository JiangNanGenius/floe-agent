// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — real render-ticket export path for `media.project`
// (job-258c68e91e6840df).
//
// The tool host never renders pixels itself. It writes ONE immutable project
// snapshot under the accepted media root, submits a native-issued ticket to
// the existing bounded mailbox, awaits the real Kotlin Media3/Bitmap
// consumer on an independent lane, then verifies the returned receipt and the
// actual output bytes before mapping the portable public receipt value.
//
// There is no reverse blocking call into the creative exchange, no synthetic
// receipt, no fallback encoder and no second export attempt after an unknown
// outcome.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidWorkbench

struct G09R2MediaToolPreparedExport: Sendable {
    let descriptor: G09R2RenderTicketDescriptorDTO
    let lease: G09R2RenderSnapshotLeaseDTO
    let snapshotURL: URL
    let outputURL: URL
    let prePinOwner: String
}

enum G09R2MediaToolExport {
    static func prepare(
        session: G09R2MediaToolSession,
        kind: G09R2MediaExportKind,
        outputRelativePath: String,
        imageSettings: G09R2ImageExportSettingsDTO?,
        videoSettings: G09R2VideoExportSettingsDTO?,
        mailbox: G09R2MediaRenderHostMailbox
    ) async throws -> G09R2MediaToolPreparedExport {
        G09R2SnapshotLeases.shared.purgeExpired()
        let extensionValue: String
        switch kind {
        case .image:
            guard let imageSettings, videoSettings == nil,
                  ["png", "jpeg"].contains(imageSettings.format.lowercased()),
                  G09R2MediaProjectToolHost.safeExportComponent(imageSettings.fileName) else {
                throw G09R2MediaToolFailure.exportUnsupported("invalid image settings").floError
            }
            extensionValue = imageSettings.format.lowercased()
        case .video:
            guard let videoSettings, imageSettings == nil,
                  G09R2MediaProjectToolHost.safeExportComponent(videoSettings.fileName) else {
                throw G09R2MediaToolFailure.exportUnsupported("invalid video settings").floError
            }
            extensionValue = "mp4"
        case .preview:
            throw G09R2MediaToolFailure.exportUnsupported("preview tickets are not a tool export").floError
        }
        let expectedRelative = "Workbench/Exports/" +
            (kind == .image ? imageSettings!.fileName : videoSettings!.fileName) +
            "." + extensionValue
        guard outputRelativePath == expectedRelative else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "the export path is not the owned Workbench/Exports location").floError
        }
        let storageRoot = session.projectRoot
        // The per-project media root is the trusted storage layer's path and
        // may not exist before the first asset/export. Create only THIS
        // trusted directory (never a fallback root), then require it to be a
        // real directory (not a symlink).
        guard storageRoot.path.hasPrefix(session.root.path + "/") else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "the media root is outside the accepted generation").floError
        }
        if !G09R2MediaToolFile.isRealDirectory(storageRoot.path) {
            if G09R2MediaToolFile.isSymlink(storageRoot.path) {
                throw G09R2MediaToolFailure.exportUnsupported(
                    "the media root is not a real directory").floError
            }
            do {
                try FileManager.default.createDirectory(
                    at: storageRoot, withIntermediateDirectories: true)
            } catch {
                throw G09R2MediaToolFailure.exportFailed("mediaRootUnavailable").floError
            }
            guard G09R2MediaToolFile.isRealDirectory(storageRoot.path) else {
                throw G09R2MediaToolFailure.exportFailed("mediaRootUnavailable").floError
            }
        }
        // The platform canonicalizes the root before echoing it in a receipt.
        // Use the same canonical spelling here so the broker compares the
        // exact same real directory on every hop (/var vs /private/var,
        // /data/user/0 vs /data/data on some devices).
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        let acceptedCanonical = URL(fileURLWithPath: session.root.path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(acceptedCanonical.path + "/") else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "the media root resolves outside the accepted generation").floError
        }
        let exportsDirectory = try G09R2MediaToolFile.ensureRealSubdirectories(
            root: root, components: ["Workbench", "Exports"])
        let snapshotDirectory = try G09R2MediaToolFile.ensureRealSubdirectories(
            root: root, components: ["Workbench", "Snapshots"])
        guard let outputURL = G09R2MediaToolFile.containedURL(
            root: root, relativePath: expectedRelative),
              outputURL.deletingLastPathComponent().standardizedFileURL
                == exportsDirectory.standardizedFileURL else {
            throw G09R2MediaToolFailure.exportUnsupported(
                "the export path leaves the owned project root").floError
        }
        guard G09R2MediaToolFile.regularFileSize(outputURL.path) == nil else {
            throw G09R2MediaToolFailure.exportFailed("exportAlreadyExists").floError
        }

        // Every referenced source asset must be a real contained file. The
        // snapshot stores the project bytes; asset bytes stay in place and are
        // never rewritten by an export.
        var pinnedAssets: [String] = []
        for asset in session.project.assets {
            guard let url = G09R2MediaToolFile.containedURL(
                root: root, relativePath: asset.relativePath),
                  G09R2MediaToolFile.regularFileSize(url.path) != nil else {
                throw G09R2MediaToolFailure.exportFailed("assetMissing").floError
            }
            pinnedAssets.append(url.path)
        }

        let leaseID = UUID().uuidString.lowercased()
        let snapshotRelative = "Workbench/Snapshots/\(leaseID).json"
        guard let snapshotURL = G09R2MediaToolFile.containedURL(
            root: root, relativePath: snapshotRelative),
              snapshotURL.deletingLastPathComponent().standardizedFileURL
                == snapshotDirectory.standardizedFileURL else {
            throw G09R2MediaToolFailure.exportFailed("snapshotPath").floError
        }
        let data: Data
        do {
            data = try G09CreativeWire.encoder().encode(session.project)
        } catch {
            throw FloeError.storageCorrupted("The media project could not be snapshotted")
        }
        guard data.count <= G09R2CreativeLimits.mediaProjectBytes else {
            throw G09R2MediaToolFailure.exportFailed("projectTooLarge").floError
        }
        do {
            try G09R2MediaToolFile.writeAtomically(
                data, to: snapshotURL, replaceExisting: false)
        } catch {
            throw G09R2MediaToolFailure.exportFailed("snapshotWrite").floError
        }
        guard let sha = try? G09R2MediaToolFile.digest(ofFileAt: snapshotURL) else {
            try? FileManager.default.removeItem(at: snapshotURL)
            throw G09R2MediaToolFailure.exportFailed("snapshotDigest").floError
        }
        let timeline = session.project.videoTimeline ?? VideoTimeline()
        let timelineDigest = G09R2MediaDigests.timeline(timeline)
        let now = Date()
        let expiresAt = now.addingTimeInterval(G09R2SnapshotLeases.lifetimeSeconds)
        let record = G09R2SnapshotLeaseRecord(
            leaseID: leaseID,
            epoch: session.epoch,
            projectID: session.project.id,
            revision: session.project.revision,
            timelineDigest: timelineDigest,
            mediaRootPath: root.path,
            relativePath: snapshotRelative,
            sha256: sha,
            byteCount: Int64(data.count),
            storage: session.storage,
            origin: session.origin,
            ownerReference: session.accessProof,
            createdAt: now,
            expiresAt: expiresAt,
            pinnedAssets: pinnedAssets)
        do {
            try G09R2SnapshotLeases.shared.insert(record, snapshotURL: snapshotURL)
        } catch {
            try? FileManager.default.removeItem(at: snapshotURL)
            throw G09R2MediaToolFailure.exportFailed("snapshotLease").floError
        }
        let prePinOwner = "mt.\(leaseID)"
        guard G09R2SnapshotLeases.shared.pin(
            leaseID: leaseID, owner: prePinOwner) else {
            G09R2SnapshotLeases.shared.release(
                G09R2RenderSnapshotLeaseDTO(
                    leaseID: leaseID, mediaRootPath: root.path,
                    relativePath: snapshotRelative, sha256: sha,
                    byteCount: Int64(data.count), expiresAt: expiresAt),
                epoch: session.epoch)
            throw G09R2MediaToolFailure.exportFailed("leasePin").floError
        }

        let ticketID = UUID().uuidString.lowercased()
        var descriptor = G09R2RenderTicketDescriptorDTO(
            ticketID: ticketID,
            descriptorVersion: 1,
            kind: kind,
            projectID: session.project.id,
            attemptID: kind == .image ? imageSettings!.fileName : videoSettings!.fileName,
            mediaRootPath: root.path,
            storage: session.storage,
            origin: session.origin,
            projectRevision: session.project.revision,
            timelineDigest: timelineDigest,
            leaseID: leaseID,
            ownerReference: session.accessProof,
            epoch: session.epoch,
            snapshotRelativePath: snapshotRelative,
            snapshotSHA256: sha,
            snapshotByteCount: Int64(data.count),
            snapshotLeaseExpiresAt: expiresAt,
            outputRelativePath: expectedRelative,
            videoSettings: videoSettings,
            imageSettings: imageSettings,
            previewWindow: nil,
            // The mailbox hard deadline is 10 minutes; the tool uses the full
            // bounded transport budget instead of shortening long exports.
            expiresAt: min(expiresAt, now.addingTimeInterval(600)),
            descriptorByteCount: 0)
        let descriptorData: Data
        do {
            descriptorData = try encodeDescriptor(&descriptor)
        } catch {
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: prePinOwner)
            G09R2SnapshotLeases.shared.release(
                G09R2RenderSnapshotLeaseDTO(
                    leaseID: leaseID, mediaRootPath: root.path,
                    relativePath: snapshotRelative, sha256: sha,
                    byteCount: Int64(data.count), expiresAt: expiresAt),
                epoch: session.epoch)
            throw FloeError.storageCorrupted("The render ticket could not be encoded")
        }
        guard descriptorData.count <= G09R2CreativeLimits.renderDescriptorBytes,
              descriptor.expiresAt > now else {
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: prePinOwner)
            G09R2SnapshotLeases.shared.release(
                G09R2RenderSnapshotLeaseDTO(
                    leaseID: leaseID, mediaRootPath: root.path,
                    relativePath: snapshotRelative, sha256: sha,
                    byteCount: Int64(data.count), expiresAt: expiresAt),
                epoch: session.epoch)
            throw G09R2MediaToolFailure.exportFailed("descriptorTooLarge").floError
        }
        guard G09R2SnapshotLeases.shared.pin(
            leaseID: leaseID, owner: ticketID) else {
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: prePinOwner)
            G09R2SnapshotLeases.shared.release(
                G09R2RenderSnapshotLeaseDTO(
                    leaseID: leaseID, mediaRootPath: root.path,
                    relativePath: snapshotRelative, sha256: sha,
                    byteCount: Int64(data.count), expiresAt: expiresAt),
                epoch: session.epoch)
            throw G09R2MediaToolFailure.exportFailed("leasePin").floError
        }
        do {
            try mailbox.submit(descriptor: descriptor, descriptorData: descriptorData,
                               epoch: session.epoch)
        } catch {
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: ticketID)
            G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: prePinOwner)
            G09R2SnapshotLeases.shared.release(
                G09R2RenderSnapshotLeaseDTO(
                    leaseID: leaseID, mediaRootPath: root.path,
                    relativePath: snapshotRelative, sha256: sha,
                    byteCount: Int64(data.count), expiresAt: expiresAt),
                epoch: session.epoch)
            throw G09R2MediaToolAccess.floError(error)
        }
        G09R2SnapshotLeases.shared.unpin(leaseID: leaseID, owner: prePinOwner)
        let lease = G09R2RenderSnapshotLeaseDTO(
            leaseID: leaseID, mediaRootPath: root.path,
            relativePath: snapshotRelative, sha256: sha,
            byteCount: Int64(data.count), expiresAt: expiresAt)
        return G09R2MediaToolPreparedExport(
            descriptor: descriptor, lease: lease, snapshotURL: snapshotURL,
            outputURL: outputURL, prePinOwner: prePinOwner)
    }

    /// One bounded wait. A nil poll result is not a settlement; the loop
    /// continues until the descriptor's real terminal reply or the tool
    /// budget. Cancellation asks the mailbox to stop the real platform work;
    /// a root stop is reported as such. An unknown outcome never submits a
    /// second export.
    static func awaitTerminal(
        prepared: G09R2MediaToolPreparedExport,
        mailbox: G09R2MediaRenderHostMailbox,
        cancellation: CancellationToken?,
        config: G09R2MediaToolHostConfig
    ) async throws -> G09R2RenderTicketReplyDTO {
        let deadline = Date().addingTimeInterval(config.exportAwaitSeconds)
        let pollMillis = max(250, min(config.exportPollMillis, 5_000))
        while Date() < deadline {
            if cancellation?.isCancelled == true {
                _ = mailbox.cancelTicket(ticketID: prepared.descriptor.ticketID)
                throw FloeError.cancelled
            }
            if mailbox.isRootStopping(epoch: prepared.descriptor.epoch) {
                _ = mailbox.cancelTicket(ticketID: prepared.descriptor.ticketID)
                throw G09R2MediaToolFailure.generationStopped.floError
            }
            if let reply = try await mailbox.awaitReply(
                ticketID: prepared.descriptor.ticketID,
                timeoutMillis: pollMillis) {
                return reply
            }
        }
        throw G09R2MediaToolFailure.exportOutcomeUnknown.floError
    }

    /// Releases the ownership this call still holds. The ticket's own lease
    /// pin is NEVER removed here: an unknown/timeout/cancelled ticket may
    /// still be doing real codec/IO work. `release` is deferred until the
    /// ticket settlement performs the authenticated unpin; then only this
    /// lease's verified snapshot bytes are removed.
    static func abandon(_ prepared: G09R2MediaToolPreparedExport,
                        mailbox: G09R2MediaRenderHostMailbox) {
        _ = mailbox
        G09R2SnapshotLeases.shared.unpin(
            leaseID: prepared.lease.leaseID, owner: prepared.prePinOwner)
        _ = G09R2SnapshotLeases.shared.release(
            prepared.lease, epoch: prepared.descriptor.epoch)
    }

    /// A verified completed export: the mailbox already unpinned the claim,
    /// so this is the final idempotent release of the immutable snapshot.
    static func finish(_ prepared: G09R2MediaToolPreparedExport,
                       mailbox: G09R2MediaRenderHostMailbox) {
        _ = mailbox
        G09R2SnapshotLeases.shared.unpin(
            leaseID: prepared.lease.leaseID,
            owner: prepared.descriptor.ticketID)
        G09R2SnapshotLeases.shared.unpin(
            leaseID: prepared.lease.leaseID, owner: prepared.prePinOwner)
        _ = G09R2SnapshotLeases.shared.release(
            prepared.lease, epoch: prepared.descriptor.epoch)
    }

    // MARK: - Native receipt + byte verification

    static func verify(receipt: G09R2MediaExportReceiptDTO,
                       descriptor: G09R2RenderTicketDescriptorDTO,
                       expectedOwner: String,
                       expectedEpoch: UInt64) throws -> URL {
        guard descriptor.epoch == expectedEpoch,
              descriptor.ownerReference == expectedOwner,
              receipt.kind == descriptor.kind,
              receipt.binding.projectID == descriptor.projectID,
              receipt.binding.mediaRootPath == descriptor.mediaRootPath,
              receipt.binding.projectRevision == descriptor.projectRevision,
              receipt.binding.timelineDigest == descriptor.timelineDigest,
              receipt.binding.attemptID == descriptor.attemptID,
              receipt.outputRelativePath == descriptor.outputRelativePath,
              receipt.byteCount > 0,
              G09CreativeAssetHost.validDigest(receipt.sha256),
              receipt.verification.playable,
              (2...16384).contains(receipt.verification.width),
              (2...16384).contains(receipt.verification.height),
              receipt.verification.audioTrackCount >= 0 else {
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        switch descriptor.kind {
        case .image:
            guard let settings = descriptor.imageSettings,
                  descriptor.videoSettings == nil,
                  ["png", "jpeg"].contains(settings.format.lowercased()),
                  receipt.verification.codec.lowercased() == settings.format.lowercased(),
                  receipt.mimeType == (settings.format.lowercased() == "png"
                                       ? "image/png" : "image/jpeg") else {
                throw G09R2MediaToolFailure.exportFailed(
                    "renderOutputUnverified").floError
            }
        case .video:
            guard let settings = descriptor.videoSettings,
                  descriptor.imageSettings == nil,
                  receipt.verification.codec == settings.codecMime,
                  receipt.verification.container == "mp4",
                  receipt.mimeType == "video/mp4",
                  let duration = receipt.verification.decodedDurationSeconds,
                  duration.isFinite, duration > 0 else {
                throw G09R2MediaToolFailure.exportFailed(
                    "renderOutputUnverified").floError
            }
        case .preview:
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        let root = URL(fileURLWithPath: descriptor.mediaRootPath, isDirectory: true)
            .standardizedFileURL
        guard let url = G09R2MediaToolFile.containedURL(
            root: root, relativePath: receipt.outputRelativePath),
              url.path.hasPrefix(root.path + "/Workbench/Exports/"),
              let size = G09R2MediaToolFile.regularFileSize(url.path),
              size == receipt.byteCount else {
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        guard let digest = try? G09R2MediaToolFile.digest(ofFileAt: url),
              digest.caseInsensitiveCompare(receipt.sha256) == .orderedSame else {
            throw G09R2MediaToolFailure.exportFailed("renderOutputUnverified").floError
        }
        return url
    }

    // Same deterministic two-pass descriptor size stamp as the existing
    // native snapshot ABI producer.
    static func encodeDescriptor(
        _ descriptor: inout G09R2RenderTicketDescriptorDTO
    ) throws -> Data {
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
}

// MARK: - Bounded real asset dimension reader

/// Reads the actual pixel dimensions of the image formats the workbench image
/// editor supports (PNG/JPEG/WebP/GIF/BMP). It is a bounded header reader, not
/// a rasterizer: unsupported containers are refused, never guessed.
enum G09R2MediaToolImageDimensions {
    static func read(_ url: URL) throws -> (width: Int, height: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw G09R2MediaToolFailure.measurementUnavailable(
                "the asset could not be opened").floError
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        guard data.count >= 16 else {
            throw G09R2MediaToolFailure.measurementUnavailable(
                "the asset header is incomplete").floError
        }
        let bytes = [UInt8](data)
        if let size = png(bytes) { return try valid(size) }
        if let size = gif(bytes) { return try valid(size) }
        if let size = bmp(bytes) { return try valid(size) }
        if let size = webp(bytes) { return try valid(size) }
        if let size = jpeg(bytes) { return try valid(size) }
        throw G09R2MediaToolFailure.measurementUnavailable(
            "this image format has no supported dimension reader").floError
    }

    private static func valid(_ size: (Int, Int)) throws
        -> (width: Int, height: Int) {
        guard (1...30000).contains(size.0), (1...30000).contains(size.1) else {
            throw G09R2MediaToolFailure.measurementUnavailable(
                "the asset dimensions are invalid").floError
        }
        return (width: size.0, height: size.1)
    }

    private static func png(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 24,
              bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E,
              bytes[3] == 0x47, bytes[4] == 0x0D, bytes[5] == 0x0A,
              bytes[6] == 0x1A, bytes[7] == 0x0A,
              bytes[12] == 0x49, bytes[13] == 0x48,
              bytes[14] == 0x44, bytes[15] == 0x52 else { return nil }
        let width = be32(bytes, 16)
        let height = be32(bytes, 20)
        return (width, height)
    }

    private static func gif(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 10,
              bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        return (le16(bytes, 6), le16(bytes, 8))
    }

    private static func bmp(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 26, bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }
        let width = le32(bytes, 18)
        let rawHeight = le32(bytes, 22)
        return (width, abs(rawHeight))
    }

    private static func webp(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 30,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
              bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 else {
            return nil
        }
        switch (bytes[12], bytes[13], bytes[14], bytes[15]) {
        case (0x56, 0x50, 0x38, 0x58): // VP8X
            guard bytes.count >= 30 else { return nil }
            let width = le24(bytes, 24) + 1
            let height = le24(bytes, 27) + 1
            return (width, height)
        case (0x56, 0x50, 0x38, 0x4C): // VP8L
            guard bytes.count >= 25, bytes[20] == 0x2F else { return nil }
            let bits = UInt32(bytes[21]) | UInt32(bytes[22]) << 8 |
                UInt32(bytes[23]) << 16 | UInt32(bytes[24]) << 24
            let width = Int(bits & 0x3FFF) + 1
            let height = Int((bits >> 14) & 0x3FFF) + 1
            return (width, height)
        case (0x56, 0x50, 0x38, 0x20): // VP8
            guard bytes.count >= 30,
                  bytes[23] == 0x9D, bytes[24] == 0x01, bytes[25] == 0x2A else {
                return nil
            }
            let width = Int(le16(bytes, 26) & 0x3FFF)
            let height = Int(le16(bytes, 28) & 0x3FFF)
            return (width, height)
        default:
            return nil
        }
    }

    private static func jpeg(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        var orientation = 1
        while index + 4 <= bytes.count {
            if bytes[index] != 0xFF {
                index += 1
                continue
            }
            var marker = bytes[index + 1]
            var markerIndex = index
            while marker == 0xFF, markerIndex + 2 < bytes.count {
                markerIndex += 1
                marker = bytes[markerIndex + 1]
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index = markerIndex + 2
                continue
            }
            if marker == 0xD9 || marker == 0xDA { return nil }
            guard markerIndex + 4 <= bytes.count else { return nil }
            let length = Int(bytes[markerIndex + 2]) << 8 |
                Int(bytes[markerIndex + 3])
            guard length >= 2, markerIndex + 2 + length <= bytes.count else { return nil }
            if marker == 0xE1 {
                orientation = exifOrientation(
                    Array(bytes[(markerIndex + 4)..<(markerIndex + 2 + length)]))
            }
            let isSOF = (0xC0...0xC3).contains(marker) ||
                (0xC5...0xC7).contains(marker) ||
                (0xC9...0xCB).contains(marker) ||
                (0xCD...0xCF).contains(marker)
            if isSOF {
                guard markerIndex + 9 <= bytes.count else { return nil }
                let height = Int(bytes[markerIndex + 5]) << 8 |
                    Int(bytes[markerIndex + 6])
                let width = Int(bytes[markerIndex + 7]) << 8 |
                    Int(bytes[markerIndex + 8])
                if (5...8).contains(orientation) {
                    return (height, width)
                }
                return (width, height)
            }
            index = markerIndex + 2 + length
        }
        return nil
    }

    private static func exifOrientation(_ payload: [UInt8]) -> Int {
        guard payload.count >= 14,
              payload[0] == 0x45, payload[1] == 0x78, payload[2] == 0x69,
              payload[3] == 0x66, payload[4] == 0x00, payload[5] == 0x00 else {
            return 1
        }
        let tiff = 6
        let endianLittle: Bool
        if payload[tiff] == 0x49, payload[tiff + 1] == 0x49 {
            endianLittle = true
        } else if payload[tiff] == 0x4D, payload[tiff + 1] == 0x4D {
            endianLittle = false
        } else {
            return 1
        }
        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= payload.count else { return 0 }
            return endianLittle
                ? Int(payload[offset]) | Int(payload[offset + 1]) << 8
                : Int(payload[offset]) << 8 | Int(payload[offset + 1])
        }
        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= payload.count else { return 0 }
            let a = Int(payload[offset]), b = Int(payload[offset + 1])
            let c = Int(payload[offset + 2]), d = Int(payload[offset + 3])
            return endianLittle
                ? a | b << 8 | c << 16 | d << 24
                : a << 24 | b << 16 | c << 8 | d
        }
        guard u16(tiff + 2) == 42 else { return 1 }
        let ifd = tiff + u32(tiff + 4)
        guard ifd + 2 <= payload.count else { return 1 }
        let count = u16(ifd)
        guard count <= 256 else { return 1 }
        var entry = ifd + 2
        for _ in 0..<count {
            guard entry + 12 <= payload.count else { return 1 }
            if u16(entry) == 0x0112 {
                let value = u16(entry + 8)
                return (1...8).contains(value) ? value : 1
            }
            entry += 12
        }
        return 1
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 |
            Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func le24(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 |
            Int(bytes[offset + 2]) << 16
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 |
            Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
}
