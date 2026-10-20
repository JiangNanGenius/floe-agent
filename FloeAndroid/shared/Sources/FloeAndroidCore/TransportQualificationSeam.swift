// SPDX-License-Identifier: MPL-2.0
// G02-P3 transport qualification seam (job-ca18980891c043b5).
//
// Synchronous, bounded @_cdecl entry consumed ONLY by the debug-only
// instrumentation wrapper (`floe_qualification.cpp` → androidTest class
// `QualificationNative`). It drives the REAL Android FoundationNetworking
// incremental transport through the ORIGINAL three wire adapters
// (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages), the
// ORIGINAL SSEParser pipeline and the ORIGINAL MCP Streamable-HTTP client,
// against a synthetic loopback HTTP fixture owned by the instrumentation
// process. It registers no grants, opens no socket itself and never reaches
// the internet. Synthetic credentials are fixture-local only.
//
// The loopback proof is synthetic transport evidence. It is NOT real cloud
// TLS/hostname/default-trust verification and NOT App/UI/business
// acceptance; Main runs the installed tests and later cloud checks.
// The shared core .so is shipped in every variant and its export table is
// reported honestly (same policy as floe_db_smoke/floe_json_kind_smoke):
// this entry exists in the prebuilt library but no release-side Kotlin/JNI
// loader references it.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeTransport

private func transportReportJSON(_ report: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    else { return "{\"ok\":false,\"error\":\"encoding\"}" }
    return String(decoding: data, as: UTF8.self)
}

private func transportErrorJSON(_ reason: String) -> String {
    transportReportJSON(["ok": false, "error": reason])
}

private func jsonDuplicate(_ text: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(text.utf8)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    if !bytes.isEmpty {
        bytes.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(output).copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
        }
    }
    output[bytes.count] = 0
    return output
}

/// Monotonic microseconds (wall-clock changes cannot make the ordering
/// evidence vacuous).
private func micros() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000)
}

private enum TransportSmokeError: Error, CustomStringConvertible {
    case fixture(String)
    case invalidSpec(String)
    var description: String {
        switch self {
        case .fixture(let detail): "fixture:\(detail)"
        case .invalidSpec(let detail): "invalidSpec:\(detail)"
        }
    }
}

/// Synthetic provider profile pointing at the loopback fixture. `allowsPlainHTTP`
/// documents the local-fixture nature; no real endpoint or credential exists.
private func fixtureProvider(base: URL, wire: ModelProtocol) -> ProviderProfile {
    ProviderProfile(
        kind: wire == .anthropicMessages ? .anthropic : .openAI,
        wireProtocol: wire,
        baseURL: base,
        displayName: "Loopback Fixture",
        allowsPlainHTTP: true
    )
}

private func fixtureModel(provider: ProviderProfile) -> ModelProfile {
    ModelProfile(
        providerID: provider.id,
        remoteModelID: "fixture-model",
        displayName: "Fixture Model",
        limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 256),
        capabilities: [.text]
    )
}

private let syntheticFixtureKey = "synthetic-local-fixture"

/// The two-way barrier opener: a tiny GET the CONSUMER performs as soon as it
/// has parsed the first event. The fixture refuses to send its tail (and EOF)
/// until this arrives, so a buffered client can never satisfy it.
private func openFixtureBarrier(base: URL, tag: String) async {
    guard var components = URLComponents(url: base.appendingPathComponent("open"),
                                         resolvingAgainstBaseURL: false) else { return }
    components.queryItems = [
        URLQueryItem(name: "tag", value: tag),
        URLQueryItem(name: "stage", value: "first"),
    ]
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    _ = try? await session.data(for: request)
    session.finishTasksAndInvalidate()
}

private func anthropicEvent(_ text: String) -> Data {
    Data("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n".utf8)
}

private func responsesEvent(_ text: String) -> Data {
    Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(text)\"}\n\n".utf8)
}

private func chatEvent(_ text: String) -> Data {
    Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
}

// MARK: - entry

