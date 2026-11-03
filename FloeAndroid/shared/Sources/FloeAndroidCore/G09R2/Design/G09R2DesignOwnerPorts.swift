// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — the app-facing owner ports for the shared design workflow.
//
// These adapters resolve the EXISTING Android owners (workspace files, private
// chat attachments) through their real stores and the accepted root. They do
// not invent a workspace/project, a chat task or an attachment: a missing
// owner row, a non-private workspace bookmark, a non-app-private attachment or
// an unsupported environment is a typed refusal.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeWorkspace

// MARK: - Shared private-task workspace resolution

enum G09R2DesignWorkspaceResolver {
    static func privateTaskRoot(
        root: RuntimeStorageRoot,
        workspaceStore: SQLiteWorkspaceStore,
        workspaceID: UUID
    ) async throws -> URL {
        guard let record = try? await workspaceStore.workspace(id: workspaceID) else {
            throw DesignTargetError.notFound("workspace \(workspaceID.uuidString.lowercased()) does not exist")
        }
        guard record.kind == .privateTask,
              let relative = record.internalRelativePath else {
            throw DesignTargetError.unavailable(
                "only the explicit private-task workspace shape is supported on Android; project/SAF bookmarks are not a native design root")
        }
        let prefix = "PrivateTasks/"
        guard relative.hasPrefix(prefix),
              UUID(uuidString: String(relative.dropFirst(prefix.count))) != nil else {
            throw DesignTargetError.unavailable("workspace identity is not the owned private-task shape")
        }
        let workspaceRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
        let target = workspaceRoot.appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
        let base = workspaceRoot.standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else {
            throw DesignTargetError.invalidReference("workspace root escapes the accepted root")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DesignTargetError.notFound("workspace directory is missing")
        }
        return target
    }

    static func format(for url: URL, fallback: String = "bin") -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? fallback : ext
    }

    static func mimeType(for format: String) -> String? {
        switch format.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tiff", "tif": return "image/tiff"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return nil
        }
    }
}

// MARK: - Workspace file owner

struct G09R2DesignWorkspaceFilePort: DesignWorkspaceFilePort {
    let root: RuntimeStorageRoot
    let workspaceStore: SQLiteWorkspaceStore

