// FloeTools — frozen authority for the native professional web.search source.
// Owned DataPro adapters accept one exact query; owned Kimi Code adapters
// accept the bounded description/query type. Neither exposes a second tool
// name or a model-supplied HTTP configuration.

import Foundation
import FloeCore

public enum ProfessionalSearchAuthority {
    public static let unifiedToolName = "web.search"

    /// One exact account registration. A replacement of the same server ID gets
    /// a new generation, so a run frozen before replacement cannot inherit it.
    public enum SourceKind: String, Sendable, Hashable { case dataPro, kimiCode }

    public struct Account: Sendable, Hashable, Identifiable {
        public var id: UUID { serverID }
        public let serverID: UUID
        public let displayName: String
        public let registrationGeneration: UInt64
        public let sourceKind: SourceKind

        public init(
            serverID: UUID,
            displayName: String,
            registrationGeneration: UInt64 = 1,
            sourceKind: SourceKind = .dataPro
        ) {
            self.serverID = serverID
            self.displayName = displayName
            self.registrationGeneration = registrationGeneration
            self.sourceKind = sourceKind
        }
    }

    /// Run-frozen, secret-free account authority. The registry is retained so
    /// its scoped registration state cannot be deallocated/reused mid-run.
    /// Accounts are captured at launch; later registrations never join this
    /// snapshot. Children receive this value only through canonical dispatch.
    public struct Frozen: Sendable {
        fileprivate let registry: ToolRunnerRegistry
        fileprivate let registryEpoch: UUID
        public let allowsProfessionalSource: Bool
        public let accounts: [Account]

        fileprivate init(
            registry: ToolRunnerRegistry,
            registryEpoch: UUID,
            allowsProfessionalSource: Bool,
            accounts: [Account]
        ) {
            self.registry = registry
            self.registryEpoch = registryEpoch
            self.allowsProfessionalSource = allowsProfessionalSource
            self.accounts = accounts
        }

        public func isBound(to registry: ToolRunnerRegistry) -> Bool {
            self.registry === registry
        }

        public func account(id: UUID) -> Account? {
            accounts.first { $0.serverID == id }
        }

        fileprivate func isSameAuthority(as other: Frozen) -> Bool {
            isBound(to: other.registry)
                && registryEpoch == other.registryEpoch
                && allowsProfessionalSource == other.allowsProfessionalSource
                && accounts == other.accounts
        }
    }

    /// The sole payload crossing into the private adapter is constructed by
    /// `execute` from a validated string. This is not a model-supplied remote
    /// method/JSON channel and cannot be registered as a callable tool name.
    public typealias Runner = @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput

    private struct Entry: Sendable {
        var account: Account
        var runner: Runner
    }

    /// Swift 6 ownership note: every mutable access is inside Store.lock. The
    /// weak identity prevents one test/custom registry from sharing state with
    /// `.shared` or unregistering another registry's account. Pruning also
    /// prevents ObjectIdentifier reuse from resurrecting an old generation.
    private final class RegistryReference: @unchecked Sendable {
        weak var registry: ToolRunnerRegistry?
        init(_ registry: ToolRunnerRegistry) { self.registry = registry }
    }

    private struct State: Sendable {
        let reference: RegistryReference
        let epoch = UUID()
        var nextGeneration: UInt64 = 0
        var entries: [UUID: Entry] = [:]

        init(registry: ToolRunnerRegistry) {
            reference = RegistryReference(registry)
        }
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ObjectIdentifier: State] = [:]

        private func pruneLocked() {
            states = states.filter { $0.value.reference.registry != nil }
        }

        private func stateLocked(
            for registry: ToolRunnerRegistry,
            create: Bool
        ) -> State? {
            let key = ObjectIdentifier(registry)
            if let existing = states[key], existing.reference.registry === registry {
                return existing
            }
            guard create else { return nil }
            let created = State(registry: registry)
            states[key] = created
            return created
        }

        func accounts(registry: ToolRunnerRegistry) -> [Account] {
            lock.lock()
            defer { lock.unlock() }
            pruneLocked()
            guard let state = stateLocked(for: registry, create: false) else { return [] }
            return Self.sorted(state.entries.values.map(\.account))
        }

