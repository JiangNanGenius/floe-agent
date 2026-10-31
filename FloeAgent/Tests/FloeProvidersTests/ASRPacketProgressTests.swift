import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Test func alibabaLiveConsumesEachPacketExactlyOnce() async throws {
    let connection = FakeWebSocketConnection()
    connection.onSend = { message in
        if case .text(let text) = message, text.contains("run-task"),
           let event = try? aliStarted() { connection.inbox.push(event) }
    }
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: FakeWebSocketTransport(connection: connection))
    let session = try await adapter.startLiveSession(
        ASRLiveSessionRequest(profile: .alibaba(billingRoute: .payAsYouGo), inputSampleRate: 16_000),
        credential: "synthetic-key")
    let pcm = Data(repeating: 0x11, count: 3_200)
        + Data(repeating: 0x22, count: 3_200) + Data(repeating: 0x33, count: 100)
    try await session.feed(pcm)
    try await session.endUtterance()
    let chunks = connection.sent.read().compactMap { message -> Data? in
        if case .data(let data) = message { return data }; return nil
    }
    #expect(chunks.count == 3)
    #expect(chunks.reduce(into: Data()) { $0.append($1) } == pcm)
    await session.cancel()
}

@Test func volcengineLiveConsumesEachPacketExactlyOnce() async throws {
    let connection = FakeWebSocketConnection()
    let adapter = VolcengineASRAdapter(
        webSocketTransport: FakeWebSocketTransport(connection: connection))
    let session = try await adapter.startLiveSession(
        ASRLiveSessionRequest(profile: .volcengine(), inputSampleRate: 16_000),
        credential: "synthetic-key")
    let pcm = Data(repeating: 0x11, count: 6_400)
        + Data(repeating: 0x22, count: 6_400) + Data(repeating: 0x33, count: 100)
    try await session.feed(pcm)
    try await session.endUtterance()
    var chunks: [Data] = []
    for message in connection.sent.read() {
        guard case .data(let frame) = message, frame.count >= 8,
              frame[frame.startIndex + 1] >> 4 == 2 else { continue }
        chunks.append(try ASRVendorGzip.decompress(frame.subdata(in: 8..<frame.count), limit: 10_000))
    }
    #expect(chunks.count == 3)
    #expect(chunks.reduce(into: Data()) { $0.append($1) } == pcm)
    await session.cancel()
}
