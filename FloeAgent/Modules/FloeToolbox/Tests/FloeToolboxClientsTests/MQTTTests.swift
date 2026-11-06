import Foundation
import Darwin
import Testing
import FloeToolboxCore
@testable import FloeToolboxClients

private actor AuthorizationLog {
    var requests: [SerialAuthorizationRequest] = []
    func accept(_ request: SerialAuthorizationRequest) -> Bool { requests.append(request); return true }
}
#if os(macOS)
private final class BrokerFixture: @unchecked Sendable {
    let process: Process; let port: UInt16; let output: FileHandle
    init() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["FLOE_TOOLBOX_MQTT_BROKER"],"Qualification requires the recorded, independently built Mosquitto helper")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [try #require(Bundle.module.url(forResource:"mqtt_broker",withExtension:"py",subdirectory:"Fixtures")).path,binary]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); var bytes = Data()
        while bytes.count < 1024 {
            var fd = pollfd(fd:pipe.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            guard poll(&fd,1,5000) > 0, let value = try pipe.fileHandleForReading.read(upToCount:1), !value.isEmpty else { process.terminate(); throw ClientError.timedOut }
            if value == Data([10]) { break }; bytes += value
        }
        port = try #require(JSONDecoder().decode([String:UInt16].self,from:bytes)["port"])
        self.process = process; output = pipe.fileHandleForReading
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close() }
}
@Test(arguments:[MQTTVersion.v311,.v5]) func mqttInteroperatesWithMosquittoAllQoSAndRedactsCredentials(version: MQTTVersion) async throws {
    let fixture = try BrokerFixture(); defer { fixture.stop() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), authorization = AuthorizationLog()
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let endpoint = try SerialEndpoint(title:"Loopback MQTT",transport:.tcp,wireProtocol:version == .v5 ? .mqtt5 : .mqtt311,host:"127.0.0.1",port:Int(fixture.port))
    let stream = try await NetworkSerialConnection.connect(host:"127.0.0.1",port:fixture.port)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:MQTTFramedConnection(stream:stream),authorize:{ await authorization.accept($0) })
    let client = try MQTTClient(configuration:MQTTConfiguration(version:version,clientID:"floe-fixture-"+UUID().uuidString,keepAlive:1),session:session)
    try await client.connect(username:"synthetic-user",password:Data("synthetic-password".utf8))
    #expect(try await client.subscribe("floe/+/test",qos:.exactlyOnce) == 2)
    for qos in [MQTTQoS.atMostOnce,.atLeastOnce,.exactlyOnce] {
        try await client.publish(topic:"floe/local/test",payload:Data([qos.rawValue,0,255]),qos:qos)
    }
    var messages: [MQTTMessage] = []
    for _ in 0..<100 { messages += await client.drainMessages().messages; if messages.count == 3 { break }; try await Task.sleep(for:.milliseconds(10)) }
    #expect(messages.count == 3)
    #expect(Set(messages.map(\.payload)) == Set([Data([0,0,255]),Data([1,0,255]),Data([2,0,255])]))
    try await client.unsubscribe("floe/+/test")
    try await Task.sleep(for:.milliseconds(1250))
    try await client.publish(topic:"floe/local/test",payload:Data([9]))
    await client.disconnect()
    let captures = await journal.snapshot().records
    #expect(captures.contains { $0.direction == .sent && $0.bytes.first == 0xC0 })
    #expect(captures.contains { $0.direction == .received && $0.bytes.first == 0xD0 })
    #expect(captures.first(where:{$0.direction == .sent})?.redacted == true)
    #expect(!captures.contains { String(decoding:$0.bytes,as:UTF8.self).contains("synthetic-password") })
    let approvals = await authorization.requests
    #expect(approvals.filter { $0.effect == .deviceWrite }.count == 4)
    #expect(!approvals.contains { String(decoding:$0.bytes,as:UTF8.self).contains("synthetic-password") })
}
#endif
private actor FragmentStream: SerialConnection {
    var fragments: [Data]; init(_ fragments: [Data]) { self.fragments = fragments }
    func send(_ bytes: Data) {}
    func receive(maximumBytes: Int) throws -> Data { guard !fragments.isEmpty else { throw ClientError.closed }; return fragments.removeFirst() }
    func close() { fragments.removeAll() }
}
@Test func mqttFramingBoundsSplitPacketsBeforeCapture() async throws {
    let packet = try MQTTWire.packet(0x30,Data(repeating:7,count:500))
    let stream = FragmentStream([Data(packet.prefix(2)),Data(packet.dropFirst(2).prefix(50)),Data(packet.dropFirst(52))+Data([0xD0,0])])
    let framed = try MQTTFramedConnection(stream:stream)
    #expect(try await framed.receive(maximumBytes:1024) == packet)
    #expect(try await framed.receive(maximumBytes:1024) == Data([0xD0,0]))
    let oversized = try MQTTFramedConnection(stream:FragmentStream([Data([0x30,0xFF,0xFF,0x7F])]),maximumPacketBytes:1024)
    await #expect(throws:ClientError.tooLarge) { try await oversized.receive(maximumBytes:1024) }
    #expect(throws:MQTTClientFailure.self) { try MQTTWire.packetLength(Data([0x30,0x80,0])) }
}