@_cdecl("floe_transport_smoke")
public func floeTransportSmoke(_ specPointer: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let specPointer else { return jsonDuplicate(transportErrorJSON("missingSpec")) }
    let text = String(cString: specPointer)
    guard !text.isEmpty, text.utf8.count <= 65_536,
          let data = text.data(using: .utf8),
          let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let baseText = spec["base"] as? String,
          let base = URL(string: baseText),
          let scenario = spec["scenario"] as? String else {
        return jsonDuplicate(transportErrorJSON("invalidSpec"))
    }
    // Extract every value the @Sendable bounded runner needs (the raw JSON
    // dictionary is not Sendable); the runner itself only sees plain values.
    let tag = (spec["tag"] as? String) ?? "fixture"
    let wire = (spec["wire"] as? String) ?? "chat"
    let ephemeral = (spec["ephemeral"] as? Bool) ?? false
    let cap = (spec["cap"] as? Int) ?? 16_384
    let outcome = runBounded(timeout: 90) {
        await transportScenario(base: base, scenario: scenario, tag: tag,
                                wire: wire, ephemeral: ephemeral, cap: cap)
    }
    return jsonDuplicate(outcome)
}

private func transportScenario(base: URL, scenario: String, tag: String,
                               wire: String, ephemeral: Bool, cap: Int) async -> String {
    do {
        switch scenario {
        case "providerBarrier":
            return try await providerBarrierReport(base: base, wire: wire,
                                                   tag: tag, ephemeral: ephemeral)
        case "providerCancel":
            return try await providerCancelReport(base: base, tag: tag)
        case "capEarly":
            return try await capEarlyReport(base: base, cap: cap)
        case "saturation":
            return try await saturationReport(base: base)
        case "mixedUnicode":
            return try await mixedUnicodeReport(base: base)
        case "mcpHandshake":
            return try await mcpHandshakeReport(base: base)
        case "mcpOversize":
            return try await mcpOversizeReport(base: base)
        case "mcpRedirect":
            return try await mcpRedirectReport(base: base)
        case "sessionPolicy":
            return await sessionPolicyReport()
        case "terminalRace":
            return try await terminalRaceReport(base: base)
        default:
            return transportErrorJSON("unknownScenario:\(scenario)")
        }
    } catch {
        return transportErrorJSON("threw:\(String(reflecting: error))")
    }
}

// MARK: - original three-wire provider streaming over the Android transport

private func wireFor(_ name: String) -> ModelProtocol {
    switch name {
    case "responses": .openAIResponses
    case "anthropic": .anthropicMessages
    default: .openAIChatCompletions
    }
}

private func adapterFor(_ wire: ModelProtocol) -> any ProviderAdapter {
    switch wire {
    case .openAIResponses: OpenAIResponsesAdapter()
    case .anthropicMessages: AnthropicMessagesAdapter()
    default: OpenAIChatCompletionsAdapter()
    }
}

private func providerBarrierReport(base: URL, wire name: String, tag: String,
                                   ephemeral: Bool) async throws -> String {
    let wire = wireFor(name)
    let provider = fixtureProvider(
        base: base.appendingPathComponent("wire-\(name)"), wire: wire)
    let model = fixtureModel(provider: provider)
    let request = ProviderStreamRequest(
        provider: provider,
        model: model,
        messages: [(role: "user", content: "ping")],
        ephemeralTransport: ephemeral
    )
    var text = ""
    var firstEventAt: Int64?
    var eventCount = 0
    for try await event in adapterFor(wire).stream(
        request: request, credentials: ProviderCredentials(apiKey: syntheticFixtureKey)) {
        eventCount += 1
        if case .textDelta(let delta) = event {
            if firstEventAt == nil {
                firstEventAt = micros()
                await openFixtureBarrier(base: base, tag: tag)
            }
            text += delta.text
        }
    }
    let endAt = micros()
    let firstAt: Int64 = firstEventAt ?? -1
    let expected = "onetwo"
    let ok = firstAt >= 0 && firstAt < endAt && text == expected && eventCount >= 2
    return transportReportJSON([
        "ok": ok,
        "wire": name,
        "ephemeral": ephemeral,
        "text": text,
        "expectedText": expected,
        "firstEventUs": firstAt,
        "endUs": endAt,
        "eventCount": eventCount,
        "firstBeforeEnd": firstAt >= 0 && firstAt < endAt,
    ])
}

