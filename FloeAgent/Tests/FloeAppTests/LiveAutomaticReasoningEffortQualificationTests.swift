// FloeAppTests — Opt-in live qualification for the automatic reasoning-effort
// decision (helper App hook; actual provider execution belongs to G2).
//
// Gated by `FLOE_LIVE_AUTOMATIC_EFFORT=1` plus the SAME private reference
// config route the prior live qualifications use:
//   * `FLOE_LIVE_QUALIFICATION_CONFIG` — private JSON path
//     `{providerKind?, wireProtocol?, baseURL, model, apiKeyPath|apiKey}` (R's
//     loader in LiveOfficeAssistantQualificationTests.swift owns the canonical
//     schema), or
//   * `FLOE_LIVE_WORKBUDDY_MODELS` + `FLOE_LIVE_WORKBUDDY_MODEL_ID`.
// The key is read in memory only and is never logged, printed or persisted.
//
// One real fresh-round decision (helper call count must be exactly 1) plus a
// steer analogue (second resolve for the same run must NOT resend), and one
// real target turn through the production adapter with the frozen model. The
// wire token assertion uses the exact mapping the adapters use
// (`AutomaticReasoningEffortSupport.wireEffort`); the SSE body is not
// intercepted, and a plain disabled run is reported as disabled, never pass.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders
@testable import FloeApp

// MARK: - Live scope + reference

