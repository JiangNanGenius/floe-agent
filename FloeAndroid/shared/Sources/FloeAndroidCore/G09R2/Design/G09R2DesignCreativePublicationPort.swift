// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — PRODUCTION result publication for immutable design owners.
//
// This is the Android port of the approved public iOS publication port
// (`FloeAgent/FloeApp/Files/DesignResultPublication.swift`,
// `AppDesignResultPublicationPort`, public baseline 10fc0083). It is a
// COMPOSITE over the EXISTING owner stores:
//
//  * `chatAttachment` keeps the already-shipped
//    `G09R2DesignChatPublicationPort` (the originating task's attachment and
//    message semantics are unchanged);
//  * `creativeDocument` writes a NEW content-addressed asset into the SAME
//    `CreativeAssetStore` and `<acceptedRoot>/FloeAgent/Materials` authority.
//    There is no parallel media library, no hidden Canvas and no second
//    publication index.
//
// Binding + idempotence are structural, not best-effort:
//
//  * every derived identity is bound to the FULL frozen target
//    (`target.stableKey`), the publication destination and
//    `publication.publicationKey` (operationID|revisionID|contentSHA256). A
//    frozen `targetStableKey` that disagrees with the live target is refused,
//    so the same operation bytes for a DIFFERENT owner can never be labelled as
//    this owner's result;
//  * the expected creative asset id is deterministic from that binding, and the
//    content hash is the canonical row identity: identical bytes are ONE
//    canonical asset (a replay after a crash resolves the same row and returns
//    the same receipt, never a duplicate). A losing candidate id never owns the
//    durable file: the file name is based on the CANONICAL asset id;
//  * the receipt is issued only after the row AND the real contained bytes are
//    read back and hash-verified;
//  * the original source asset/file is never modified or deleted.
//
// A failure throws; the shared workflow then reports `publication.pending`,
// keeps the durable decision record open and retries the SAME idempotent
// publication on replay/reconcile. A publication is never claimed from a
// success string, a JSON label or an unverified path.
import Foundation
import FloeCore

/// Typed publication refusal whose `localizedDescription` is safe to surface
/// in the shared workflow's pending reason. No path or secret is included.
struct G09R2DesignPublicationError: Error, LocalizedError, Equatable, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}

// MARK: - Creative publication

/// Publishes an adopted creative result into the existing creative library.
struct G09R2DesignCreativePublicationPort: DesignResultPublicationPort {
    let assets: G09CreativeAssetHost

