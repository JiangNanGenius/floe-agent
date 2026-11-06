import Foundation
import FloeWorkspace
import FloeToolboxRemoteFiles
import FloeToolboxFileTransports

/// Reads an already resolved mount, including a host File Provider SMB mount. It never creates
/// a connection/credential store or unmounts a share owned by another feature. The legacy
/// SMBClient-backed registry still needs its host framing/aggregation fixes before activation;
/// post-return bounds here cannot bound allocations inside that upstream adapter.
public actor ToolboxWorkspaceMountBridge {
    private let adapter: any WorkspaceMountAdapter
    private let relativeRoot: RemoteFilePath
    private var listing: (RemoteFilePath,[RemoteFileEntry])?
    private var closed = false
    public init(adapter: any WorkspaceMountAdapter,relativeRoot: String = "/") throws {
        self.adapter = adapter; self.relativeRoot = try RemoteFilePath(relativeRoot)
    }
    private func hostPath(_ path: RemoteFilePath) throws -> String {
        guard !closed else { throw RemoteFileError.staleSession }; _ = try path.validated()
        let suffix = path.value == "/" ? "" : String(path.value.dropFirst())
        return relativeRoot.value == "/" ? suffix : String(relativeRoot.value.dropFirst())+(suffix.isEmpty ? "" : "/"+suffix)
    }
    private func entry(path: RemoteFilePath,isDirectory: Bool,size: Int64,date: Date?,tag: String?) throws -> RemoteFileEntry {
        guard size >= 0 || isDirectory,(tag?.utf8.count ?? 0) <= 8192 else { throw RemoteFileError.malformedResponse }
        return RemoteFileEntry(path:path,kind:isDirectory ? .directory : .file,
                               revision:RemoteFileRevision(entityTag:tag,byteCount:size >= 0 ? UInt64(size) : nil,modifiedAt:date))
    }
    private func page(_ path: RemoteFilePath,cursor: String?,maximum: Int) async throws -> HostMountPage {
        let host = try hostPath(path)
        let start: Int
        if let cursor { guard let offset = Int(cursor),offset > 0,listing?.0 == path else { throw RemoteFileError.malformedResponse }; start = offset }
        else {
            let values = try await adapter.list(path:host); _ = try hostPath(path)
            guard values.count <= 10000 else { throw RemoteFileError.limit }
            var entries: [RemoteFileEntry] = [],total = 0
            for value in values {
                let child = try path.appending(value.name); total += child.value.utf8.count+(value.entityTag?.utf8.count ?? 0)
                guard total <= 8*1024*1024 else { throw RemoteFileError.limit }
                entries.append(try entry(path:child,isDirectory:value.isDirectory,size:value.byteCount,date:value.modifiedAt,tag:value.entityTag))
            }
            listing = (path,entries); start = 0
        }
        guard let values = listing?.1,start <= values.count,(1...256).contains(maximum) else { throw RemoteFileError.malformedResponse }
        let end = min(start+maximum,values.count), result = Array(values[start..<end])
        if end == values.count { listing = nil }
        return HostMountPage(entries:result,nextCursor:end < values.count ? String(end) : nil)
    }
    private func metadata(_ path: RemoteFilePath) async throws -> RemoteFileEntry {
        let value = try await adapter.metadata(path:hostPath(path)); _ = try hostPath(path)
        return try entry(path:path,isDirectory:value.isDirectory,size:value.byteCount,date:value.modifiedAt,tag:value.entityTag)
    }
    private func read(_ path: RemoteFilePath,offset: UInt64,maximum: Int) async throws -> Data {
        guard offset <= UInt64(Int.max),(1...1024*1024).contains(maximum) else { throw RemoteFileError.limit }
        let data = try await adapter.read(path:hostPath(path),offset:Int(offset),limit:maximum); _ = try hostPath(path)
        guard data.count <= maximum else { throw RemoteFileError.limit }; return data
    }
    private func close() { closed = true; listing = nil }
    public nonisolated func backend(windowsNames: Bool = false) throws -> HostMountFileBackend {
        try HostMountFileBackend(root:RemoteFilePath("/"),windowsNames:windowsNames,io:HostMountFileIO(
            page:{ path,cursor,maximum in try await self.page(path,cursor:cursor,maximum:maximum) },
            metadata:{ try await self.metadata($0) },read:{ path,offset,maximum in try await self.read(path,offset:offset,maximum:maximum) },
            releaseLease:{ await self.close() }))
    }
}
