import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxWorkbenches

private actor ScriptedModbusWire: SerialConnection {
    var sent: [Data] = []
    var replies: [Data]
    var closed = false
    init(_ replies: [Data]) { self.replies = replies }
    func send(_ bytes: Data) throws {
        guard !closed else { throw ClientError.closed }
        sent.append(bytes)
    }
    func receive(maximumBytes: Int) throws -> Data {
        guard !closed, !replies.isEmpty else { throw ClientError.closed }
        return replies.removeFirst()
    }
    func close() { closed = true }
}

private struct ModbusFixtureSession {
    let root: URL
    let journal: CaptureJournal
    let client: ModbusClient

    init(framing: ModbusFraming, wire: any SerialConnection,
         authorize: @escaping @Sendable (SerialAuthorizationRequest) async throws -> Bool = { _ in true }) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lease = SessionLease(ownerID:UUID())
        let repository: any CaptureRepository = try FileCaptureRepository(root:root)
        journal = try await CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:repository,limits:CaptureLimits())
        let proto: SerialProtocol = switch framing { case .mbap: .modbusTCP; case .rtu: .modbusRTU; case .ascii: .modbusASCII }
        let endpoint = try SerialEndpoint(title:"Controlled loopback", transport:.tcp, wireProtocol:proto,host:"127.0.0.1",port:1502)
        let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:wire,authorize:authorize)
        client = try ModbusClient(session:session)
    }
}

@Test @MainActor func modbusWorkbenchManualEditsAndReadBackUseSelectedWire() async throws {
    let writePDU = Data([6, 0, 9, 0x12, 0x34])
    let readPDU = Data([3, 0, 9, 0, 1])
    let echo = try ModbusCodec.encode(unit:7,pdu:writePDU,framing:.ascii)
    let actual = try ModbusCodec.encode(unit:7,pdu:Data([3,2,0x12,0x35]),framing:.ascii)
    let read = try ModbusCodec.encode(unit:7,pdu:readPDU,framing:.ascii)
    let wire = ScriptedModbusWire([echo,actual,actual,actual])
    let fixture = try await ModbusFixtureSession(framing:.ascii,wire:wire)
    defer { try? FileManager.default.removeItem(at:fixture.root) }
    let model = ModbusWorkbenchModel(client:fixture.client,journal:fixture.journal)
    model.draft = ModbusOperationDraft(kind:.writeSingleRegister,unitText:"7",addressText:"40010",valuesText:"0x1234")
    await model.refreshPreview()
    #expect(model.requestPreview == echo)
    let reviewed = model.draft
    model.draft.valuesText = "12"
    await model.execute(reviewed)
    #expect(await wire.sent.isEmpty)
    model.draft = reviewed
    await model.execute(reviewed)
    #expect(model.result?.writeEchoVerified == true)
    #expect(model.readBack?.expected == [0x1234] && model.readBack?.actual == [0x1235] && model.readBack?.matches == false)
    model.draft = ModbusOperationDraft(kind:.readHoldingRegisters,unitText:"7",addressText:"9",quantityText:"1")
    await model.refreshPreview()
    model.fillManualFromCurrent()
    #expect(model.manual?.sourceBytes == read)
    await model.sendManual()
    #expect(model.manualResult?.report?.fields["registerValues"] == "4661")
    model.manualFraming = .rtu
    #expect(model.manual == nil)
    model.manualInput = try ModbusCodec.encode(unit:7,pdu:readPDU,framing:.rtu).hex
    model.convertManual()
    let review = try #require(model.manual)
    model.manualInput += " FF"
    await model.sendManual(review)
    #expect(await wire.sent == [echo,read,read])
    model.manualInput = review.sourceBytes.hex
    model.convertManual()
    await model.sendManual()
    #expect(await wire.sent == [echo,read,read,read])
    await model.close()
}

@Test func modbusAllEightRequestsAndResponsesUseEveryFraming() async throws {
    let rows: [(ModbusOperation, [UInt8], [UInt8])] = [
        (.read(function:1,quantity:3),[1,0,5,0,3],[1,1,5]),
        (.read(function:2,quantity:3),[2,0,5,0,3],[2,1,3]),
        (.read(function:3,quantity:1),[3,0,5,0,1],[3,2,0x12,0x34]),
        (.read(function:4,quantity:1),[4,0,5,0,1],[4,2,0x56,0x78]),
        (.singleCoil(true),[5,0,5,0xff,0],[5,0,5,0xff,0]),
        (.singleRegister(0xabcd),[6,0,5,0xab,0xcd],[6,0,5,0xab,0xcd]),
        (.coils([true,false,true]),[15,0,5,0,3,1,5],[15,0,5,0,3]),
        (.registers([0x1234,0x5678]),[16,0,5,0,2,4,0x12,0x34,0x56,0x78],[16,0,5,0,2])
    ]
    for framing in ModbusFraming.allCases {
        let replies = try rows.enumerated().map { index,row in
            try ModbusCodec.encode(unit:1,pdu:Data(row.2),framing:framing,transactionID:UInt16(index+1))
        }
        let wire = ScriptedModbusWire(replies.flatMap { [Data($0.prefix(2)),Data($0.dropFirst(2))] })
        let fixture = try await ModbusFixtureSession(framing:framing,wire:wire)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        for (index,row) in rows.enumerated() {
            let exchange = try await fixture.client.exchange(unit:1,address:5,operation:row.0)
            #expect(try ModbusCodec.decodeFrame(exchange.request,framing:framing).pdu == Data(row.1))
            #expect(exchange.response == replies[index])
            #expect(exchange.writeEchoVerified == (index >= 4))
        }
        #expect(await wire.sent.count == 8)
        await fixture.client.session.close()
    }
}

