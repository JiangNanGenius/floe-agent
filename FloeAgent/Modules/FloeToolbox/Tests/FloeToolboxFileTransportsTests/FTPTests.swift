import Foundation
import Darwin
import Testing
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxRemoteFiles
@testable import FloeToolboxFileTransports
#if os(macOS)
private final class FTPFixture: @unchecked Sendable {
    let root: URL; let port: UInt16; let process: Process; let output: FileHandle
    init(tls: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(repeating:42,count:180000).write(to:root.appendingPathComponent("source.bin"))
        let process = Process(), pipe = Pipe(), environment = ProcessInfo.processInfo.environment
        process.executableURL = URL(fileURLWithPath:try #require(environment["FLOE_TOOLBOX_FTP_PYTHON"]))
        process.arguments = [try #require(Bundle.module.url(forResource:"ftp_server",withExtension:"py",subdirectory:"Fixtures")).path,root.path,tls ? "tls" : "plain",environment["FLOE_TOOLBOX_FTP_CERT"] ?? "",environment["FLOE_TOOLBOX_FTP_KEY"] ?? ""]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        if let folder = environment["FLOE_TOOLBOX_FILE_FIXTURE_LOG_DIR"] {
            let url = URL(fileURLWithPath:folder).appendingPathComponent("ftp-"+UUID().uuidString+".log")
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])
            process.standardError = try FileHandle(forWritingTo:url)
        }
        try process.run(); var bytes = Data()
        while bytes.count < 4096 {
            var fd = pollfd(fd:pipe.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            guard poll(&fd,1,5000) > 0, let value = try pipe.fileHandleForReading.read(upToCount:1), !value.isEmpty else { process.terminate(); throw ClientError.timedOut }
            if value == Data([10]) { break }; bytes += value
        }
        port = try #require(JSONDecoder().decode([String:UInt16].self,from:bytes)["port"])
        self.process = process; output = pipe.fileHandleForReading
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close(); try? FileManager.default.removeItem(at:root) }
}
private actor ChunkCollector {
    var bytes = Data()
    func append(_ offset: UInt64,_ data: Data) throws { guard offset == bytes.count else { throw RemoteFileError.conflict }; bytes += data }
}
@Test(arguments:[false,true]) func FTPAndExplicitFTPSInteroperateWithIndependentServer(tls: Bool) async throws {
    let fixture = try FTPFixture(tls:tls); defer { fixture.stop() }
    let lease = SessionLease(ownerID:UUID()), machine = MachineReference.temporary(connectionID:UUID())
    let plan = try RemoteFileConnectionPlan(source:.temporary,transport:tls ? .ftps : .ftp,host:"127.0.0.1",port:fixture.port,root:RemoteFilePath("/"),username:"fixture")
    let certificate: ClientTLSConfiguration?
    if tls { certificate = try ClientTLSConfiguration(additionalRootCertificates:[Data(contentsOf:URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["FLOE_TOOLBOX_FTP_DER"])))] ) } else { certificate = nil }
    print("FTP fixture \(tls): connecting")
    let client = try await FTPClient.connect(lease:lease,plan:plan,machine:machine,password:"fixture-password",tls:certificate,authorize:{ _ in true })
    print("FTP fixture \(tls): listing")
    #expect(try await client.list(RemoteFilePath("/")).contains { $0.path.name == "source.bin" })
    print("FTP fixture \(tls): downloading")
    let downloaded = ChunkCollector()
    let receipt = try await client.download(path:RemoteFilePath("/source.bin"),writer:{ try await downloaded.append($0,$1) })
    #expect(receipt.bytes == 180000)
    #expect(await downloaded.bytes == Data(repeating:42,count:180000))
    print("FTP fixture \(tls): uploading")
    let upload = Data(repeating:9,count:190000)
    _ = try await client.upload(path:RemoteFilePath("/uploaded.bin"),size:UInt64(upload.count),reader:{ offset,maximum in Data(upload.dropFirst(Int(offset)).prefix(maximum)) })
    #expect(try Data(contentsOf:fixture.root.appendingPathComponent("uploaded.bin")) == upload)
    try await client.createDirectory(RemoteFilePath("/folder")); try await client.delete(RemoteFilePath("/folder"),directory:true)
    await client.close()
}
#endif
