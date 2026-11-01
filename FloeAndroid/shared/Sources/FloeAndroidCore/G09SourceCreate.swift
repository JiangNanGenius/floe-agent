// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — atomic source-import project creation.
//
// A new Canvas/media project can be created FROM a user-selected source file
// without first publishing an empty project and hoping a later import works.
// The trusted Android host stages the SAF bytes under the accepted root, reads
// the actual bytes for metadata (size, digest, kind, dimensions) and calls one
// closed `floe.creative/5` action. Native verifies the staged bytes, ingests
// the asset into the SAME store the ordinary import path uses, assembles the
// complete non-empty draft, records a durable pre-commit intent keyed by the
// caller's stable opID/derived project identity, and only then publishes the
// project file atomically.
//
// This file owns the additive DTOs and the deterministic identity derivations;
// the storage hosts own the actual commit. Nothing here is a model tool, a
// second store or a path authority.
import Foundation
import FloeCore

// MARK: - Requests

/// Canvas document creation from one staged source file.
///
/// `width`/`height` are optional host-measured pixel hints used only to size
/// the initial node; they never come from recorded project JSON and are never
/// a storage grant. `sourceKind` is the host-derived actual kind of the bytes
/// (`image|video|audio|file`); native falls back to mime/extension when it is
/// absent and rejects an unknown spelling.
public struct G09CanvasSourceCreateRequest: Decodable, Sendable {
    public var token: String
    public var opID: String
    public var name: String
    public var workspaceID: UUID?
    public var sessionToken: String
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var sourceKind: String?
    public var width: Int?
    public var height: Int?
}

/// Media project creation from one staged source image/video file.
///
/// The host measures the actual bytes and supplies `width`/`height`
/// (`durationSeconds`/`frameRate`/`rotationDegrees` for video); native
/// bounds-checks them, requires them to agree with `kind`/`sourceKind`, and
/// persists them as the asset metadata. Recorded project JSON and UI strings
/// are never storage authority: the media root is re-derived from the accepted
/// composition plus this explicit storage layer.
public struct G09MediaSourceCreateRequest: Decodable, Sendable {
    public var token: String
    public var opID: String
    public var name: String
    public var kind: String
    public var storage: G09StorageLayerDTO
    public var origin: G09CreativeOriginDTO?
    public var sessionToken: String
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var sourceKind: String?
    public var width: Int
    public var height: Int
    public var durationSeconds: Double?
    public var frameRate: Double?
    public var rotationDegrees: Double?
}

// MARK: - Identity

/// Stable identities derived from the caller's `opID`.
///
/// Deriving the project identity from the operation (instead of a fresh UUID
/// per attempt) is what makes a retry land on the SAME intended document: two
/// attempts with one `opID` can never publish two projects, and a retry after a
/// pre-commit failure reuses the identical file path, intent and asset row.
/// The derivation includes a domain tag so a Canvas op and a media op that
/// happen to share an opID cannot collide.
public enum G09SourceCreateIdentity {
    public static let scheme = "floe.g09.source-create/1"

    /// Maximum accepted caller opID bytes. The host derives sub-operation IDs
    /// (`.ref`/`.asset` suffixes) that must still fit the 128-byte receipt
    /// bound.
    public static let maximumOperationBytes = 100

    public static func projectID(domain: String, opID: String) -> UUID {
        uuid(tag: "project", domain: domain, opID: opID)
    }

    /// Deterministic initial node identity for the Canvas draft, so a retry
    /// that has not published yet assembles byte-identical content.
    public static func nodeID(domain: String, opID: String) -> UUID {
        uuid(tag: "node", domain: domain, opID: opID)
    }

    /// Deterministic media asset identity: the copied file name is stable
    /// across retries, so an interrupted attempt never leaves two copies.
    public static func assetID(domain: String, opID: String) -> UUID {
        uuid(tag: "asset", domain: domain, opID: opID)
    }

    /// Layer/clip identity stays stable across retries for the same reason.
    public static func childID(domain: String, opID: String, tag child: String) -> UUID {
        uuid(tag: "child-\(child)", domain: domain, opID: opID)
    }

    /// Durable request fingerprint. It covers every field that decides the
    /// published document (never a timestamp), so the same opID with changed
    /// content/storage/name is refused as `intentMismatch` instead of silently
    /// replacing or duplicating the committed project.
    public static func fingerprint(domain: String, opID: String, projectID: UUID,
                                   fields: [String: String?]) -> String {
        let canonical = fields.keys.sorted().map { key -> String in
            let value: String = fields[key].flatMap { $0 } ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "\u{1f}")
        return FloeDigest.sha256Hex(Data(
            "\(scheme)|\(domain)|\(opID)|\(projectID.uuidString.lowercased())|\(canonical)".utf8))
    }

    /// Accepted canvas node kinds for a source import. Unknown spellings are
    /// rejected rather than silently downgraded.
    public static func canvasNodeKind(sourceKind: String?, fileName: String,
                                      mimeType: String?) throws -> CanvasNodeKind {
        if let raw = sourceKind, !raw.isEmpty {
            switch raw {
            case "image": return .image
            case "video": return .video
            case "audio": return .audio
            case "file": return .file
            default: throw G09CreativeError.invalidPayload("invalidSourceKind")
            }
        }
        return G09CreativeAssetHost.canvasNodeKind(
            fileName: fileName, mimeType: mimeType)
    }

    private static func uuid(tag: String, domain: String, opID: String) -> UUID {
        let digest = FloeDigest.sha256Hex(Data(
            "\(scheme)|\(tag)|\(domain)|\(opID)".utf8))
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = digest.startIndex
        for _ in 0..<16 {
            let end = digest.index(index, offsetBy: 2)
            bytes.append(UInt8(digest[index..<end], radix: 16) ?? 0)
            index = end
        }
        // RFC 4122 textual form with a deterministic version/variant nibble;
        // this is an app-derived stable identity, not a random v4 UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Validation helpers

enum G09SourceCreateValidation {
    /// One opID spelling shared by both source-create actions. The limit is
    /// below the generic receipt bound because the handler derives `.ref`
    /// sub-operation IDs from it.
    static func requireOperationID(_ raw: String) throws {
        guard G09CreativeWire.safeOperationID(raw),
              raw.utf8.count <= G09SourceCreateIdentity.maximumOperationBytes else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
    }

    /// The staged token must be under `CreativeIncoming` and scoped to the
    /// exact live editor session; the asset hosts resolve it again.
    static func requireStagingToken(_ token: String, sessionToken: String) throws {
        guard G09CreativeWire.validSessionToken(sessionToken),
              token.hasPrefix(sessionToken + "."),
              G09CreativeAssetHost.safeStagingToken(token) else {
            throw G09CreativeError.assetStagingInvalid
        }
    }

    static func requireByteCount(_ byteCount: Int64, digest: String) throws {
        guard byteCount > 0 else { throw G09CreativeError.assetEmpty }
        guard byteCount <= G09CreativeLimits.assetBytes else {
            throw G09CreativeError.assetTooLarge
        }
        guard G09CreativeAssetHost.validDigest(digest) else {
            throw G09CreativeError.assetStagingInvalid
        }
    }

    /// Host-measured pixel size bounds. A 0/negative or absurd measurement is
    /// refused instead of being clamped into a fabricated draft.
    static func requireDimensions(_ width: Int?, _ height: Int?) throws
        -> (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        guard (2...8192).contains(width), (2...8192).contains(height) else {
            throw G09CreativeError.invalidPayload("invalidSourceDimensions")
        }
        return (width, height)
    }
}
