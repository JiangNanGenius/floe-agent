// FloeProvidersTests — Provider catalog search, filters and Codable safety.
// Offline: synthetic documents plus an optional read of the checked-in
// ProviderCatalog.json; no network and no credentials.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

private func makeDocument(_ providers: [ProviderCatalogEntry]) -> ProviderCatalogDocument {
    ProviderCatalogDocument(
        schemaVersion: 1,
        source: .init(
            project: "models.dev",
            url: "https://models.dev",
            license: "MIT",
            documentSHA256: String(repeating: "a", count: 64),
            fetchedAt: "2026-10-09T00:00:00Z"
        ),
        providers: providers
    )
}

private func makeEntry(
    _ presetID: String,
    name: String,
    aliases: [String] = [],
    kind: ProviderKind = .custom,
    defaultProtocol: ModelProtocol = .openAIChatCompletions,
    baseURL: String? = "https://api.example.com/v1",
    domains: [String] = [],
    models: [String] = [],
    availability: ProviderCatalogAvailability = .available,
    unsupportedReason: String? = nil,
    authStyle: String = "bearer"
) -> ProviderCatalogEntry {
    ProviderCatalogEntry(
        presetID: presetID,
        name: name,
        aliases: aliases,
        kind: kind,
        defaultProtocol: defaultProtocol,
        baseURL: baseURL.flatMap(URL.init(string:)),
        domains: domains,
        models: models,
        availability: availability,
        unsupportedReason: unsupportedReason,
        upstreamID: presetID,
        authStyle: authStyle
    )
}

@Suite("FloeProviders.ProviderCatalog")
struct ProviderCatalogTests {

    @Test("Exact name, alias and width-insensitive matches rank first")
    func exactMatches() {
        let alpha = makeEntry("alpha", name: "Alpha AI", aliases: ["阿尔法"])
        let beta = makeEntry("beta", name: "Beta Labs")
        let index = ProviderCatalogIndex(document: makeDocument([alpha, beta]))

        #expect(index.search(query: "Alpha AI", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["alpha"])
        #expect(index.search(query: "阿尔法", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["alpha"])
        #expect(index.search(query: "Ａｌｐｈａ ＡＩ", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["alpha"])
    }

    @Test("Alias exact match beats a name-prefix match")
    func aliasExactBeatsPrefix() {
        let upstart = makeEntry("upstart", name: "Upstart")
        let alias = makeEntry("aliased", name: "Zed", aliases: ["up"])
        let index = ProviderCatalogIndex(document: makeDocument([upstart, alias]))

        #expect(index.search(query: "up", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["aliased", "upstart"])
    }

    @Test("Domain and model matches are found")
    func domainAndModelMatches() {
        let alpha = makeEntry(
            "alpha",
            name: "Alpha AI",
            baseURL: "https://api.alpha.example/v1",
            domains: ["api.alpha.example"],
            models: ["alpha-1", "alpha-2"]
        )
        let beta = makeEntry("beta", name: "Beta Labs", domains: ["beta.example"], models: ["beta-pro"])
        let index = ProviderCatalogIndex(document: makeDocument([alpha, beta]))

        #expect(index.search(query: "api.alpha.example", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["alpha"])
        #expect(index.search(query: "alpha-2", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["alpha"])
        #expect(index.search(query: "beta-pro", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["beta"])
        #expect(index.search(query: "unknown", filter: .all, configuredPresetIDs: []).isEmpty)
    }

    @Test("Substring matches remain searchable")
    func substringMatches() {
        let magnetar = makeEntry("magnetar", name: "Magnetar", baseURL: nil, domains: [], models: [])
        let index = ProviderCatalogIndex(document: makeDocument([magnetar]))

        #expect(index.search(query: "gne", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["magnetar"])
    }

    @Test("Empty query keeps document order with configured providers first")
    func emptyQueryStability() {
        let one = makeEntry("one", name: "One")
        let two = makeEntry("two", name: "Two")
        let three = makeEntry("three", name: "Three")
        let index = ProviderCatalogIndex(document: makeDocument([one, two, three]))

        let results = index.search(query: "", filter: .all, configuredPresetIDs: ["three"])
        #expect(results.map(\.presetID) == ["three", "one", "two"])
        let repeatResults = index.search(query: "", filter: .all, configuredPresetIDs: ["three"])
        #expect(results.map(\.presetID) == repeatResults.map(\.presetID))
    }

    @Test("Configured providers win at equal rank")
    func configuredPriority() {
        let one = makeEntry("one", name: "Aaa Cloud")
        let two = makeEntry("two", name: "Abb Cloud")
        let index = ProviderCatalogIndex(document: makeDocument([one, two]))

        let results = index.search(query: "a", filter: .all, configuredPresetIDs: ["two"])
        #expect(results.map(\.presetID) == ["two", "one"])
    }

