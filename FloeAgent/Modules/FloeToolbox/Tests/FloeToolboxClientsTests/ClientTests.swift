import Foundation
import Testing
import Darwin
import FloeToolboxCore
@testable import FloeToolboxClients

#if os(macOS)
private final class FixtureServer: @unchecked Sendable {
    let process: Process
    let ports: [String:UInt16]
    let output: FileHandle
    init() throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [try #require(Bundle.module.url(forResource:"servers",withExtension:"py",subdirectory:"Fixtures")).path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        if let path = ProcessInfo.processInfo.environment["FLOE_TOOLBOX_TEST_LOG_DIR"] {
            let directory = URL(fileURLWithPath:path)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let log = directory.appendingPathComponent("fixture-"+UUID().uuidString+".log")
            FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            process.standardError = try FileHandle(forWritingTo:log)
        }
        try process.run()
        var line = Data()
        while line.count < 4096 {
            var ready = pollfd(fd:pipe.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            guard poll(&ready,1,3000) > 0, let byte = try pipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty else { process.terminate(); throw ClientError.timedOut }
            if byte == Data([10]) { break }; line.append(byte)
        }
        self.process = process; self.output = pipe.fileHandleForReading
        ports = try JSONDecoder().decode([String:UInt16].self,from:line)
    }
    func port(_ name: String) throws -> UInt16 { try #require(ports[name]) }
    func url(_ path: String) throws -> URL { try #require(URL(string:"http://127.0.0.1:\(port("http"))\(path)")) }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close() }
}

@Test func tcpLoopbackPreservesBytesAcrossStreamChunksAndClose() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    let connection = try await NetworkSerialConnection.connect(host:"127.0.0.1",port:fixture.port("tcp"),readTimeout:2)
    let bytes = Data((0..<100000).map { UInt8(truncatingIfNeeded:$0) })
    try await connection.send(bytes)
    var response = Data()
    while response.count < bytes.count { response.append(try await connection.receive(maximumBytes:4096)) }
    #expect(response == bytes)
    await connection.close()
    await #expect(throws:ClientError.closed) { try await connection.send(Data([1])) }
}
@Test func udpLoopbackRetainsDatagramBoundariesAndRejectsTruncation() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    let connection = try await NetworkSerialConnection.connect(host:"127.0.0.1",port:fixture.port("udp"),kind:.udp,localPort:0,readTimeout:2)
    try await connection.send(Data([1,2,3])); try await connection.send(Data([4,5]))
    #expect(try await connection.receive(maximumBytes:64) == Data([1,2,3]))
    #expect(try await connection.receive(maximumBytes:64) == Data([4,5]))
    try await connection.send(Data(repeating:7,count:64))
    await #expect(throws:ClientError.tooLarge) { try await connection.receive(maximumBytes:8) }
    await connection.close()
}
@Test func pendingNetworkReadCancelsWithoutWaitingForPeer() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    let connection = try await NetworkSerialConnection.connect(host:"127.0.0.1",port:fixture.port("tcp"))
    let read = Task { try await connection.receive(maximumBytes:64) }
    try await Task.sleep(for:.milliseconds(20)); read.cancel()
    await #expect(throws:(any Error).self) { try await read.value }
    await connection.close()
}
@Test func httpPostsActualBodyAndRejectsCrossOriginRedirect() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    let bytes = Data("local request body".utf8)
    let result = try await HTTPClient.send(HTTPClientRequest(url:fixture.url("/ok"),method:"POST",body:bytes))
    #expect(result.status == 201 && result.bytes == bytes && !result.truncated)
    await #expect(throws:HTTPClientFailure.self) { try await HTTPClient.send(HTTPClientRequest(url:fixture.url("/redirect"))) }
}
@Test func httpChunkedResponseStopsAtBoundAndRetainsMarkedPartial() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    do { _ = try await HTTPClient.send(HTTPClientRequest(url:fixture.url("/chunked"),maximumResponseBytes:1024)); Issue.record("oversized response accepted") }
    catch HTTPClientFailure.responseLimit(let partial) { #expect(partial.truncated && partial.bytes.count == 1024 && partial.status == 200) }
}
@Test func websocketLoopbackPreservesTextBinaryAndCoreJournalFacts() async throws {
    let fixture = try FixtureServer(); defer { fixture.stop() }
    let url = try #require(URL(string:"ws://127.0.0.1:\(fixture.port("http"))/socket"))
    let connection = try await WebSocketClientConnection.connect(url:url)
    try await connection.sendMessage(.text("中文 message"))
    #expect(try await connection.receiveMessage(maximumBytes:1024) == .text("中文 message"))
    try await connection.sendMessage(.bytes(Data([0,255,7])))
    #expect(try await connection.receiveMessage(maximumBytes:1024) == .bytes(Data([0,255,7])))
    try await connection.ping(); await connection.close()
    await #expect(throws:ClientError.closed) { try await connection.sendMessage(.text("late")) }
}
#endif

@Test func clientConfigurationRejectsHeaderInjectionAndUnsafeTargets() throws {
    #expect(throws:ClientError.self) { try HTTPClientRequest(url:URL(string:"https://user:password@example.test")!) }
    #expect(throws:ClientError.self) { try HTTPClientRequest(url:URL(string:"https://example.test")!,headers:["X-Test":"line\r\ninjected: true"]) }
    #expect(throws:ClientError.self) { try HTTPClientRequest(url:URL(string:"https://example.test")!,maximumResponseBytes:0) }
    #expect(throws:ClientError.self) { try ClientTLSConfiguration(additionalRootCertificates:[Data([0])]) }
}
