// Focused qualification tests — Volcengine streaming ASR framing, live
// session, file replay and cancellation. No network or provider call.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Test func volcengineLiveRevisionsArriveBeforeUtteranceFinal() async throws {
    let connection = FakeWebSocketConnection()
    let adapter = VolcengineASRAdapter(
        webSocketTransport: FakeWebSocketTransport(connection: connection))
    let request = ASRLiveSessionRequest(profile: .volcengine(billingRoute: .agentPlan),
                                        inputSampleRate: 16_000)
    let session = try await adapter.startLiveSession(request, credential: "synthetic-plan-key")
    try await session.feed(Data(repeating: 0x5a, count: 6_400))
    for (index, text) in ["This is.", "This is a.", "This is a streaming."].enumerated() {
        connection.inbox.push(.data(try volcServerFrame(
            ["result": ["text": text]], isFinal: false, sequence: index + 1)))
    }
    let partials = try await collectEvents(session, count: 3)
    #expect(partials.map(\.text) == ["This is.", "This is a.", "This is a streaming."])
    #expect(partials.map(\.replacesPartial) == [false, true, true])
    #expect(partials.allSatisfy { $0.kind == .partial && $0.turnID == request.turnID })
    // The final audio packet has not been sent: all three updates above are
    // genuine live hypotheses, including punctuation revisions.
    try await session.endUtterance()
    connection.inbox.push(.data(try volcServerFrame(
        ["result": ["text": "This is a streaming test."]], isFinal: true, sequence: -4)))
    let finals = try await collectEvents(session, count: 2)
    #expect(finals.filter { $0.kind == .final }.count == 1)
    #expect(finals.last?.text == "This is a streaming test.")
    try await session.finish()
}

@Test func volcengineProductNamesUseTheSAUCModelSelector() throws {
    let audio = ASRVendorAudioInput(data: Data(), format: .pcm, sampleRate: 16_000,
                                   channelCount: 1, durationSeconds: nil, mimeType: "audio/L16")
    for name in ["doubao-seed-asr-2.0", "Doubao-Seed-ASR-2.0", "seed-asr-2.0", "bigmodel"] {
        let data = try VolcengineASRAdapter.configuration(modelID: name, input: audio, live: true)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])
        #expect(request["model_name"] as? String == "bigmodel")
    }
}

@Test func volcengineClientFramesUseDocumentedV3HeaderAndGzip() throws {
    let config = try jsonData([
        "audio": ["format": "pcm", "rate": 16_000, "bits": 16, "channel": 1],
        "request": ["model_name": "bigmodel"],
    ])
    let request = try VolcengineASRFrame.clientFullRequest(config)
    #expect(Array(request.prefix(4)) == [0x11, 0x10, 0x11, 0x00])
    let requestSize = Int(beUInt32(request, at: 4))
    #expect(requestSize == request.count - 8)
    let requestPayload = request.subdata(in: 8..<request.count)
    #expect(try ASRVendorGzip.decompress(requestPayload, limit: 16_384) == config)

    let pcm = Data((0..<6_400).map { UInt8($0 & 0xff) })
    let audio = try VolcengineASRFrame.clientAudio(pcm, isLast: false)
    #expect(Array(audio.prefix(4)) == [0x11, 0x20, 0x01, 0x00])
    let audioSize = Int(beUInt32(audio, at: 4))
    #expect(audioSize == audio.count - 8)
    #expect(try ASRVendorGzip.decompress(
        audio.subdata(in: 8..<audio.count), limit: 16_384) == pcm)

    let last = try VolcengineASRFrame.clientAudio(pcm, isLast: true)
    #expect(Array(last.prefix(4)) == [0x11, 0x22, 0x01, 0x00])
    #expect(try ASRVendorGzip.decompress(
        last.subdata(in: 8..<last.count), limit: 16_384) == pcm)
}