    @Test("Available ranks before unsupported at equal rank")
    func unsupportedOrdering() {
        let available = makeEntry("zavier", name: "Zavier Corp")
        let unsupported = makeEntry(
            "aardvark",
            name: "Aardvark Corp",
            availability: .unsupported,
            unsupportedReason: "requires OAuth device flow"
        )
        let index = ProviderCatalogIndex(document: makeDocument([unsupported, available]))

        let results = index.search(query: "corp", filter: .all, configuredPresetIDs: [])
        #expect(results.map(\.presetID) == ["zavier", "aardvark"])
    }

    @Test("Filters restrict all, configured, available and local results")
    func filters() {
        let remote = makeEntry("remote", name: "Remote", domains: ["remote.example"])
        let unsupported = makeEntry(
            "blocked",
            name: "Blocked",
            domains: ["blocked.example"],
            availability: .unsupported,
            unsupportedReason: "requires OAuth device flow"
        )
        let local = makeEntry("ondevice", name: "On-device", kind: .local, baseURL: "http://127.0.0.1")
        let index = ProviderCatalogIndex(document: makeDocument([remote, unsupported, local]))

        #expect(index.search(query: "", filter: .all, configuredPresetIDs: []).count == 3)
        #expect(index.search(query: "", filter: .configured, configuredPresetIDs: ["blocked"]).map(\.presetID) == ["blocked"])
        #expect(index.search(query: "", filter: .available, configuredPresetIDs: []).map(\.presetID) == ["remote", "ondevice"])
        #expect(index.search(query: "", filter: .local, configuredPresetIDs: []).map(\.presetID) == ["ondevice"])
    }

    @Test("Document JSON round-trips, including nil base URL and unsupported reason")
    func jsonRoundTrip() throws {
        let providers = [
            makeEntry(
                "openai",
                name: "OpenAI",
                aliases: ["开放人工智能"],
                kind: .openAI,
                defaultProtocol: .openAIResponses,
                baseURL: "https://api.openai.com/v1",
                domains: ["api.openai.com"],
                models: ["gpt-5.6"]
            ),
            makeEntry(
                "azure",
                name: "Azure OpenAI",
                kind: .custom,
                baseURL: nil,
                domains: ["openai.azure.com"],
                availability: .unsupported,
                unsupportedReason: "requires a deployment-specific endpoint"
            )
        ]
        let document = makeDocument(providers)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ProviderCatalogDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.providers[1].baseURL == nil)
        #expect(decoded.providers[1].unsupportedReason == "requires a deployment-specific endpoint")
    }

    @Test("Checked-in ProviderCatalog.json parses when the checkout provides it")
    func bundledCatalogFileLoads() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = packageRoot.appendingPathComponent("FloeApp/Resources/ProviderCatalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            // Volume/worktree checkouts may omit the app target resource; the
            // integration build covers the bundled path instead.
            try Test.cancel("ProviderCatalog.json not present in this checkout")
        }
        let index = try ProviderCatalogIndex.validated(from: Data(contentsOf: catalogURL))
        #expect(index.document.schemaVersion == 1)
        #expect(index.document.source.project == "models.dev")
        #expect(index.document.source.license == "MIT")
        #expect(index.document.source.documentSHA256.count == 64)
        #expect(index.all.count >= 10)
        for entry in index.all {
            #expect(entry.models == entry.models.sorted(), "\(entry.presetID) model list must be sorted")
            if entry.availability == .available {
                #expect(entry.baseURL != nil, "\(entry.presetID) must expose a base URL")
                #expect(entry.unsupportedReason == nil)
            }
        }
        #expect(index.all.first { $0.presetID == "openai" }?.kind == .openAI)
        #expect(index.search(query: "深度求索", filter: .all, configuredPresetIDs: []).first?.presetID == "deepseek")
        #expect(index.search(query: "硅基流动", filter: .all, configuredPresetIDs: []).first?.presetID == "siliconflow")
    }
}

@Suite("FloeProviders.ProviderCatalogValidation")
struct ProviderCatalogValidationTests {

    private func validDocument(providers: [ProviderCatalogEntry]? = nil) -> ProviderCatalogDocument {
        makeDocument(providers ?? [
            makeEntry(
                "openai",
                name: "OpenAI",
                aliases: ["开放人工智能"],
                kind: .openAI,
                defaultProtocol: .openAIResponses,
                baseURL: "https://api.openai.com/v1",
                domains: ["api.openai.com"],
                models: ["gpt-5"]
            )
        ])
    }

