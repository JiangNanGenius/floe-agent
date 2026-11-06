import Foundation

/// A dedicated, already authenticated SSH `sftp` subsystem. Closing it must unblock receive.
/// The host owns SSH authentication, host-key decisions, credentials and timeout policy.
public protocol RemoteFileByteChannel: Sendable {
    func send(_ bytes: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data
    func close() async
}

private struct SFTPReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count-offset }
    mutating func uint(_ count: Int) throws -> UInt64 {
        guard count <= remaining else { throw RemoteFileError.malformedResponse }
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 8 | UInt64(bytes[offset]); offset += 1 }
        return value
    }
    mutating func data(maximum: Int = 32768) throws -> Data {
        let count = try uint(4)
        guard count <= UInt64(maximum), count <= UInt64(remaining) else { throw RemoteFileError.malformedResponse }
        let end = offset+Int(count); defer { offset = end }
        return Data(bytes[offset..<end])
    }
    mutating func text() throws -> String {
        guard let value = String(data:try data(),encoding:.utf8), !value.contains("\0") else { throw RemoteFileError.malformedResponse }
        return value
    }
    mutating func attributes() throws -> (RemoteFileKind, RemoteFileRevision, UInt32?) {
        let flags = try uint(4)
        guard flags & ~UInt64(0x8000000f) == 0 else { throw RemoteFileError.malformedResponse }
        var size: UInt64?, modified: Date?, permissions: UInt32?
        if flags & 1 != 0 { size = try uint(8) }
        if flags & 2 != 0 { _ = try uint(8) }
        if flags & 4 != 0 { permissions = UInt32(try uint(4)) }
        if flags & 8 != 0 { _ = try uint(4); modified = Date(timeIntervalSince1970:Double(try uint(4))) }
        if flags & 0x80000000 != 0 {
            let count = try uint(4); guard count <= 256 else { throw RemoteFileError.limit }
            for _ in 0..<count { _ = try data(); _ = try data() }
        }
        let kind: RemoteFileKind
        switch (permissions ?? 0) & 0xf000 {
        case 0x8000: kind = .file
        case 0x4000: kind = .directory
        case 0xa000: kind = .symbolicLink
        default: kind = .unknown
        }
        return (kind,RemoteFileRevision(byteCount:size,modifiedAt:modified),permissions)
    }
    func finished() throws { guard remaining == 0 else { throw RemoteFileError.malformedResponse } }
}
private extension Data {
    mutating func sftpUInt(_ value: UInt64, count: Int = 4) {
        for index in (0..<count).reversed() { append(UInt8(truncatingIfNeeded:value >> (index*8))) }
    }
    mutating func sftpString(_ data: Data) { sftpUInt(UInt64(data.count)); append(data) }
    mutating func sftpText(_ string: String) { sftpString(Data(string.utf8)) }
}

/// One bounded request at a time; malformed framing/correlation fences the subsystem.
private actor SFTPTransport {
    private let channel: any RemoteFileByteChannel
    private var buffer = Data()
    private var nextID: UInt32 = 0
    private var busy = false
    private var closed = false
    init(_ channel: any RemoteFileByteChannel) { self.channel = channel }
    private func frame() async throws -> Data {
        while buffer.count < 4 { try await fill() }
        let length = buffer.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard (1...1024*1024).contains(length) else { throw RemoteFileError.limit }
        while buffer.count < Int(length)+4 { try await fill() }
        let result = Data(buffer[4..<Int(length)+4]); buffer = Data(buffer.dropFirst(Int(length)+4))
        return result
    }
    private func fill() async throws {
        guard !closed, !Task.isCancelled else { throw RemoteFileError.connectionClosed }
        let bytes = try await channel.receive(maximumBytes:65536)
        guard !closed, !Task.isCancelled else { throw RemoteFileError.connectionClosed }
        guard !bytes.isEmpty else { throw RemoteFileError.connectionClosed }
        guard bytes.count <= 65536, buffer.count+bytes.count <= 1024*1024+65536 else { throw RemoteFileError.limit }
        buffer.append(bytes)
    }
    private func sendFrame(_ payload: Data) async throws {
        guard !closed, !Task.isCancelled else { throw RemoteFileError.connectionClosed }
        var bytes = Data(); bytes.sftpUInt(UInt64(payload.count)); bytes.append(payload)
        try await channel.send(bytes)
    }
    func initialize() async throws -> Bool {
        guard !busy, !closed else { throw RemoteFileError.busy }
        busy = true; defer { busy = false }
        do {
            return try await withTaskCancellationHandler {
                var packet = Data([1]); packet.sftpUInt(3); try await sendFrame(packet)
                var response = SFTPReader(try await frame())
                guard try response.uint(1) == 2, try response.uint(4) == 3 else { throw RemoteFileError.unsupported }
                var posixRename = false, count = 0
                while response.remaining > 0 {
                    count += 1; guard count <= 128 else { throw RemoteFileError.limit }
                    let name = try response.text(), version = try response.text()
                    if name == "posix-rename@openssh.com", version == "1" { posixRename = true }
                }
                return posixRename
            } onCancel: { Task { await self.close() } }
        } catch { await close(); throw error }
    }
    func request(_ type: UInt8, payload: Data) async throws -> (UInt8, Data) {
        guard !busy, !closed, !Task.isCancelled else { throw RemoteFileError.connectionClosed }
        busy = true; defer { busy = false }
        do {
            return try await withTaskCancellationHandler {
                nextID &+= 1
                let id = nextID
                var packet = Data([type]); packet.sftpUInt(UInt64(id)); packet.append(payload)
                try await sendFrame(packet)
                var response = SFTPReader(try await frame())
                let responseType = UInt8(try response.uint(1))
                guard try response.uint(4) == UInt64(id), !closed, !Task.isCancelled else { throw RemoteFileError.malformedResponse }
                return (responseType,Data(response.bytes.dropFirst(response.offset)))
            } onCancel: { Task { await self.close() } }
        } catch { await close(); throw error }
    }
    func close() async { guard !closed else { return }; closed = true; buffer.removeAll(); await channel.close() }
}

