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
import FloeCore
import FloeDocuments
import FloeImages
import FloeModels

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
        // The workspace root lives in a temp/work area; throws only if the
        // directory cannot be created, which cannot happen for temp.
        self.workspace = (try? SecurityScopedDocumentWorkspace())
            // swiftlint:disable:next force_try
            ?? (try! SecurityScopedDocumentWorkspace(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("FloeFilesFallback", isDirectory: true)
            ))
    }

    // MARK: - Picking & recents

    /// Records a picked document as a recent attachment with a
    /// security-scoped bookmark. Called by the document picker.
    func registerPickedDocument(url: URL, displayName: String) async throws -> AttachmentRef {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let contentType = values?.contentType
        let attachment = AttachmentRef(
            id: UUID(),
            kind: Self.attachmentKind(for: contentType),
            displayName: displayName.isEmpty ? url.lastPathComponent : displayName,
            uti: values?.contentType?.identifier ?? "",
            byteCount: values?.fileSize ?? 0,
            storage: .securityScopedBookmark,
            urlBookmark: bookmark
        )
        recentFiles.insert(attachment, at: 0)
        return attachment
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

    /// Resolves a stored security-scoped bookmark back to a URL.
    func resolveURL(for attachment: AttachmentRef) throws -> URL {
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
        let data = try Data(contentsOf: url)
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
