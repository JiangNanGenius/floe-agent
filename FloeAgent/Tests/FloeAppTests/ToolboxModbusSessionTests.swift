import Foundation
import Testing
import FloeTools
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxHost

private actor ModbusToolWire: SerialConnection {
    private var next = Data()
    private var value: UInt16 = 7
    var packets: [Data] = []
    func send(_ bytes: Data) throws {
        let frame = try ModbusCodec.decodeFrame(bytes,framing:.mbap)
        packets.append(frame.pdu)
        switch frame.pdu.first {
        case 3: next = Data([3,2,UInt8(value >> 8),UInt8(value & 255)])
        case 6:
            value = UInt16(frame.pdu[3]) << 8 | UInt16(frame.pdu[4])
            next = frame.pdu
        default: throw ClientError.protocolViolation
        }
        next = try ModbusCodec.encode(unit:frame.unit,pdu:next,framing:.mbap,transactionID:frame.transactionID ?? 0)
    }
    func receive(maximumBytes: Int) -> Data { defer { next = Data() }; return next }
    func close() {}
}

private actor ModbusHostGate {
    var current = true
    var reasons: [String] = []
    func close() { current = false }
    func record(_ reason: String) -> NestedApprovalOutcome { reasons.append(reason); return .allowed }
}

@Test func nativeModbusFrozenConnectionRequiresHumanWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), run = UUID(), gate = ModbusHostGate()
    let repository: any CaptureRepository = try FileCaptureRepository(root:root)
    let journal = try await CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:repository,limits:CaptureLimits())
    let wire = ModbusToolWire()
    let endpoint = try SerialEndpoint(title:"Synthetic MBAP",transport:.tcp,wireProtocol:.modbusTCP,host:"127.0.0.1",port:1502)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:wire,authorize:{ request in
        guard request.lease == lease else { return false }
        return await gate.current
    })
    let client = try ModbusClient(session:session)
    let host = try ToolboxAIHostContext(runID:run,lease:lease,journal:journal,serial:session,modbus:client,
                                        redactor:CaptureRedactor(),isCurrent:{ await gate.current })
    let tools: Set<String> = ["toolbox.modbus.read","toolbox.modbus.write","toolbox.modbus.build","toolbox.modbus.decode"]
    #expect(tools.isSubset(of:host.availableToolNames))
    #expect(!host.availableToolNames.contains("toolbox.serial.send"))
    let registry = ToolRunnerRegistry()
    NativeToolboxTools.register(in:registry,enabledNames:host.availableToolNames,resolve:{ _ in host })
    let read = try #require(registry.runner(named:"toolbox.modbus.read"))
    let write = try #require(registry.runner(named:"toolbox.modbus.write"))
    let build = try #require(registry.runner(named:"toolbox.modbus.build"))
    let decode = try #require(registry.runner(named:"toolbox.modbus.decode"))
    let readArgs = Data(#"{"unit":255,"address":3,"function":3,"quantity":1}"#.utf8)
    let writeArgs = Data(#"{"unit":255,"address":3,"function":6,"values":[43981]}"#.utf8)
    let base = ToolContext(runID:run,allowedToolNames:tools,cancellation:CancellationToken(),frozenEffectiveCatalogNames:tools)
    let built = try await build.execute(argumentsJSON:readArgs,context:base)
    #expect(built.summary.contains(#""sent":false"#))
    let decoded = try await decode.execute(argumentsJSON:Data(#"{"framing":"mbap","frame":"00 00 00 00 00 06 FF 03 00 03 00 01"}"#.utf8),context:base)
    #expect(decoded.summary.contains("zeroBasedAddress"))
    #expect(await wire.packets.isEmpty)
    let before = try await read.execute(argumentsJSON:readArgs,context:base)
    #expect(before.summary.contains(#""registerValues":"7""#))
    await #expect(throws:ToolboxError.denied) { try await write.execute(argumentsJSON:writeArgs,context:base) }
    var policy = base
    policy.approvalGrantID = UUID()
    policy.approvalOrigin = .policy("auto")
    let unattended = policy
    await #expect(throws:ToolboxError.denied) { try await write.execute(argumentsJSON:writeArgs,context:unattended) }
    policy.nestedApproval = .init { _ in .denied(reason:"cancel") }
    let refused = policy
    await #expect(throws:ToolboxError.denied) { try await write.execute(argumentsJSON:writeArgs,context:refused) }
    #expect(await wire.packets.count == 1)
    policy.nestedApproval = .init { await gate.record($0) }
    let fromCard = try await write.execute(argumentsJSON:writeArgs,context:policy)
    #expect(fromCard.summary.contains(#""writeEchoVerified":true"#))
    #expect(await gate.reasons.count == 1)
    #expect(await gate.reasons.first?.contains("127.0.0.1:1502") == true)
    let result = try await read.execute(argumentsJSON:readArgs,context:base)
    #expect(result.summary.contains(#""registerValues":"43981""#))
    var explicit = base; explicit.approvalOrigin = .humanCard; explicit.approvalGrantID = UUID()
    _ = try await write.execute(argumentsJSON:writeArgs,context:explicit)
    #expect(await gate.reasons.count == 1)
    await #expect(throws:ToolboxError.staleSession) {
        try await read.execute(argumentsJSON:readArgs,context:ToolContext(runID:UUID(),cancellation:CancellationToken()))
    }
    var narrow = base; narrow.frozenEffectiveCatalogNames = ["toolbox.modbus.read"]
    let limited = narrow
    await #expect(throws:ToolboxError.denied) { try await write.execute(argumentsJSON:writeArgs,context:limited) }
    policy.nestedApproval = .init { _ in await gate.close(); return .allowed }
    let expired = policy
    await #expect(throws:ToolboxError.staleSession) { try await write.execute(argumentsJSON:writeArgs,context:expired) }
    #expect(await wire.packets == [Data([3,0,3,0,1]),Data([6,0,3,0xab,0xcd]),Data([3,0,3,0,1]),Data([6,0,3,0xab,0xcd])])
    await session.close()
}