/// SFTP v3 only. No SSH implementation, shell fallback, whole-file reads or automatic SCP fallback.
/// Directory handles close on success/failure; server status is checked for every mutation.
public actor SFTPRemoteFileBackend: RemoteFileBackend {
    public nonisolated let capabilities: Set<RemoteFileCapability>
    private let wire: SFTPTransport
    private var busy = false
    private var closed = false
    private init(wire: SFTPTransport, posixRename: Bool) {
        self.wire = wire
        var caps: Set<RemoteFileCapability> = [.list,.read,.write,.createDirectory,.rename,.delete,.resolveLink,.resumeRead,.resumeWrite]
        if posixRename { caps.insert(.atomicRename) }
        capabilities = caps
    }
    public static func connect(channel: any RemoteFileByteChannel) async throws -> SFTPRemoteFileBackend {
        let wire = SFTPTransport(channel)
        let posixRename = try await wire.initialize()
        return SFTPRemoteFileBackend(wire:wire,posixRename:posixRename)
    }
    private func begin() throws {
        guard !closed, !Task.isCancelled else { throw RemoteFileError.connectionClosed }
        guard !busy else { throw RemoteFileError.busy }; busy = true
    }
    private func pathPayload(_ path: RemoteFilePath) throws -> Data {
        _ = try path.validated(); var payload = Data(); payload.sftpText(path.value); return payload
    }
    private func status(_ type: UInt8, _ payload: Data, eofAllowed: Bool = false) throws -> Bool {
        guard type == 101 else { throw RemoteFileError.malformedResponse }
        var reader = SFTPReader(payload)
        let code = UInt32(try reader.uint(4)); _ = try reader.text(); _ = try reader.text(); try reader.finished()
        switch code {
        case 0: return true
        case 1 where eofAllowed: return false
        case 2: throw RemoteFileError.notFound
        case 3: throw RemoteFileError.denied
        case 8: throw RemoteFileError.unsupported
        default: throw RemoteFileError.serverStatus(code)
        }
    }
    private func handle(_ type: UInt8, _ payload: Data) throws -> Data {
        if type == 101 { _ = try status(type,payload); throw RemoteFileError.malformedResponse }
        guard type == 102 else { throw RemoteFileError.malformedResponse }
        var reader = SFTPReader(payload); let value = try reader.data(maximum:4096); try reader.finished()
        guard !value.isEmpty else { throw RemoteFileError.malformedResponse }; return value
    }
    private func closeHandle(_ handle: Data) async throws {
        var payload = Data(); payload.sftpString(handle)
        do {
            let (type,data) = try await wire.request(4,payload:payload); _ = try status(type,data)
        } catch { await wire.close(); throw error }
    }
    public func list(_ path: RemoteFilePath) async throws -> [RemoteFileEntry] {
        try begin(); defer { busy = false }
        let response = try await wire.request(11,payload:pathPayload(path))
        let handle = try handle(response.0,response.1)
        do {
            var entries: [RemoteFileEntry] = []
            var names: Set<RemoteFilePath> = []
            var metadataBytes = 0
            var payload = Data(); payload.sftpString(handle)
            for _ in 0..<1024 {
                let (type,data) = try await wire.request(12,payload:payload)
                if type == 101 {
                    guard try !status(type,data,eofAllowed:true) else { throw RemoteFileError.malformedResponse }
                    try await closeHandle(handle); return entries
                }
                guard type == 104 else { throw RemoteFileError.malformedResponse }
                var reader = SFTPReader(data); let count = try reader.uint(4)
                guard count <= UInt64(10000-entries.count) else { throw RemoteFileError.limit }
                for _ in 0..<count {
                    let name = try reader.text(); _ = try reader.text()
                    let (kind,revision,permissions) = try reader.attributes()
                    if name == "." || name == ".." { continue }
                    let child = try path.appending(name)
                    metadataBytes += child.value.utf8.count
                    guard metadataBytes <= 8*1024*1024 else { throw RemoteFileError.limit }
                    guard names.insert(child).inserted else { throw RemoteFileError.malformedResponse }
                    entries.append(RemoteFileEntry(path:child,kind:kind,revision:revision,permissions:permissions))
                }
                try reader.finished()
            }
            throw RemoteFileError.limit
        } catch { try? await closeHandle(handle); throw error }
    }
    public func metadata(_ path: RemoteFilePath) async throws -> RemoteFileEntry {
        try begin(); defer { busy = false }
        let (type,data) = try await wire.request(7,payload:pathPayload(path))
        if type == 101 { _ = try status(type,data); throw RemoteFileError.malformedResponse }
        guard type == 105 else { throw RemoteFileError.malformedResponse }
        var reader = SFTPReader(data); let (kind,revision,permissions) = try reader.attributes(); try reader.finished()
        return RemoteFileEntry(path:path,kind:kind,revision:revision,permissions:permissions)
    }
    public func read(_ path: RemoteFilePath, offset: UInt64, maximumBytes: Int) async throws -> Data {
        try begin(); defer { busy = false }
        guard (1...1024*1024).contains(maximumBytes) else { throw RemoteFileError.limit }
        var payload = try pathPayload(path); payload.sftpUInt(1); payload.sftpUInt(0)
        let response = try await wire.request(3,payload:payload); let handle = try handle(response.0,response.1)
        do {
            payload = Data(); payload.sftpString(handle); payload.sftpUInt(offset,count:8); payload.sftpUInt(UInt64(maximumBytes))
            let (type,data) = try await wire.request(5,payload:payload)
            let bytes: Data
            if type == 101 { guard try !status(type,data,eofAllowed:true) else { throw RemoteFileError.malformedResponse }; bytes = Data() }
            else {
                guard type == 103 else { throw RemoteFileError.malformedResponse }
                var reader = SFTPReader(data); bytes = try reader.data(maximum:maximumBytes); try reader.finished()
            }
            try await closeHandle(handle); return bytes
        } catch { try? await closeHandle(handle); throw error }
    }
    public func write(_ path: RemoteFilePath, offset: UInt64, bytes: Data, createExclusive: Bool) async throws {
        try begin(); defer { busy = false }
        guard bytes.count <= 1024*1024, !createExclusive || offset == 0 else { throw RemoteFileError.limit }
        var payload = try pathPayload(path); payload.sftpUInt(createExclusive ? 0x2a : 2); payload.sftpUInt(4); payload.sftpUInt(0o100600)
        let response = try await wire.request(3,payload:payload); let handle = try handle(response.0,response.1)
        do {
            payload = Data(); payload.sftpString(handle); payload.sftpUInt(offset,count:8); payload.sftpString(bytes)
            let (type,data) = try await wire.request(6,payload:payload); _ = try status(type,data)
            try await closeHandle(handle)
        } catch { try? await closeHandle(handle); throw error }
    }
    public func createDirectory(_ path: RemoteFilePath) async throws {
        try begin(); defer { busy = false }
        var payload = try pathPayload(path); payload.sftpUInt(4); payload.sftpUInt(0o40700)
        let (type,data) = try await wire.request(14,payload:payload); _ = try status(type,data)
    }
    public func rename(_ source: RemoteFilePath, to destination: RemoteFilePath, replace: Bool) async throws {
        try begin(); defer { busy = false }
        guard !replace || capabilities.contains(.atomicRename) else { throw RemoteFileError.unsupported }
        var payload = Data()
        if replace { payload.sftpText("posix-rename@openssh.com") }
        payload.append(try pathPayload(source)); payload.append(try pathPayload(destination))
        let (type,data) = try await wire.request(replace ? 200 : 18,payload:payload); _ = try status(type,data)
    }
    public func delete(_ path: RemoteFilePath, directory: Bool) async throws {
        try begin(); defer { busy = false }
        let (type,data) = try await wire.request(directory ? 15 : 13,payload:pathPayload(path)); _ = try status(type,data)
    }
    public func resolve(_ path: RemoteFilePath) async throws -> RemoteFilePath {
        try begin(); defer { busy = false }
        let (type,data) = try await wire.request(16,payload:pathPayload(path))
        if type == 101 { _ = try status(type,data); throw RemoteFileError.malformedResponse }
        guard type == 104 else { throw RemoteFileError.malformedResponse }
        var reader = SFTPReader(data)
        guard try reader.uint(4) == 1 else { throw RemoteFileError.malformedResponse }
        let resolved = try RemoteFilePath(reader.text()); _ = try reader.text(); _ = try reader.attributes(); try reader.finished()
        return resolved
    }
    public func close() async { guard !closed else { return }; closed = true; await wire.close() }
}
