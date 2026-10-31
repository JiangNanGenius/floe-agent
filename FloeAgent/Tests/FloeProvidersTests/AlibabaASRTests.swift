// Focused qualification tests — Alibaba Qwen ASR file and live routes.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Test func alibabaFilePayAsYouGoPostsDocumentedPayloadAndTiming() async throws {
    let body = try jsonData([
        "output": [
            "text": "Hello World，这里是阿里巴巴语音实验室。",
            "sentence": [
                "begin_time": 760,
                "end_time": 3_800,
                "sentence_end": true,
                "sentence_id": 1,
                "text": "Hello World，这里是阿里巴巴语音实验室。",
                "words": [
                    ["begin_time": 760, "end_time": 1_040, "text": "Hello"],
                    ["begin_time": 1_040, "end_time": 3_800, "text": "World"],
                ],
            ],
        ],
    ])
    let http = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200, headers: ["content-type": "application/json"], body: body))
    let ws = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let adapter = AlibabaASRAdapter(
        httpTransport: http, webSocketTransport: ws)
    let profile = ASRProfile.alibaba(billingRoute: .payAsYouGo)
    let request = ASRFileTranscriptionRequest(
        profile: profile,
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav",
        sourceDurationSeconds: 3.8)
    let result = try await adapter.transcribe(
        request, credential: "test-key")
    #expect(result.text == "Hello World，这里是阿里巴巴语音实验室。")
    #expect(result.timing == .providerSegments)
    #expect(result.segments.count == 1)
    #expect(result.segments[0].start == 0.76)
    #expect(result.segments[0].end == 3.8)

    let recorded = try #require(http.recorded.first)
    #expect(recorded.request.httpMethod == "POST")
    #expect(recorded.request.url?.host == "dashscope.aliyuncs.com")
    #expect(recorded.request.url?.path
        == "/api/v1/services/aigc/multimodal-generation/generation")
    #expect(headerValue(recorded.request, "Authorization") == "Bearer test-key")
    #expect(headerValue(recorded.request, "Content-Type") == "application/json")
    #expect(headerValue(recorded.request, "X-DashScope-SSE") == "disable")
    #expect(http.recorded.count == 1)

    let root = try #require(
        try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
    #expect(root["model"] as? String == "qwen-audio-3.1-asr-flash")
    let parameters = try #require(root["parameters"] as? [String: Any])
    #expect(parameters["format"] as? String == "wav")
    #expect(parameters["sample_rate"] as? String == "16000")
    let input = try #require(root["input"] as? [String: Any])
    let messages = try #require(input["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "user")
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "input_audio")
    let audio = try #require(content.first?["input_audio"] as? [String: Any])
    let dataURI = try #require(audio["data"] as? String)
    #expect(dataURI.hasPrefix("data:audio/wav;base64,"))
}

@Test func alibabaFileTokenPlanUsesPlanHostAndModelWithoutGate() async throws {
    let body = try jsonData([
        "output": [
            "text": "你好世界",
            "sentences": [
                ["begin_time": 0, "end_time": 500, "text": "你好", "sentence_end": true],
                ["begin_time": 700, "end_time": 1_200, "text": "世界", "sentence_end": true],
            ],
        ],
    ])
    let http = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200, headers: [:], body: body))
    let ws = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let adapter = AlibabaASRAdapter(
        httpTransport: http, webSocketTransport: ws)
    let profile = ASRProfile.alibaba(billingRoute: .tokenPlan)
    let request = ASRFileTranscriptionRequest(
        profile: profile,
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav")
    let result = try await adapter.transcribe(
        request, credential: "sk-sp-token-plan-key")
    #expect(result.text == "你好世界")
    #expect(result.segments.count == 2)
    #expect(result.timing == .providerSegments)

    let recorded = try #require(http.recorded.first)
    #expect(recorded.request.url?.host == "token-plan.cn-beijing.maas.aliyuncs.com")
    let root = try #require(
        try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
    #expect(root["model"] as? String == "qwen-audio-3.0-asr-flash")
    let live = try ASRAdapterFactory.liveAdapter(for: profile)
    #expect(live == nil)
    let file = try ASRAdapterFactory.fileAdapter(for: profile)
    #expect(file is AlibabaASRAdapter)
}

