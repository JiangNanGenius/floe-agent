// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// One deterministic custom-cover command for a Notes document.
///
/// This is the single mutation surface shared by the manual Notes UI and the
/// Notes document assistant (`notes.cover`). Both callers must supply the
/// document identity (its own id), the content revision and the cover revision
/// they actually read, and — for `useResource` — a resource id that is already
/// registered in the same `NotesStore` and has been validated by
/// `NotesCoverImageProcessor`. A raw external path is never a valid command
/// input, so a caller (including a model) cannot turn an arbitrary file into
/// persistent storage or a permission grant.
public enum NoteCoverCommand: Sendable, Equatable {
    /// Use one existing, registered Notes image resource as the explicit cover.
    case useResource(UUID)
    /// Remove the explicit cover and return to the original automatic renderer.
    case restoreAutomatic
}

/// The effective cover of one document. `.custom` always wins over every
/// automatic renderer; `.automatic` keeps the existing native renderer.
public enum NoteCoverMode: Equatable, Sendable {
    case automatic
    case custom(UUID)
}

/// Bounded, deterministic cover asset policy.
///
/// The bounds mirror the existing Notes/Creative image ingestion limits so the
/// manual picker, the assistant tool and any future call site reject exactly
/// the same inputs. It is pure: no file system access, no state, no platform
/// types, so it is directly testable off-device.
public enum NoteCoverAssetPolicy {
    /// A single cover asset never exceeds 20 MiB after normalization.
    public static let maximumBytes = 20 * 1_024 * 1_024
    /// Decoded pixel bound shared with the workspace image ingestion boundary.
    public static let maximumPixelCount = 80_000_000
    public static let maximumDimension = 20_000
    /// The stored cover is normalized to this long edge at most.
    public static let maximumStoredPixelSize = 2_048
    /// The only stored cover formats: everything a cover surface persists is
    /// either PNG (alpha) or JPEG (opaque), produced by
    /// `NotesCoverImageProcessor`. A resource in any other image format (HEIC,
    /// TIFF, SVG, …) must be normalized by the processor first; this gate is
    /// what makes "a custom cover always decodes" true for every caller of the
    /// shared command, including a direct `useResource`.
    public static let acceptedStoredMediaTypes: Set<String> = ["image/png", "image/jpeg"]

    /// True for any image media type. This is a classification helper (for
    /// example when listing candidate assets); it is NOT sufficient to persist
    /// a cover — see `acceptsStoredAsset(mediaType:)`.
    public static func isImageMediaType(_ mediaType: String?) -> Bool {
        guard let mediaType, !mediaType.isEmpty else { return false }
        return mediaType.lowercased().hasPrefix("image/")
    }

    public static func acceptsStoredAsset(mediaType: String?) -> Bool {
        guard let mediaType else { return false }
        return acceptedStoredMediaTypes.contains(mediaType.lowercased())
    }

    public static func accepts(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumBytes
    }

    public static func accepts(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= maximumDimension, pixelHeight <= maximumDimension,
              pixelWidth.multipliedReportingOverflow(by: pixelHeight).overflow == false else { return false }
        return pixelWidth * pixelHeight <= maximumPixelCount
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
/// The one bounded raster validation/normalization used by both cover callers.
///
/// Manual photo/file import, an assistant `path` import and an assistant
/// `resourceID` all run through this exact function before a cover command, so
/// a custom cover can never point at an unsupported vector (SVG), a corrupt
/// file or an oversized image. The original file is never modified: the
/// normalized result is a new (or content-addressed identical) Notes resource,
/// and rejection happens before any cover mutation, leaving the previous cover
/// untouched.
public enum NotesCoverImageProcessor {
    public static func normalizedCoverData(_ data: Data) throws -> (data: Data, fileExtension: String, mediaType: String) {
        let invalidAsset = NoteError.invalidOperation(NoteLocalization.text(
            "notes.cover.error.invalidAsset",
            fallback: "This image can't be used as a cover"))
        guard NoteCoverAssetPolicy.accepts(byteCount: data.count) else { throw invalidAsset }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              NoteCoverAssetPolicy.accepts(pixelWidth: width, pixelHeight: height),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: NoteCoverAssetPolicy.maximumStoredPixelSize
              ] as CFDictionary) else { throw invalidAsset }
        let alpha = thumbnail.alphaInfo
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        let encoded: Data?
        let fileExtension: String
        let mediaType: String
        if hasAlpha {
            encoded = encode(thumbnail, type: .png); fileExtension = "png"; mediaType = "image/png"
        } else {
            encoded = encode(thumbnail, type: .jpeg); fileExtension = "jpg"; mediaType = "image/jpeg"
        }
        guard let encoded, NoteCoverAssetPolicy.accepts(byteCount: encoded.count) else { throw invalidAsset }
        return (encoded, fileExtension, mediaType)
    }