@Test func volcengineServerParserHandlesSequenceFinalAndError() throws {
    let partial = try volcServerFrame(
        ["result": ["text": "你"]], isFinal: false, sequence: 1)
    guard case .json(let payload, let isFinal, let sequence) =
            try VolcengineASRFrame.decode(partial, maximumEventBytes: 4_096) else {
        Issue.record("expected a JSON server frame")
        return
    }
    #expect(isFinal == false)
    #expect(sequence == 1)
    #expect(try JSONSerialization.jsonObject(with: payload) as? [String: Any] != nil)

    let final = try volcServerFrame(
        ["result": ["text": "你好"]], isFinal: true, sequence: -2)
    guard case .json(_, let finalFlag, let finalSequence) =
            try VolcengineASRFrame.decode(final, maximumEventBytes: 4_096) else {
        Issue.record("expected a final JSON server frame")
        return
    }
    #expect(finalFlag)
    #expect(finalSequence == -2)

    let noSequenceFinal = try VolcengineASRFrame.serverJSON(
        try jsonData(["result": ["text": "好"]]),
        isFinal: true,
        sequence: nil)
    guard case .json(_, let noSequenceFinalFlag, let noSequence) =
            try VolcengineASRFrame.decode(
                noSequenceFinal, maximumEventBytes: 4_096) else {
        Issue.record("expected a no-sequence final frame")
        return
    }
    #expect(noSequenceFinalFlag)
    #expect(noSequence == nil)

    guard case .error(let code, _) = try VolcengineASRFrame.decode(
        volcErrorFrame(45_000_002), maximumEventBytes: 4_096) else {
        Issue.record("expected an error frame")
        return
    }
    #expect(code == 45_000_002)

    do {
        _ = try VolcengineASRFrame.decode(
            Data([0x11, 0x10]), maximumEventBytes: 4_096)
        Issue.record("truncated frame should fail")
    } catch let error as VolcengineASRFrame.CodecError {
        #expect(error == .truncated)
    }
}

@Test func volcengineLivePayAsYouGoUsesRouteHeadersAndFrames() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let profile = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "new-console-key")

    guard let urlRequest = transport.lastRequest else {
        Issue.record("missing connect request")
        return
    }
    #expect(urlRequest.url?.path == "/api/v3/sauc/bigmodel_async")
    #expect(urlRequest.url?.host == "openspeech.bytedance.com")
    #expect(headerValue(urlRequest, "X-Api-Key") == "new-console-key")
    #expect(headerValue(urlRequest, "X-Api-Resource-Id")
        == "volc.seedasr.sauc.duration")
    #expect(headerValue(urlRequest, "X-Api-Connect-Id")?.isEmpty == false)
    #expect(headerValue(urlRequest, "X-Api-Request-Id")?.isEmpty == false)
    #expect(headerValue(urlRequest, "X-Api-Sequence") == "-1")
    #expect(headerValue(urlRequest, "Authorization") == nil)
    #expect(transport.connectCount == 1)

    guard case .data(let firstMessage) = connection.lastSent else {
        Issue.record("expected the full client request frame")
        return
    }
    #expect(Array(firstMessage.prefix(4)) == [0x11, 0x10, 0x11, 0x00])
    let configData = try ASRVendorGzip.decompress(
        firstMessage.subdata(in: 8..<firstMessage.count), limit: 16_384)
    guard let config = try JSONSerialization.jsonObject(with: configData)
        as? [String: Any],
          let audio = config["audio"] as? [String: Any],
          let requestObject = config["request"] as? [String: Any] else {
        Issue.record("config JSON missing")
        return
    }
    #expect(audio["format"] as? String == "pcm")
    #expect(audio["rate"] as? Int == 16_000)
    #expect(audio["bits"] as? Int == 16)
    #expect(audio["channel"] as? Int == 1)
    #expect(requestObject["model_name"] as? String == "bigmodel")
    #expect(requestObject["show_utterances"] as? Bool == true)

    let chunk = Data(repeating: 0x5a, count: 6_400)
    try await session.feed(chunk)
    guard case .data(let audioFrame) = connection.lastSent else {
        Issue.record("missing audio frame")
        return
    }
    #expect(Array(audioFrame.prefix(4)) == [0x11, 0x20, 0x01, 0x00])
    #expect(try ASRVendorGzip.decompress(
        audioFrame.subdata(in: 8..<audioFrame.count), limit: 16_384) == chunk)

    let tail = Data(repeating: 0x33, count: 3_200)
    try await session.feed(tail)
    try await session.endUtterance()
    guard case .data(let lastFrame) = connection.lastSent else {
        Issue.record("missing final audio frame")
        return
    }
    #expect(Array(lastFrame.prefix(4)) == [0x11, 0x22, 0x01, 0x00])
    #expect(try ASRVendorGzip.decompress(
        lastFrame.subdata(in: 8..<lastFrame.count), limit: 16_384) == tail)

    connection.inbox.push(.data(try volcServerFrame(
        ["result": ["text": "你"]], isFinal: false, sequence: 1)))
    let partialEvents = try await collectEvents(session, count: 1)
    let partial = try #require(partialEvents.first)
    #expect(partial.kind == .partial)
    #expect(partial.text == "你")
    #expect(partial.turnID == request.turnID)
    #expect(partial.itemID?.isEmpty == false)

    connection.inbox.push(.data(try volcServerFrame(
        [
            "result": [
                "text": "你好",
                "utterances": [
                    ["start_time": 0, "end_time": 500, "text": "你好"],
                ],
            ],
        ],
        isFinal: true,
        sequence: -2)))
    let finalEvents = try await collectEvents(session, count: 2)
    #expect(finalEvents.count == 2)
    #expect(finalEvents[0].kind == .partial)
    #expect(finalEvents[0].text == "好")
    #expect(finalEvents[1].kind == .final)
    #expect(finalEvents[1].text == "你好")
    try await session.finish()
    #expect(connection.closeCount.read() >= 1)
}