@Test func alibabaFileRouteIsolationEvenOnFailure() async throws {
    let paygHTTP = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 401, headers: [:], body: Data("provider detail".utf8)))
    let paygWS = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let paygAdapter = AlibabaASRAdapter(
        httpTransport: paygHTTP, webSocketTransport: paygWS)
    let paygRequest = ASRFileTranscriptionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav")
    do {
        _ = try await paygAdapter.transcribe(paygRequest, credential: "payg-key")
        Issue.record("pay-as-you-go failure should surface authentication")
    } catch let error as ASRTranscriptionError {
        #expect(error == .authentication)
    }
    #expect(paygHTTP.recorded.count == 1)
    #expect(paygHTTP.recorded.first?.request.url?.host == "dashscope.aliyuncs.com")

    let planHTTP = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 429, headers: [:], body: Data("provider detail".utf8)))
    let planWS = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let planAdapter = AlibabaASRAdapter(
        httpTransport: planHTTP, webSocketTransport: planWS)
    let planRequest = ASRFileTranscriptionRequest(
        profile: ASRProfile.alibaba(billingRoute: .tokenPlan),
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav")
    do {
        _ = try await planAdapter.transcribe(
            planRequest, credential: "plan-key")
        Issue.record("Token Plan failure should surface quota")
    } catch let error as ASRTranscriptionError {
        #expect(error == .quotaOrRateLimited)
    }
    #expect(planHTTP.recorded.count == 1)
    #expect(planHTTP.recorded.first?.request.url?.host
        == "token-plan.cn-beijing.maas.aliyuncs.com")
}

@Test func alibabaFileRejectsFiveMinutesUnsupportedAndOversizedInput()
    async throws {
    let http = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200, headers: [:], body: try jsonData(["output": ["text": "x"]])))
    let ws = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let adapter = AlibabaASRAdapter(
        httpTransport: http, webSocketTransport: ws)
    let profile = ASRProfile.alibaba(billingRoute: .payAsYouGo)
    let long = ASRFileTranscriptionRequest(
        profile: profile,
        audio: makeWAV(),
        filename: "long.wav",
        mimeType: "audio/wav",
        sourceDurationSeconds: 301)
    do {
        _ = try await adapter.transcribe(long, credential: "key")
        Issue.record("audio over five minutes must be rejected")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration(let message) = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
        #expect(message.contains("5-minute"))
    }
    #expect(http.recorded.isEmpty)

    let unsupported = ASRFileTranscriptionRequest(
        profile: profile,
        audio: Data("not audio".utf8),
        filename: "clip.m4a",
        mimeType: "audio/mp4")
    do {
        _ = try await adapter.transcribe(unsupported, credential: "key")
        Issue.record("m4a must be rejected")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration(let message) = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
        #expect(message.contains("convert"))
    }
    #expect(http.recorded.isEmpty)

    let smallAdapter = AlibabaASRAdapter(
        httpTransport: http,
        webSocketTransport: ws,
        fileByteLimit: 100)
    let oversized = ASRFileTranscriptionRequest(
        profile: profile,
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav")
    do {
        _ = try await smallAdapter.transcribe(oversized, credential: "key")
        Issue.record("configured byte limit must be enforced")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }
    #expect(http.recorded.isEmpty)
}

