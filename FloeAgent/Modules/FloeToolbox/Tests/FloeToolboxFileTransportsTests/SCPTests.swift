import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxRemoteFiles
@testable import FloeToolboxFileTransports
#if os(macOS)
import Darwin
private actor LocalSCPFixture: RemoteFileByteChannel {
    let process: Process; let input: FileHandle; let output: FileHandle
    var closed = false
    init(_ command: SSHFileCommand) throws {
        guard command.executable == "scp", command.arguments.count == 3, ["-f","-t"].contains(command.arguments[0]), command.arguments[1] == "--" else { throw RemoteFileError.denied }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/scp"); process.arguments = command.arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    func send(_ data: Data) throws { guard !closed else { throw RemoteFileError.connectionClosed }; try input.write(contentsOf:data) }
    func receive(maximumBytes: Int) async throws -> Data {
        let descriptor = output.fileDescriptor
        return try await Task.detached {
            var ready = pollfd(fd:descriptor,events:Int16(POLLIN),revents:0)
            guard poll(&ready,1,3000) > 0 else { throw RemoteFileError.connectionClosed }
            var bytes = [UInt8](repeating:0,count:maximumBytes); let count = read(descriptor,&bytes,bytes.count)
            guard count >= 0 else { throw RemoteFileError.connectionClosed }; return Data(bytes.prefix(count))
        }.value
    }
    func close() { guard !closed else { return }; closed = true; try? input.close(); if process.isRunning { process.terminate() }; process.waitUntilExit(); try? output.close() }
}
private actor DownloadBuffer { var bytes = Data(); func append(_ offset: UInt64,_ data: Data) throws { guard offset == bytes.count else { throw RemoteFileError.conflict }; bytes += data } }
@Test func scpWireInteroperatesWithOpenSSHForUploadAndDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), machine = MachineReference.temporary(connectionID:UUID()), path = try RemoteFilePath(root.appendingPathComponent("space name.bin").path)
    let client = try SCPTransferClient(lease:lease,machine:machine,root:RemoteFilePath(root.path),factory:{ _,_,command in try LocalSCPFixture(command) },authorize:{ _ in true })
    let bytes = Data(repeating:77,count:200000)
    let upload = try await client.upload(path:path,size:UInt64(bytes.count),reader:{ offset,maximum in Data(bytes.dropFirst(Int(offset)).prefix(maximum)) })
    #expect(upload.bytes == bytes.count)
    #expect(try Data(contentsOf:URL(fileURLWithPath:path.value)) == bytes)
    let destination = DownloadBuffer()
    let downloaded = try await client.download(path:path,writer:{ try await destination.append($0,$1) })
    #expect(downloaded.bytes == bytes.count)
    #expect(await destination.bytes == bytes)
    await client.close()
}
#endif
private actor BadSCPServer: RemoteFileByteChannel {
    var bytes = Data("C0644 3 ../../evil\nabc\0".utf8)
    func send(_ bytes: Data) {}
    func receive(maximumBytes: Int) -> Data { let result = Data(bytes.prefix(maximumBytes)); bytes.removeFirst(result.count); return result }
    func close() {}
}
@Test func SCPServerCannotChangeTheRequestedDownloadName() async throws {
    let client = try SCPTransferClient(lease:SessionLease(ownerID:UUID()),machine:.temporary(connectionID:UUID()),root:RemoteFilePath("/safe"),factory:{ _,_,_ in BadSCPServer() },authorize:{ _ in true })
    await #expect(throws:RemoteFileError.malformedResponse) { try await client.download(path:RemoteFilePath("/safe/file.bin"),writer:{ _,_ in Issue.record("untrusted destination reached writer") }) }
    await client.close()
}