private enum LiveAutomaticEffortQualification {
    static let enabledEnvironmentKey = "FLOE_LIVE_AUTOMATIC_EFFORT"
    static let configPathEnvironmentKey = "FLOE_LIVE_QUALIFICATION_CONFIG"
    static let workBuddyModelsEnvironmentKey = "FLOE_LIVE_WORKBUDDY_MODELS"
    static let workBuddyModelEnvironmentKey = "FLOE_LIVE_WORKBUDDY_MODEL_ID"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enabledEnvironmentKey] == "1"
    }

    struct ProviderReference: Sendable {
        var kind: ProviderKind
        var wireProtocol: ModelProtocol
        var baseURL: URL
        var remoteModelID: String
        var apiKey: String
    }

    enum ReferenceError: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .missing(let detail): return detail
            case .malformed(let detail): return detail
            }
        }
    }

    static func providerReference() throws -> ProviderReference {
        let environment = ProcessInfo.processInfo.environment
        if let configPath = environment[configPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configPath.isEmpty {
            return try providerReference(fromConfigPath: configPath)
        }
        if let modelsPath = environment[workBuddyModelsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !modelsPath.isEmpty {
            return try providerReference(fromWorkBuddyModelsPath: modelsPath, environment: environment)
        }
        throw ReferenceError.missing(
            "No live qualification credential reference is configured. Set "
                + "\(configPathEnvironmentKey)=/private/path/config.json or "
                + "\(workBuddyModelsEnvironmentKey)=/private/path/models.json with "
                + "\(workBuddyModelEnvironmentKey)=<model id>, then re-run with "
                + "\(enabledEnvironmentKey)=1. The key itself is never read from this file."
        )
    }

    private static func providerReference(fromConfigPath path: String) throws -> ProviderReference {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch {
            throw ReferenceError.malformed(
                "The private qualification config could not be read: \(error.localizedDescription)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReferenceError.malformed("The private qualification config is not a JSON object")
        }
        guard let baseURLString = object["baseURL"] as? String,
              let baseURL = URL(string: baseURLString),
              let model = object["model"] as? String, !model.isEmpty else {
            throw ReferenceError.malformed("The private qualification config needs baseURL and model")
        }
        let apiKey: String
        if let inline = object["apiKey"] as? String, !inline.isEmpty {
            apiKey = inline
        } else if let keyPath = object["apiKeyPath"] as? String, !keyPath.isEmpty {
            do {
                apiKey = try String(contentsOfFile: keyPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw ReferenceError.malformed("The private qualification key file could not be read")
            }
        } else {
            throw ReferenceError.malformed("The private qualification config needs apiKey or apiKeyPath")
        }
        guard apiKey.count >= 16 else {
            throw ReferenceError.malformed("The resolved API key is too short")
        }
        let kind = (object["providerKind"] as? String)
            .flatMap(ProviderKind.init(rawValue:)) ?? .custom
        let protocolName = (object["wireProtocol"] as? String)
            ?? ModelProtocol.openAIChatCompletions.rawValue
        guard let wireProtocol = ModelProtocol(rawValue: protocolName) else {
            throw ReferenceError.malformed("Unsupported wireProtocol \(protocolName)")
        }
        return ProviderReference(
            kind: kind, wireProtocol: wireProtocol, baseURL: baseURL,
            remoteModelID: model, apiKey: apiKey)
    }

    private static func providerReference(
        fromWorkBuddyModelsPath path: String,
        environment: [String: String]
    ) throws -> ProviderReference {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch {
            throw ReferenceError.malformed(
                "The WorkBuddy models reference could not be read: \(error.localizedDescription)")
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ReferenceError.malformed("The WorkBuddy models reference is not a JSON array")
        }
        let requested = environment[workBuddyModelEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = requested.flatMap { id in
            array.first { ($0["id"] as? String) == id }
        }
        guard let entry,
              let model = entry["id"] as? String, !model.isEmpty,
              let key = entry["apiKey"] as? String, key.count >= 16,
              let urlString = entry["url"] as? String, let baseURL = URL(string: urlString) else {
            throw ReferenceError.malformed(
                "The WorkBuddy models reference needs an entry with id/apiKey/url; set "
                    + "\(workBuddyModelEnvironmentKey) to the exact entry id"
            )
        }
        return ProviderReference(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: normalizedBaseURL(from: baseURL), remoteModelID: model, apiKey: key)
    }

    /// The WorkBuddy reference stores the FULL endpoint (e.g.
    /// `/coding/v1/chat/completions`), while the production OpenAI adapter
    /// builds `{baseURL}/chat/completions`. Feeding the endpoint as the base
    /// double-appends the path and the provider answers 404 with zero tool
    /// turns; strip exactly the endpoint suffix the adapter appends and keep
    /// every other path component untouched (same normalization as R's live
    /// Office harness).
    private static func normalizedBaseURL(from url: URL) -> URL {
        let path = url.path
        for suffix in ["/chat/completions", "/completions", "/messages", "/responses"] {
            guard path.hasSuffix(suffix) else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = String(path.dropLast(suffix.count))
            return components?.url ?? url
        }
        return url
    }
}

// MARK: - Encoded-request assertion (sanitized keys only)

private enum SanitizedWireFields {
    /// Builds the exact body the production adapter would send and returns
    /// ONLY the effort/thinking keys. The full body, headers, credentials and
    /// messages never leave this function.
    static func effortFields(adapter: any ProviderAdapter,
                             request: ProviderStreamRequest) -> [String: String] {
        switch adapter.protocolKind {
        case .openAIChatCompletions:
            guard let object = json(OpenAIChatCompletionsAdapter().buildBody(from: request)) else { return [:] }
            var fields: [String: String] = [:]
            if let effort = object["reasoning_effort"] as? String { fields["reasoning_effort"] = effort }
            if let thinking = object["thinking"] as? [String: Any],
               let type = thinking["type"] as? String { fields["thinking.type"] = type }
            return fields
        case .anthropicMessages:
            guard let object = json(AnthropicMessagesAdapter().buildBody(from: request)),
                  let config = object["output_config"] as? [String: Any],
                  let effort = config["effort"] as? String else { return [:] }
            return ["output_config.effort": effort]
        case .openAIResponses:
            guard let object = json(OpenAIResponsesAdapter().buildBody(from: request)),
                  let reasoning = object["reasoning"] as? [String: Any],
                  let effort = reasoning["effort"] as? String else { return [:] }
            return ["reasoning.effort": effort]
        default:
            return [:]
        }
    }

    private static func json<Value: Encodable>(_ value: Value) -> [String: Any]? {
        guard let data = try? ProviderWireEncoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Counts real classifier calls around the production classifier.
private final class LiveCountingClassifier: AutomaticReasoningEffortClassifying, @unchecked Sendable {
    private let wrapped: any AutomaticReasoningEffortClassifying
    private let lock = NSLock()
    private var count = 0

    init(wrapping wrapped: any AutomaticReasoningEffortClassifying) {
        self.wrapped = wrapped
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func classify(_ input: String) async throws -> ModelReasoningEffort {
        // NSLock stays inside a synchronous helper: taking it directly in an
        // async context is unavailable under Swift 6 strict concurrency.
        recordCall()
        return try await wrapped.classify(input)
    }

    private func recordCall() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

// MARK: - Live suite

@Suite("FloeApp.LiveAutomaticReasoningEffortQualification", .serialized)
struct LiveAutomaticReasoningEffortQualificationTests {

    @Test(.timeLimit(.minutes(5)), .enabled(if: LiveAutomaticEffortQualification.isEnabled))
    func auxiliaryModelDecidesOnceAndTheFrozenWireIsValid() async throws {
        let reference = try LiveAutomaticEffortQualification.providerReference()
        let provider = ProviderProfile(
            kind: reference.kind,
            wireProtocol: reference.wireProtocol,
            baseURL: reference.baseURL,
            displayName: "live-qualification")
        let target = ModelProfile(
            providerID: provider.id,
            remoteModelID: reference.remoteModelID,
            displayName: reference.remoteModelID,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 1_024),
            capabilities: [.text, .tools],
            reasoningEffort: .automatic
        )
        try #require(
            AutomaticReasoningEffortSupport.supportsVariableEffort(
                provider: provider, model: target),
            "The live qualification model must expose a real reasoning-effort wire field")

        let adapter = ProviderAdapterFactory.adapter(for: reference.wireProtocol)
        let credentials = ProviderCredentials(apiKey: reference.apiKey)
        // The configured auxiliary route is the same controlled reference the
        // app uses, and the hook keeps the PRODUCTION deadline (2 s): a 20 s
        // harness deadline could "pass" where production would fall back, so
        // it would prove nothing. The decision record below must show a real
        // auxiliary answer inside that deadline. No retry is performed.
        let real = AutomaticReasoningEffortAuxiliaryClassifier(
            provider: provider,
            model: target,
            credentials: credentials,
            adapter: adapter,
            ephemeralTransport: false
        )
        let counting = LiveCountingClassifier(wrapping: real)
        let coordinator = AutomaticReasoningEffortCoordinator()
        let runID = UUID()
        let input = AutomaticReasoningEffortInputBuilder.build(
            goal: "Reply with exactly: FLOE_EFFORT_OK",
            attachments: []
        )

        let resolved = await coordinator.resolvedModel(
            runID: runID,
            provider: provider,
            model: target,
            boundedInput: input,
            classifier: counting,
            ingress: .freshRound
        )
        let chosen = try #require(
            resolved.reasoningEffort,
            "The auxiliary model must produce one valid bounded level for a supported target")
        let decision = try #require(
            await coordinator.decision(runID: runID),
            "the fresh-round decision must be recorded")
        // The production deadline is 2 s: a real auxiliary answer must be the
        // recorded source. A slow helper records the honest fallback with its
        // bounded category and latency instead of being waved through.
        #expect(decision.source == .auxiliary,
                "production-deadline fallback recorded: category=\(decision.errorCategory ?? "none") latencyMs=\(decision.latencyMilliseconds.map(String.init) ?? "none")")
        #expect(decision.errorCategory == nil)
        #expect((decision.latencyMilliseconds ?? Int.max) < 2_000,
                "the helper must answer inside the 2 s production deadline, recorded=\(decision.latencyMilliseconds ?? -1) ms")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: provider, model: resolved) != nil)
        #expect(await counting.calls == 1)

        // One real target turn through the REAL adapter with the frozen model.
        var visible = ""
        var completed = false
        var providerError: String?
        let request = ProviderStreamRequest(
            provider: provider,
            model: resolved,
            messages: [(role: "user", content: "Reply with exactly: FLOE_EFFORT_OK")],
            toolSchemas: []
        )
        for try await event in adapter.stream(request: request, credentials: credentials) {
            switch event {
            case .textDelta(let delta): visible += delta.text
            case .completed: completed = true
            case .error(let error):
                providerError = "\(error.kind.rawValue)/http\(error.httpStatus.map(String.init) ?? "none")"
            default: break
            }
        }
        #expect(providerError == nil, "target provider error: \(providerError ?? "")")
        #expect(completed)
        #expect(visible.contains("FLOE_EFFORT_OK"))

        // The frozen choice must be present in the ACTUAL encoded HTTP body
        // the production adapter builds for this exact request. Only the
        // sanitized effort/thinking keys are read — never auth, messages or
        // any other input — and nothing from the body is printed.
        let expectedWireEffort = AutomaticReasoningEffortSupport.wireEffort(
            provider: provider, model: resolved)
        let encodedFields = SanitizedWireFields.effortFields(
            adapter: adapter, request: request)
        switch reference.wireProtocol {
        case .openAIChatCompletions:
            #expect(encodedFields["reasoning_effort"] == expectedWireEffort,
                    "the encoded target body must carry the frozen effort (keys=\(encodedFields.keys.sorted()))")
        case .anthropicMessages:
            #expect(encodedFields["output_config.effort"] == expectedWireEffort,
                    "the encoded Anthropic body must carry the frozen effort")
        case .openAIResponses:
            #expect(encodedFields["reasoning.effort"] == expectedWireEffort,
                    "the encoded Responses body must carry the frozen effort")
        default:
            Issue.record("no encoded-effort assertion exists for \(reference.wireProtocol.rawValue)")
        }

        // Steering keeps the frozen choice: a second resolve for the same run
        // — the same-round continuation ingress — must not resubmit the
        // helper request.
        let steered = await coordinator.resolvedModel(
            runID: runID,
            provider: provider,
            model: target,
            boundedInput: "steer",
            classifier: counting,
            ingress: .continuation
        )
        #expect(steered.reasoningEffort == chosen)
        #expect(await counting.calls == 1)
    }
}
#endif
