import Foundation
import Testing
@testable import FloeToolboxCore

private actor AnalysisObserver: SerialAnalysisProvider {
    private(set) var observed: SerialAnalysisContext?
    func analyze(_ context: SerialAnalysisContext, question: String) -> SerialAnalysisResult {
        observed = context
        return SerialAnalysisResult(facts:["bounded fixture"])
    }
}
private actor IdleConnection: SerialConnection {
    func send(_ bytes: Data) {}
    func receive(maximumBytes: Int) -> Data { Data() }
    func close() {}
}
private struct EncodedAnalysis: Encodable { let context: SerialAnalysisContext; let question: String }

@Test func analysisCapsFullEncodedInputAndOmitsURLSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID())
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,
        repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    try await journal.append((0..<30).map { _ in CaptureEvent(bytes:Data(repeating:65,count:80),direction:.received,
        notes:[String(repeating:"metadata",count:32)]) })
    let endpoint = try SerialEndpoint(title:"WS",transport:.webSocket,
        host:"wss://example.test/private/credential?token=synthetic-secret#secret")
    let provider = AnalysisObserver()
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:IdleConnection(),authorize:{ _ in true })
    _ = try await session.analyze(question:"inspect",expected:lease,provider:provider,maximumContextBytes:2048)
    let context = try #require(await provider.observed)
    #expect(context.selectionTruncated)
    #expect(!context.records.isEmpty)
    #expect(try JSONEncoder().encode(EncodedAnalysis(context:context,question:"inspect")).count <= 2048)
    #expect(context.endpoint.host == "wss://example.test")
    await #expect(throws: ToolboxError.self) {
        try await session.analyze(question:"inspect",expected:lease,provider:provider,maximumContextBytes:32)
    }
}

@Test func importedSecretsAreRecheckedBeforeModelExtraction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID())
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,
        repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    try await journal.append([CaptureEvent(bytes:Data("header\u{0}synthetic-value".utf8),direction:.observation,
        layer:.networkPacket,origin:.pcap,notes:["synthetic-value"])])
    let provider = AnalysisObserver(), endpoint = try SerialEndpoint(title:"capture",transport:.tcp,host:"192.0.2.1",port:9000)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:IdleConnection(),
        redactor:CaptureRedactor(knownSecrets:[Data("synthetic-value".utf8)]),authorize:{ _ in true })
    _ = try await session.analyze(question:"inspect",expected:lease,provider:provider)
    let record = try #require(await provider.observed?.records.first)
    #expect(record.redacted && record.bytes.isEmpty)
    #expect(!record.notes.joined().contains("synthetic-value"))
}

