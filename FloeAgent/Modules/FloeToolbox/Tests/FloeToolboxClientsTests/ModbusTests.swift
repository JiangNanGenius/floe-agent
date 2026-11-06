import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxClients
#if os(macOS)
import Darwin
private final class ModbusFixture: @unchecked Sendable {
    let process: Process; let port: UInt16; let output: FileHandle
    init() throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["FLOE_TOOLBOX_FTP_PYTHON"]))
        process.arguments = [try #require(Bundle.module.url(forResource:"modbus_server",withExtension:"py",subdirectory:"Fixtures")).path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run()
        var bytes = Data()
        while bytes.count < 4096 {
            var ready = pollfd(fd:pipe.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            guard poll(&ready,1,5000) > 0,let byte = try pipe.fileHandleForReading.read(upToCount:1),!byte.isEmpty else { process.terminate(); throw ClientError.timedOut }
            if byte == Data([10]) { break }; bytes += byte
        }
        port = try #require(JSONDecoder().decode([String:UInt16].self,from:bytes)["port"])
        self.process = process; output = pipe.fileHandleForReading
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? output.close() }
}
@Test func ModbusTCPReadsWritesAndExceptionsInteroperateWithPymodbus() async throws {
    let fixture = try ModbusFixture(); defer { fixture.stop() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), connection = try await NetworkSerialConnection.connect(host:"127.0.0.1",port:fixture.port)
    let endpoint = try SerialEndpoint(title:"Loopback Modbus",transport:.tcp,wireProtocol:.modbusTCP,host:"127.0.0.1",port:Int(fixture.port))
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let approvals = ModbusApprovals()
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:connection,authorize:{ await approvals.record($0.effect) })
    let client = try ModbusClient(session:session)
    let read = try await client.exchange(unit:1,address:0,operation:.read(function:3,quantity:2))
    #expect(read.report?.fields["registerValues"] == "0,1")
    _ = try await client.exchange(unit:1,address:10,operation:.registers([1234,4321]))
    let verify = try await client.exchange(unit:1,address:10,operation:.read(function:3,quantity:2))
    #expect(verify.report?.fields["registerValues"] == "1234,4321")
    _ = try await client.exchange(unit:1,address:5,operation:.singleCoil(true))
    let coil = try await client.exchange(unit:1,address:5,operation:.read(function:1,quantity:1))
    #expect(coil.report?.fields["packedCoilsHex"] == "01")
    let exception = try await client.exchange(unit:1,address:10000,operation:.read(function:3,quantity:1))
    #expect(exception.report?.fields["exceptionCode"] == "2")
    #expect(await approvals.effects.filter {$0 == .deviceWrite}.count == 2)
    await session.close()
}
#endif
private actor ModbusApprovals { var effects: [SerialActionEffect] = []; func record(_ effect: SerialActionEffect) -> Bool { effects.append(effect); return true } }
private actor RTUFragments: SerialConnection {
    var sent: [Data] = []; var fragments: [Data]
    init(_ fragments: [Data]) { self.fragments = fragments }
    func send(_ bytes: Data) { sent.append(bytes) }
    func receive(maximumBytes: Int) throws -> Data { guard !fragments.isEmpty else { throw ClientError.closed }; return fragments.removeFirst() }
    func close() {}
}
@Test func RTUOverStreamAssemblesByLengthAndNeverInventsBroadcastAcknowledgement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), endpoint = try SerialEndpoint(title:"RTU stream",transport:.tcp,wireProtocol:.modbusRTU,host:"127.0.0.1",port:9000)
    let body = Data([1,3,2,0,42]), crc = ModbusCodec.crc16(body), response = body+Data([UInt8(crc&255),UInt8(crc>>8)])
    let wire = RTUFragments([Data(response.prefix(2)),Data(response.dropFirst(2))])
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:wire,authorize:{ _ in true }), client = try ModbusClient(session:session)
    #expect(try await client.exchange(unit:1,address:0,operation:.read(function:3,quantity:1)).report?.fields["registerValues"] == "42")
    let broadcast = try await client.exchange(unit:0,address:0,operation:.singleRegister(1))
    #expect(broadcast.broadcast && broadcast.report == nil)
    #expect(throws:ClientError.self) { try ModbusRequestBuilder.build(unit:0,address:0,operation:.read(function:3,quantity:1),rtu:true) }
    await session.close()
}