    func resolve(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        guard runID == nil else {
            throw DesignTargetError.notAuthorized(
                "run-scoped workspace design resolution requires a live app authorization grant; this direct host path does not infer one")
        }
        guard environmentID == nil else {
            throw DesignTargetError.unavailable(
                "environment-scoped workspace design is not connected in this build")
        }
        guard let workspaceUUID = UUID(uuidString: workspaceID) else {
            throw DesignTargetError.invalidReference("workspaceID is not a UUID")
        }
        let clean = try DesignTargetValidation.relativeReference(reference)
        let rootURL = try await G09R2DesignWorkspaceResolver.privateTaskRoot(
            root: root, workspaceStore: workspaceStore, workspaceID: workspaceUUID)
        let service = WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: rootURL,
            maxReadBytes: Int(G09R2CreativeLimits.designSourceBytes),
            maxWriteBytes: Int(G09R2CreativeLimits.designSourceBytes)))
        let url = try service.guardResolver.resolve(clean)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw DesignTargetError.notFound("workspace file is missing")
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, Int64(size) > G09R2CreativeLimits.designSourceBytes {
            throw DesignTargetError.unverifiable("workspace file exceeds the design source cap")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw DesignTargetError.unverifiable("workspace file could not be read")
        }
        guard !data.isEmpty,
              Int64(data.count) <= G09R2CreativeLimits.designSourceBytes else {
            throw DesignTargetError.unverifiable("workspace file is empty or too large")
        }
        let digest = FloeDigest.sha256Hex(data)
        let modified: Date?
        do {
            modified = try url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch {
            modified = nil
        }
        let mtime = modified?.timeIntervalSince1970 ?? 0
        let token = Self.workspaceBaseToken(
            workspaceID: workspaceUUID, digest: digest, mtime: mtime)
        return DesignResolvedFile(
            data: data,
            format: G09R2DesignWorkspaceResolver.format(for: url),
            displayName: url.lastPathComponent,
            contentSHA256: digest,
            baseRevisionToken: token,
            allowsInPlaceUpdate: true)
    }

    func isAuthorized(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        guard runID == nil, environmentID == nil,
              let workspaceUUID = UUID(uuidString: workspaceID),
              let clean = try? DesignTargetValidation.relativeReference(reference) else {
            return false
        }
        guard let rootURL = try? await G09R2DesignWorkspaceResolver.privateTaskRoot(
            root: root, workspaceStore: workspaceStore, workspaceID: workspaceUUID) else {
            return false
        }
        let guarder = WorkspacePathGuard(rootURL: rootURL)
        guard let url = try? guarder.resolve(clean) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool {
        await isAuthorized(
            workspaceID: workspaceID, reference: reference,
            environmentID: environmentID, runID: nil)
    }

    static func workspaceBaseToken(
        workspaceID: UUID,
        digest: String,
        mtime: TimeInterval
    ) -> String {
        "workspace:\(workspaceID.uuidString.lowercased()):sha:\(digest.lowercased()):mtime:\(Int64(mtime * 1000))"
    }

    static func baseDigest(from token: String) -> String? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, String(parts[0]) == "workspace", String(parts[2]) == "sha" else {
            return nil
        }
        let digest = String(parts[3]).lowercased()
        guard digest.count == 64, digest.unicodeScalars.allSatisfy({
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }) else { return nil }
        return digest
    }
}

// MARK: - Workspace in-place commit (CAS + readback)

struct G09R2DesignWorkspaceCommitPort: DesignOwnerCommitPort {
    let root: RuntimeStorageRoot
    let workspaceStore: SQLiteWorkspaceStore

    func canCommit(_ target: DesignTarget) -> Bool {
        target.kind == .fileDocument
    }