private func providerCancelReport(base: URL, tag: String) async throws -> String {
    let cancelProvider = fixtureProvider(
        base: base.appendingPathComponent("chat-cancel"), wire: .openAIChatCompletions)
    let secondProvider = fixtureProvider(
        base: base.appendingPathComponent("chat-second"), wire: .openAIChatCompletions)
    let model = fixtureModel(provider: cancelProvider)
    let request = ProviderStreamRequest(
        provider: cancelProvider, model: model,
        messages: [(role: "user", content: "ping")])
    let adapter = OpenAIChatCompletionsAdapter()
    let stream = adapter.stream(request: request,
                                credentials: ProviderCredentials(apiKey: syntheticFixtureKey))
    actor Accumulator {
        var text = ""
        func append(_ value: String) { text += value }
        var current: String { text }
    }
    let accumulator = Accumulator()
    let consumer = Task { () -> String? in
        do {
            for try await event in stream {
                if case .textDelta(let delta) = event { await accumulator.append(delta.text) }
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }
    var spins = 0
    var observed = await accumulator.current
    while observed.isEmpty, spins < 600 {
        try? await Task.sleep(nanoseconds: 10_000_000)
        observed = await accumulator.current
        spins += 1
    }
    let sawFirstEvent = !observed.isEmpty
    consumer.cancel()
    _ = await consumer.value
    // A second unrelated request on the SAME default streaming session must
    // still complete after the cancellation (no session invalidation and no
    // cross-request fence leak).
    let secondRequest = ProviderStreamRequest(
        provider: secondProvider, model: fixtureModel(provider: secondProvider),
        messages: [(role: "user", content: "second")])
    var secondText = ""
    for try await event in adapter.stream(
        request: secondRequest, credentials: ProviderCredentials(apiKey: syntheticFixtureKey)) {
        if case .textDelta(let delta) = event { secondText += delta.text }
    }
    let ok = sawFirstEvent && secondText == "second-complete"
    return transportReportJSON([
        "ok": ok,
        "sawFirstEvent": sawFirstEvent,
        "partialText": observed,
        "secondText": secondText,
        "cancelled": true,
    ])
}

// MARK: - non-stream cap (Android BoundedHTTP branch)

private func capEarlyReport(base: URL, cap: Int) async throws -> String {
    var request = URLRequest(url: base.appendingPathComponent("huge"))
    request.timeoutInterval = 20
    do {
        let (data, _) = try await ProviderBoundedHTTP.data(for: request, maxBytes: cap)
        return transportReportJSON(["ok": false, "error": "notRejected",
                                    "bytes": data.count])
    } catch let error as FloeError {
        let description: String
        switch error {
        case .validationFailed(let message): description = message
        default: description = "\(error)"
        }
        let ok = description.contains("exceeds \(cap) bytes")
        return transportReportJSON(["ok": ok, "errorLabel": "responseTooLarge",
                                    "message": description])
    }
}

// MARK: - slow-consumer saturation (bounded whole pipeline)

private func saturationReport(base: URL) async throws -> String {
    var limits = IncrementalSSEPipeline.Limits()
    limits.maxBufferedBodyBytes = 1_024
    limits.maxPendingEvents = 2
    limits.maxPendingEventBytes = 512
    var request = URLRequest(url: base.appendingPathComponent("sse/flood"))
    request.timeoutInterval = 20
    let stream = IncrementalSSEPipeline.events(
        urlRequest: request,
        via: ProviderStreamingSessions.session(ephemeral: false),
        limits: limits)
    var committed = 0
    do {
        for try await _ in stream {
            committed += 1
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return transportReportJSON(["ok": false, "error": "noSaturation",
                                    "committedEvents": committed])
    } catch let error as IncrementalTransportError {
        guard case .pendingBufferSaturated = error else {
            return transportReportJSON(["ok": false, "error": "\(error)"])
        }
        return transportReportJSON(["ok": committed > 0,
                                    "errorLabel": "pendingBufferSaturated",
                                    "committedEvents": committed])
    }
}

// MARK: - original parser semantics (BOM / CRLF / split Unicode)

private func mixedUnicodeReport(base: URL) async throws -> String {
    var request = URLRequest(url: base.appendingPathComponent("sse/mixed"))
    request.timeoutInterval = 20
    let stream = IncrementalSSEPipeline.events(
        urlRequest: request,
        via: ProviderStreamingSessions.session(ephemeral: true))
    var events: [String] = []
    for try await event in stream { events.append(event.data) }
    let expected = ["first", "😀tail", "end"]
    return transportReportJSON(["ok": events == expected, "events": events,
                                "expected": expected])
}

// MARK: - MCP Streamable HTTP over the Android transport

private func mcpConfiguration(base: URL, path: String) -> MCPServerConfiguration {
    MCPServerConfiguration(
        displayName: "Loopback MCP Fixture",
        endpoint: path.split(separator: "/").reduce(base) { partial, component in
            partial.appendingPathComponent(String(component))
        },
        allowInsecureHTTP: true,
        timeoutSeconds: 15
    )
}

private func mcpClient(base: URL, path: String) throws -> MCPRemoteClient {
    try MCPRemoteClient(
        configuration: mcpConfiguration(base: base, path: path),
        credential: nil,
        artifactRootProvider: { FileManager.default.temporaryDirectory }
    )
}

private func mcpHandshakeReport(base: URL) async throws -> String {
    let client = try mcpClient(base: base, path: "mcp")
    let tools = try await client.discoverTools()
    await client.disconnect()
    let names = tools.map(\.remoteName)
    return transportReportJSON(["ok": names == ["fixture_echo"], "tools": names])
}

private func mcpOversizeReport(base: URL) async throws -> String {
    let client = try mcpClient(base: base, path: "mcp/oversize")
    do {
        _ = try await client.discoverTools()
        await client.disconnect()
        return transportReportJSON(["ok": false, "error": "notRejected"])
    } catch let error as MCPClientError {
        await client.disconnect()
        guard case .responseTooLarge(let cap) = error else {
            return transportReportJSON(["ok": false, "error": "\(error)"])
        }
        return transportReportJSON(["ok": cap == MCPRemoteClient.maximumResponseBytes,
                                    "errorLabel": "responseTooLarge",
                                    "cap": cap])
    }
}

private func mcpRedirectReport(base: URL) async throws -> String {
    let client = try mcpClient(base: base, path: "mcp/redirect")
    do {
        _ = try await client.discoverTools()
        await client.disconnect()
        return transportReportJSON(["ok": false, "error": "redirectFollowed"])
    } catch let error as MCPClientError {
        await client.disconnect()
        // Darwin delivers the refused 3xx as the final response (host test
        // pins that contract). A FoundationNetworking build may instead
        // surface a URLError for the refused redirect. Both are accepted as
        // "fail closed"; the SECURITY essence is asserted on the fixture
        // side: zero requests (and therefore zero auth forwarding) to the
        // redirect target.
        guard case .httpError(let status, _) = error else {
            return transportReportJSON(["ok": true,
                                        "errorLabel": "mcpError",
                                        "detail": "\(error)"])
        }
        return transportReportJSON(["ok": status == 302,
                                    "errorLabel": "httpError",
                                    "status": status])
    } catch let error as URLError {
        await client.disconnect()
        return transportReportJSON(["ok": true,
                                    "errorLabel": "urlError",
                                    "urlErrorCode": error.code.rawValue])
    }
}

// MARK: - session ownership / temporary isolation / fail-closed

private func sessionPolicyReport() async -> String {
    let normal = ProviderStreamingSessions.session(ephemeral: false)
    let ephemeral = ProviderStreamingSessions.session(ephemeral: true)
    let configuration = ProviderStreamingSessions.ephemeralConfiguration()
    let zeroed = configuration.urlCache == nil
        && configuration.httpCookieStorage == nil
        && configuration.urlCredentialStorage == nil
        && configuration.httpShouldSetCookies == false
        && configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData
    var plainFailedClosed = false
    do {
        _ = try await StreamingTransport.collect(
            URLRequest(url: URL(string: "http://127.0.0.1:1/never")!),
            via: URLSession.shared, maxBytes: 16)
    } catch let error as IncrementalTransportError {
        if case .sessionNotStreamable = error { plainFailedClosed = true }
    } catch {
        plainFailedClosed = false
    }
    let ok = StreamingTransport.isStreamable(normal)
        && StreamingTransport.isStreamable(ephemeral)
        && zeroed && plainFailedClosed
    return transportReportJSON([
        "ok": ok,
        "defaultStreamable": StreamingTransport.isStreamable(normal),
        "ephemeralStreamable": StreamingTransport.isStreamable(ephemeral),
        "ephemeralStorageZeroed": zeroed,
        "plainSharedFailsClosed": plainFailedClosed,
    ])
}

// MARK: - terminal-once under completion/cancel race

private func terminalRaceReport(base: URL) async throws -> String {
    var request = URLRequest(url: base.appendingPathComponent("sse/race"))
    request.timeoutInterval = 15
    let stream = try StreamingTransport.stream(
        request,
        via: ProviderStreamingSessions.session(ephemeral: false),
        maxBufferedBytes: 4_096)
    let consumer = Task { () -> Void in
        do { for try await _ in stream {} } catch { return }
    }
    try? await Task.sleep(nanoseconds: 45_000_000)
    stream.cancelOwned()
    for _ in 0..<20 {
        if stream.terminalDeliveries >= 1 { break }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    _ = await consumer.value
    return transportReportJSON([
        "ok": stream.terminalDeliveries == 1,
        "terminalDeliveries": stream.terminalDeliveries,
    ])
}
