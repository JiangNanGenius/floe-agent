// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeSecurity
import FloeTools

/// Secret-free iPad instance records and device-only keys, isolated to this Mac profile.
public final class MacSearchAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let namespace: String
    private let preferences: UserDefaults
    private let useKeychain: Bool
    private var memoryKeys: [String: Data] = [:]

    init(namespace: String, useKeychain: Bool, preferences: UserDefaults) {
        self.namespace = namespace
        self.useKeychain = useKeychain
        self.preferences = preferences
    }

    static func supported(_ kind: WebSearchProviderKind?) -> Bool {
        switch kind {
        case .brave, .tavily, .exa, .bochaWeb, .tencentWSA, .googleProgrammable, .deepseek, .volcengine, .moonshot: true
        default: false
        }
    }

    private var instancesKey: String { namespace + "." + WebSearchInstanceStore.instancesKey }
    private func records() throws -> [WebSearchProviderInstance] {
        guard let data = preferences.data(forKey: instancesKey) else { return [] }
        return try JSONDecoder().decode([WebSearchProviderInstance].self, from: data)
    }

    func instances() throws -> [WebSearchProviderInstance] { try lock.withLock { try records() } }

    private func vault(_ config: WebSearchProviderConfiguration) -> KeychainStore {
        KeychainStore(service: namespace + ".web-search." + config.kind.rawValue, synchronizable: false,
                      accessibility: .whenUnlockedThisDeviceOnly)
    }
    private func credential(_ config: WebSearchProviderConfiguration) throws -> WebSearchCredential {
        let bytes: Data
        if useKeychain { bytes = try vault(config).read(account: config.credentialAccount) }
        else if let data = memoryKeys[config.credentialAccount] { bytes = data }
        else { throw KeychainStoreError.itemNotFound }
        return try JSONDecoder().decode(WebSearchCredential.self, from: bytes)
    }
    private func store(_ key: WebSearchCredential, for config: WebSearchProviderConfiguration) throws {
        let bytes = try JSONEncoder().encode(key)
        if useKeychain { try vault(config).store(account: config.credentialAccount, secret: bytes) }
        else { memoryKeys[config.credentialAccount] = bytes }
    }
    /// A credential can only be used with the instance, channel and compiled origin that own it.
    static func account(_ config: WebSearchProviderConfiguration) throws -> String {
        guard supported(config.kind), config.endpoint == nil else {
            throw FloeError.validationFailed("Choose a built-in public search provider.")
        }
        if config.kind == .moonshot {
            return try MoonshotSearchOptions(options: config.options).credentialAccount(providerID: config.id)
        }
        if config.kind == .volcengine {
            guard let channel = try VolcengineSearchOptions(options: config.options).interface else {
                throw FloeError.validationFailed("Choose a Volcengine search interface.")
            }
            return "web-search.volcengine.\(config.id.uuidString.lowercased()).\(channel.rawValue)"
        }
        return WebSearchProviderInstance.credentialAccount(for: config.id)
    }

    private func active() -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        lock.withLock {
            ((try? records()) ?? []).compactMap { instance in
                let c = instance.configuration
                guard c.enabled, (try? Self.account(c)) == c.credentialAccount,
                      let key = try? credential(c), WebSearchService.isConfigured(c, credential: key) else { return nil }
                return (c, key)
            }
        }
    }
    public var isConfigured: Bool { !active().isEmpty }
    private static func transport() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 120
        return config
    }
    func service() -> WebSearchService {
        WebSearchService(configuration: Self.transport(), configurations: { [self] in active() })
    }

    #if FLOE_MAC_HOST_SMOKE
    func fixtureService(protocolClass: URLProtocol.Type) -> WebSearchService {
        let config = Self.transport()
        config.protocolClasses = [protocolClass]
        return WebSearchService(configuration: config, configurations: { [self] in active() }, validateDestination: { url, _ in
            guard url.scheme == "https", url.host == "api.search.brave.com" else { throw URLError(.unsupportedURL) }
        })
    }
    #endif

    private func prepared(_ instance: WebSearchProviderInstance, fields: [String: String],
                          existing: WebSearchProviderInstance?) throws -> (WebSearchProviderInstance, WebSearchCredential) {
        var result = instance
        var c = result.configuration
        if c.kind == .bochaWeb { c.options["summaryEnabled"] = "false" }
        c.displayName = c.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.displayName.isEmpty, c.displayName.count <= 100 else { throw FloeError.validationFailed("Enter a provider name (1–100 characters).") }
        c.credentialAccount = try Self.account(c)
        var key = WebSearchCredential(values: [:])
        if let old = existing?.configuration {
            guard old.kind == c.kind, old.credentialAccount == c.credentialAccount else {
                throw FloeError.validationFailed("Add a separate account for this provider or billing channel.")
            }
            // Failing to read an existing key must never silently replace it.
            do { key = try credential(old) } catch KeychainStoreError.itemNotFound { /* All required fields must be re-entered. */ }
        }
        for (name, value) in fields {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { key.values[name] = text }
        }
        if c.kind == .moonshot { key.values["moonshotChannel"] = try MoonshotSearchOptions(options: c.options).channel.rawValue }
        var check = c
        check.enabled = true
        guard WebSearchService.isConfigured(check, credential: key) else {
            throw FloeError.validationFailed(Locale.current.language.languageCode?.identifier == "zh" ? "请填写搜索供应商所需的密钥。" : "Enter the required search credentials.")
        }
        result.configuration = c
        return (result, key)
    }

    func save(_ instance: WebSearchProviderInstance, fields: [String: String], isNew: Bool) throws {
        try lock.withLock {
            var rows = try records()
            let pos = rows.firstIndex { $0.id == instance.id }
            guard isNew == (pos == nil) else { throw FloeError.validationFailed("Reopen the search provider and try again.") }
            let (prepared, key) = try prepared(instance, fields: fields, existing: pos.map { rows[$0] })
            var row = prepared
            row.configuration.priority = pos ?? rows.count
            if let pos { rows[pos] = row } else { rows.append(row) }
            let bytes = try JSONEncoder().encode(rows)
            try store(key, for: row.configuration)
            preferences.set(bytes, forKey: instancesKey)
        }
    }

    func test(_ instance: WebSearchProviderInstance, fields: [String: String], query: String) async throws -> WebSearchTestOutcome {
        let (row, key) = try lock.withLock {
            try prepared(instance, fields: fields, existing: records().first { $0.id == instance.id })
        }
        var c = row.configuration
        c.enabled = true
        let selected = c
        let service = WebSearchService(configuration: Self.transport(), configurations: { [(selected, key)] })
        return await service.testSearch(configuration: selected, credential: key, text: query)
    }

    func change(_ id: UUID, enable: Bool? = nil, moveUp: Bool = false, remove: Bool = false) throws {
        try lock.withLock {
            var rows = try records()
            guard let i = rows.firstIndex(where: { $0.id == id }) else { throw FloeError.validationFailed("The search provider was removed.") }
            let c = rows[i].configuration
            if let enable { rows[i].configuration.enabled = enable }
            if moveUp, i > 0 { rows.swapAt(i, i - 1) }
            if remove { rows.remove(at: i) }
            for index in rows.indices { rows[index].configuration.priority = index }
            let bytes = try JSONEncoder().encode(rows)
            if remove {
                guard (try? Self.account(c)) == c.credentialAccount else { throw FloeError.validationFailed("Invalid credential account.") }
                if useKeychain { try vault(c).delete(account: c.credentialAccount) }
                else { memoryKeys.removeValue(forKey: c.credentialAccount) }
            }
            preferences.set(bytes, forKey: instancesKey)
        }
    }
}