@Test func volcengineAgentPlanNeverCrossesToPayAsYouGoOnError() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let profile = ASRProfile.volcengine(billingRoute: .agentPlan)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "plan-key")

    #expect(transport.lastRequest?.url?.path
        == "/api/v3/plan/sauc/bigmodel_async")
    #expect(transport.connectCount == 1)
    #expect(headerValue(transport.lastRequest!, "X-Api-Key") == "plan-key")

    connection.inbox.push(.data(volcErrorFrame(45_000_002)))
    let events = try await collectEvents(session, count: 1)
    let failed = try #require(events.first)
    #expect(failed.kind == .failed)
    #expect(failed.failure == .emptyResult)

    do {
        try await session.finish()
        Issue.record("finish should surface the provider failure")
    } catch let error as ASRTranscriptionError {
        #expect(error == .emptyResult)
    }
    #expect(transport.connectCount == 1)
    #expect(transport.lastRequest?.url?.path
        == "/api/v3/plan/sauc/bigmodel_async")
}

@Test func volcengineLegacyPayAsYouGoHeadersAndPlanRejection() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let payg = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    var live = ASRLiveSessionRequest(profile: payg, inputSampleRate: 16_000)
    live.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        live, credential: "legacy:12345:access-token")
    #expect(headerValue(transport.lastRequest!, "X-Api-App-Key") == "12345")
    #expect(headerValue(transport.lastRequest!, "X-Api-Access-Key")
        == "access-token")
    #expect(headerValue(transport.lastRequest!, "X-Api-Key") == nil)
    await session.cancel()

    let plan = ASRProfile.volcengine(billingRoute: .agentPlan)
    let planRequest = ASRLiveSessionRequest(
        profile: plan, inputSampleRate: 16_000)
    do {
        _ = try await adapter.startLiveSession(
            planRequest, credential: "legacy:12345:access-token")
        Issue.record("legacy AppID credentials must not reach Agent Plan")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }
    #expect(transport.connectCount == 1)
}

@Test func volcengineLiveCancelDiscardsLateFinalAndDoesNotFallback()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let profile = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "cancel-key")
    try await session.feed(Data(repeating: 1, count: 6_400))
    await session.cancel()

    let failure = await eventFailure(session, timeout: 1)
    #expect(failure is CancellationError)
    connection.inbox.push(.data(try volcServerFrame(
        ["result": ["text": "late"]], isFinal: true, sequence: -9)))
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(transport.connectCount == 1)
    #expect(connection.cancelCount.read() >= 1)
}

@Test func volcengineLiveTruncatedAndOversizedFramesAreRedacted()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let profile = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 0.5
    let session = try await adapter.startLiveSession(
        request, credential: "frame-key")
    connection.inbox.push(.data(Data([0x11, 0x20, 0x01, 0x00, 0, 0])))
    let failure = await eventFailure(session, timeout: 1)
    #expect(failure as? ASRTranscriptionError == .providerRejected)
    await session.cancel()

    let connection2 = FakeWebSocketConnection()
    let transport2 = FakeWebSocketTransport(connection: connection2)
    let adapter2 = VolcengineASRAdapter(webSocketTransport: transport2)
    var small = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    small.maximumEventBytes = 512
    small.finishTimeoutSeconds = 0.5
    let session2 = try await adapter2.startLiveSession(
        small, credential: "frame-key")
    connection2.inbox.push(.data(try volcServerFrame(
        ["result": ["text": String(repeating: "a", count: 2_000)]],
        isFinal: false,
        sequence: 1)))
    let oversized = await eventFailure(session2, timeout: 1)
    #expect(oversized as? ASRTranscriptionError == .responseTooLarge)
    await session2.cancel()
}

@Test func volcengineLiveFinishTimesOutWithoutAFinal() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let profile = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 0.2
    let session = try await adapter.startLiveSession(
        request, credential: "timeout-key")
    try await session.feed(Data(repeating: 1, count: 6_400))
    try await session.endUtterance()
    do {
        try await session.finish()
        Issue.record("finish should time out")
    } catch let error as ASRTranscriptionError {
        #expect(error == .transport(.timedOut))
    }
    #expect(connection.cancelCount.read() >= 1)
}

