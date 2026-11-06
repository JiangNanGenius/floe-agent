import Foundation
import FloeToolboxRemoteFiles

public struct HostMountPage: Sendable {
    public let entries: [RemoteFileEntry]
    public let nextCursor: String?
    public init(entries: [RemoteFileEntry],nextCursor: String? = nil) { self.entries = entries; self.nextCursor = nextCursor }
}
/// Adapts the App's existing mount/File Provider and credential owner, including SMB shares.
/// These callbacks describe actual operations, not another mount or password registry.
public struct HostMountFileIO: Sendable {
    public let page: @Sendable (RemoteFilePath,String?,Int) async throws -> HostMountPage
    public let metadata: @Sendable (RemoteFilePath) async throws -> RemoteFileEntry
    public let read: @Sendable (RemoteFilePath,UInt64,Int) async throws -> Data
    public let writeWhole: (@Sendable (RemoteFilePath,Data,String?) async throws -> Void)?
    public let mkdir: (@Sendable (RemoteFilePath) async throws -> Void)?
    public let rename: (@Sendable (RemoteFilePath,RemoteFilePath) async throws -> Void)?
    public let delete: (@Sendable (RemoteFilePath,Bool) async throws -> Void)?
    public let releaseLease: @Sendable () async -> Void
    public init(page: @escaping @Sendable (RemoteFilePath,String?,Int) async throws -> HostMountPage,
                metadata: @escaping @Sendable (RemoteFilePath) async throws -> RemoteFileEntry,
                read: @escaping @Sendable (RemoteFilePath,UInt64,Int) async throws -> Data,
                writeWhole: (@Sendable (RemoteFilePath,Data,String?) async throws -> Void)? = nil,
                mkdir: (@Sendable (RemoteFilePath) async throws -> Void)? = nil,
                rename: (@Sendable (RemoteFilePath,RemoteFilePath) async throws -> Void)? = nil,
                delete: (@Sendable (RemoteFilePath,Bool) async throws -> Void)? = nil,
                releaseLease: @escaping @Sendable () async -> Void = {}) {
        self.page = page; self.metadata = metadata; self.read = read; self.writeWhole = writeWhole; self.mkdir = mkdir; self.rename = rename; self.delete = delete; self.releaseLease = releaseLease
    }
}
public actor HostMountFileBackend: RemoteFileBackend {
    public nonisolated let capabilities: Set<RemoteFileCapability>
    private let io: HostMountFileIO
    private let root: RemoteFilePath
    private let windowsNames: Bool
    private var closed = false,busy = false
    public init(root: RemoteFilePath,windowsNames: Bool = false,io: HostMountFileIO) throws {
        self.root = try root.validated(); self.io = io; self.windowsNames = windowsNames
        var capabilities: Set<RemoteFileCapability> = [.list,.read,.resumeRead]
        if io.mkdir != nil { capabilities.insert(.createDirectory) }
        if io.rename != nil { capabilities.insert(.rename) }
        if io.delete != nil { capabilities.insert(.delete) }
        // Whole-file-only hosts do not advertise random-write/resume or atomic replacement.
        self.capabilities = capabilities
    }
    private func check(_ path: RemoteFilePath) throws {
        guard !closed,!Task.isCancelled else { throw RemoteFileError.staleSession }
        _ = try path.validated(); guard path.isWithin(root) else { throw RemoteFileError.outsideRoot }
        if windowsNames { guard !path.value.utf8.contains(where: { [0,34,42,58,60,62,63,92,124].contains($0) || $0 < 32 }) else { throw RemoteFileError.invalidPath } }
    }
    private func completed(_ path: RemoteFilePath) throws { do { try check(path) } catch { throw RemoteFileError.mutationCompletedAfterInvalidation } }
    public func list(_ path: RemoteFilePath) async throws -> [RemoteFileEntry] {
        try check(path); guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        var result: [RemoteFileEntry] = [], cursor: String?, seen: Set<String> = [], names: Set<RemoteFilePath> = [], metadataBytes = 0
        repeat {
            let page = try await io.page(path,cursor,256); try check(path)
            guard page.entries.count <= 256 else { throw RemoteFileError.limit }
            for entry in page.entries {
                try check(entry.path)
                guard entry.path.parent == path, names.insert(entry.path).inserted else { throw RemoteFileError.malformedResponse }
                metadataBytes += entry.path.value.utf8.count+(entry.revision.entityTag?.utf8.count ?? 0)
                guard result.count < 10000, metadataBytes <= 8*1024*1024, (entry.revision.entityTag?.utf8.count ?? 0) <= 8192 else { throw RemoteFileError.limit }
                result.append(entry)
            }
            cursor = page.nextCursor
            if let cursor { guard cursor.utf8.count <= 4096, !cursor.isEmpty, seen.count < 256, seen.insert(cursor).inserted else { throw RemoteFileError.malformedResponse } }
        } while cursor != nil
        return result
    }
    public func metadata(_ path: RemoteFilePath) async throws -> RemoteFileEntry {
        try check(path); let value = try await io.metadata(path); try check(path)
        guard value.path == path else { throw RemoteFileError.malformedResponse }; return value
    }
    public func read(_ path: RemoteFilePath,offset: UInt64,maximumBytes: Int) async throws -> Data {
        try check(path); guard (1...1024*1024).contains(maximumBytes) else { throw RemoteFileError.limit }
        let value = try await io.read(path,offset,maximumBytes); try check(path)
        guard value.count <= maximumBytes else { throw RemoteFileError.limit }; return value
    }
    public func write(_ path: RemoteFilePath,offset: UInt64,bytes: Data,createExclusive: Bool) throws { throw RemoteFileError.unsupported }
    public func writeWhole(_ bytes: Data,to path: RemoteFilePath,expectedETag: String? = nil) async throws {
        try check(path); guard !busy, bytes.count <= 8*1024*1024, let write = io.writeWhole else { throw RemoteFileError.unsupported }
        busy = true; defer { busy = false }; try await write(path,bytes,expectedETag); try completed(path)
    }
    public func createDirectory(_ path: RemoteFilePath) async throws { try check(path); guard let mkdir = io.mkdir else { throw RemoteFileError.unsupported }; try await mkdir(path); try completed(path) }
    public func rename(_ source: RemoteFilePath,to destination: RemoteFilePath,replace: Bool) async throws {
        try check(source); try check(destination); guard !replace, let rename = io.rename else { throw RemoteFileError.unsupported }; try await rename(source,destination); try completed(destination)
    }
    public func delete(_ path: RemoteFilePath,directory: Bool) async throws { try check(path); guard path != root, let delete = io.delete else { throw RemoteFileError.unsupported }; try await delete(path,directory); try completed(path) }
    public func resolve(_ path: RemoteFilePath) throws -> RemoteFilePath { throw RemoteFileError.unsupported }
    public func close() async { guard !closed else { return }; closed = true; await io.releaseLease() }
}