        func register(
            serverID: UUID,
            displayName: String,
            registry: ToolRunnerRegistry,
            runner: @escaping Runner,
            sourceKind: SourceKind = .dataPro
        ) -> Account {
            lock.lock()
            defer { lock.unlock() }
            pruneLocked()
            var state = stateLocked(for: registry, create: true)!
            state.nextGeneration &+= 1
            if state.nextGeneration == 0 { state.nextGeneration = 1 }
            let account = Account(
                serverID: serverID,
                displayName: displayName,
                registrationGeneration: state.nextGeneration,
                sourceKind: sourceKind
            )
            state.entries[serverID] = Entry(account: account, runner: runner)
            states[ObjectIdentifier(registry)] = state
            return account
        }

        func unregister(serverID: UUID, registry: ToolRunnerRegistry) {
            lock.lock()
            defer { lock.unlock() }
            pruneLocked()
            let key = ObjectIdentifier(registry)
            guard var state = stateLocked(for: registry, create: false) else { return }
            state.entries.removeValue(forKey: serverID)
            states[key] = state
        }

        func freeze(
            registry: ToolRunnerRegistry,
            allowsProfessionalSource: Bool
        ) -> Frozen {
            lock.lock()
            defer { lock.unlock() }
            pruneLocked()
            let state = stateLocked(for: registry, create: true)!
            return Frozen(
                registry: registry,
                registryEpoch: state.epoch,
                allowsProfessionalSource: allowsProfessionalSource,
                accounts: allowsProfessionalSource
                    ? Self.sorted(state.entries.values.map(\.account)) : []
            )
        }