    private func expectRejection(
        _ document: ProviderCatalogDocument,
        containing token: String
    ) throws {
        let data = try JSONEncoder().encode(document)
        do {
            _ = try ProviderCatalogIndex.validated(from: data)
            Issue.record("expected rejection containing '\(token)'")
        } catch let error as ProviderCatalogValidationError {
            #expect(error.message.contains(token), "\(error.message)")
        }
    }

    @Test("Minimal valid document is accepted")
    func validDocumentAccepted() throws {
        let index = try ProviderCatalogIndex.validated(from: JSONEncoder().encode(validDocument()))
        #expect(index.all.map(\.presetID) == ["openai"])
    }

    @Test("Rejects bad schema, counts and source metadata")
    func structuralRejections() throws {
        var document = validDocument()
        document.schemaVersion = 2
        try expectRejection(document, containing: "schemaVersion")

        document = validDocument()
        document.providers = []
        try expectRejection(document, containing: "1...256")

        document = validDocument()
        document.providers = Array(repeating: makeEntry("openai", name: "OpenAI"), count: 257)
        try expectRejection(document, containing: "1...256")

        document = validDocument()
        document.source.project = " "
        try expectRejection(document, containing: "source.project")

        document = validDocument()
        document.source.license = ""
        try expectRejection(document, containing: "source.license")
    }

    @Test("Rejects duplicate and malformed presetIDs")
    func presetIDRejections() throws {
        var document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI"),
            makeEntry("openai", name: "OpenAI duplicate")
        ]
        try expectRejection(document, containing: "duplicate presetID")

        document = validDocument()
        document.providers = [makeEntry("OpenAI", name: "OpenAI")]
        try expectRejection(document, containing: "invalid presetID")