private actor BlockingModbusWire: SerialConnection {
    let blockSend: Bool
    var closed = false
    var blocked = false
    private var waiting: CheckedContinuation<Void, any Error>?
    init(blockSend: Bool) { self.blockSend = blockSend }
    func send(_ bytes: Data) async throws { if blockSend { try await waitForClose() } }
    func receive(maximumBytes: Int) async throws -> Data { try await waitForClose(); return Data() }
    private func waitForClose() async throws {
        guard !closed else { throw ClientError.closed }
        blocked = true
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() {
        closed = true
        waiting?.resume(throwing:ClientError.closed)
        waiting = nil
    }
}

@Test func modbusTimeoutClosesBlockedSendAndReceive() async throws {
    for blockSend in [true,false] {
        let wire = BlockingModbusWire(blockSend:blockSend)
        let fixture = try await ModbusFixtureSession(framing:.rtu,wire:wire)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        await #expect(throws:ClientError.timedOut) {
            try await fixture.client.exchange(unit:1,address:0,operation:.read(function:3,quantity:1),timeout:0.1)
        }
        #expect(await wire.blocked)
        #expect(await wire.closed)
    }
}

@Test func modbusRejectsInvalidUnitPaddingEchoAndStaleReplies() async throws {
    let empty = ScriptedModbusWire([])
    let serial = try await ModbusFixtureSession(framing:.rtu,wire:empty)
    defer { try? FileManager.default.removeItem(at:serial.root) }
    for unit: UInt8 in [0,248,255] {
        let bad = try ModbusCodec.encode(unit:unit,pdu:Data([3,0,0,0,1]),framing:.rtu)
        #expect(throws:ToolboxError.self) { try ModbusCodec.convert(bad,from:.rtu,to:.mbap) }
        let tcp = try ModbusCodec.encode(unit:unit,pdu:Data([3,0,0,0,1]),framing:.mbap)
        #expect(throws:ToolboxError.self) { try ModbusCodec.convert(tcp,from:.mbap,to:.ascii) }
        await #expect(throws:ToolboxError.self) { try await serial.client.exchangeFrame(bad) }
    }
    #expect(await empty.sent.isEmpty)
    await serial.client.session.close()
    for (operation,pdu) in [(ModbusOperation.singleRegister(2),Data([6,0,0,0,3])),
                           (.read(function:1,quantity:1),Data([1,1,0x81]))] {
        let wire = ScriptedModbusWire([try ModbusCodec.encode(unit:1,pdu:pdu,framing:.rtu)])
        let fixture = try await ModbusFixtureSession(framing:.rtu,wire:wire)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        await #expect(throws:ClientError.protocolViolation) { try await fixture.client.exchange(unit:1,address:0,operation:operation) }
        #expect(await wire.closed)
    }
    for framing: ModbusFraming in [.ascii,.mbap] {
        func response(_ unit: UInt8,_ tx: UInt16,_ value: UInt8) throws -> Data {
            try ModbusCodec.encode(unit:unit,pdu:Data([3,2,0,value]),framing:framing,transactionID:tx)
        }
        let foreign = try response(framing == .ascii ? 2 : 1,88,99)
        let current = try response(1,1,42)
        let tail = try response(1,2,50)
        let wire = ScriptedModbusWire([foreign + current + tail])
        let fixture = try await ModbusFixtureSession(framing:framing,wire:wire)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        #expect(try await fixture.client.exchange(unit:1,address:0,operation:.read(function:3,quantity:1)).report?.fields["registerValues"] == "42")
        await fixture.client.session.close()
    }
}

@Test func modbusWriteDenialPreservesSessionAndDisconnectStopsReplay() async throws {
    let wire = ScriptedModbusWire([])
    let fixture = try await ModbusFixtureSession(framing:.rtu,wire:wire,authorize:{ $0.effect != .deviceWrite })
    defer { try? FileManager.default.removeItem(at:fixture.root) }
    await #expect(throws:ToolboxError.denied) { try await fixture.client.exchange(unit:1,address:0,operation:.singleCoil(true)) }
    #expect(await wire.sent.isEmpty)
    #expect(await !wire.closed)
    await #expect(throws:ClientError.closed) { try await fixture.client.exchange(unit:1,address:0,operation:.read(function:3,quantity:1)) }
    #expect(await wire.closed)
    await #expect(throws:ToolboxError.staleSession) { try await fixture.client.exchange(unit:1,address:0,operation:.read(function:3,quantity:1)) }
    #expect(await wire.sent.count == 1)
}

@Test @MainActor func modbusAmbiguousReadNeedsAnExplicitDirection() async throws {
    let bytes = try ModbusCodec.encode(unit:1,pdu:Data([1,3,0,0,1]),framing:.rtu)
    #expect(try ModbusCodec.decodeAuto(bytes,framing:.rtu).fields["direction"] == "requestOrResponse")
    let wire = ScriptedModbusWire([])
    let fixture = try await ModbusFixtureSession(framing:.rtu,wire:wire)
    defer { try? FileManager.default.removeItem(at:fixture.root) }
    let model = ModbusWorkbenchModel(client:fixture.client,journal:fixture.journal)
    model.manualInput = bytes.hex
    model.convertManual()
    #expect(model.manual?.isResponse == true)
    await model.sendManual()
    #expect(await wire.sent.isEmpty)
    model.manualAsResponse = false; model.convertManual()
    #expect(model.manual?.isResponse == false)
    model.manualAsResponse = true; model.convertManual()
    #expect(model.manual?.isResponse == true)
    let invalidASCII = Data(":+10300000001FB\r\n".utf8)
    #expect(throws:ToolboxError.self) { try ModbusCodec.decodeFrame(invalidASCII,framing:.ascii) }
    await model.close()
}