    /// Import a picked photo/file (or any read-authorized URL) into the Notes
    /// store. The security-scoped access belongs to the picker result and is
    /// released before returning.
    public static func importCover(from url: URL, store: NotesStore) async throws -> UUID {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await importCover(data: data, store: store)
    }

    /// Normalize and import as one immutable resource. A cancelled or failed
    /// import never touches the document's current cover.
    public static func importCover(data: Data, store: NotesStore) async throws -> UUID {
        let normalized = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try normalizedCoverData(data)
        }.value
        try Task.checkCancellation()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-cover-\(UUID().uuidString).\(normalized.fileExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try normalized.data.write(to: staging, options: .atomic)
        // `importResource` re-hashes the bytes into the immutable CAS; the
        // staging name only carries the validated extension and media type.
        return try await store.importResource(from: staging, mediaType: normalized.mediaType)
    }

    /// Validate and normalize one already-registered Notes resource into a
    /// cover-eligible resource.
    ///
    /// The bytes are read through the store (bounded by the recorded size and
    /// the policy byte bound), decoded, and normalized. Because the store is
    /// content-addressed, an asset that is already a normalized PNG/JPEG keeps
    /// its own resource id; a HEIC/TIFF image becomes a new JPEG resource; an
    /// SVG, corrupt or oversized input throws before anything is written and
    /// the original resource is left untouched.
    public static func validatedCoverResource(_ resourceID: UUID, store: NotesStore) async throws -> UUID {
        let url = try await store.resourceURL(resourceID)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize,
              NoteCoverAssetPolicy.accepts(byteCount: byteCount) else {
            throw NoteError.invalidOperation(NoteLocalization.text(
                "notes.cover.error.invalidAsset",
                fallback: "This image can't be used as a cover"))
        }
        return try await importCover(from: url, store: store)
    }

    private static func encode(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

/// The one shared, deterministic cover command service.
///
/// Both entry points execute the same store transaction: read the document,
/// verify identity/content revision/cover revision, re-check the editing scope
/// at commit time when the caller is an assistant, then update only the cover
/// metadata. The result is one `NoteDocument` value — the UI never keeps a
/// shadow copy of cover state.
public enum NotesCoverCommandService {
    /// Native/manual entry point (and the body of the assistant entry point).
    /// `authorizedConversationID` is nil for the app's own user-driven paths;
    /// only the assistant path passes the runtime-issued conversation id.
    @discardableResult
    public static func apply(_ command: NoteCoverCommand, documentID: UUID, expectedRevision: Int,
                             expectedCoverRevision: Int, store: NotesStore,
                             authorizedConversationID: UUID? = nil) async throws -> NoteDocument {
        try await store.applyCoverCommand(command, documentID: documentID, expectedRevision: expectedRevision,
                                          expectedCoverRevision: expectedCoverRevision,
                                          authorizedConversationID: authorizedConversationID)
    }

    /// Assistant entry point used by the registered `notes.cover` tool.
    ///
    /// `conversationID` is taken from the runtime tool context, never from tool
    /// arguments, so a model can neither supply nor widen it. The editing grant
    /// is checked here and then re-checked inside the same database write as the
    /// cover mutation, exactly like `NotesStore.apply(NoteEditBatch)`, so a
    /// native revoke during an async image import still wins at commit. The
    /// asset must already be a Notes resource validated by
    /// `NotesCoverImageProcessor`; the caller can never import an arbitrary path
    /// through this call.
    @discardableResult
    public static func apply(_ command: NoteCoverCommand, conversationID: UUID, documentID: UUID,
                             expectedRevision: Int, expectedCoverRevision: Int, store: NotesStore) async throws -> NoteDocument {
        try await store.authorize(conversationID: conversationID, documentID: documentID, editing: true)
        return try await apply(command, documentID: documentID, expectedRevision: expectedRevision,
                               expectedCoverRevision: expectedCoverRevision, store: store,
                               authorizedConversationID: conversationID)
    }
}
