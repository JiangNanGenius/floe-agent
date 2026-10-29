// FloeProvidersTests — Subscription connection-probe contract.
//
// Offline only. A URLProtocol stub stands in for the endpoint; no credential
// or paid provider request leaves the process.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data
        var error: Error? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func prepare(_ newStubs: [Stub]) {
        lock.lock()
        stubs = newStubs
        requests = []
        lock.unlock()
    }

    static func snapshotRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let stub = Self.stubs.isEmpty
            ? Stub(statusCode: 500, body: Data(#"{"error":"missing stub"}"#.utf8))
            : Self.stubs.removeFirst()
        Self.lock.unlock()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum InjectedProbeError: Error, Sendable {
    case injected
}

private struct InjectedProbeAdapter: ProviderAdapter {
    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream<AgentEvent, Error> { continuation in
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        throw InjectedProbeError.injected
    }

    func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws {
        throw InjectedProbeError.injected
    }
}

private func probeProfile(baseURL: String) -> ProviderProfile {
    ProviderProfile(
        kind: .custom,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: baseURL)!
    )
}

@Suite("FloeProviders.ProviderConnectionProbe", .serialized)
struct ProviderConnectionProbeTests {

    private let tokenPlan = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func run(
        status: Int,
        body: String,
        session: URLSession
    ) async -> Error? {
        ProbeURLProtocol.prepare([.init(statusCode: status, body: Data(body.utf8))])
        do {
            try await ProviderConnectionProbe.testConnection(
                provider: probeProfile(baseURL: tokenPlan),
                credentials: ProviderCredentials(apiKey: "test-key"),
                modelRemoteID: "qwen3.8-flash",
                session: session
            )
            return nil
        } catch {
            return error
        }
    }

    @Test("Plan model listing is rejected at the common wire boundary")
    func planDiscoveryNeverUsesModelsEndpoint() async throws {
        for url in [tokenPlan, "https://ark.cn-beijing.volces.com/api/plan/v3"] {
            do {
                _ = try await ModelDiscovery.fetchOpenAICompatibleModels(
                    provider: probeProfile(baseURL: url), credentials: ProviderCredentials(apiKey: "test-key"))
                Issue.record("An undocumented subscription listing must not run")
            } catch let error as FloeError {
                guard case .invalidConfiguration(let message) = error else {
                    Issue.record("Expected the pre-network catalog-only refusal, got \(error)")
                    continue
                }
                #expect(message == FloeL10n.l("providers.model_discovery.subscription_catalog"))
            }
        }
    }

    @Test("The probe request is bounded and names only the selected model")
    func boundedRequest() throws {
        let request = try ProviderConnectionProbe.minimalChatRequest(
            provider: probeProfile(baseURL: tokenPlan),
            credentials: ProviderCredentials(apiKey: "test-key"),
            modelRemoteID: "qwen3.8-flash"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/compatible-mode/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen3.8-flash")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == ProviderConnectionProbe.probeMaxOutputTokens)
        #expect(ProviderConnectionProbe.probeMaxOutputTokens > 0)
        #expect(ProviderConnectionProbe.probeMaxOutputTokens <= 64)
        #expect((json["messages"] as? [[String: Any]])?.count == 1)
    }

    @Test("A subscription probe never invents an unselected model")
    func missingSelectionFailsBeforeNetwork() async {
        ProbeURLProtocol.prepare([])
        do {
            try await ProviderConnectionProbe.testConnection(
                provider: probeProfile(baseURL: tokenPlan),
                credentials: ProviderCredentials(apiKey: "test-key"),
                modelRemoteID: nil,
                session: session()
            )
            Issue.record("Expected a missing-model validation failure")
        } catch let error as FloeError {
            guard case .validationFailed = error else {
                Issue.record("Expected validationFailed, got \(error)")
                return
            }
            #expect(ProbeURLProtocol.snapshotRequests().isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A non-plan probe uses the caller's adapter, not a fresh default")
    func injectedAdapterIsPreserved() async {
        do {
            try await ProviderConnectionProbe.testConnection(
                provider: ProviderProfile(
                    kind: .alibabaStudio,
                    wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
                ),
                credentials: ProviderCredentials(apiKey: "test-key"),
                modelRemoteID: "qwen3.8-flash",
                adapter: InjectedProbeAdapter(),
                session: session()
            )
            Issue.record("Expected the injected adapter to run")
        } catch is InjectedProbeError {
            // Passed: the injected PAYG adapter was used.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("401 is authentication, 403 is model/plan permission, 429 is quota")
    func statusClassification() async {
        let session = session()
        let auth = await run(status: 401, body: #"{"error":{"message":"bad key"}}"#, session: session)
        let permission = await run(status: 403, body: #"{"error":{"message":"model not enabled"}}"#, session: session)
        let quota = await run(status: 429, body: #"{"error":{"message":"quota exhausted"}}"#, session: session)

        guard let auth,
              let authError = auth as? FloeError,
              case .validationFailed(let authMessage) = authError else {
            Issue.record("401 should be a validation failure")
            return
        }
        #expect(!authMessage.contains("HTTP 403"))
        #expect(!authMessage.contains("HTTP 429"))

        guard let permission,
              let permissionError = permission as? FloeError,
              case .validationFailed(let permissionMessage) = permissionError else {
            Issue.record("403 should be a validation failure")
            return
        }
        #expect(permissionMessage.contains("HTTP 403"))
        #expect(permissionMessage.contains("model not enabled"))

        guard let quota,
              let quotaError = quota as? FloeError,
              case .validationFailed(let quotaMessage) = quotaError else {
            Issue.record("429 should be a validation failure")
            return
        }
        #expect(quotaMessage.contains("HTTP 429"))
        #expect(quotaMessage.contains("quota exhausted"))
    }

    @Test("A network failure is reported as network, not as a chat success")
    func networkFailure() async {
        ProbeURLProtocol.prepare([
            .init(
                statusCode: 0,
                body: Data(),
                error: URLError(.notConnectedToInternet)
            )
        ])
        do {
            try await ProviderConnectionProbe.testConnection(
                provider: probeProfile(baseURL: tokenPlan),
                credentials: ProviderCredentials(apiKey: "test-key"),
                modelRemoteID: "qwen3.8-flash",
                session: session()
            )
            Issue.record("Expected a network failure")
        } catch {
            #expect(error.localizedDescription.contains(FloeL10n.l("providers.connection_test.network_error", "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    @Test("A 200 without a completion choice is not a successful probe")
    func emptyTwoHundredRejected() async {
        let session = session()
        let empty = await run(status: 200, body: "{}", session: session)
        #expect(empty != nil)
        let choices = await run(status: 200, body: #"{"choices":[]}"#, session: session)
        #expect(choices != nil)
        let messageMissing = await run(
            status: 200,
            body: #"{"choices":[{"finish_reason":"stop"}]}"#,
            session: session
        )
        #expect(messageMissing != nil)
    }

    @Test("A real completion choice proves the subscription chat route")
    func validCompletionAccepted() async {
        let session = session()
        let result = await run(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#,
            session: session
        )
        #expect(result == nil)
        let request = ProbeURLProtocol.snapshotRequests().first
        #expect(request?.url?.path == "/compatible-mode/v1/chat/completions")
        if let body = request?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["max_tokens"] as? Int == ProviderConnectionProbe.probeMaxOutputTokens)
        } else {
            Issue.record("Expected a probe request body")
        }
    }
}
