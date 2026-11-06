import Foundation
import FloeToolboxCore

public enum RemoteFileProtocol: String, Codable, CaseIterable, Sendable { case sftp, scp, ftp, ftps, webDAV, smb }
public enum RemoteFileCapability: String, Codable, Hashable, Sendable {
    case list, read, write, createDirectory, rename, delete, resolveLink, resumeRead, resumeWrite, atomicRename
}
public enum RemoteFileKind: String, Codable, Sendable { case file, directory, symbolicLink, unknown }
public enum RemoteFileError: Error, Equatable, Sendable {
    case invalidPath, outsideRoot, staleSession, denied, unsupported, limit, busy, notFound, conflict
    case connectionClosed, malformedResponse, serverStatus(UInt32), authenticationFailed, cancelled
    case mutationCompletedAfterInvalidation
}

/// Canonical POSIX-style paths inside the explicit root of one remote connection.
public struct RemoteFilePath: Codable, Hashable, Sendable {
    public let value: String
    public init(_ raw: String) throws {
        guard raw.hasPrefix("/"), raw.utf8.count <= 32768, !raw.contains("\0") else { throw RemoteFileError.invalidPath }
        var parts: [Substring] = []
        for part in raw.split(separator:"/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { throw RemoteFileError.outsideRoot }; parts.removeLast() }
            else { parts.append(part) }
        }
        value = "/"+parts.joined(separator:"/")
    }
    public var name: String { value.split(separator:"/").last.map(String.init) ?? "/" }
    private init(canonical: String) { value = canonical }
    public var parent: RemoteFilePath {
        guard let slash = value.lastIndex(of:"/"), slash != value.startIndex else { return Self(canonical:"/") }
        return Self(canonical:String(value[..<slash]))
    }
    private enum CodingKeys: String, CodingKey { case value }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy:CodingKeys.self)
        try self.init(container.decode(String.self,forKey:.value))
    }
    public func appending(_ name: String) throws -> Self {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 4096 else { throw RemoteFileError.invalidPath }
        return try Self((value == "/" ? "" : value)+"/"+name)
    }
    public func isWithin(_ root: Self) -> Bool { root.value == "/" || value == root.value || value.hasPrefix(root.value+"/") }
    public func validated() throws -> Self {
        let normalized = try Self(value)
        guard normalized.value == value else { throw RemoteFileError.invalidPath }; return normalized
    }
}