private actor TerminalFixture: TerminalAssistantHost {
    let bytes: Data
    var authorized = true
    var inputs: [Data] = []
    var requested = false
    var gate: CheckedContinuation<Bool,Never>?
    var observer: CheckedContinuation<Void,Never>?
    let waits: Bool
    init(bytes: Data = Data("output".utf8), waits: Bool = false) { self.bytes = bytes; self.waits = waits }
    func output(for lease: SessionLease, maximumBytes: Int) -> Data { bytes }
    func authorize(command: String, lease: SessionLease, target: MachineReference) async -> Bool {
        if !waits { return authorized }
        return await withCheckedContinuation { gate = $0; requested = true; observer?.resume(); observer = nil }
    }
    func waitUntilRequested() async { if requested { return }; await withCheckedContinuation { observer = $0 } }
    func release() { gate?.resume(returning:authorized); gate = nil }
    func sendInput(_ bytes: Data, lease: SessionLease) { inputs.append(bytes) }
    func deny() { authorized = false }
}
private actor TerminalObserver: TerminalAnalysisProvider {
    private(set) var output: String?
    func analyze(_ context: TerminalAnalysisContext, question: String) -> TerminalSuggestion {
        output = context.output
        return TerminalSuggestion(explanation:"fixture",commands:["pwd"])
    }
}
@Test func terminalSecretsAndOversizedHostOutputAreGuarded() async throws {
    let lease = SessionLease(ownerID:UUID()), provider = TerminalObserver()
    let host = TerminalFixture(bytes:Data("TOKEN=synthetic-value".utf8))
    let assistant = TerminalAssistant(lease:lease,target:.temporary(connectionID:UUID()),host:host)
    _ = try await assistant.suggest(question:"inspect",expected:lease,provider:provider)
    #expect(await provider.output == "[Sensitive content omitted]")
    let oversized = TerminalAssistant(lease:lease,target:.temporary(connectionID:UUID()),
        host:TerminalFixture(bytes:Data(repeating:65,count:32769)))
    await #expect(throws: ToolboxError.self) { try await oversized.suggest(question:"inspect",expected:lease,provider:provider) }
    #expect(await host.inputs.isEmpty)
}
@Test func terminalInvalidationDuringApprovalPreventsInput() async throws {
    let lease = SessionLease(ownerID:UUID()), host = TerminalFixture(waits:true)
    let assistant = TerminalAssistant(lease:lease,target:.builtIn(environmentID:"fixture-linux"),host:host)
    let task = Task { try await assistant.run(command:"pwd",expected:lease) }
    await host.waitUntilRequested(); await assistant.invalidate(); await host.release()
    await #expect(throws: ToolboxError.staleSession) { try await task.value }
    #expect(await host.inputs.isEmpty)
}
@Test func terminalRunWritesOneReviewedCommandToTheExactHost() async throws {
    let lease = SessionLease(ownerID:UUID()), host = TerminalFixture()
    let assistant = TerminalAssistant(lease:lease,target:.temporary(connectionID:UUID()),host:host)
    try await assistant.run(command:"printf reviewed",expected:lease)
    #expect(await host.inputs == [Data("printf reviewed\n".utf8)])
}
@Test func terminalRunRejectsMultilineOrControlInputBeforeApproval() async throws {
    let lease = SessionLease(ownerID:UUID()), host = TerminalFixture()
    let assistant = TerminalAssistant(lease:lease,target:.builtIn(environmentID:"fixture-linux"),host:host)
    for command in ["pwd\nwhoami", "pwd\r", "pwd\u{0}", "   ", String(repeating:"x",count:TerminalAssistant.maximumCommandBytes + 1)] {
        await #expect(throws: ToolboxError.self) { try await assistant.run(command:command,expected:lease) }
    }
    #expect(await host.inputs.isEmpty)
    try await assistant.run(command:String(repeating:"x",count:TerminalAssistant.maximumCommandBytes),expected:lease)
    #expect(await host.inputs.last?.count == TerminalAssistant.maximumCommandBytes + 1)
}
@Test func terminalDeniedOrWrongLeaseNeverWrites() async throws {
    let lease = SessionLease(ownerID:UUID()), host = TerminalFixture()
    let assistant = TerminalAssistant(lease:lease,target:.toolboxMachine(hostID:UUID()),host:host)
    await host.deny()
    await #expect(throws: ToolboxError.denied) { try await assistant.run(command:"pwd",expected:lease) }
    await #expect(throws: ToolboxError.staleSession) { try await assistant.run(command:"pwd",expected:SessionLease(ownerID:lease.ownerID)) }
    #expect(await host.inputs.isEmpty)
}

@Test func boundedMalformedCorpusNeverTrapsParsers() throws {
    // Fixed corpus: deterministic coverage of partial lengths, arbitrary bytes and Data slice offsets.
    var seed: UInt64 = 0x5eed
    for length in 0...384 {
        let data = Data((0..<length).map { _ -> UInt8 in
            seed = seed &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded:seed >> 32)
        })
        _ = try? ModbusCodec.decode(data,rtu:true,response:true)
        _ = try? ModbusCodec.decode(data,response:false)
        _ = try? MQTTCodec.decode(data)
        _ = try? PacketCaptureImporter.parse(data)
        _ = try? USBSerialChipPlans.stripFTDIStatus(data,maximumPacketSize:64)
        if !data.isEmpty { _ = try? ModbusCodec.decode(data.dropFirst(),rtu:true,response:true) }
    }
}