@Test func alibabaFileTextOnlyTimingAndResponseBounds() async throws {
    let textOnly = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200,
        headers: [:],
        body: try jsonData(["output": ["text": "plain text"]])))
    let ws = FakeWebSocketTransport(connection: FakeWebSocketConnection())
    let adapter = AlibabaASRAdapter(
        httpTransport: textOnly, webSocketTransport: ws)
    let request = ASRFileTranscriptionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        audio: makeWAV(),
        filename: "clip.wav",
        mimeType: "audio/wav",
        sourceDurationSeconds: 2)
    let result = try await adapter.transcribe(request, credential: "key")
    #expect(result.segments.isEmpty)
    #expect(result.timing == .sourceSpanOnly)

    let empty = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200, headers: [:], body: try jsonData(["output": [:]])))
    let emptyAdapter = AlibabaASRAdapter(
        httpTransport: empty, webSocketTransport: ws)
    do {
        _ = try await emptyAdapter.transcribe(request, credential: "key")
        Issue.record("empty output must fail")
    } catch let error as ASRTranscriptionError {
        #expect(error == .emptyResult)
    }

    let huge = RecordingHTTPTransport(response: ASRHTTPResponse(
        statusCode: 200,
        headers: [:],
        body: Data(count: 8 * 1024 * 1024 + 1)))
    let hugeAdapter = AlibabaASRAdapter(
        httpTransport: huge, webSocketTransport: ws)
    do {
        _ = try await hugeAdapter.transcribe(request, credential: "key")
        Issue.record("oversized response must fail")
    } catch let error as ASRTranscriptionError {
        #expect(error == .responseTooLarge)
    }
}

@Test func alibabaLiveRunTaskAudioFinishAndFinalEvent() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: transport)
    connection.onSend = { message in
        guard case .text(let text) = message,
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let header = root["header"] as? [String: Any],
              let action = header["action"] as? String else { return }
        if action == "run-task", let event = try? aliStarted() {
            connection.inbox.push(event)
        } else if action == "finish-task" {
            if let event = try? aliResult(
                text: "你", sentenceEnd: false, end: nil) {
                connection.inbox.push(event)
            }
            if let event = try? aliResult(
                text: "你好", sentenceEnd: true, end: 500) {
                connection.inbox.push(event)
            }
            if let event = try? aliFinished() {
                connection.inbox.push(event)
            }
        }
    }
    let profile = ASRProfile.alibaba(billingRoute: .payAsYouGo)
    var request = ASRLiveSessionRequest(
        profile: profile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "live-key")
    #expect(transport.lastRequest?.url?.path == "/api-ws/v1/inference")
    #expect(transport.lastRequest?.url?.host == "dashscope.aliyuncs.com")
    #expect(headerValue(transport.lastRequest!, "Authorization")
        == "bearer live-key")
    #expect(transport.connectCount == 1)

    guard case .text(let runTaskText) = connection.lastSent else {
        Issue.record("missing run-task")
        return
    }
    let runTask = try #require(
        try JSONSerialization.jsonObject(
            with: Data(runTaskText.utf8)) as? [String: Any])
    let header = try #require(runTask["header"] as? [String: Any])
    #expect(header["action"] as? String == "run-task")
    #expect(header["streaming"] as? String == "duplex")
    let taskID = try #require(header["task_id"] as? String)
    #expect(taskID.count == 32)
    let payload = try #require(runTask["payload"] as? [String: Any])
    #expect(payload["task_group"] as? String == "audio")
    #expect(payload["task"] as? String == "asr")
    #expect(payload["function"] as? String == "recognition")
    #expect(payload["model"] as? String == "qwen-audio-3.1-asr-flash-streaming")
    let parameters = try #require(payload["parameters"] as? [String: Any])
    #expect(parameters["sample_rate"] as? Int == 16_000)
    #expect(parameters["format"] as? String == "pcm")

    let audio = Data(repeating: 0x44, count: 3_200)
    try await session.feed(audio)
    guard case .data(let sentAudio) = connection.lastSent else {
        Issue.record("missing binary audio")
        return
    }
    #expect(sentAudio == audio)

    try await session.endUtterance()
    let events = try await collectEvents(session, count: 3)
    #expect(events.count == 3)
    #expect(events[0].kind == .partial)
    #expect(events[0].text == "你")
    #expect(events[1].kind == .partial)
    #expect(events[1].text == "好")
    #expect(events[2].kind == .final)
    #expect(events[2].text == "你好")
    #expect(events.allSatisfy { $0.turnID == request.turnID })
    #expect(events.allSatisfy { $0.itemID == taskID })
    try await session.finish()
    #expect(connection.closeCount.read() >= 1)
}