    func commit(
        target: DesignTarget,
        reference: String,
        bytes: Data,
        format: String,
        baseRevisionToken: String
    ) async throws -> String {
        guard target.kind == .fileDocument,
              let workspaceUUID = UUID(uuidString: target.ownerID),
              let baseDigest = G09R2DesignWorkspaceFilePort.baseDigest(
                from: baseRevisionToken) else {
            throw DesignOwnerCommitError.notWritten("invalid workspace design base token")
        }
        let proposedDigest = FloeDigest.sha256Hex(bytes)
        guard !bytes.isEmpty,
              Int64(bytes.count) <= G09R2CreativeLimits.designSourceBytes else {
            throw DesignOwnerCommitError.notWritten("design payload is empty or too large")
        }
        let clean = try DesignTargetValidation.relativeReference(reference)
        let rootURL: URL
        do {
            rootURL = try await G09R2DesignWorkspaceResolver.privateTaskRoot(
                root: root, workspaceStore: workspaceStore, workspaceID: workspaceUUID)
        } catch {
            throw DesignOwnerCommitError.notWritten("workspace owner is unavailable")
        }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: rootURL,
            maxReadBytes: Int(G09R2CreativeLimits.designSourceBytes),
            maxWriteBytes: Int(G09R2CreativeLimits.designSourceBytes)))
        let artifacts = G09R2DesignArtifactStore(root: root)
        var scratch: URL?
        defer {
            if let scratch {
                artifacts.removeScratchFile(scratch)
            }
        }
        do {
            let url = try artifacts.makeScratchFile(bytes: bytes, format: format)
            scratch = url
            let outcome = try service.replaceBinaryFile(
                clean,
                from: url,
                expectedOriginalSHA256: baseDigest,
                expectedSourceSHA256: proposedDigest,
                expectedSourceBytes: bytes.count)
            guard outcome.sha256.caseInsensitiveCompare(proposedDigest) == .orderedSame else {
                throw DesignOwnerCommitError.unknown(
                    "workspace readback did not report the proposed digest")
            }
            let writtenURL = try service.guardResolver.resolve(clean)
            let readback = try FloeDigest.sha256Hex(ofFileAt: writtenURL)
            guard readback.caseInsensitiveCompare(proposedDigest) == .orderedSame else {
                throw DesignOwnerCommitError.unknown(
                    "workspace readback digest mismatch")
            }
            let modified: Date?
            do {
                modified = try writtenURL.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate
            } catch {
                modified = nil
            }
            let mtime = modified?.timeIntervalSince1970 ?? 0
            return G09R2DesignWorkspaceFilePort.workspaceBaseToken(
                workspaceID: workspaceUUID, digest: readback, mtime: mtime)
        } catch let typed as DesignOwnerCommitError {
            throw typed
        } catch let typed as WorkspaceToolError {
            switch typed {
            case .conflict(_, _), .invalidArguments(_), .tooLarge(_),
                 .escapesRoot(_), .notFound(_), .isDirectory(_),
                 .secretFile(_), .unsupportedContent(_):
                throw DesignOwnerCommitError.notWritten("workspace CAS refused the write")
            default:
                throw DesignOwnerCommitError.unknown("workspace write may have landed")
            }
        } catch {
            throw DesignOwnerCommitError.unknown("workspace write may have landed")
        }
    }

    func verify(
        target: DesignTarget,
        reference: String,
        proposedContentSHA256: String,
        baseRevisionToken: String
    ) async throws -> DesignCommitVerification {
        guard target.kind == .fileDocument,
              let workspaceUUID = UUID(uuidString: target.ownerID),
              let baseDigest = G09R2DesignWorkspaceFilePort.baseDigest(
                from: baseRevisionToken) else {
            throw DesignTargetError.invalidReference("invalid workspace verification token")
        }
        let clean = try DesignTargetValidation.relativeReference(reference)
        let rootURL = try await G09R2DesignWorkspaceResolver.privateTaskRoot(
            root: root, workspaceStore: workspaceStore, workspaceID: workspaceUUID)
        let service = WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: rootURL,
            maxReadBytes: Int(G09R2CreativeLimits.designSourceBytes),
            maxWriteBytes: Int(G09R2CreativeLimits.designSourceBytes)))
        let url = try service.guardResolver.resolve(clean)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .missing
        }
        let actual = try FloeDigest.sha256Hex(ofFileAt: url)
        if actual.caseInsensitiveCompare(proposedContentSHA256) == .orderedSame {
            return .matchesProposed
        }
        if actual.caseInsensitiveCompare(baseDigest) == .orderedSame {
            return .matchesBase
        }
        return .diverged(actualSHA256: actual)
    }
}

// MARK: - Chat attachment owner

struct G09R2DesignChatAttachmentPort: DesignChatAttachmentPort {
    let root: RuntimeStorageRoot
    let conversationStore: SQLiteConversationStore