        document = validDocument()
        document.providers = [makeEntry("_openai", name: "OpenAI")]
        try expectRejection(document, containing: "invalid presetID")
    }

    @Test("Rejects reason/availability mismatches")
    func availabilityRejections() throws {
        var document = validDocument()
        document.providers = [
            makeEntry(
                "blocked",
                name: "Blocked",
                baseURL: nil,
                availability: .unsupported,
                unsupportedReason: nil
            )
        ]
        try expectRejection(document, containing: "requires a reason")

        document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", unsupportedReason: "why")]
        try expectRejection(document, containing: "must not carry")
    }

    @Test("Rejects auth styles outside the compatibility table")
    func authRejections() throws {
        var document = validDocument()
        document.providers = [
            makeEntry(
                "claude",
                name: "Anthropic",
                defaultProtocol: .anthropicMessages,
                authStyle: "bearer"
            )
        ]
        try expectRejection(document, containing: "apiKeyHeader")

        document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", authStyle: "none")]
        try expectRejection(document, containing: "bearer or apiKeyHeader")

        document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", authStyle: "oauth")]
        try expectRejection(document, containing: "unknown authStyle")

        document = validDocument()
        document.providers = [
            makeEntry("ondevice", name: "On-device", kind: .local, authStyle: "bearer")
        ]
        try expectRejection(document, containing: "local kind requires authStyle none")
    }

    @Test("Unsupported providers may carry descriptive non-activatable auth metadata")
    func unsupportedAuthMetadataAccepted() throws {
        var document = validDocument()
        document.providers = [
            makeEntry(
                "amazon-bedrock",
                name: "Amazon Bedrock",
                baseURL: nil,
                availability: .unsupported,
                unsupportedReason: "requires AWS SigV4 request signing",
                authStyle: "none"
            )
        ]
        let index = try ProviderCatalogIndex.validated(from: JSONEncoder().encode(document))
        #expect(index.all.first?.authStyle == "none")
    }

    @Test("Rejects kind/protocol mismatches")
    func kindProtocolRejections() throws {
        var document = validDocument()
        document.providers = [
            makeEntry(
                "claude",
                name: "Anthropic",
                kind: .anthropic,
                defaultProtocol: .openAIChatCompletions
            )
        ]
        try expectRejection(document, containing: "anthropic kind requires anthropicMessages")

        document = validDocument()
        document.providers = [
            makeEntry(
                "google",
                name: "Google",
                kind: .googleGemini,
                defaultProtocol: .anthropicMessages
            )
        ]
        try expectRejection(document, containing: "googleGemini kind requires openAIChatCompletions")

        for kind in [ProviderKind.volcengineArk, .openAI] {
            document = validDocument()
            document.providers = [
                makeEntry("ark", name: "Ark", kind: kind, defaultProtocol: .anthropicMessages)
            ]
            try expectRejection(document, containing: "requires an OpenAI protocol")
        }
    }

    @Test("Rejects unsafe available base URLs")
    func baseURLRejections() throws {
        var document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", baseURL: nil)]
        try expectRejection(document, containing: "requires a baseURL")

        let cases: [(String, String)] = [
            ("http://api.example.com/v1", "must be https"),
            ("https:///v1", "must have a host"),
            ("https://user:pass@api.example.com/v1", "must not carry"),
            ("https://api.example.com:8443/v1", "must not carry"),
            ("https://api.example.com/v1?x=1", "must not carry"),
            ("https://api.example.com/v1#frag", "must not carry")
        ]
        for (baseURL, token) in cases {
            document = validDocument()
            document.providers = [makeEntry("openai", name: "OpenAI", baseURL: baseURL)]
            try expectRejection(document, containing: token)
        }

        let longURL = "https://api.example.com/" + String(repeating: "a", count: 490)
        document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", baseURL: longURL)]
        try expectRejection(document, containing: "exceeds 512")
    }

    @Test("Rejects oversized aliases, domains, models and names")
    func boundsRejections() throws {
        var document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI", aliases: (0...16).map { "alias-\($0)" })
        ]
        try expectRejection(document, containing: "more than 16 aliases")

        document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI", aliases: [String(repeating: "a", count: 65)])
        ]
        try expectRejection(document, containing: "alias must be 1...64")

        document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI", domains: (0...16).map { "\($0).example.com" })
        ]
        try expectRejection(document, containing: "more than 16 domains")

        document = validDocument()
        document.providers = [makeEntry("openai", name: "OpenAI", domains: ["api_example.com"])]
        try expectRejection(document, containing: "invalid domain")

        document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI", domains: [String(repeating: "a", count: 254)])
        ]
        try expectRejection(document, containing: "invalid domain")

        document = validDocument()
        document.providers = [
            makeEntry("openai", name: "OpenAI", models: (0...200).map { "model-\($0)" })
        ]
        try expectRejection(document, containing: "more than 200 models")

        for models in [[String(repeating: "m", count: 257)], ["gpt 5"], [""]] {
            document = validDocument()
            document.providers = [makeEntry("openai", name: "OpenAI", models: models)]
            try expectRejection(document, containing: "invalid model identifier")
        }

        document = validDocument()
        document.providers = [makeEntry("openai", name: String(repeating: "n", count: 129))]
        try expectRejection(document, containing: "name must be 1...128")
    }

    @Test("Rejects oversized payloads before decoding")
    func oversizedPayloadRejected() {
        let data = Data(count: ProviderCatalogIndex.maximumDocumentBytes + 1)
        do {
            _ = try ProviderCatalogIndex.validated(from: data)
            Issue.record("expected oversized payload rejection")
        } catch let error as ProviderCatalogValidationError {
            #expect(error.message.contains("maximum"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("Rejects unknown kind, protocol and availability raw values")
    func unknownRawValuesRejected() throws {
        for (key, value) in [("kind", "bogus"), ("defaultProtocol", "bogus"), ("availability", "maybe")] {
            let data = try JSONEncoder().encode(validDocument())
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var providers = try #require(object["providers"] as? [[String: Any]])
            providers[0][key] = value
            object["providers"] = providers
            let mutated = try JSONSerialization.data(withJSONObject: object)
            do {
                _ = try ProviderCatalogIndex.validated(from: mutated)
                Issue.record("expected rejection for \(key)")
            } catch let error as ProviderCatalogValidationError {
                #expect(error.message.contains("malformed"), "\(error.message)")
            } catch {
                Issue.record("unexpected error type \(type(of: error))")
            }
        }
    }
}

@Suite("FloeProviders.ProviderProfilePresetID")
struct ProviderProfilePresetIDTests {

    private func profile(presetID: String?) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!,
            presetID: presetID
        )
    }

    @Test("presetID survives a Codable round trip")
    func presetIDRoundTrip() throws {
        let original = profile(presetID: "deepseek")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
        #expect(decoded.presetID == "deepseek")
        #expect(decoded == original)
    }

    @Test("Nil presetID encodes without the key and decodes as nil")
    func nilPresetIDOmitsKey() throws {
        let data = try JSONEncoder().encode(profile(presetID: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["presetID"] == nil)
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
        #expect(decoded.presetID == nil)
    }

    @Test("JSON written before presetID existed still decodes")
    func legacyJSONDecodesNil() throws {
        let data = try JSONEncoder().encode(profile(presetID: "deepseek"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "presetID")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: legacy)
        #expect(decoded.presetID == nil)
    }
}