@Test func volcengineFileReplaysWAVAndReturnsProviderTiming() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    connection.onSend = { message in
        guard case .data(let data) = message, data.count > 2,
              data[1] & 0x0f == 0x02 else { return }
        let result: [String: Any] = [
            "result": [
                "text": "你好世界",
                "utterances": [
                    ["start_time": 0, "end_time": 1_500, "text": "你好"],
                    ["start_time": 2_000, "end_time": 3_500, "text": "世界"],
                ],
            ],
        ]
        if let frame = try? volcServerFrame(
            result, isFinal: true, sequence: -3) {
            connection.inbox.push(.data(frame))
        }
    }
    let adapter = VolcengineASRAdapter(
        webSocketTransport: transport,
        replayDelayNanoseconds: 0,
        fileFinishTimeoutSeconds: 2)
    let profile = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    let audio = makeWAV()
    let request = ASRFileTranscriptionRequest(
        profile: profile,
        audio: audio,
        filename: "clip.wav",
        mimeType: "audio/wav",
        sourceDurationSeconds: 0.1)
    let result = try await adapter.transcribe(request, credential: "file-key")
    #expect(result.text == "你好世界")
    #expect(result.timing == .providerSegments)
    #expect(result.segments.count == 2)
    #expect(result.segments[0].start == 0)
    #expect(result.segments[0].end == 1.5)
    #expect(result.segments[1].start == 2.0)
    #expect(result.segments[1].end == 3.5)
    #expect(connection.closeCount.read() >= 1)

    guard case .data(let first) = connection.sent.read().first else {
        Issue.record("missing file full request")
        return
    }
    let config = try ASRVendorGzip.decompress(
        first.subdata(in: 8..<first.count), limit: 16_384)
    guard let root = try JSONSerialization.jsonObject(with: config)
        as? [String: Any],
          let audioConfig = root["audio"] as? [String: Any] else {
        Issue.record("missing file config")
        return
    }
    #expect(audioConfig["format"] as? String == "wav")
    #expect(audioConfig["rate"] as? Int == 16_000)
    #expect(audioConfig["channel"] as? Int == 1)
    #expect(transport.lastRequest?.url?.path == "/api/v3/sauc/bigmodel_async")
}

@Test func volcengineFileTextOnlyUsesSourceSpanOnly() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    connection.onSend = { message in
        guard case .data(let data) = message, data.count > 2,
              data[1] & 0x0f == 0x02 else { return }
        if let frame = try? volcServerFrame(
            ["result": ["text": "plain text"]],
            isFinal: true,
            sequence: -1) {
            connection.inbox.push(.data(frame))
        }
    }
    let adapter = VolcengineASRAdapter(
        webSocketTransport: transport,
        replayDelayNanoseconds: 0,
        fileFinishTimeoutSeconds: 2)
    let request = ASRFileTranscriptionRequest(
        profile: ASRProfile.volcengine(billingRoute: .payAsYouGo),
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav",
        sourceDurationSeconds: 2.5)
    let result = try await adapter.transcribe(request, credential: "file-key")
    #expect(result.text == "plain text")
    #expect(result.segments.isEmpty)
    #expect(result.timing == .sourceSpanOnly)
}

@Test func volcengineFileRejectsUnsupportedContainerBeforeConnecting()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = VolcengineASRAdapter(webSocketTransport: transport)
    let request = ASRFileTranscriptionRequest(
        profile: ASRProfile.volcengine(billingRoute: .payAsYouGo),
        audio: Data("not audio".utf8),
        filename: "clip.m4a",
        mimeType: "audio/mp4")
    do {
        _ = try await adapter.transcribe(request, credential: "file-key")
        Issue.record("m4a must be rejected")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration(let message) = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
        #expect(message.contains("convert"))
    }
    #expect(transport.connectCount == 0)
}

@Test func volcengineFileCancellationAfterFinalPacketStaysCancellation()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    connection.onSend = { message in
        guard case .data(let data) = message, data.count > 2,
              data[1] & 0x0f == 0x02 else { return }
        connection.finalPacketSeen.write(true)
    }
    let adapter = VolcengineASRAdapter(
        webSocketTransport: transport,
        replayDelayNanoseconds: 0,
        fileFinishTimeoutSeconds: 1)
    let request = ASRFileTranscriptionRequest(
        profile: ASRProfile.volcengine(billingRoute: .payAsYouGo),
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav")
    let task = Task {
        try await adapter.transcribe(request, credential: "cancel-file-key")
    }
    let sentFinal = await connection.waitForFinalPacket()
    #expect(sentFinal)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("cancelled file transcription must not return a result")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(transport.connectCount == 1)
    #expect(connection.cancelCount.read() >= 1)
}