/// A delegated call must have passed the same parent dispatcher and approval
/// path as the main run. The identity, scope and call ID come from ToolContext.
enum MacTaskWebAccess {
    static func validate(_ descriptor: ToolCatalog.Descriptor, context: ToolContext) throws {
        let failure = FloeError.validationFailed("Web access requires the current task's authorized call.")
        guard case .local = context.scope, let taskID = context.conversationID,
              context.allowedToolNames?.contains(descriptor.name) != false else { throw failure }
        if let handoff = context.childExecution {
            let identity = handoff.identity
            guard let origin = context.callOrigin, origin.kind == .delegatedChild,
                  context.approvalGrantID != nil, identity.depth == 1,
                  identity.parentRunID == context.runID, identity.rootTaskID == taskID,
                  origin.childID == identity.childID, origin.rootTaskID == identity.rootTaskID,
                  origin.runID == context.runID, origin.callID == context.toolCallID,
                  origin.callID != identity.delegateCallID, origin.toolName == descriptor.name,
                  handoff.dispatcher.descriptor(named: descriptor.name)?.authorizationIdentity == descriptor.authorizationIdentity
            else { throw failure }
        } else if let origin = context.callOrigin {
            guard origin.childID == nil, origin.rootTaskID == nil,
                  origin.authorizesMainOnlyCapability(toolName: descriptor.name, runID: context.runID, callID: context.toolCallID)
            else { throw failure }
        } else if context.childBudget != nil { throw failure }
    }
}

struct MacSearchTool: AgentTool, MacAgentWorkspaceExecutable {
    typealias Arguments = WebSearchTool.Arguments
    static let name = WebSearchTool.name
    static let riskLabels = WebSearchTool.riskLabels
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    static let executionBoundary = WebSearchTool.executionBoundary
    static let toolDescription = "Search the public web using the user's enabled search providers. Results contain untrusted search-index metadata. Use web.fetch to verify page contents."
    static let parametersJSON = #"""
    {"type":"object","properties":{"query":{"type":"string"},"mode":{"type":"string","enum":["fast","balanced","deep"]},"domains":{"type":"array","items":{"type":"string"}},"excludeDomains":{"type":"array","items":{"type":"string"}},"recencyDays":{"type":"integer","minimum":1,"maximum":1825},"maxResults":{"type":"integer","minimum":1,"maximum":50},"provider":{"type":"string","description":"Configured provider name, kind or UUID"},"source":{"type":"string","enum":["web"]}},"required":["query"],"additionalProperties":false}
    """#
    private let tool: WebSearchTool

    init(access: MacSearchAccess) { tool = WebSearchTool(service: access.service()) }
    #if FLOE_MAC_HOST_SMOKE
    init(service: WebSearchService) { tool = WebSearchTool(service: service) }
    #endif

    func validate(_ args: Arguments) throws {
        guard args.source == nil || args.source == "web", args.dataset == nil,
              (1...1825).contains(args.recencyDays ?? 1) else { throw FloeError.validationFailed("Use public web search parameters.") }
        try tool.validate(args)
    }
    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        guard argumentsJSON.count <= 16_384,
              let fields = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
              Set(fields.keys).isSubset(of: ["query","mode","domains","excludeDomains","recencyDays","maxResults","provider","source"]) else {
            throw FloeError.validationFailed("Use public web search parameters.")
        }
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        try validate(arguments)
        return try await execute(arguments, context: context)
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try MacTaskWebAccess.validate(Self.descriptor, context: context)
        let result = try await tool.execute(args, context: context)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        return result
    }
}