    static let maximumBytes = G09R2CreativeLimits.designSourceBytes

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        guard publication.target.kind == .creativeDocument else {
            throw G09R2DesignPublicationError(
                reason: "the creative publication destination only serves creativeDocument targets")
        }
        let targetKey = try Self.validatedTargetKey(publication)
        guard !publication.target.ownerID.isEmpty,
              publication.target.ownerID.utf8.count <= 1024 else {
            throw G09R2DesignPublicationError(
                reason: "the creative owner identity is empty or too large")
        }
        let digest = publication.contentSHA256.lowercased()
        guard Self.validDigest(digest) else {
            throw G09R2DesignPublicationError(
                reason: "the publication payload digest is malformed")
        }
        guard !publication.bytes.isEmpty,
              Int64(publication.bytes.count) <= Self.maximumBytes else {
            throw G09R2DesignPublicationError(
                reason: "the publication payload is empty or exceeds the creative asset cap")
        }
        guard FloeDigest.sha256Hex(publication.bytes)
            .caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09R2DesignPublicationError(
                reason: "the publication payload does not match its verified digest")
        }
        let format = try Self.validatedFormat(publication.format)
        // An adopted creative result always comes from a verified design format
        // family (the shared adopt path runs `verifyReopen` first). Refuse a
        // bare/unknown extension here as well: the publication never invents a
        // format, a renderer conversion or a "bin" library entry.
        guard DesignContentType.from(format: format) != nil else {
            throw G09R2DesignPublicationError(
                reason: "the publication format has no verified design content family")
        }
        let destination = Self.destination(for: publication)
        let bindingKey = Self.bindingKey(
            publication, targetKey: targetKey, destination: destination)
        let expectedAssetID = Self.deterministicUUID(
            "floe.design.publication.asset|\(bindingKey)")
        let displayName = Self.publicationDisplayName(
            publication.displayName, format: format, digest: digest)
        let published: G09CreativePublishedDesignAsset
        do {
            published = try await assets.publishDesignResult(
                candidateID: expectedAssetID,
                bytes: publication.bytes,
                format: format,
                displayName: displayName,
                kind: Self.mediaKind(forFormat: format),
                mimeType: G09R2DesignWorkspaceResolver.mimeType(for: format),
                tags: ["design", "adopted"])
        } catch let typed as G09R2DesignPublicationError {
            throw typed
        } catch {
            throw G09R2DesignPublicationError(
                reason: "the creative asset could not be retained: \(Self.reason(for: error))")
        }
        guard published.contentSHA256.caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09R2DesignPublicationError(
                reason: "the read-back creative asset does not carry the publication digest")
        }
        return DesignResultPublicationReceipt(
            identifier: published.assetID.uuidString.lowercased(),
            destination: destination,
            contentSHA256: digest)
    }

    // MARK: Binding identity

    /// The frozen target recorded at commit time is audit data; when present it
    /// MUST agree with the live owner identity. This is the cross-owner replay
    /// guard: a publication key alone is never the whole identity.
    static func validatedTargetKey(
        _ publication: DesignResultPublication
    ) throws -> String {
        let targetKey = publication.target.stableKey
        let frozen = publication.targetStableKey
        guard frozen.isEmpty || frozen == targetKey else {
            throw G09R2DesignPublicationError(
                reason: "the publication's frozen target does not match its live owner identity")
        }
        return targetKey
    }

    static func destination(for publication: DesignResultPublication) -> String {
        "creative:\(publication.target.ownerID)"
    }

    static func bindingKey(
        _ publication: DesignResultPublication,
        targetKey: String,
        destination: String
    ) -> String {
        "\(targetKey)|\(destination)|\(publication.publicationKey)"
    }

    // MARK: Format / naming

    static func validatedFormat(_ raw: String) throws -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let format: String
        switch value {
        case "markdown": format = "md"
        case "jpeg": format = "jpg"
        case "text": format = "txt"
        default: format = value
        }
        guard !format.isEmpty, format.utf8.count <= 16,
              format.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
              }) else {
            throw G09R2DesignPublicationError(
                reason: "the publication format is not a safe file extension")
        }
        return format
    }

    /// Deterministic safe display name with the verified format extension. The
    /// digest seeds the fallback so a retry of the SAME publication cannot
    /// produce a differently named second partial file.
    static func publicationDisplayName(
        _ raw: String, format: String, digest: String
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Design-\(String(digest.prefix(12))).\(format)"
        }
        let base = G09CreativeAssetHost.safeDisplayName(trimmed)
        let stem = (base as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty {
            return "Design-\(String(digest.prefix(12))).\(format)"
        }
        return "\(stem).\(format)"
    }

    static func mediaKind(forFormat format: String) -> MediaKind {
        switch format.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg":
            return .image
        case "mp4", "mov", "m4v", "webm":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac":
            return .audio
        default:
            return .document
        }
    }

    /// RFC 4122 v5-style UUID over SHA-256: stable across launches/devices for
    /// the same binding, so a replay cannot mint a second candidate identity.
    static func deterministicUUID(_ seed: String) -> UUID {
        let hex = FloeDigest.sha256Hex(Data(seed.utf8))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            let start = hex.index(hex.startIndex, offsetBy: index * 2)
            let end = hex.index(start, offsetBy: 2)
            bytes[index] = UInt8(hex[start..<end], radix: 16) ?? 0
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func validDigest(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }

    private static func reason(for error: Error) -> String {
        if let typed = error as? G09CreativeError { return typed.code }
        if let typed = error as? G09R2DesignStoreError {
            switch typed {
            case .tooLarge: return "assetTooLarge"
            case .writeFailed: return "writeFailed"
            case .corrupt(let detail): return "storageCorrupted:\(detail)"
            case .invalidKey(let key): return "invalidKey:\(key)"
            case .conflict: return "revisionConflict"
            }
        }
        if let typed = error as? FloeError { return String(describing: typed) }
        return "storageUnavailable"
    }
}

// MARK: - Composite publication router

/// The workflow's single default publication port. Chat keeps the existing
/// port byte-for-byte; creative uses the real asset publication above. Other
/// owners have no separate destination and keep the typed refusal.
struct G09R2DesignCompositePublicationPort: DesignResultPublicationPort {
    let chat: G09R2DesignChatPublicationPort
    let creative: G09R2DesignCreativePublicationPort

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        // The frozen target check is a common pre-flight for every immutable
        // owner: a publication bound to a different owner than it claims is
        // never written, regardless of destination kind.
        _ = try G09R2DesignCreativePublicationPort.validatedTargetKey(publication)
        switch publication.target.kind {
        case .creativeDocument:
            return try await creative.publish(publication)
        case .chatAttachment:
            return try await chat.publish(publication)
        case .canvasNode, .fileDocument:
            throw G09R2DesignPublicationError(
                reason: "no separate result-publication destination exists for this owner kind")
        }
    }
}
