// FloeApp — Files coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns document/image working copies, security-scoped bookmarks and the
// local image pipeline; exposes recent files and Quick Look. Security-
// scoped access uses bookmarks; writeback is conflict-safe and surfaces an
// explicit conflict state. Remote image ops are capability-gated — an
// unsupported op is surfaced honestly, never emulated.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import FloeCore
import FloeDocuments
import FloeImages
import FloeModels
import FloeProviders

/// Coordinates document and image workflows for the UI layer.
@MainActor
final class FilesCenter: ObservableObject {

    /// Recently opened attachments.
    @Published var recentFiles: [AttachmentRef] = []
    /// Live image edit sessions keyed by session ID.
    @Published private(set) var imageSessions: [UUID: ImageEditSession] = [:]
    /// An explicit conflict surfaced when the underlying file changed.
    @Published var conflict: FileConflict?

    // FileConflict is Identifiable so it can drive `.alert(item:)`.

    let environment: AppEnvironment
    private let workspace: SecurityScopedDocumentWorkspace
    private let pipeline = ImagePipeline()
    private let generatedImageDirectory: URL
    private var documentSessions: [UUID: DocumentSession] = [:]

    /// A writeback conflict: the working copy differs but the original
    /// changed underneath. The user must resolve explicitly.
    struct FileConflict: Identifiable, Sendable {
        let attachmentID: UUID
        let displayName: String
        var id: UUID { attachmentID }
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        generatedImageDirectory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
        // Staging area for picked/uploaded attachments. Files are copied here
        // at pick time so the run does not depend on a provider bookmark still
        // resolving after the document-picker access window closes.
        attachmentsStagingDirectory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: attachmentsStagingDirectory,
            withIntermediateDirectories: true
        )
        // The workspace root lives in a temp/work area; throws only if the
        // directory cannot be created, which cannot happen for temp.
        self.workspace = (try? SecurityScopedDocumentWorkspace())
            // swiftlint:disable:next force_try
            ?? (try! SecurityScopedDocumentWorkspace(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("FloeFilesFallback", isDirectory: true)
            ))
    }

    /// Where picked/uploaded files are copied so they persist for the model.
    private let attachmentsStagingDirectory: URL

    // MARK: - Picking & recents

    /// Records a picked document as a recent attachment. The file is COPIED
    /// into the app-owned staging directory so it stays readable after the
    /// security-scoped access window closes. Non-image files are copied into
    /// the task workspace when the run starts; images are sent inline.
    /// Images are compressed (JPEG, ≤1MB) before staging so the model gets a
    /// usable size without silent drops. Pass `compressImage: false` when the
    /// model explicitly asks for the original/large version.
    func registerPickedDocument(
        url: URL,
        displayName: String,
        compressImage: Bool = true
    ) async throws -> AttachmentRef {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let contentType = values?.contentType
        let requestedName = displayName.isEmpty ? url.lastPathComponent : displayName
        let finalName = (requestedName as NSString).lastPathComponent
        let kind = Self.attachmentKind(for: contentType)

        // Copy into staging with a collision-safe name.
        let stagedName = "\(UUID().uuidString)-\(finalName)"
        let stagedURL = attachmentsStagingDirectory.appendingPathComponent(stagedName)

        // Compress images before staging so the model gets a usable size.
        // Skip when the model explicitly asks for the original/large version.
        if compressImage, kind == .image,
           let image = await Self.rasterImage(at: url),
           let compressed = Self.compressImage(image, maxBytes: 1_024 * 1_024) {
            let jpegDisplayName = "\((finalName as NSString).deletingPathExtension).jpg"
            let jpegStagedName = "\(UUID().uuidString)-\(jpegDisplayName)"
            let jpegURL = attachmentsStagingDirectory.appendingPathComponent(jpegStagedName)
            try compressed.write(to: jpegURL, options: .atomic)
            let attachment = AttachmentRef(
                id: UUID(),
                kind: kind,
                displayName: jpegDisplayName,
                uti: UTType.jpeg.identifier,
                byteCount: compressed.count,
                storage: .applicationSupport,
                relativePath: jpegStagedName
            )
            recentFiles.insert(attachment, at: 0)
            return attachment
        }

        do {
            try FileManager.default.copyItem(at: url, to: stagedURL)
        } catch {
            // Fall back to the bookmark path if the copy fails (e.g. the
            // source is a network volume that can't be read right now).
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let attachment = AttachmentRef(
                id: UUID(),
                kind: kind,
                displayName: finalName,
                uti: values?.contentType?.identifier ?? "",
                byteCount: values?.fileSize ?? 0,
                storage: .securityScopedBookmark,
                urlBookmark: bookmark
            )
            recentFiles.insert(attachment, at: 0)
            return attachment
        }

        let attachment = AttachmentRef(
            id: UUID(),
            kind: kind,
            displayName: finalName,
            uti: values?.contentType?.identifier ?? "",
            byteCount: values?.fileSize ?? 0,
            storage: .applicationSupport,
            relativePath: stagedName
        )
        recentFiles.insert(attachment, at: 0)
        return attachment
    }

    /// Loads every system-supported image as pixels before it is persisted.
    /// Quick Look is the fallback for vector/container formats (notably SVG)
    /// that `UIImage(contentsOfFile:)` does not decode consistently.
    private static func rasterImage(at url: URL) async -> UIImage? {
        if let image = UIImage(contentsOfFile: url.path) { return image }
        if let data = try? Data(floeContentsOf: url), let image = UIImage(data: data) {
            return image
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 2_048, height: 2_048),
            scale: 1,
            representationTypes: .thumbnail
        )
        return try? await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let representation {
                    continuation.resume(returning: representation.uiImage)
                } else {
                    continuation.resume(throwing: error ?? FloeError.validationFailed("Unsupported image format"))
                }
            }
        }
    }

    /// Compresses an image to fit under maxBytes by progressively lowering
    /// JPEG quality and scaling down. Returns nil if compression fails.
    private static func compressImage(_ image: UIImage, maxBytes: Int) -> Data? {
        var quality: CGFloat = 0.8
        var scale: CGFloat = 1.0
        var data = image.jpegData(compressionQuality: quality)
        while (data?.count ?? 0) > maxBytes, quality > 0.1 {
            quality -= 0.1
            data = image.jpegData(compressionQuality: quality)
        }
        while (data?.count ?? 0) > maxBytes, scale > 0.2 {
            scale -= 0.2
            let newSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            data = scaled.jpegData(compressionQuality: quality)
        }
        return data
    }

    private static func attachmentKind(for contentType: UTType?) -> AttachmentRef.Kind {
        guard let contentType else { return .other }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .audio) { return .audio }
        if contentType.conforms(to: .content) || contentType.conforms(to: .data) {
            return .document
        }
        return .other
    }

    /// Resolves an attachment back to a readable URL. Staged uploads live in
    /// the Attachments directory; generated images live in GeneratedImages;
    /// legacy bookmarks fall back to security-scoped resolution.
    func resolveURL(for attachment: AttachmentRef) throws -> URL {
        if attachment.storage == .applicationSupport, let relativePath = attachment.relativePath {
            // Staged uploads and generated images share the applicationSupport
            // storage kind; resolve against whichever directory holds the file.
            for root in [attachmentsStagingDirectory, generatedImageDirectory] {
                let allowedRoot = root.standardizedFileURL
                let url = allowedRoot.appendingPathComponent(relativePath).standardizedFileURL
                let prefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
                guard url.path.hasPrefix(prefix) else { continue }
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            throw FloeError.notFound("attachment \(relativePath)")
        }
        guard let bookmark = attachment.urlBookmark else {
            throw FloeError.notFound("bookmark for \(attachment.displayName)")
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // Refresh the bookmark for next time.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ), let index = recentFiles.firstIndex(where: { $0.id == attachment.id }) {
                recentFiles[index].urlBookmark = refreshed
            }
        }
        return url
    }

    // MARK: - Provider image generation/editing

    @discardableResult
    func performRemoteImage(
        operation: RemoteImageOperation,
        prompt: String,
        source: AttachmentRef? = nil,
        count: Int = 1,
        size: String? = nil
    ) async throws -> [AttachmentRef] {
        let center = environment.conversationCenter
        guard let (provider, model) = center.auxiliaryProviderAndModel(for: operation),
              let adapter = ImageProviderAdapterFactory().adapter(for: provider),
              adapter.supports(operation, for: provider) else {
            throw FloeError.invalidConfiguration("No compatible image model is configured for this operation")
        }
        var sources: [Data] = []
        if let source {
            let url = try resolveURL(for: source)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(floeContentsOf: url)
            guard data.count <= 12 * 1_024 * 1_024 else {
                throw FloeError.validationFailed("Source image exceeds 12 MiB")
            }
            sources = [data]
        }
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: operation,
                prompt: prompt,
                sourceImages: sources,
                sizeHint: size,
                count: count,
                modelRemoteID: model.remoteModelID
            ),
            provider: provider,
            credentials: center.resolveCredentials(for: provider)
        )
        try FileManager.default.createDirectory(
            at: generatedImageDirectory,
            withIntermediateDirectories: true
        )
        let attachments = try result.images.enumerated().map { index, data in
            guard data.count <= 12 * 1_024 * 1_024 else {
                throw FloeError.validationFailed("Generated image exceeds 12 MiB")
            }
            let id = UUID()
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let ext = isPNG ? "png" : "jpg"
            let relative = "\(id.uuidString).\(ext)"
            try data.write(to: generatedImageDirectory.appendingPathComponent(relative), options: .atomic)
            return AttachmentRef(
                id: id,
                kind: .image,
                displayName: operation == .generate
                    ? "Generated \(index + 1).\(ext)"
                    : "Edited \(index + 1).\(ext)",
                uti: isPNG ? UTType.png.identifier : UTType.jpeg.identifier,
                byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                storage: .applicationSupport,
                relativePath: relative
            )
        }
        recentFiles.insert(contentsOf: attachments, at: 0)
        return attachments
    }

    // MARK: - Document working copies

    /// Opens a working copy for safe writeback. The Office editing engine is
    /// deferred; the Alpha ships open / preview / safe writeback / Save As.
    func makeWorkingCopy(of attachment: AttachmentRef) async throws -> DocumentSession {
        let url = try resolveURL(for: attachment)
        let session = try await workspace.open(securityScopedURL: url)
        documentSessions[attachment.id] = session
        return session
    }

    /// Writes the working copy back to the original. Surfaces an explicit
    /// conflict state when the underlying file changed.
    func saveWorkingCopy(
        _ session: DocumentSession,
        of attachment: AttachmentRef
    ) async throws {
        do {
            try await workspace.save(session)
        } catch {
            conflict = FileConflict(
                attachmentID: attachment.id,
                displayName: attachment.displayName
            )
            throw error
        }
    }

    /// Save As: copies the working copy to a new destination.
    func saveAs(_ session: DocumentSession, to url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: session.workingURL, to: url)
    }

    /// Closes a document working copy.
    func closeDocument(_ attachmentID: UUID) async {
        if let session = documentSessions.removeValue(forKey: attachmentID) {
            await workspace.close(session)
        }
    }

    // MARK: - Image editing (local, deterministic pipeline)

    /// Opens an image into a non-destructive edit session.
    func openImage(_ attachment: AttachmentRef) async throws -> UUID {
        let url = try resolveURL(for: attachment)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(floeContentsOf: url)
        guard let source = UIImage(data: data)?.cgImage else {
            throw FloeError.validationFailed("Not a readable image")
        }
        let session = ImageEditSession(source: source)
        imageSessions[session.id] = session
        return session.id
    }

    /// Applies a validated operation to an image edit session.
    func apply(_ operation: ImageOperation, to sessionID: UUID) async throws {
        var session = try requireSession(sessionID)
        try session.apply(operation)
        imageSessions[sessionID] = session
    }

    /// Undoes the last applied operation.
    func undo(sessionID: UUID) async throws {
        var session = try requireSession(sessionID)
        session.undo()
        imageSessions[sessionID] = session
    }

    /// Re-renders the current session state (deterministic).
    func render(sessionID: UUID) throws -> CGImage {
        try requireSession(sessionID).render(using: pipeline)
    }

    /// Exports the current session image in the given format. Metadata is
    /// stripped unless the operation history says otherwise.
    func exportImage(
        sessionID: UUID,
        format: ImageOperation.ImageFormat
    ) async throws -> URL {
        let image = try render(sessionID: sessionID)
        let uiImage = UIImage(cgImage: image)
        let data: Data?
        let ext: String
        switch format {
        case .png:
            data = uiImage.pngData(); ext = "png"
        case .jpeg:
            data = uiImage.jpegData(compressionQuality: 0.9); ext = "jpg"
        case .heic:
            data = uiImage.heicData(); ext = "heic"
        case .webp:
            // WebP encode is not in Core Image/ImageIO on all SDKs; fall
            // back to PNG bytes with a clear extension to avoid a fake.
            data = uiImage.pngData(); ext = "png"
        }
        guard let bytes = data else {
            throw FloeError.internalError("Could not encode image as \(format.rawValue)")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-export-\(sessionID.uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func requireSession(_ sessionID: UUID) throws -> ImageEditSession {
        guard let session = imageSessions[sessionID] else {
            throw FloeError.notFound("image session \(sessionID.uuidString)")
        }
        return session
    }
}
#endif
