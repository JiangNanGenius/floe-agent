import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxRemoteFiles
@testable import FloeToolboxFileTransports
#if os(macOS)
import Darwin
private final class WebDAVFixture: @unchecked Sendable {
    let root: URL; let process: Process; let port: UInt16; let output: FileHandle
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(repeating:66,count:180000).write(to:root.appendingPathComponent("source.bin"))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["FLOE_TOOLBOX_FTP_PYTHON"]))
        process.arguments = [try #require(Bundle.module.url(forResource:"webdav_server",withExtension:"py",subdirectory:"Fixtures")).path,root.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        if let folder = ProcessInfo.processInfo.environment["FLOE_TOOLBOX_FILE_FIXTURE_LOG_DIR"] {
            let url = URL(fileURLWithPath:folder).appendingPathComponent("dav-"+UUID().uuidString+".log")
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]); process.standardError = try FileHandle(forWritingTo:url)
        }
        try process.run(); var bytes = Data()
        while bytes.count < 16384 {
            var descriptor = pollfd(fd:pipe.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            guard poll(&descriptor,1,5000) > 0, let byte = try pipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty else { process.terminate(); throw ClientError.timedOut }
            if byte == Data([10]) { if bytes.first == 123 { break }; bytes.removeAll() } else { bytes += byte }
        }
        port = try #require(JSONDecoder().decode([String:UInt16].self,from:bytes)["port"])
        self.process = process; output = pipe.fileHandleForReading
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close(); try? FileManager.default.removeItem(at:root) }
}
@Test func WebDAVInteroperatesWithWsgiDAVRangesConditionalUploadAndRename() async throws {
    let fixture = try WebDAVFixture(); defer { fixture.stop() }
    let backend = try WebDAVRemoteFileBackend(baseURL:try #require(URL(string:"http://127.0.0.1:\(fixture.port)/")))
    let path = try RemoteFilePath("/source.bin")
    print("DAV fixture: list")
    #expect(try await backend.list(RemoteFilePath("/")).contains { $0.path == path })
    print("DAV fixture: metadata")
    let original = try await backend.metadata(path)
    #expect(original.revision.byteCount == 180000 && original.revision.entityTag != nil)
    print("DAV fixture: ranges")
    #expect(try await backend.read(path,offset:123,maximumBytes:4096) == Data(repeating:66,count:4096))
    #expect(try await backend.read(path,offset:180000,maximumBytes:4096).isEmpty)
    let staged = fixture.root.appendingPathComponent("local-upload.bin")
    try Data(repeating:44,count:200000).write(to:staged)
    print("DAV fixture: upload")
    try await backend.uploadFile(staged,to:RemoteFilePath("/remote-upload.bin"))
    #expect(try Data(contentsOf:fixture.root.appendingPathComponent("remote-upload.bin")) == Data(repeating:44,count:200000))
    await #expect(throws:RemoteFileError.conflict) { try await backend.uploadFile(staged,to:RemoteFilePath("/remote-upload.bin")) }
    try await backend.rename(RemoteFilePath("/remote-upload.bin"),to:RemoteFilePath("/renamed.bin"),replace:false)
    try await backend.createDirectory(RemoteFilePath("/folder")); try await backend.delete(RemoteFilePath("/folder"),directory:true)
    try Data([1]).write(to:fixture.root.appendingPathComponent("source.bin"))
    await #expect(throws:RemoteFileError.conflict) { try await backend.uploadFile(staged,to:path,expectedETag:original.revision.entityTag,createExclusive:false) }
    await backend.close()
}
#endif
