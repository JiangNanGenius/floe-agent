// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeNotes
import FloeWorkspace
import FloeAgentRuntime

/// No original bytes are loaded during setup. All reads happen inside runtime-owned providers.
@MainActor final class NativeGlobalSourceProvider: GlobalSourceProvider {
    nonisolated let id = "app.formal-native.v1"
    private weak var environment: AppEnvironment?
    private let extractFile: (@Sendable (URL) async throws -> String?)?
    init(environment: AppEnvironment, extractFile: (@Sendable (URL) async throws -> String?)? = nil) {
        self.environment = environment; self.extractFile = extractFile
    }
    @MainActor func inventory(cursor: String?, limit: Int) async throws -> GlobalSourcePage {
        guard let environment else { throw GlobalSourceJobError.unavailable }
        let parts = (cursor ?? "notes:0").split(separator: ":").map(String.init)
        let section = parts.first ?? "notes", offset = Int(parts.last ?? "0") ?? 0, limit = min(128, max(1, limit))
        switch section {
        case "notes":
            let notes = try await NotesRepository.shared.existingStore()?.documents() ?? []
            let values = notes.sorted { $0.id.uuidString < $1.id.uuidString }
            let slice = values.dropFirst(offset).prefix(limit).map { note in
                GlobalSourceDescriptor(id: "note:" + note.id.uuidString, providerID: id, kind: .note, ownerID: note.id.uuidString,
                    revision: String(note.revision), title: note.title, locator: note.id.uuidString, modifiedAt: note.updatedAt)
            }
            return .init(sources: Array(slice), nextCursor: offset + slice.count < values.count ? "notes:\(offset + slice.count)" : "personal:0")
        case "personal":
            let library = try await PersonalContentService.shared.library(), records = try await library.records().sorted { $0.id.uuidString < $1.id.uuidString }
            var slice: [GlobalSourceDescriptor] = []
            for record in records.dropFirst(offset).prefix(limit) where GlobalSourceTextPolicy.permittedName(record.relativePath) {
                try Task.checkCancellation()
                let revision: String
                do {
                    let location = try await library.resolve(record.id)
                    revision = try await personalRevision(record, directory: location.url)
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
                slice.append(GlobalSourceDescriptor(id: "personal:" + record.id.uuidString, providerID: id,
                    kind: record.kind == .document ? .personalFile : .personalWork,
                    ownerID: record.id.uuidString, revision: revision, title: record.title, locator: record.id.uuidString,
                    modifiedAt: record.modifiedAt, availability: record.kind == .document ? .available : .needsTextExtraction))
            }
            // Advance over the original page even when a source is excluded by the path policy.
            let next = min(records.count, offset + limit)
            return .init(sources: Array(slice), nextCursor: next < records.count ? "personal:\(next)" : "chat:0")
        default:
            let providerID = id
            let values = try await environment.database.reader { db in
                try Row.fetchAll(db, sql: "SELECT m.id,m.conversation_id,m.content,m.created_at,c.title,wc.workspace_id FROM messages m JOIN conversations c ON c.id=m.conversation_id LEFT JOIN conversation_workspace_ownership wc ON wc.conversation_id=c.id WHERE c.purpose='ordinary' AND c.is_searchable=1 AND m.role IN ('user','assistant') ORDER BY m.id LIMIT ? OFFSET ?", arguments: [limit, offset]).compactMap { row -> GlobalSourceDescriptor? in
                    let key: String = row["id"], conversation: String = row["conversation_id"], body: String = row["content"], workspace: String? = row["workspace_id"], created: String = row["created_at"]
                    guard let messageID = UUID(uuidString: key), let conversationID = UUID(uuidString: conversation) else { return nil }
                    return .init(id: "message:" + key, providerID: providerID, kind: .conversationMessage, ownerID: conversation,
                        revision: MemoryContentDigest.make(body), title: row["title"], locator: key, workspaceID: workspace.flatMap(UUID.init(uuidString:)), conversationID: conversationID, messageID: messageID,
                        modifiedAt: ISO8601DateFormatter().date(from: created) ?? .distantPast)
                }
            }
            return .init(sources: values, nextCursor: values.count == limit ? "chat:\(offset + limit)" : nil)
        }
    }
    @MainActor func read(_ source: GlobalSourceDescriptor) async throws -> GlobalSourceSnapshot {
        guard let environment, source.providerID == id else { throw GlobalSourceJobError.unavailable }
        switch source.kind {
        case .note:
            guard let key = UUID(uuidString: source.locator), let store = try await NotesRepository.shared.existingStore() else { throw GlobalSourceJobError.unavailable }
            let note = try await store.document(key)
            guard note.deletedAt == nil, note.id.uuidString == source.ownerID, String(note.revision) == source.revision else { throw GlobalSourceJobError.sourceChanged }
            return .init(source: source, text: String(note.searchableText.prefix(1_000_000)), truncated: note.searchableText.count > 1_000_000)
        case .personalFile, .personalWork:
            guard let key = UUID(uuidString: source.locator) else { throw GlobalSourceJobError.unavailable }
            let library = try await PersonalContentService.shared.library(), location = try await library.resolve(key), record = location.record
            guard record.id.uuidString == source.ownerID, GlobalSourceTextPolicy.permittedName(record.relativePath),
                  try await personalRevision(record, directory: location.url) == source.revision else { throw GlobalSourceJobError.sourceChanged }
            let text: String?
            if record.kind == .document {
                let url = try await PersonalContentService.shared.originalFile(key)
                text = try await Self.fileText(url, extractor: extractFile)
            } else if [.image, .drawing, .video].contains(record.kind) {
                text = try await GlobalSavedMediaTextReader.shared.read(personalDirectory: location.url, ownerID: key)?.text
            } else { text = nil }
            guard try await personalRevision(record, directory: location.url) == source.revision else { throw GlobalSourceJobError.sourceChanged }
            var descriptor = source
            descriptor.availability = text == nil ? .needsTextExtraction : .available
            return .init(source: descriptor, text: String((text ?? record.title).prefix(1_000_000)), truncated: (text?.count ?? 0) > 1_000_000)
        case .conversationMessage:
            return try await environment.database.reader { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT m.content,m.conversation_id FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.id=? AND c.purpose='ordinary' AND c.is_searchable=1", arguments: [source.locator]) else { throw GlobalSourceJobError.unavailable }
                let body: String = row["content"], owner: String = row["conversation_id"]
                guard owner == source.ownerID, MemoryContentDigest.make(body) == source.revision else { throw GlobalSourceJobError.sourceChanged }
                return .init(source: source, text: String(body.prefix(1_000_000)), truncated: body.count > 1_000_000)
            }
        case .workspaceFile: throw GlobalSourceJobError.unavailable
        }
    }
    /// Native identity and actual saved-file metadata, never frontmost editor
    /// state or a path taken from source contents. Parser revisions retrigger
    /// extraction when this App gains support for an already-existing file.
    private func personalRevision(_ record: PersonalContentRecord, directory: URL) async throws -> String {
        let saved: String
        if record.kind == .document {
            let file = try await PersonalContentService.shared.originalFile(record.id)
            saved = try GlobalExtractionFile.revision(file)
        } else if [.image, .drawing, .video].contains(record.kind) {
            saved = try GlobalSavedMediaTextReader.revision(personalDirectory: directory, ownerID: record.id)
        } else { saved = ProtectedGlobalFileTextExtractor.revision }
        return record.modifiedAt.ISO8601Format() + "|" + saved
    }
    func isAccessible(_ source: GlobalSourceDescriptor) async -> Bool { (try? await read(source)) != nil }
    nonisolated static func fileText(_ url: URL, extractor: (@Sendable (URL) async throws -> String?)?) async throws -> String? {
        guard GlobalSourceTextPolicy.permittedName(url.lastPathComponent) else { throw GlobalSourceJobError.excluded }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 16 * 1_024 * 1_024 else { throw GlobalSourceJobError.unavailable }
        let plain = ["txt", "md", "markdown", "json", "csv", "tsv", "html", "htm", "xml", "yaml", "yml", "swift", "py", "js", "ts", "c", "h", "cpp", "rs", "java", "kt"]
        if plain.contains(url.pathExtension.lowercased()) {
            return try await Task.detached(priority: .utility) { String(data: try Data(contentsOf: url, options: .mappedIfSafe), encoding: .utf8) }.value
        }
        // PDF/Office/media extraction must be injected from the existing protected native services.
        return try await extractor?(url)
    }
}

nonisolated final class GlobalWorkspaceReadLease: Sendable {
    let workspaceID: UUID
    let ownerID: String
    let root: URL
    let release: @Sendable () async -> Void
    init(workspaceID: UUID, ownerID: String, root: URL, release: @escaping @Sendable () async -> Void) {
        self.workspaceID = workspaceID; self.ownerID = ownerID; self.root = root; self.release = release
    }
}
/// The host supplies its existing bookmark/root lease resolver. Neither indexed paths
/// nor model arguments can mint a lease or select an arbitrary filesystem root.
nonisolated struct WorkspaceGlobalSourceProvider: GlobalSourceProvider {
    let id = "app.formal-workspaces.v1"
    let workspaceIDs: @Sendable () async throws -> [UUID]
    let acquire: @Sendable (UUID) async throws -> GlobalWorkspaceReadLease
    var extractFile: (@Sendable (URL) async throws -> String?)?
    func inventory(cursor: String?, limit: Int) async throws -> GlobalSourcePage {
        let pieces = (cursor ?? "0:0").split(separator: ":"), workspaceIndex = Int(pieces.first ?? "0") ?? 0, fileOffset = Int(pieces.last ?? "0") ?? 0
        let ids = try await workspaceIDs().sorted { $0.uuidString < $1.uuidString }
        guard workspaceIndex < ids.count else { return .init(sources: [], nextCursor: nil) }
        let lease: GlobalWorkspaceReadLease
        do { lease = try await acquire(ids[workspaceIndex]) }
        catch {
            return .init(sources: [], nextCursor: workspaceIndex + 1 < ids.count ? "\(workspaceIndex + 1):0" : nil, unavailableOwners: [ids[workspaceIndex].uuidString])
        }
        do {
            let files = try Self.files(lease), slice = files.dropFirst(fileOffset).prefix(min(128, max(1, limit)))
            await lease.release()
            let next = fileOffset + slice.count < files.count ? "\(workspaceIndex):\(fileOffset + slice.count)" : workspaceIndex + 1 < ids.count ? "\(workspaceIndex + 1):0" : nil
            return .init(sources: Array(slice), nextCursor: next)
        } catch { await lease.release(); throw error }
    }
    private static func files(_ lease: GlobalWorkspaceReadLease) throws -> [GlobalSourceDescriptor] {
        let resolver = WorkspacePathGuard(rootURL: lease.root)
        guard let walk = FileManager.default.enumerator(at: lease.root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey], options: [.skipsHiddenFiles]) else { return [] }
        var output = [GlobalSourceDescriptor]()
        for case let url as URL in walk {
            let relative = String(url.path.dropFirst(lease.root.path.count + 1))
            if !GlobalSourceTextPolicy.permittedName(relative) { walk.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            guard values.isSymbolicLink != true else { walk.skipDescendants(); continue }
            guard values.isRegularFile == true, (try? resolver.resolve(relative)) != nil, let size = values.fileSize, size <= 16 * 1_024 * 1_024 else { continue }
            guard output.count < 20_000 else { throw GlobalSourceJobError.unavailable }
            let stable = values.fileResourceIdentifier.map { String(describing: $0) } ?? relative
            let date = values.contentModificationDate ?? .distantPast
            output.append(.init(id: "workspace:" + lease.workspaceID.uuidString + ":" + MemoryContentDigest.make(stable), providerID: "app.formal-workspaces.v1", kind: .workspaceFile,
                ownerID: lease.ownerID, revision: try GlobalExtractionFile.revision(url), title: url.lastPathComponent, locator: relative, workspaceID: lease.workspaceID, modifiedAt: date))
        }
        return output.sorted { $0.id < $1.id }
    }
    func read(_ source: GlobalSourceDescriptor) async throws -> GlobalSourceSnapshot {
        guard source.providerID == id, let workspaceID = source.workspaceID else { throw GlobalSourceJobError.unavailable }
        let lease = try await acquire(workspaceID)
        do {
            guard lease.ownerID == source.ownerID, GlobalSourceTextPolicy.permittedName(source.locator) else { throw GlobalSourceJobError.excluded }
            let url = try WorkspacePathGuard(rootURL: lease.root).resolve(source.locator)
            let revision = try GlobalExtractionFile.revision(url)
            guard revision == source.revision else { throw GlobalSourceJobError.sourceChanged }
            let text = try await NativeGlobalSourceProvider.fileText(url, extractor: extractFile)
            guard try GlobalExtractionFile.revision(url) == source.revision else { throw GlobalSourceJobError.sourceChanged }
            var descriptor = source
            if text == nil { descriptor.availability = .needsTextExtraction }
            let result = GlobalSourceSnapshot(source: descriptor, text: String((text ?? source.title).prefix(1_000_000)), truncated: (text?.count ?? 0) > 1_000_000)
            await lease.release(); return result
        } catch { await lease.release(); throw error }
    }
    func isAccessible(_ source: GlobalSourceDescriptor) async -> Bool { (try? await read(source)) != nil }
}
#endif
