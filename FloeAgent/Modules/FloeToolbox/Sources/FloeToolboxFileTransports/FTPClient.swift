import Foundation
@preconcurrency import Network
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxRemoteFiles

private final class FTPStartTLS: NWProtocolFramerImplementation {
    static let label = "Floe FTP explicit TLS"
    static let definition = NWProtocolFramer.Definition(implementation:FTPStartTLS.self)
    private var buffer = Data(), stage = 0, multiline: Int?
    private let tls: NWProtocolOptions?
    required init(framer: NWProtocolFramer.Instance) { tls = framer.options["tls"] as? NWProtocolOptions }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { return .willMarkReady }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if stage == 2 { framer.passThroughInput(); return 0 }
        while stage < 2 {
            var line: Data?
            let parsed = framer.parseInput(minimumIncompleteLength:1,maximumLength:65536) { bytes,_ in
                guard let bytes, !bytes.isEmpty else { return 0 }
                let values = bytes.bindMemory(to:UInt8.self)
                for index in values.indices { if values[index] == 10 { line = Data(values[0...index]); return index+1 } }
                if buffer.count+values.count <= 65536 { buffer.append(contentsOf:values); return values.count }
                framer.markFailed(error:.posix(.EMSGSIZE)); return values.count
            }
            guard parsed, let line else { return 1 }
            buffer += line
            guard buffer.count <= 65536, let text = String(data:buffer,encoding:.utf8), text.hasSuffix("\r\n") else { framer.markFailed(error:.posix(.EPROTO)); return 0 }
            buffer.removeAll(); let digits = text.utf8.prefix(3)
            guard digits.count == 3, digits.allSatisfy({(48...57).contains($0)}), let code = Int(String(decoding:digits,as:UTF8.self)), text.utf8.count >= 5 else { framer.markFailed(error:.posix(.EPROTO)); return 0 }
            let separator = Array(text.utf8)[3]
            if multiline == nil, separator == 45 { multiline = code; continue }
            if let multiline { if code != multiline || separator != 32 { continue }; self.multiline = nil }
            guard separator == 32, code == (stage == 0 ? 220 : 234) else { framer.markFailed(error:.posix(.EPROTO)); return 0 }
            if stage == 0 { stage = 1; framer.writeOutput(data:Data("AUTH TLS\r\n".utf8)) }
            else {
                guard let tls else { framer.markFailed(error:.posix(.EINVAL)); return 0 }
                do { try framer.prependApplicationProtocol(options:tls); stage = 2; framer.markReady(); framer.passThroughInput(); framer.passThroughOutput() }
                catch { framer.markFailed(error:.posix(.EPROTO)) }
            }
        }
        return 0
    }
    func handleOutput(framer: NWProtocolFramer.Instance,message: NWProtocolFramer.Message,messageLength: Int,isComplete: Bool) {
        guard stage == 2 else { framer.markFailed(error:.posix(.EPROTO)); return }
        do { try framer.writeOutputNoCopy(length:messageLength) } catch { framer.markFailed(error:.posix(.EIO)) }
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) { buffer.removeAll() }
}
public struct FTPTransferReceipt: Sendable { public let path: RemoteFilePath; public let bytes: UInt64 }
/// Native passive FTP/FTPS. Data sockets remain bound to the authorized server host, never
/// a PASV-advertised third-party address. Credentials never enter capture or diagnostics.
public actor FTPClient {
    private struct Reply { let code: Int; let lines: [String] }
    public nonisolated let lease: SessionLease
    private let plan: RemoteFileConnectionPlan
    private let machine: MachineReference
    private let authorize: RemoteFileAuthorizer
    private let control: NetworkSerialConnection
    private let tls: ClientTLSConfiguration?
    private var buffer = Data(), closed = false, busy = false
    private var dataConnection: NetworkSerialConnection?
    private init(lease: SessionLease,plan: RemoteFileConnectionPlan,machine: MachineReference,authorize: @escaping RemoteFileAuthorizer,
                 control: NetworkSerialConnection,tls: ClientTLSConfiguration?) {
        self.lease = lease; self.plan = plan; self.machine = machine; self.authorize = authorize; self.control = control; self.tls = tls
    }
    public static func connect(lease: SessionLease,plan: RemoteFileConnectionPlan,machine: MachineReference,password: String,
                               tls: ClientTLSConfiguration? = nil,authorize: @escaping RemoteFileAuthorizer) async throws -> FTPClient {
        guard [.ftp,.ftps].contains(plan.transport), password.utf8.count <= 4096,
              !password.utf8.contains(where:{ [0,10,13].contains($0) }) else { throw RemoteFileError.authenticationFailed }
        guard try await authorize(RemoteFileAuthorizationRequest(lease:lease,machine:machine,effect:.list,source:plan.root)) else { throw RemoteFileError.denied }
        let security: ClientTLSConfiguration? = plan.transport == .ftps ? try tls ?? ClientTLSConfiguration() : nil
        var protocols: [NWProtocolOptions] = []
        if plan.transport == .ftps, plan.ftpsMode == .explicit {
            let options = NWProtocolFramer.Options(definition:FTPStartTLS.definition); options["tls"] = try security?.options(serverName:plan.host); protocols = [options]
        }
        let connection = try await NetworkSerialConnection.connect(host:plan.host,port:plan.port,
            tls:plan.transport == .ftps && plan.ftpsMode == .implicit ? security : nil,readTimeout:30,applicationProtocols:protocols)
        let client = FTPClient(lease:lease,plan:plan,machine:machine,authorize:authorize,control:connection,tls:security)
        do { try await client.login(password:password); return client } catch { await client.close(); throw error }
    }
    private func check() throws { guard !closed, !Task.isCancelled else { throw RemoteFileError.staleSession } }
    private func reply() async throws -> Reply {
        var lines: [String] = [], firstCode: Int?, multiline = false, total = 0
        while lines.count < 128 {
            while buffer.range(of:Data([13,10])) == nil {
                let bytes = try await control.receive(maximumBytes:8192); try check()
                guard !bytes.isEmpty, buffer.count+bytes.count <= 65536 else { throw RemoteFileError.limit }; buffer += bytes
            }
            guard let end = buffer.range(of:Data([13,10])) else { throw RemoteFileError.malformedResponse }
            let raw = Data(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound); total += raw.count
            guard total <= 65536, let line = String(data:raw,encoding:.utf8), raw.count >= 4 else { throw RemoteFileError.malformedResponse }
            lines.append(line)
            let digits = raw.prefix(3), code = Int(String(decoding:digits,as:UTF8.self))
            if firstCode == nil { guard let code, digits.allSatisfy({(48...57).contains($0)}), raw[raw.startIndex+3] == 32 || raw[raw.startIndex+3] == 45 else { throw RemoteFileError.malformedResponse }; firstCode = code; multiline = raw[raw.startIndex+3] == 45 }
            if !multiline || code == firstCode && raw[raw.startIndex+3] == 32 { return Reply(code:firstCode ?? 0,lines:lines) }
        }
        throw RemoteFileError.limit
    }
    private func command(_ verb: String,_ argument: String? = nil,expect: Set<Int>) async throws -> Reply {
        try check(); let text = verb+(argument.map { " "+$0 } ?? "")
        guard text.utf8.count <= 32768, !text.utf8.contains(where:{ [0,10,13].contains($0) }) else { throw RemoteFileError.invalidPath }
        try await control.send(Data((text+"\r\n").utf8)); let value = try await reply()
        guard expect.contains(value.code) else { if value.code == 550 { throw RemoteFileError.notFound }; if value.code == 530 { throw RemoteFileError.authenticationFailed }; throw RemoteFileError.serverStatus(UInt32(value.code)) }; return value
    }
    private func login(password: String) async throws {
        if plan.transport != .ftps || plan.ftpsMode != .explicit { let greeting = try await reply(); guard greeting.code == 220 else { throw RemoteFileError.authenticationFailed } }
        let user = try await command("USER",plan.username.isEmpty ? "anonymous" : plan.username,expect:[230,331])
        if user.code == 331 { _ = try await command("PASS",password,expect:[230]) }
        if plan.transport == .ftps { _ = try await command("PBSZ","0",expect:[200]); _ = try await command("PROT","P",expect:[200]) }
        _ = try await command("TYPE","I",expect:[200])
    }
    private func permit(_ path: RemoteFilePath,_ effect: RemoteFileEffect) async throws {
        try check(); guard path.isWithin(plan.root), !path.value.utf8.contains(where:{[0,10,13].contains($0)}) else { throw RemoteFileError.outsideRoot }
        guard try await authorize(RemoteFileAuthorizationRequest(lease:lease,machine:machine,effect:effect,source:effect == .read || effect == .list ? path : nil,destination:effect == .upload ? path : nil)) else { throw RemoteFileError.denied }; try check()
    }
    private func passive() async throws -> NetworkSerialConnection {
        let port: UInt16
        do {
            let response = try await command("EPSV",expect:[229]), line = response.lines.last ?? ""
            guard let a = line.firstIndex(of:"("), let b = line[a...].firstIndex(of:")") else { throw RemoteFileError.malformedResponse }
            let value = Array(line[line.index(after:a)..<b].utf8)
            guard value.count >= 5, value[0] == value[1], value[1] == value[2], value.last == value.first,
                  let parsed = UInt16(String(decoding:value.dropFirst(3).dropLast(),as:UTF8.self)), parsed != 0 else { throw RemoteFileError.malformedResponse }; port = parsed
        } catch RemoteFileError.serverStatus(let code) where [500,502,522].contains(code) {
            let value = try await command("PASV",expect:[227]), line = value.lines.last ?? ""
            guard let a = line.firstIndex(of:"("), let b = line[a...].firstIndex(of:")") else { throw RemoteFileError.malformedResponse }
            let values = line[line.index(after:a)..<b].split(separator:",").compactMap { UInt16($0.trimmingCharacters(in:.whitespaces)) }
            guard values.count == 6, values.allSatisfy({$0 <= 255}), values[4]*256+values[5] != 0 else { throw RemoteFileError.malformedResponse }; port = values[4]*256+values[5]
        }
        let connection = try await NetworkSerialConnection.connect(host:plan.host,port:port,tls:tls,readTimeout:30)
        dataConnection = connection; return connection
    }
    private func download(_ command: String,path: RemoteFilePath,offset: UInt64,maximum: UInt64,writer: RemoteFileChunkWriter) async throws -> UInt64 {
        let data = try await passive()
        if offset > 0 { _ = try await self.command("REST",String(offset),expect:[350]) }
        _ = try await self.command(command,path.value,expect:[125,150]); var received: UInt64 = 0
        do {
            while true {
                let chunk: Data
                do { chunk = try await data.receive(maximumBytes:65536) } catch ClientError.closed { break }
                try check(); guard !chunk.isEmpty, UInt64(chunk.count) <= maximum-received else { throw RemoteFileError.limit }
                try await writer(offset+received,chunk); try check(); received += UInt64(chunk.count)
            }
            await data.close(); dataConnection = nil; let completion = try await reply(); guard completion.code == 226 || completion.code == 250 else { throw RemoteFileError.serverStatus(UInt32(completion.code)) }; return received
        } catch { await data.close(); await close(); throw error }
    }
    public func download(path: RemoteFilePath,offset: UInt64 = 0,maximumBytes: UInt64 = 32*1024*1024*1024,
                         writer: @escaping RemoteFileChunkWriter) async throws -> FTPTransferReceipt {
        guard !busy, maximumBytes > 0, maximumBytes <= 1024*1024*1024*1024, offset <= 1024*1024*1024*1024 else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        try await permit(path,.read); let count = try await download("RETR",path:path,offset:offset,maximum:maximumBytes,writer:writer)
        return FTPTransferReceipt(path:path,bytes:count)
    }
    public func list(_ path: RemoteFilePath) async throws -> [RemoteFileEntry] {
        guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        try await permit(path,.list); let collector = FTPListingCollector()
        _ = try await download("MLSD",path:path,offset:0,maximum:8*1024*1024,writer:{ _,bytes in try await collector.append(bytes) })
        return try await collector.entries(path)
    }
    /// Explicit write operation. The host uses a unique .part path for staging; FTP provides
    /// neither exclusive-create nor compare-and-swap, so generic atomic copy is not advertised.
    public func upload(path: RemoteFilePath,size: UInt64,reader: @escaping RemoteFileChunkReader) async throws -> FTPTransferReceipt {
        guard !busy, size <= 1024*1024*1024*1024 else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        try await permit(path,.upload); let data = try await passive()
        do {
            _ = try await command("STOR",path.value,expect:[125,150]); var sent: UInt64 = 0
            while sent < size { try check(); let amount = Int(min(UInt64(65536),size-sent)), chunk = try await reader(sent,amount); guard !chunk.isEmpty, chunk.count <= amount else { throw RemoteFileError.limit }; try check(); try await data.send(chunk); sent += UInt64(chunk.count) }
            guard try await reader(size,1).isEmpty else { throw RemoteFileError.conflict }
            await data.close(); dataConnection = nil; let completion = try await reply(); guard completion.code == 226 || completion.code == 250 else { throw RemoteFileError.serverStatus(UInt32(completion.code)) }; return FTPTransferReceipt(path:path,bytes:sent)
        } catch { await data.close(); await close(); throw error }
    }
    public func createDirectory(_ path: RemoteFilePath) async throws { guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }; try await permit(path,.createDirectory); _ = try await command("MKD",path.value,expect:[257]) }
    public func delete(_ path: RemoteFilePath,directory: Bool) async throws { guard !busy, path != plan.root else { throw RemoteFileError.busy }; busy = true; defer { busy = false }; try await permit(path,.delete); _ = try await command(directory ? "RMD" : "DELE",path.value,expect:[250]) }
    public func close() async { closed = true; await dataConnection?.close(); dataConnection = nil; await control.close(); buffer.removeAll() }
}
private actor FTPListingCollector {
    var bytes = Data()
    func append(_ data: Data) throws { guard bytes.count+data.count <= 8*1024*1024 else { throw RemoteFileError.limit }; bytes += data }
    func entries(_ path: RemoteFilePath) throws -> [RemoteFileEntry] {
        guard let text = String(data:bytes,encoding:.utf8) else { throw RemoteFileError.malformedResponse }
        let lines = text.components(separatedBy:"\r\n").filter { !$0.isEmpty }; guard lines.count <= 10000 else { throw RemoteFileError.limit }
        var entries: [RemoteFileEntry] = [], names: Set<String> = []
        for line in lines {
            guard let split = line.firstIndex(of:" ") else { throw RemoteFileError.malformedResponse }
            let name = String(line[line.index(after:split)...]), facts = line[..<split].split(separator:";")
            var fields: [String:String] = [:]
            for fact in facts { let value = fact.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false); guard value.count == 2 else { throw RemoteFileError.malformedResponse }; fields[String(value[0]).lowercased()] = String(value[1]) }
            if ["cdir","pdir"].contains(fields["type"]) { continue }
            let kind: RemoteFileKind = fields["type"] == "dir" ? .directory : fields["type"] == "file" ? .file : .unknown
            let entryPath = try path.appending(name); guard names.insert(name).inserted else { throw RemoteFileError.malformedResponse }
            entries.append(RemoteFileEntry(path:entryPath,kind:kind,revision:RemoteFileRevision(byteCount:fields["size"].flatMap(UInt64.init))))
        }
        return entries
    }
}
