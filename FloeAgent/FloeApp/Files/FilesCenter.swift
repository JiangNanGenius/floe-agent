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

    /// Small data-only context attachments use the SAME staging/resolution
    /// and composer ownership as picked documents, without recents or a
    /// bookmark fallback. No whole model/file copy or user file is created.
    func registerContextJSON(_ data: Data, displayName: String,
                             conversationID: UUID) throws -> AttachmentRef {
        guard !data.isEmpty, data.count <= 64 * 1024,
              (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw FloeError.validationFailed(FloeL10n.l("cad.selection.attachFailed"))
        }
        let id=UUID(), relative="cad-context-\(id.uuidString).json"
        let url=attachmentsStagingDirectory.appendingPathComponent(relative)
        try data.write(to: url, options: .atomic)
        return AttachmentRef(id:id,conversationID:conversationID,kind:.document,
            displayName:displayName,uti:UTType.json.identifier,byteCount:data.count,
            sha256:FloeDigest.sha256Hex(data),storage:.applicationSupport,relativePath:relative)
    }

    /// Only the fresh, not-adopted context produced above may be removed.
    /// Callers must not invoke this for an attachment accepted by a draft.
    func discardUnadoptedContextJSON(_ attachment: AttachmentRef,
                                     conversationID: UUID) throws {
        guard attachment.conversationID == conversationID,attachment.storage == .applicationSupport,
              attachment.kind == .document,
              !ComposerDraftStore.shared.attachments(for:conversationID).contains(where: { $0.id == attachment.id }),
              attachment.relativePath == "cad-context-\(attachment.id.uuidString).json" else {
            throw FloeError.validationFailed("Invalid unadopted context owner")
        }
        let url=attachmentsStagingDirectory.appendingPathComponent(attachment.relativePath!)
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true,values.isSymbolicLink != true,
              try FloeDigest.sha256Hex(ofFileAt:url) == attachment.sha256 else {
            throw FloeError.validationFailed("Context staging identity changed")
        }
        try FileManager.default.removeItem(at:url)
    }

    /// Stages image bytes without manufacturing a security-scoped URL;
    /// normalize them to JPEG exactly like document-picked images. Context
    /// snapshots can omit the recent-files list while retaining normal
    /// attachment storage and message ownership.
    func registerPhotoData(
        _ data: Data,
        displayName: String = "Photo.jpg",
        recordRecent: Bool = true
    ) throws -> AttachmentRef {
        guard let image = UIImage(data: data),
              let compressed = Self.compressImage(image, maxBytes: 1_024 * 1_024) else {
            throw FloeError.validationFailed(FloeL10n.l("composer.attachment.photo_unreadable"))
        }
        let base = ((displayName as NSString).deletingPathExtension as NSString)
            .lastPathComponent
        let finalName = "\(base.isEmpty ? "Photo" : base).jpg"
        let stagedName = "\(UUID().uuidString)-\(finalName)"
        let stagedURL = attachmentsStagingDirectory.appendingPathComponent(stagedName)
        try compressed.write(to: stagedURL, options: .atomic)
        let attachment = AttachmentRef(
            id: UUID(),
            kind: .image,
            displayName: finalName,
            uti: UTType.jpeg.identifier,
            byteCount: compressed.count,
            storage: .applicationSupport,
            relativePath: stagedName
        )
        if recordRecent { recentFiles.insert(attachment, at: 0) }
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

    /// One eligible image route plus its reviewed parameter contract. Manual
    /// controls must be derived from this contract instead of hard-coded
    /// resolution/count ranges that may not exist on the selected provider.
    struct RemoteImageModelOption: Identifiable {
        let provider: ProviderProfile
        let model: ModelProfile
        let contract: ImageGenerationPresetResolver.ParameterContract

        var id: UUID { model.id }
        var title: String {
            let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? model.remoteModelID : name
        }
        var providerTitle: String {
            let name = (provider.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? provider.kind.rawValue : name
        }
    }

    /// Eligible manual candidates in the same preferred-first order used by
    /// `image.models`. Plan-ineligible saved ids (for example lite on Agent
    /// Plan) never become a manual choice.
    func remoteImageModelOptions(operation: RemoteImageOperation) -> [RemoteImageModelOption] {
        environment.conversationCenter.agentImageRoutes(operation: operation).map { route in
            RemoteImageModelOption(
                provider: route.0,
                model: route.1,
                contract: ImageGenerationPresetResolver.parameterContract(
                    provider: route.0, model: route.1, operation: operation))
        }
    }

    @discardableResult
    func performRemoteImage(
        operation: RemoteImageOperation, prompt: String, source: AttachmentRef? = nil,
        count: Int = 1, size: String? = nil
    ) async throws -> [AttachmentRef] {
        try await performRemoteImageResult(operation: operation, prompt: prompt, source: source,
            count: count, size: size).0
    }

    @discardableResult
    func performRemoteImageResult(
        operation: RemoteImageOperation,
        prompt: String,
        source: AttachmentRef? = nil,
        count: Int = 1,
        size: String? = nil,
        modelID: UUID? = nil,
        selection: ImageGenerationSelection? = nil,
        agentInitiated: Bool = false,
        routing: ImageGenerationRouting = .agent
    ) async throws -> ([AttachmentRef], ImageGenerationBatchReport) {
        let center = environment.conversationCenter
        let effectiveSelection = selection ?? .init(nativeSizeOverride: size)
        let sourceImages: [Data]
        if let source {
            let url = try resolveURL(for: source)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(floeContentsOf: url)
            guard data.count <= 12 * 1_024 * 1_024 else {
                throw FloeError.validationFailed("Source image exceeds 12 MiB")
            }
            sourceImages = [data]
        } else {
            sourceImages = []
        }

        let routed: (RemoteImageResult, ProviderProfile, ModelProfile)
        if agentInitiated {
            // Preserve the caller's original intent. Passing a pre-resolved
            // model id here would turn autonomous routing into an exact
            // explicit selection and suppress the reviewed fallback policy.
            routed = try await center.performAgentImage(
                operation: operation, prompt: prompt, sourceImages: sourceImages,
                modelID: modelID, selection: effectiveSelection, count: count,
                routing: routing)
        } else {
            // Legacy/manual callers still use the same executable batch path,
            // but an exact route id is passed deliberately: manual generation
            // must not fall back to another paid model. The eligible route list
            // excludes unsupported plan ids before any network call.
            let routes = center.agentImageRoutes(operation: operation)
            let chosen: (ProviderProfile, ModelProfile)?
            if let modelID {
                chosen = routes.first { $0.1.id == modelID }
            } else if let preferred = center.auxiliaryProviderAndModel(for: operation) {
                chosen = routes.first { $0.1.id == preferred.1.id }
            } else {
                chosen = nil
            }
            guard let chosen else {
                throw FloeError.invalidConfiguration(
                    modelID == nil
                        ? "The saved image model is not available on its billing channel; choose another model."
                        : "The selected image model is not available on its billing channel; choose another model.")
            }
            routed = try await center.performAgentImage(
                operation: operation, prompt: prompt, sourceImages: sourceImages,
                modelID: chosen.1.id, selection: effectiveSelection,
                count: count, routing: .selected)
        }

        let attachments = try persistGeneratedImages(
            routed.0.images, operation: operation)
        let report = ImageGenerationBatchReport(metadata: routed.0.metadata)
        return (attachments, report)
    }

    /// Per-image result of a Files persistence attempt. `attachments` are the
    /// bytes that are actually written, recorded and visible in Files; a mixed
    /// batch never hides those references because one later image failed.
    struct GeneratedImagePersistenceOutcome: Sendable {
        var attachments: [AttachmentRef]
        var failedCount: Int
        /// Technical detail for logs/handoff. User-facing copy uses counts.
        var failure: String?
    }

    struct GeneratedImagePersistenceError: LocalizedError, Sendable {
        let failedCount: Int
        let savedCount: Int
        let technicalFailure: String

        var errorDescription: String? {
            var parts: [String] = []
            if failedCount > 0 {
                parts.append(FloeL10n.l(
                    "files.remote_image_creation_view.image_save_failed_count",
                    failedCount))
            }
            if savedCount > 0 {
                parts.append(FloeL10n.l(
                    "files.remote_image_creation_view.images_saved_count",
                    savedCount))
            }
            return parts.isEmpty ? technicalFailure : parts.joined(separator: " ")
        }
    }

    /// Persists already-paid image bytes into the Files generated-image store
    /// and the recents list. Shared by normal generation and the Canvas partial
    /// path so a failed batch never discards successful provider output.
    ///
    /// Every payload is sniffed before it is named: an unchanged WebP/GIF/JPEG
    /// keeps its real extension and UTI instead of being relabelled JPEG. A
    /// later write failure returns the earlier attachments rather than losing
    /// their references.
    @discardableResult
    func persistGeneratedImages(
        _ images: [Data],
        operation: RemoteImageOperation
    ) throws -> [AttachmentRef] {
        let outcome = persistGeneratedImagesOutcome(images, operation: operation)
        if let failure = outcome.failure {
            throw GeneratedImagePersistenceError(
                failedCount: outcome.failedCount,
                savedCount: outcome.attachments.count,
                technicalFailure: failure)
        }
        return outcome.attachments
    }

    func persistGeneratedImagesOutcome(
        _ images: [Data],
        operation: RemoteImageOperation
    ) -> GeneratedImagePersistenceOutcome {
        guard !images.isEmpty else {
            return GeneratedImagePersistenceOutcome(
                attachments: [], failedCount: 0, failure: nil)
        }
        do {
            try FileManager.default.createDirectory(
                at: generatedImageDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return GeneratedImagePersistenceOutcome(
                attachments: [], failedCount: images.count,
                failure: "The generated-image directory is unavailable: \(error.localizedDescription)")
        }

        var attachments: [AttachmentRef] = []
        var failures: [String] = []
        for (index, data) in images.enumerated() {
            let label = operation == .generate
                ? "Generated \(index + 1)" : "Edited \(index + 1)"
            guard !data.isEmpty else {
                failures.append("\(label) is empty.")
                continue
            }
            guard data.count <= 12 * 1_024 * 1_024 else {
                failures.append("\(label) exceeds 12 MiB.")
                continue
            }
            let format: ImageGenerationImageFormat
            do {
                format = try ImageGenerationImageFormatResolver.resolve(data)
            } catch {
                failures.append("\(label) has unsupported or unrecognized image bytes.")
                continue
            }
            let id = UUID()
            let relative = "\(id.uuidString).\(format.fileExtension)"
            let destination = generatedImageDirectory.appendingPathComponent(relative)
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                // A failed atomic write must not leave an unreferenced file
                // that looks like a saved generated image.
                try? FileManager.default.removeItem(at: destination)
                failures.append("\(label) could not be saved: \(error.localizedDescription)")
                continue
            }
            attachments.append(AttachmentRef(
                id: id,
                kind: .image,
                displayName: "\(label).\(format.fileExtension)",
                uti: format.uti,
                byteCount: data.count,
                sha256: FloeDigest.sha256Hex(data),
                storage: .applicationSupport,
                relativePath: relative
            ))
        }
        if !attachments.isEmpty {
            recentFiles.insert(contentsOf: attachments, at: 0)
        }
        return GeneratedImagePersistenceOutcome(
            attachments: attachments,
            failedCount: failures.count,
            failure: failures.isEmpty ? nil : failures.joined(separator: " "))
    }

    // MARK: - Document working copies

    /// Opens a working copy for safe writeback through the native Office
    /// engine (SecurityScopedDocumentWorkspace + FloeDocuments).
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