@Test func alibabaTokenPlanDefaultFileOnlyAndManualLiveHasNoGate()
    async throws {
    let defaultProfile = ASRProfile.alibaba(billingRoute: .tokenPlan)
    let defaultLive = try ASRAdapterFactory.liveAdapter(for: defaultProfile)
    #expect(defaultLive == nil)
    let defaultFile = try ASRAdapterFactory.fileAdapter(for: defaultProfile)
    #expect(defaultFile is AlibabaASRAdapter)

    let manualProfile = ASRProfile.alibaba(
        billingRoute: .tokenPlan,
        liveModelID: "qwen-audio-3.1-asr-flash-streaming",
        liveEndpoint: "wss://example.com/api-ws/v1/inference")
    let manualLive = try ASRAdapterFactory.liveAdapter(for: manualProfile)
    #expect(manualLive is AlibabaASRAdapter)

    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    connection.onSend = { message in
        guard case .text = message, let event = try? aliStarted() else { return }
        connection.inbox.push(event)
    }
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: transport)
    var request = ASRLiveSessionRequest(
        profile: manualProfile, inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "sk-sp-manual-key")
    #expect(transport.lastRequest?.url?.host == "example.com")
    #expect(transport.lastRequest?.url?.path == "/api-ws/v1/inference")
    await session.cancel()
}

@Test func alibabaLiveRejectsSampleRateAndSurfaceTaskFailure()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: transport)
    var badRate = ASRLiveSessionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        inputSampleRate: 24_000)
    badRate.finishTimeoutSeconds = 1
    do {
        _ = try await adapter.startLiveSession(
            badRate, credential: "key")
        Issue.record("24 kHz must be rejected")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }
    #expect(transport.connectCount == 0)

    connection.onSend = { message in
        guard case .text = message, let event = try? aliFailed() else { return }
        connection.inbox.push(event)
    }
    var normal = ASRLiveSessionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        inputSampleRate: 16_000)
    normal.finishTimeoutSeconds = 1
    do {
        _ = try await adapter.startLiveSession(
            normal, credential: "key")
        Issue.record("task-failed must fail the start")
    } catch let error as ASRTranscriptionError {
        #expect(error == .providerRejected)
    }
    #expect(transport.connectCount == 1)
}

@Test func alibabaLiveCancelDiscardsLateFinalAndDoesNotFallback()
    async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: transport)
    connection.onSend = { message in
        guard case .text = message, let event = try? aliStarted() else { return }
        connection.inbox.push(event)
    }
    var request = ASRLiveSessionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 1
    let session = try await adapter.startLiveSession(
        request, credential: "cancel-key")
    try await session.feed(Data(repeating: 2, count: 3_200))
    await session.cancel()
    let failure = await eventFailure(session, timeout: 1)
    #expect(failure is CancellationError)
    if let event = try? aliResult(text: "late", sentenceEnd: true) {
        connection.inbox.push(event)
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(transport.connectCount == 1)
    #expect(connection.cancelCount.read() >= 1)
}

@Test func alibabaLiveFinishTimesOutWithoutTaskFinished() async throws {
    let connection = FakeWebSocketConnection()
    let transport = FakeWebSocketTransport(connection: connection)
    let adapter = AlibabaASRAdapter(
        httpTransport: RecordingHTTPTransport(response: ASRHTTPResponse(
            statusCode: 500, headers: [:], body: Data())),
        webSocketTransport: transport)
    connection.onSend = { message in
        guard case .text = message, let event = try? aliStarted() else { return }
        connection.inbox.push(event)
    }
    var request = ASRLiveSessionRequest(
        profile: ASRProfile.alibaba(billingRoute: .payAsYouGo),
        inputSampleRate: 16_000)
    request.finishTimeoutSeconds = 0.2
    let session = try await adapter.startLiveSession(
        request, credential: "timeout-key")
    try await session.feed(Data(repeating: 3, count: 3_200))
    try await session.endUtterance()
    do {
        try await session.finish()
        Issue.record("finish should time out")
    } catch let error as ASRTranscriptionError {
        #expect(error == .transport(.timedOut))
    }
    #expect(connection.cancelCount.read() >= 1)
}