        func entry(
            registry: ToolRunnerRegistry,
            epoch: UUID,
            accountID: UUID
        ) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            pruneLocked()
            guard let state = stateLocked(for: registry, create: false),
                  state.epoch == epoch else { return nil }
            return state.entries[accountID]
        }

        private static func sorted(_ accounts: [Account]) -> [Account] {
            accounts.sorted {
                $0.displayName == $1.displayName
                    ? $0.serverID.uuidString < $1.serverID.uuidString
                    : $0.displayName < $1.displayName
            }
        }
    }

    private static let store = Store()

    /// Live readiness is registry-scoped. Only the exact owned registration
    /// path below can make an account visible here; disabled, unowned or
    /// missing-method MCP configurations never reach this ledger.
    public static func registeredAccounts(
        registry: ToolRunnerRegistry = .shared
    ) -> [Account] {
        store.accounts(registry: registry)
    }

    /// Internal because ownership/readiness is established by
    /// MCPRemoteToolSource before this call. Tests use @testable fixtures.
    static func register(
        serverID: UUID,
        displayName: String,
        registry: ToolRunnerRegistry,
        runner: @escaping Runner
    ) -> Account {
        store.register(
            serverID: serverID,
            displayName: displayName,
            registry: registry,
            runner: runner
        )
    }

    /// Called only by Floe's owned Kimi Code provider path. No remote tool
    /// annotation can register a dataset account or select its transport.
    @discardableResult
    public static func registerKimiCode(
        providerID: UUID,
        displayName: String,
        registry: ToolRunnerRegistry = .shared,
        runner: @escaping @Sendable (ProfessionalDatasetRequest, ToolContext) async throws -> ToolExecutionOutput
    ) -> Account {
        store.register(serverID: providerID, displayName: displayName, registry: registry, runner: { data, context in
            let invocation = try JSONDecoder().decode(ProfessionalDatasetInvocation.self, from: data)
            try invocation.dataset.validate()
            return try await runner(invocation.dataset, context)
        }, sourceKind: .kimiCode)
    }

    public static func unregisterKimiCode(providerID: UUID, registry: ToolRunnerRegistry = .shared) {
        guard registeredAccounts(registry: registry).contains(where: {
            $0.serverID == providerID && $0.sourceKind == .kimiCode
        }) else { return }
        store.unregister(serverID: providerID, registry: registry)
    }

    static func unregister(serverID: UUID, registry: ToolRunnerRegistry) {
        store.unregister(serverID: serverID, registry: registry)
    }

    /// Captures account IDs and generations at run launch. `allowedToolNames`
    /// is the FINAL intersected task/skill/provider/route ceiling: an explicit
    /// allowlist without web.search never acquires professional authority.
    /// Passing allowsProfessionalSource=false preserves temporary/fast-chat,
    /// plan, Canvas, Notes, local-model and explicit task restrictions.
    public static func freeze(
        registry: ToolRunnerRegistry = .shared,
        allowedToolNames: Set<String>?,
        allowsProfessionalSource: Bool = true
    ) -> Frozen {
        let allowed = allowsProfessionalSource
            && (allowedToolNames?.contains(unifiedToolName) ?? true)
        return store.freeze(
            registry: registry,
            allowsProfessionalSource: allowed
        )
    }

    /// Exact selector recognition shared by restricted public-web policies.
    /// Unknown/case-varied values are left to WebSearchTool's validation and
    /// are never treated as authority-bearing remote metadata.
    public static func requestsProfessionalSource(argumentsJSON: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: argumentsJSON)
                as? [String: Any] else { return false }
        return object["source"] as? String == "professional"
    }

    /// Executes one native read through the same registered MCP client. The
    /// outer web.search descriptor remains readOnly/networkAccess and its
    /// authorization identity is untouched. Generic MCP runners stay on their
    /// existing mutating approval path; this is the intentionally reviewed,
    /// bounded native-query semantic change, not facade approval preservation.
    public static func execute(
        registry: ToolRunnerRegistry,
        authority: Frozen,
        account: Account,
        query: String,
        dataset: ProfessionalDatasetRequest? = nil,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        guard authority.isBound(to: registry),
              context.professionalSearchAuthority?.isSameAuthority(as: authority) == true else {
            throw ProfessionalSearchAuthorityError.authorityMismatch
        }
        guard authority.allowsProfessionalSource,
              !context.publicWebOnly,
              !context.temporaryReadOnly,
              context.allowedToolNames?.contains(unifiedToolName) != false,
              context.frozenEffectiveCatalogNames?.contains(unifiedToolName) != false else {
            throw ProfessionalSearchAuthorityError.outsideToolCeiling
        }
        guard authority.accounts.contains(account) else {
            throw ProfessionalSearchAuthorityError.accountNotAuthorized
        }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 2_000 else {
            throw ProfessionalSearchAuthorityError.invalidQuery
        }
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard let entry = store.entry(
            registry: registry,
            epoch: authority.registryEpoch,
            accountID: account.serverID
        ), entry.account == account else {
            throw ProfessionalSearchAuthorityError.registrationChanged(account.displayName)
        }
        // Construct the adapter-specific payload after frozen authority checks.
        // DataPro stays query-only. Kimi gets only its validated fixed action.
        let arguments: Data
        switch account.sourceKind {
        case .dataPro:
            guard dataset == nil else {
                throw FloeError.validationFailed("DataPro accepts only query and provider, without dataset actions.")
            }
            arguments = try JSONSerialization.data(withJSONObject: ["query": normalized], options: [.sortedKeys])
        case .kimiCode:
            guard let dataset else {
                throw FloeError.validationFailed("Kimi Code requires dataset.action describe or query and dataset.name; read the description before querying.")
            }
            try dataset.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            arguments = try encoder.encode(ProfessionalDatasetInvocation(query: normalized, dataset: dataset))
        }
        let output = try await entry.runner(arguments, context)
        // Unregister/replace invalidates a late result even though web.search's
        // outer descriptor/authorization identity stayed unchanged.
        guard store.entry(
            registry: registry,
            epoch: authority.registryEpoch,
            accountID: account.serverID
        )?.account == account else {
            throw ProfessionalSearchAuthorityError.registrationChanged(account.displayName)
        }
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        return output
    }
}

public enum ProfessionalSearchAuthorityError: Error, LocalizedError, Sendable {
    case authorityMismatch
    case outsideToolCeiling
    case accountNotAuthorized
    case registrationChanged(String)
    case invalidQuery

    public var errorDescription: String? {
        switch self {
        case .authorityMismatch:
            return "Professional search authority does not match this run's frozen registry."
        case .outsideToolCeiling:
            return "Professional search is outside this task's tool ceiling."
        case .accountNotAuthorized:
            return "This professional dataset account was not authorized when the run started."
        case .registrationChanged(let name):
            return "Professional dataset account changed or was removed during this run: \(name). Start a new run to use the current registration."
        case .invalidQuery:
            return "Professional search query must contain 1-2000 UTF-8 bytes."
        }
    }
}
