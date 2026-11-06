import Foundation
import FloeToolboxCore
import FloeToolboxRemoteFiles

public struct SSHFileCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    /// Only the host's authenticated SSH exec channel may use this command. No local shell.
    public var quotedCommand: String { ([executable]+arguments).map { "'"+$0.replacingOccurrences(of:"'",with:"'\\''")+"'" }.joined(separator:" ") }
}
public typealias SSHFileChannelFactory = @Sendable (SessionLease,MachineReference,SSHFileCommand) async throws -> any RemoteFileByteChannel
public typealias RemoteFileChunkReader = @Sendable (UInt64,Int) async throws -> Data
public typealias RemoteFileChunkWriter = @Sendable (UInt64,Data) async throws -> Void
public typealias RemoteFileProgress = @Sendable (UInt64,UInt64?) async -> Void
public struct SCPTransferReceipt: Sendable { public let path: RemoteFilePath; public let bytes: UInt64 }

/// The SCP legacy wire protocol is deliberately transfer-only. SFTP remains the directory
/// browser. The host opens a dedicated authenticated SSH exec channel for each transfer.
public actor SCPTransferClient {
    public nonisolated let lease: SessionLease
    private let machine: MachineReference
    private let root: RemoteFilePath
    private let factory: SSHFileChannelFactory
    private let authorize: RemoteFileAuthorizer
    private var active: (any RemoteFileByteChannel)?
    private var busy = false, closed = false
    private var buffer = Data()
    public init(lease: SessionLease,machine: MachineReference,root: RemoteFilePath,
                factory: @escaping SSHFileChannelFactory,authorize: @escaping RemoteFileAuthorizer) throws {
        self.lease = lease; self.machine = machine; self.root = try root.validated(); self.factory = factory; self.authorize = authorize
    }
    private func permit(_ path: RemoteFilePath,effect: RemoteFileEffect) async throws {
        guard !closed, !Task.isCancelled, path.isWithin(root), path != root,
              !path.value.utf8.contains(where:{ $0 == 0 || $0 == 10 || $0 == 13 }), path.name.utf8.count <= 4096 else { throw RemoteFileError.invalidPath }
        guard try await authorize(RemoteFileAuthorizationRequest(lease:lease,machine:machine,effect:effect,
            source:effect == .read ? path : nil,destination:effect == .upload ? path : nil)) else { throw RemoteFileError.denied }
        try check()
    }
    private func check() throws { guard !closed, !Task.isCancelled else { throw RemoteFileError.staleSession } }
    private func exact(_ count: Int) async throws -> Data {
        guard (0...65536).contains(count), let active else { throw RemoteFileError.connectionClosed }
        while buffer.count < count {
            let bytes = try await active.receive(maximumBytes:65536)
            guard !bytes.isEmpty, bytes.count <= 65536, buffer.count+bytes.count <= 131072 else { throw RemoteFileError.limit }
            buffer += bytes; try check()
        }
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    private func line() async throws -> Data {
        var result = Data()
        while result.count <= 8192 { let byte = try await exact(1); if byte.first == 10 { return result }; result += byte }
        throw RemoteFileError.limit
    }
    private func acknowledge() async throws {
        let code = try await exact(1)
        guard code.first != 1, code.first != 2 else { _ = try await line(); throw RemoteFileError.serverStatus(UInt32(code.first ?? 2)) }
        guard code.first == 0 else { throw RemoteFileError.malformedResponse }
    }
    public func upload(path: RemoteFilePath,size: UInt64,reader: @escaping RemoteFileChunkReader,
                       progress: @escaping RemoteFileProgress = { _,_ in }) async throws -> SCPTransferReceipt {
        guard !busy, size <= 1024*1024*1024*1024 else { throw RemoteFileError.busy }; busy = true
        defer { busy = false; buffer.removeAll() }
        do {
            try await permit(path,effect:.upload)
            let channel = try await factory(lease,machine,SSHFileCommand(executable:"scp",arguments:["-t","--",path.value])); active = channel; try check()
            try await acknowledge()
            let header = "C0644 \(size) \(path.name)\n"
            try await channel.send(Data(header.utf8)); try await acknowledge()
            var sent: UInt64 = 0
            while sent < size {
                try check(); let amount = Int(min(UInt64(65536),size-sent)), chunk = try await reader(sent,amount)
                guard !chunk.isEmpty, chunk.count <= amount else { throw RemoteFileError.limit }; try check()
                try await channel.send(chunk); sent += UInt64(chunk.count); await progress(sent,size)
            }
            guard try await reader(size,1).isEmpty else { throw RemoteFileError.conflict }
            try await channel.send(Data([0])); try await acknowledge()
            await channel.close(); active = nil; try check(); return SCPTransferReceipt(path:path,bytes:sent)
        } catch { await active?.close(); active = nil; throw error }
    }
    public func download(path: RemoteFilePath,maximumBytes: UInt64 = 32*1024*1024*1024,
                         writer: @escaping RemoteFileChunkWriter,progress: @escaping RemoteFileProgress = { _,_ in }) async throws -> SCPTransferReceipt {
        guard !busy, maximumBytes > 0, maximumBytes <= 1024*1024*1024*1024 else { throw RemoteFileError.busy }; busy = true
        defer { busy = false; buffer.removeAll() }
        do {
            try await permit(path,effect:.read)
            let channel = try await factory(lease,machine,SSHFileCommand(executable:"scp",arguments:["-f","--",path.value])); active = channel; try check()
            try await channel.send(Data([0]))
            let header = try await line()
            guard header.first == 67, let text = String(data:header.dropFirst(),encoding:.utf8) else { throw RemoteFileError.malformedResponse }
            let fields = text.split(separator:" ",maxSplits:2,omittingEmptySubsequences:false)
            guard fields.count == 3, fields[0].utf8.count == 4, fields[0].utf8.allSatisfy({ (48...55).contains($0) }),
                  !fields[1].isEmpty, fields[1].utf8.allSatisfy({(48...57).contains($0)}), let size = UInt64(fields[1]), size <= maximumBytes,
                  fields[2] == Substring(path.name) else { throw RemoteFileError.malformedResponse }
            // A server-supplied filename never changes the destination selected by the host.
            try await channel.send(Data([0])); var received: UInt64 = 0
            while received < size {
                try check(); let chunk = try await exact(Int(min(UInt64(65536),size-received)))
                try await writer(received,chunk); try check(); received += UInt64(chunk.count); await progress(received,size)
            }
            try await acknowledge(); try await channel.send(Data([0])); await channel.close(); active = nil
            try check(); return SCPTransferReceipt(path:path,bytes:received)
        } catch { await active?.close(); active = nil; throw error }
    }
    public func close() async { closed = true; await active?.close(); active = nil; buffer.removeAll() }
}