    func resolveAttachment(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async throws -> DesignChatAttachment {
        guard runID == nil else {
            throw DesignTargetError.notAuthorized(
                "run-scoped chat design requires a live task authorization; this direct host path does not infer one")
        }
        let attachment = try await loadAttachment(
            conversationID: conversationID,
            messageID: messageID,
            attachmentID: attachmentID)
        guard attachment.storage == .applicationSupport,
              let relative = attachment.relativePath,
              G09CreativeAssetHost.safeRelativePath(relative) else {
            throw DesignTargetError.unavailable(
                "only app-private conversation attachments are a design source")
        }
        let attachmentsRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        guard let url = G09R2DesignFileIO.containedURL(
            root: attachmentsRoot, relative: relative) else {
            throw DesignTargetError.invalidReference("attachment path escapes its owner root")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignTargetError.notFound("attachment bytes are missing")
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, Int64(size) > G09R2CreativeLimits.designSourceBytes {
            throw DesignTargetError.unverifiable("attachment exceeds the design source cap")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw DesignTargetError.unverifiable("attachment bytes could not be read")
        }
        guard !data.isEmpty,
              Int64(data.count) <= G09R2CreativeLimits.designSourceBytes else {
            throw DesignTargetError.unverifiable("attachment is empty or too large")
        }
        let digest = FloeDigest.sha256Hex(data)
        if !attachment.sha256.isEmpty,
           attachment.sha256.caseInsensitiveCompare(digest) != .orderedSame {
            throw DesignTargetError.unverifiable("attachment digest mismatch")
        }
        let format = G09R2DesignWorkspaceResolver.format(for: url)
        return DesignChatAttachment(
            data: data,
            format: format,
            displayName: attachment.displayName.isEmpty
                ? url.lastPathComponent : attachment.displayName,
            contentSHA256: digest,
            baseRevisionToken: Self.chatBaseToken(id: attachment.id, digest: digest),
            conversationID: conversationID)
    }

    func attachmentIsAccessible(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async -> Bool {
        guard runID == nil else { return false }
        guard let attachment = try? await loadAttachment(
            conversationID: conversationID,
            messageID: messageID,
            attachmentID: attachmentID),
              attachment.storage == .applicationSupport,
              let relative = attachment.relativePath,
              G09CreativeAssetHost.safeRelativePath(relative) else {
            return false
        }
        let attachmentsRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        guard let url = G09R2DesignFileIO.containedURL(
            root: attachmentsRoot, relative: relative) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func loadAttachment(
        conversationID: String,
        messageID: String,
        attachmentID: String
    ) async throws -> AttachmentRef {
        guard let conversationUUID = UUID(uuidString: conversationID),
              let attachmentUUID = UUID(uuidString: attachmentID) else {
            throw DesignTargetError.invalidReference("invalid chat attachment identity")
        }
        guard let attachment = try? await conversationStore.attachment(id: attachmentUUID),
              let owner = attachment.conversationID,
              owner == conversationUUID else {
            throw DesignTargetError.notFound("attachment does not belong to the requested conversation")
        }
        if !messageID.isEmpty {
            guard let messageUUID = UUID(uuidString: messageID),
                  attachment.messageID == messageUUID else {
                throw DesignTargetError.notFound("attachment does not belong to the requested message")
            }
        }
        return attachment
    }

    static func chatBaseToken(id: UUID, digest: String) -> String {
        "chat:\(id.uuidString.lowercased()):sha:\(digest.lowercased())"
    }
}

// MARK: - Chat publication (immutable owner result)

struct G09R2DesignChatPublicationPort: DesignResultPublicationPort {
    let root: RuntimeStorageRoot
    let conversationStore: SQLiteConversationStore

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        guard publication.target.kind == .chatAttachment,
              let conversationUUID = UUID(uuidString: publication.target.ownerID) else {
            throw DesignTargetError.unavailable(
                "no result-publication destination is connected for this owner kind")
        }
        let conversation = try await conversationStore.conversation(
            id: conversationUUID)
        guard conversation != nil else {
            throw DesignTargetError.notFound("originating conversation no longer exists")
        }
        let digest = FloeDigest.sha256Hex(publication.bytes)
        guard digest.caseInsensitiveCompare(publication.contentSHA256) == .orderedSame else {
            throw DesignTargetError.unverifiable("publication payload digest mismatch")
        }
        let attachmentID = Self.deterministicUUID(
            key: publication.publicationKey)
        if let existing = try? await conversationStore.attachment(id: attachmentID) {
            guard existing.conversationID == conversationUUID,
                  existing.sha256.caseInsensitiveCompare(digest) == .orderedSame,
                  let relative = existing.relativePath,
                  G09CreativeAssetHost.safeRelativePath(relative) else {
                throw DesignTargetError.invalidReference(
                    "publication id is already bound to different bytes")
            }
            let attachmentsRoot = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent("Attachments", isDirectory: true)
            guard let url = G09R2DesignFileIO.containedURL(
                root: attachmentsRoot, relative: relative),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw DesignTargetError.unverifiable(
                    "published attachment bytes are missing")
            }
            let existingBytes = try G09R2DesignFileIO.readBounded(
                url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
            guard FloeDigest.sha256Hex(existingBytes)
                .caseInsensitiveCompare(digest) == .orderedSame else {
                throw DesignTargetError.unverifiable(
                    "published attachment bytes do not match the receipt")
            }
            return DesignResultPublicationReceipt(
                identifier: existing.id.uuidString.lowercased(),
                destination: "chat:\(conversationUUID.uuidString.lowercased())",
                contentSHA256: digest)
        }
        let format = publication.format.lowercased()
        let extensionValue = G09R2DesignArtifactStore.fileExtension(for: format)
        let baseName = G09R2DesignArtifactStore.safeFileName(
            publication.displayName, format: format)
            ?? "design-result.\(extensionValue)"
        let directoryName = attachmentID.uuidString.lowercased()
        let relative = "\(directoryName)/\(baseName)"
        let attachmentsRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        guard let url = G09R2DesignFileIO.containedURL(
            root: attachmentsRoot, relative: relative) else {
            throw DesignTargetError.invalidReference("publication path escapes its owner root")
        }
        var created = false
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try G09R2DesignFileIO.readBounded(
                url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
            guard FloeDigest.sha256Hex(existing)
                .caseInsensitiveCompare(digest) == .orderedSame else {
                throw DesignTargetError.invalidReference(
                    "publication path already holds different bytes")
            }
        } else {
            try G09R2DesignFileIO.writeAtomically(publication.bytes, to: url)
            created = true
            let readback = try G09R2DesignFileIO.readBounded(
                url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
            guard FloeDigest.sha256Hex(readback)
                .caseInsensitiveCompare(digest) == .orderedSame else {
                G09R2DesignFileIO.remove(url)
                throw DesignTargetError.unverifiable("publication readback mismatch")
            }
        }
        let kind: AttachmentRef.Kind
        switch format {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff":
            kind = .image
        case "mp4", "mov", "m4v", "webm":
            kind = .other
        case "pdf", "md", "markdown", "txt", "html", "htm", "svg", "json",
             "docx", "xlsx", "pptx":
            kind = .document
        default:
            kind = .other
        }
        let ref = AttachmentRef(
            id: attachmentID,
            conversationID: conversationUUID,
            kind: kind,
            displayName: baseName,
            uti: G09R2DesignWorkspaceResolver.mimeType(for: format) ?? format,
            byteCount: publication.bytes.count,
            sha256: digest,
            storage: .applicationSupport,
            relativePath: relative,
            createdAt: Date())
        do {
            try await conversationStore.saveAttachment(ref)
        } catch {
            if created {
                G09R2DesignFileIO.remove(url)
            }
            throw error
        }
        return DesignResultPublicationReceipt(
            identifier: attachmentID.uuidString.lowercased(),
            destination: "chat:\(conversationUUID.uuidString.lowercased())",
            contentSHA256: digest)
    }

    private static func deterministicUUID(key: String) -> UUID {
        let digest = FloeDigest.sha256Hex(Data(key.utf8))
        let hex = String(digest.prefix(32))
        let start = hex.startIndex
        func slice(_ offset: Int, _ length: Int) -> String {
            let lower = hex.index(start, offsetBy: offset)
            let upper = hex.index(lower, offsetBy: length)
            return String(hex[lower..<upper])
        }
        let value = "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
        return UUID(uuidString: value) ?? UUID()
    }
}
