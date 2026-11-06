import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxClients

private actor BLEExchangeFixture {
    var chunks: [Data] = [],closed = 0
    func exchange(_ data: Data?,_ wait: TimeInterval,_ maximum: Int) -> Data {
        guard let data else { return Data() }; chunks.append(data); return Data([UInt8(chunks.count)])
    }
    func close() { closed += 1 }
}
@Test func bluetoothAdapterChunksWritesAndKeepsBytesReceivedDuringWrite() async throws {
    let fixture = BLEExchangeFixture()
    let connection = try HostBluetoothSerialConnection(exchange:{ data,wait,maximum in await fixture.exchange(data,wait,maximum) },close:{ await fixture.close() })
    try await connection.send(Data(repeating:7,count:49))
    #expect(await fixture.chunks.map(\.count) == [20,20,9])
    #expect(try await connection.receive(maximumBytes:2) == Data([1,2]))
    #expect(try await connection.receive(maximumBytes:8) == Data([3]))
    await connection.close(); await connection.close(); #expect(await fixture.closed == 1)
    await #expect(throws:ClientError.closed) { try await connection.send(Data([1])) }
}
private actor HTTPAuthorizationFixture {
    var requests: [SerialAuthorizationRequest] = []
    func deny(_ request: SerialAuthorizationRequest) -> Bool { requests.append(request); return false }
}
@Test func HTTPApprovalBindsOriginClassifiesWriteAndDoesNotExposeKnownSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let lease = SessionLease(ownerID:UUID()), authorization = HTTPAuthorizationFixture()
    let journal = try CaptureJournal(ownerID:lease.ownerID,captureID:lease.sessionID,repository:FileCaptureRepository(root:root),limits:CaptureLimits())
    let session = try HTTPDebugSession(lease:lease,targetURL:URL(string:"https://example.test")!,journal:journal,redactor:CaptureRedactor(knownSecrets:[Data("synthetic-secret".utf8)]),authorize:{ await authorization.deny($0) })
    await #expect(throws:ToolboxError.denied) { try await session.send(HTTPClientRequest(url:URL(string:"https://example.test/device?token=synthetic-secret")!,method:"POST",body:Data("synthetic-secret".utf8)),expected:lease) }
    let requests = await authorization.requests
    #expect(requests.count == 1 && requests[0].effect == .deviceWrite && requests[0].payloadRedacted)
    #expect(requests.first?.operationSummary == "POST https://example.test/device")
    #expect(!String(decoding:requests[0].bytes,as:UTF8.self).contains("synthetic-secret"))
    await #expect(throws:ClientError.invalidConfiguration) { try await session.send(HTTPClientRequest(url:URL(string:"https://other.test")!),expected:lease) }
    #expect(await authorization.requests.count == 1 && journal.captureID == lease.sessionID)
    #expect(await journal.snapshot().records.isEmpty)
    await session.close()
}