public struct RemoteFileRevision: Codable, Equatable, Sendable {
    public var entityTag: String?
    public var byteCount: UInt64?
    public var modifiedAt: Date?
    public init(entityTag: String? = nil, byteCount: UInt64? = nil, modifiedAt: Date? = nil) {
        self.entityTag = entityTag; self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
}
public struct RemoteFileEntry: Codable, Equatable, Identifiable, Sendable {
    public let path: RemoteFilePath
    public let kind: RemoteFileKind
    public let revision: RemoteFileRevision
    public let permissions: UInt32?
    public var id: String { path.value }
    public init(path: RemoteFilePath, kind: RemoteFileKind, revision: RemoteFileRevision = RemoteFileRevision(), permissions: UInt32? = nil) {
        self.path = path; self.kind = kind; self.revision = revision; self.permissions = permissions
    }
}
public enum RemoteFileEffect: String, Sendable { case list, read, upload, createDirectory, rename, delete, synchronize }
public struct RemoteFileAuthorizationRequest: Sendable {
    public let lease: SessionLease
    public let machine: MachineReference
    public let effect: RemoteFileEffect
    public let source: RemoteFilePath?
    public let destination: RemoteFilePath?
    public init(lease: SessionLease, machine: MachineReference, effect: RemoteFileEffect,
                source: RemoteFilePath? = nil, destination: RemoteFilePath? = nil) {
        self.lease = lease; self.machine = machine; self.effect = effect; self.source = source; self.destination = destination
    }
}
public typealias RemoteFileAuthorizer = @Sendable (RemoteFileAuthorizationRequest) async throws -> Bool

/// Actual adapters advertise operations they implement, independently of a protocol's name.
public protocol RemoteFileBackend: Sendable {
    var capabilities: Set<RemoteFileCapability> { get }
    func list(_ path: RemoteFilePath) async throws -> [RemoteFileEntry]
    func metadata(_ path: RemoteFilePath) async throws -> RemoteFileEntry
    func read(_ path: RemoteFilePath, offset: UInt64, maximumBytes: Int) async throws -> Data
    func write(_ path: RemoteFilePath, offset: UInt64, bytes: Data, createExclusive: Bool) async throws
    func createDirectory(_ path: RemoteFilePath) async throws
    func rename(_ source: RemoteFilePath, to destination: RemoteFilePath, replace: Bool) async throws
    func delete(_ path: RemoteFilePath, directory: Bool) async throws
    func resolve(_ path: RemoteFilePath) async throws -> RemoteFilePath
    func close() async
}

/// One target/root/lease; host adapts the callback to its existing approval chain.
public actor RemoteFileSession {
    public nonisolated let lease: SessionLease
    public nonisolated let machine: MachineReference
    public nonisolated let root: RemoteFilePath
    public nonisolated let capabilities: Set<RemoteFileCapability>
    private let backend: any RemoteFileBackend
    private let authorize: RemoteFileAuthorizer
    private var closed = false
    public init(lease: SessionLease, machine: MachineReference, root: RemoteFilePath,
                backend: any RemoteFileBackend, authorize: @escaping RemoteFileAuthorizer) throws {
        self.lease = lease; self.machine = machine; self.root = try root.validated()
        self.backend = backend; self.capabilities = backend.capabilities; self.authorize = authorize
    }
    private func check(_ expected: SessionLease, _ paths: RemoteFilePath...) throws {
        guard expected == lease, !closed, !Task.isCancelled else { throw RemoteFileError.staleSession }
        for path in paths { _ = try path.validated(); guard path.isWithin(root) else { throw RemoteFileError.outsideRoot } }
    }
    private func allow(_ effect: RemoteFileEffect, source: RemoteFilePath? = nil, destination: RemoteFilePath? = nil) async throws {
        guard try await authorize(RemoteFileAuthorizationRequest(lease:lease,machine:machine,effect:effect,source:source,destination:destination)) else { throw RemoteFileError.denied }
    }
    private func resolvedCheck(_ path: RemoteFilePath, parent: Bool = false, expected: SessionLease) async throws {
        guard capabilities.contains(.resolveLink) else { return }
        let resolved = try await backend.resolve(parent ? path.parent : path)
        try check(expected,resolved)
    }
    private func mutationCompleted(_ expected: SessionLease) throws {
        do { try check(expected) } catch { throw RemoteFileError.mutationCompletedAfterInvalidation }
    }
    private func validate(_ entry: RemoteFileEntry) throws {
        guard (entry.revision.entityTag?.utf8.count ?? 0) <= 8192 else { throw RemoteFileError.limit }
        if let date = entry.revision.modifiedAt {
            guard date.timeIntervalSince1970.isFinite, (-62135596800...253402300799).contains(date.timeIntervalSince1970) else { throw RemoteFileError.malformedResponse }
        }
    }
    public func list(_ path: RemoteFilePath, expected: SessionLease) async throws -> [RemoteFileEntry] {
        try check(expected,path); guard capabilities.contains(.list) else { throw RemoteFileError.unsupported }
        try await allow(.list,source:path); try check(expected,path)
        try await resolvedCheck(path,expected:expected)
        let entries = try await backend.list(path); try check(expected,path)
        guard entries.count <= 10_000 else { throw RemoteFileError.limit }
        var names: Set<RemoteFilePath> = []
        var metadataBytes = 0
        for entry in entries {
            try validate(entry)
            _ = try entry.path.validated()
            guard entry.path.isWithin(root), entry.path.parent == path else { throw RemoteFileError.outsideRoot }
            guard names.insert(entry.path).inserted else { throw RemoteFileError.malformedResponse }
            metadataBytes += entry.path.value.utf8.count+(entry.revision.entityTag?.utf8.count ?? 0)
            guard metadataBytes <= 8*1024*1024 else { throw RemoteFileError.limit }
        }
        return entries
    }
    public func metadata(_ path: RemoteFilePath, expected: SessionLease) async throws -> RemoteFileEntry {
        try check(expected,path); try await allow(.read,source:path); try check(expected,path)
        if path != root { try await resolvedCheck(path,parent:true,expected:expected) }
        let entry = try await backend.metadata(path); try check(expected,path)
        try validate(entry)
        guard entry.path == path else { throw RemoteFileError.malformedResponse }; return entry
    }
    public func read(_ path: RemoteFilePath, offset: UInt64, maximumBytes: Int = 65536, expected: SessionLease) async throws -> Data {
        try check(expected,path)
        guard capabilities.contains(.read), offset == 0 || capabilities.contains(.resumeRead) else { throw RemoteFileError.unsupported }
        guard (1...1024*1024).contains(maximumBytes) else { throw RemoteFileError.limit }
        try await allow(.read,source:path); try check(expected,path)
        try await resolvedCheck(path,expected:expected)
        let bytes = try await backend.read(path,offset:offset,maximumBytes:maximumBytes); try check(expected,path)
        guard bytes.count <= maximumBytes else { throw RemoteFileError.limit }; return bytes
    }
    public func write(_ path: RemoteFilePath, offset: UInt64, bytes: Data, createExclusive: Bool, expected: SessionLease) async throws {
        try check(expected,path)
        guard capabilities.contains(.write), offset == 0 || capabilities.contains(.resumeWrite) else { throw RemoteFileError.unsupported }
        guard bytes.count <= 1024*1024 else { throw RemoteFileError.limit }
        try await allow(.upload,destination:path); try check(expected,path)
        try await resolvedCheck(path,parent:true,expected:expected)
        if !createExclusive { try await resolvedCheck(path,expected:expected) }
        try await backend.write(path,offset:offset,bytes:bytes,createExclusive:createExclusive); try mutationCompleted(expected)
    }
    public func createDirectory(_ path: RemoteFilePath, expected: SessionLease) async throws {
        try check(expected,path); guard path != root, capabilities.contains(.createDirectory) else { throw RemoteFileError.unsupported }
        try await allow(.createDirectory,destination:path); try check(expected,path)
        try await resolvedCheck(path,parent:true,expected:expected)
        try await backend.createDirectory(path); try mutationCompleted(expected)
    }
    public func rename(_ path: RemoteFilePath, to destination: RemoteFilePath, replace: Bool, expected: SessionLease) async throws {
        try check(expected,path,destination)
        guard path != root, destination != root, capabilities.contains(.rename), !replace || capabilities.contains(.atomicRename) else { throw RemoteFileError.unsupported }
        try await allow(.rename,source:path,destination:destination); try check(expected,path,destination)
        try await resolvedCheck(path,parent:true,expected:expected)
        try await resolvedCheck(destination,parent:true,expected:expected)
        try await backend.rename(path,to:destination,replace:replace); try mutationCompleted(expected)
    }
    public func delete(_ path: RemoteFilePath, directory: Bool, expected: SessionLease) async throws {
        try check(expected,path); guard path != root, capabilities.contains(.delete) else { throw RemoteFileError.unsupported }
        try await allow(.delete,source:path); try check(expected,path)
        try await resolvedCheck(path,parent:true,expected:expected)
        try await backend.delete(path,directory:directory); try mutationCompleted(expected)
    }
    public func followLink(_ path: RemoteFilePath, expected: SessionLease) async throws -> RemoteFilePath {
        try check(expected,path); guard capabilities.contains(.resolveLink) else { throw RemoteFileError.unsupported }
        try await allow(.read,source:path); try check(expected,path)
        let resolved = try await backend.resolve(path); try check(expected,resolved); return resolved
    }
    public func close() async { guard !closed else { return }; closed = true; await backend.close() }
}
