// SPDX-License-Identifier: MPL-2.0
#if FLOE_MAC_HOST_SMOKE
import Foundation
import FloeCore
import FloeTools

/// Uses a throwaway preferences domain and RAM-only keys. Network checks are explicit.
enum MacSearchSmoke {
    @MainActor
    static func verify(catalog: SearchProviderCatalogIndex? = SearchProviderCatalogIndex.loadBundled(),
                       discover: (MacSearchAccess) throws -> Bool,
                       liveProviderError: Bool = false) async throws -> [String: Bool] {
        let suite = "org.floeagent.fixture.search." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite),
              let catalog, let brave = catalog.entry(presetID: "brave"),
              var draft = SearchProviderDraftFactory.draftInstance(for: brave, localePrimary: "en") else {
            throw FloeError.validationFailed("Search fixture catalog is unavailable.")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = MacSearchAccess(namespace: suite, useKeychain: false, preferences: defaults)
        var checks: [String: Bool] = [:]
        checks["hiddenBeforeConfiguration"] = try !discover(access)
        do {
            try access.save(draft, fields: [:], isNew: true)
            checks["missingKeyRejected"] = false
        } catch { checks["missingKeyRejected"] = try access.instances().isEmpty }
        try access.save(draft, fields: ["apiKey": MacSearchFixtureProtocol.fixtureKey], isNew: true)
        checks["disabledDraftHidden"] = try !discover(access)
        try access.change(draft.id, enable: true)
        checks["enabledDiscoverable"] = try discover(access)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: UUID())
        let tool = MacSearchTool(service: access.fixtureService(protocolClass: MacSearchFixtureProtocol.self))
        let query = Data(#"{"query":"Swift public test","maxResults":2}"#.utf8)
        let output = try await tool.run(argumentsJSON: query, context: context)
        let page = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        let rows = page?["results"] as? [[String: Any]]
        checks["realProviderContractAndMetadata"] = rows?.first?["title"] as? String == "Swift"
            && rows?.first?["url"] as? String == "https://www.swift.org/"
            && rows?.first?["contentState"] as? String == "searchMetadataOnly"
            && rows?.count == 1 && !output.summary.contains(MacSearchFixtureProtocol.fixtureKey)
        do {
            _ = try await tool.run(argumentsJSON: Data(#"{"query":"Swift","source":"professional"}"#.utf8), context: context)
            checks["professionalSourceRejected"] = false
        } catch { checks["professionalSourceRejected"] = true }
        checks["delegatedSearchAuthority"] = try await verifyDelegated(tool: tool, context: context, query: query)
        do {
            _ = try await tool.run(argumentsJSON: Data(#"{"query":"oversize fixture"}"#.utf8), context: context)
            checks["oversizeRejected"] = false
        } catch { checks["oversizeRejected"] = error.localizedDescription.contains("download limit") }
        let secret = "test/key!"
        let escaped = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let redacted = WebSearchService.redact("failure: " + secret + " " + escaped, credential: .init(values: ["apiKey": secret]))
        checks["secretErrorRedacted"] = !redacted.contains(secret) && !redacted.contains(escaped)
        if liveProviderError {
            let outcome = try await access.test(draft, fields: [:], query: "Swift programming language")
            // Use an explicitly selected official service and deliberately invalid fixture key.
            let status = [401, 403, 422].first { outcome.error?.contains("HTTP " + String($0)) == true }
            checks["liveProviderRejectedFixtureKey"] = outcome.results.isEmpty && status != nil
                && outcome.error?.contains(MacSearchFixtureProtocol.fixtureKey) == false
            if let status { checks["liveProviderHTTP" + String(status)] = true }
        }
        // Settings edit with blank secure fields preserves the key and shared metadata format.
        draft.configuration.enabled = true
        draft.configuration.displayName = "Work Search"
        try access.save(draft, fields: [:], isNew: false)
        let key = suite + "." + WebSearchInstanceStore.instancesKey
        let bytes = defaults.data(forKey: key) ?? Data()
        let persisted = try JSONDecoder().decode([WebSearchProviderInstance].self, from: bytes)
        checks["sharedRecordNoPlaintextKey"] = persisted.first?.configuration.displayName == "Work Search"
            && bytes.range(of: Data(MacSearchFixtureProtocol.fixtureKey.utf8)) == nil && access.isConfigured
        try access.change(draft.id, enable: false)
        checks["hiddenAfterDisable"] = try !discover(access)
        do {
            _ = try await tool.run(argumentsJSON: query, context: context)
            checks["staleBindingRevoked"] = false
        } catch WebRetrievalError.noProviderConfigured { checks["staleBindingRevoked"] = true }
        try access.change(draft.id, remove: true)
        checks["removed"] = try access.instances().isEmpty && !discover(access)
        let publicEntries = catalog.entries.filter { MacSearchAccess.supported($0.supportedAdapter) }
        for entry in publicEntries {
            guard var account = SearchProviderDraftFactory.draftInstance(for: entry, localePrimary: "en") else {
                throw FloeError.validationFailed("Invalid search catalog preset.")
            }
            let fields = Dictionary(uniqueKeysWithValues: entry.credentialFields.map { ($0.key, MacSearchFixtureProtocol.fixtureKey) })
            account.configuration.enabled = true
            try access.save(account, fields: fields, isNew: true)
            let ready = try discover(access)
            try access.change(account.id, remove: true)
            checks["officialPreset." + entry.presetID] = ready
        }
        return checks
    }
    static func childFixture(context: ToolContext, descriptor: ToolCatalog.Descriptor, callID: String) -> ToolContext {
        var child = context
        let taskID = context.conversationID!
        let id = ChildExecutionIdentity(parentRunID: context.runID, rootTaskID: taskID, delegateCallID: "delegate")
        let dispatcher = ChildToolDispatcher(descriptorProvider: { $0 == descriptor.name ? descriptor : nil },
            allDescriptors: { [descriptor] }, dispatch: { _, _ in preconditionFailure("Fixture dispatch is not a tool executor") })
        let peers = PeerCollaborationHandle(register: { _ in }, unregister: {}, drain: { [] }, peers: { _ in [] },
                                            send: { _, _, _ in .init(accepted: false, messageID: nil) })
        child.toolCallID = callID
        child.allowedToolNames = [descriptor.name]
        child.approvalGrantID = UUID()
        child.childExecution = .init(identity: id, dispatcher: dispatcher, peers: peers)
        child.callOrigin = .init(kind: .delegatedChild, runID: child.runID, callID: callID,
                                 toolName: descriptor.name, childID: id.childID, rootTaskID: taskID)
        return child
    }

    private static func verifyDelegated(tool: MacSearchTool, context: ToolContext, query: Data) async throws -> Bool {
        let child = childFixture(context: context, descriptor: MacSearchTool.descriptor, callID: "child-search")
        _ = try await tool.run(argumentsJSON: query, context: child)
        var mismatched = child
        mismatched.toolCallID = "different"
        do { _ = try await tool.run(argumentsJSON: query, context: mismatched); return false } catch {}
        mismatched = child
        mismatched.childExecution = nil
        do { _ = try await tool.run(argumentsJSON: query, context: mismatched); return false } catch {}
        mismatched = child
        mismatched.approvalGrantID = nil
        do { _ = try await tool.run(argumentsJSON: query, context: mismatched); return false } catch {}
        return true
    }
}

private final class MacSearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixtureKey = "invalid-floe-search-fixture"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "api.search.brave.com",
              url.path == "/res/v1/web/search", request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "X-Subscription-Token") == Self.fixtureKey,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
              ["oversize fixture", "Swift public test"].contains(query),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: query == "oversize fixture" ? ["Content-Length": String(WebSearchService.maximumResponseBytes + 1)] : ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"web":{"results":[{"title":"Swift","url":"https://www.swift.org/","description":"Swift language."}]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
