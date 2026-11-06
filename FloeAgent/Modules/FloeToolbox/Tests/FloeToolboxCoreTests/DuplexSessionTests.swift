import Foundation
import Testing
@testable import FloeToolboxCore

private actor DuplexFixture: SerialConnection {
    var receiving = false
    var receiveWaiter: CheckedContinuation<Data,any Error>?
    var readyWaiter: CheckedContinuation<Void,Never>?
    private(set) var sent: [Data] = []
    func receive(maximumBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { receiveWaiter = $0; receiving = true; readyWaiter?.resume(); readyWaiter = nil }
    }
    func waitUntilReceiving() async { if !receiving { await withCheckedContinuation { readyWaiter = $0 } } }
    func send(_ bytes: Data) { sent.append(bytes); receiveWaiter?.resume(returning:bytes); receiveWaiter = nil }
    func close() { receiveWaiter?.resume(throwing:ToolboxError.staleSession); receiveWaiter = nil }
}
@Test func continuousReceiveDoesNotBlockAuthorizedSend() async throws {
    var root = URL(fileURLWithPath:#filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    root.appendPathComponent("Local/Scratch/toolbox-duplex-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), fixture = DuplexFixture()
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,
        repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let session = try SerialSession(lease:lease,endpoint:SerialEndpoint(title:"fixture",transport:.tcp,host:"192.0.2.1",port:9000),
        journal:journal,connection:fixture,authorize:{ _ in true })
    let receive = Task { try await session.receive(expected:lease) }
    await fixture.waitUntilReceiving()
    await #expect(throws:ToolboxError.self) { try await session.receive(expected:lease) }
    do { try await session.send(Data("duplex".utf8),expected:lease) }
    catch { await session.close(); throw error }
    #expect(try await receive.value == Data("duplex".utf8))
    #expect(await fixture.sent.count == 1)
    let records = await journal.snapshot().records
    #expect(records.contains { $0.direction == .sent } && records.contains { $0.direction == .received })
    await session.close()
}
