import Foundation
import Testing
@testable import FloeToolboxCore

private actor FakeConnection: SerialConnection {
    var sent: [Data] = []; var didClose = false
    func send(_ bytes: Data) throws { if didClose { throw ToolboxError.staleSession }; sent.append(bytes) }
    func receive(maximumBytes: Int) -> Data { Data([1,2,3]) }
    func close() { didClose = true }
}
private actor ApprovalGate {
    var continuation: CheckedContinuation<Bool,Never>?
    var started: CheckedContinuation<Void,Never>?
    var waiting = false
    func request() async -> Bool {
        await withCheckedContinuation { c in continuation = c; waiting = true; started?.resume(); started = nil }
    }
    func waitUntilRequested() async { if waiting { return }; await withCheckedContinuation { started = $0 } }
    func release() { continuation?.resume(returning:true); continuation = nil }
}
private actor EffectLog {
    var effects: [SerialActionEffect] = []
    func record(_ effect: SerialActionEffect) -> Bool { effects.append(effect); return true }
}
private struct Provider: SerialAnalysisProvider {
    func analyze(_ context: SerialAnalysisContext, question: String) -> SerialAnalysisResult {
        SerialAnalysisResult(facts:["records=\(context.records.count)",context.lease.sessionID.uuidString],inferences:["fixture provider, not live inference"])
    }
}
private func makeJournal(_ lease: SessionLease, root: URL) throws -> CaptureJournal {
    try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
}
@Test func sessionSendCaptureAndIsolation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), connection = FakeConnection(), journal = try makeJournal(lease,root:root)
    let endpoint = try SerialEndpoint(title:"test",transport:.tcp,host:"192.0.2.1",port:9000)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:connection,authorize:{ _ in true })
    try await session.send(Data([1,2]),expected:lease)
    #expect(await connection.sent == [Data([1,2])])
    #expect(await journal.snapshot().records.first?.direction == .sent)
    await #expect(throws: ToolboxError.staleSession) { try await session.send(Data([3]),expected:SessionLease(ownerID:lease.ownerID)) }
    let analysis = try await session.analyze(question:"what is this",expected:lease,provider:Provider())
    #expect(analysis.facts.contains(lease.sessionID.uuidString))
}
@Test func deniedSendDoesNotTouchTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), connection = FakeConnection(), journal = try makeJournal(lease,root:root)
    let endpoint = try SerialEndpoint(title:"test",transport:.udp,host:"192.0.2.1",port:9000)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:connection,authorize:{ _ in false })
    await #expect(throws: ToolboxError.denied) { try await session.send(Data([1]),expected:lease) }
    #expect(await connection.sent.isEmpty); #expect(await journal.snapshot().records.isEmpty)
}
@Test func closeDuringApprovalFencesSend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), connection = FakeConnection(), gate = ApprovalGate(), journal = try makeJournal(lease,root:root)
    let endpoint = try SerialEndpoint(title:"test",transport:.tcp,host:"192.0.2.1",port:9000)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:connection,authorize:{ _ in await gate.request() })
    let task = Task { try await session.send(Data([1]),expected:lease) }
    await gate.waitUntilRequested(); await session.close(); await gate.release()
    await #expect(throws: ToolboxError.staleSession) { try await task.value }
    #expect(await connection.sent.isEmpty)
}
@Test func modbusWritesCannotBeRelabeledOrSplit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), connection = FakeConnection(), effects = EffectLog(), journal = try makeJournal(lease,root:root)
    let endpoint = try SerialEndpoint(title:"PLC",transport:.tcp,wireProtocol:.modbusTCP,host:"192.0.2.1",port:502)
    let session = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:connection,authorize:{ await effects.record($0.effect) })
    try await session.send(Data([0,1,0,0,0,6,1,6,0,0,0,5]),expected:lease)
    #expect(await effects.effects == [.deviceWrite])
    await #expect(throws: ToolboxError.self) { try await session.send(Data([0,1,0]),expected:lease) }
    #expect(await connection.sent.count == 1)
}
@Test func catalogPreservesOriginalToolsAndAppNavigation() {
    #expect(ToolboxTool.allCases.count == 31)
    #expect(ToolboxSpacePage.allCases == [.overview,.notes,.files,.toolbox])
    #expect(!ToolboxTool.vnc.hasAssistant)
    #expect([ToolboxTool.serialAssistant,.http,.webSocket,.mqtt].allSatisfy { $0.hasAssistant })
    #expect(ToolboxTool.roaming.group == .diagnostics)
    #expect([ToolboxTool.level, .motion, .compass, .ruler, .measure, .location].allSatisfy { $0.group == .instruments })
    #expect(ToolboxTool.calculator.group == .utilities)
}
