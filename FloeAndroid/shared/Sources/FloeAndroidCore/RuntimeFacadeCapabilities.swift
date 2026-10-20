// SPDX-License-Identifier: MPL-2.0
//
// RB-6 capabilities domain — REAL usable-tool discovery behind the frozen
// `capability.tools.list` rule. (private source candidate; NOT compiled, NOT
// executed, NOT registered by this package.)
//
// Composition (exact reviewed originals; no second sources of truth):
// * ToolRunnerRegistry.shared.allDescriptors — availability-filtered RUNTIME
//   truth (the registry's own isAvailable() closures; descriptor-only
//   advertising is impossible because unavailable runners return nil from
//   runner(named:)). RetiredExecutionTools remain dropped by the registry
//   (ToolCatalog.swift:8-14); this package never re-adds exec.localPython /
//   exec.javascript / exec.compatEvaluator / exec.wasm / python.packages /
//   wasm.packages and never exposes language-specific exec aliases.
// * CapabilityExecutionRouter.decision(for:) — the ORIGINAL backend routing
//   table (nativeApple/linuxGuest/remoteHost). On G02 Android the
//   linuxGuest and remoteHost backends are UNRESOLVED (no G03
//   environments/jobs), so tools routed there are projected NOT_IMPLEMENTED
//   with the typed reason — never offered as usable, and never silently
//   deleted from inventory (the capability definition is retained per the
//   contract's "keep declared and typed unavailable until the real backend"
//   rule).
// * TemporaryChatToolPolicy — the CURRENT upstream-main ceiling
//   (origin/main 603b6826…, sha 3479a0a1…, Main manifest
//   main-upstream-child-temporary-20261019): a CLOSED public-web-only set
//   (web.search/web.searchAI/web.fetch) enforced on descriptor visibility
//   AND every execution/child/tool invocation path. The exact upstream body
//   ships in this candidate as the provenance-pinned REGULAR mirror
//   (candidate/FloeAndroid/shared/Sources/FloeTools/
//   TemporaryChatToolPolicy.swift) so the overlay stops resolving the stale
//   permissive root symlink when Main serializes publication. The old broad
//   personal/authenticated read-only behavior is NOT reused anywhere.
// * ModelProfile.explicitCapabilities / ModelConfigurationStore — SAVED
//   model capability overrides are authoritative (the tools bit gates the
//   model-scoped projection; an explicit decision is never "repaired" by
//   discovery), read through the ORIGINAL store.
// * Web-search availability for the provider-backed names consumes the RB2
//   resolver facts through a typed port — the native websearch resolver
//   stays SHARED (no duplicate default provider or routing); unbound ⇒
//   honest needsConfiguration.
// * MCP overlay facts come from the MCPDomain through a typed observer,
//   keyed by the ORIGINAL namespace prefix ("mcp_" + 10 lowercase uuid hex,
//   MCPServerConfiguration.namespacePrefix :60-61). A configured-but-
//   unconnected server's tools are NOT usable: they only enter the registry
//   after a valid discovery completes, and failure/disable/remove
//   unregisters them exactly like the original lifecycle.
//
// The availability vocabulary mirrors the accepted Kotlin contract
// (core/contracts RuntimeContracts.kt:13 — AVAILABLE, NEEDS_CONFIGURATION,
// NEEDS_PERMISSION, NOT_IMPLEMENTED, UNSUPPORTED) so RB7 projects without
// inventing states. No future Linux/root/phone/Play-absent capability is
// ever advertised usable; counts/names in this projection are ACTUAL
// registry/store readback only.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

// MARK: - Availability item

public struct FacadeToolAvailabilityItem: Sendable {
    public struct Prerequisite: Sendable {
        public let kind: String
        public let reason: String
        public init(kind: String, reason: String) {
            self.kind = kind
            self.reason = reason
        }
    }
    public let descriptor: ToolCatalog.Descriptor
    public let availability: FacadeCapabilityAvailability
    public let prerequisites: [Prerequisite]
    /// "native" | "mcp" (namespaced remote) — honest source class only.
    public let source: String
    public let temporaryCeilingIncluded: Bool

    public init(descriptor: ToolCatalog.Descriptor,
                availability: FacadeCapabilityAvailability,
                prerequisites: [Prerequisite],
                source: String,
                temporaryCeilingIncluded: Bool) {
        self.descriptor = descriptor
        self.availability = availability
        self.prerequisites = prerequisites
        self.source = source
        self.temporaryCeilingIncluded = temporaryCeilingIncluded
    }

    public func jsonObject() -> sending [String: Any] {
        var object: [String: Any] = [
            "name": descriptor.name,
            "description": String(descriptor.toolDescription.prefix(1_024)),
            "parametersSchemaBytes": descriptor.parametersJSON.utf8.count,
            "riskLabels": descriptor.riskLabels.map { $0.rawValue }.sorted(),
            "isSideEffecting": descriptor.isSideEffecting,
            "effect": descriptor.effect.rawValue,
            "executionBoundary": descriptor.executionBoundary.rawValue,
            "requiresHostScope": descriptor.requiresHostScope,
            "availability": availability.rawValue,
            "source": source,
            "inTemporaryCeiling": temporaryCeilingIncluded,
            // authorizationIdentity lets RB4/RB7 detect authority swaps
            // without shipping the full schema in every frame.
            "authorizationIdentity": descriptor.authorizationIdentity,
        ]
        if !prerequisites.isEmpty {
            object["prerequisites"] = prerequisites.map {
                ["kind": $0.kind, "reason": $0.reason]
            }
        }
        return object
    }
}

// MARK: - Availability ports (typed, honest-unbound)

/// Shared web-search availability (RB2 owns the resolver; this port feeds
/// the provider-backed web.search names into the projection). Unbound ⇒
/// NEEDS_CONFIGURATION, never a duplicate default provider.
public protocol CapabilitiesWebSearchProviding: Sendable {
    /// true only when an enabled+configured provider exists whose
    /// credential resolves (RB2 WebSearchProviderState semantics).
    func providerBackedSearchAvailable() async -> Bool
}

public struct CapabilitiesWebSearchUnbound: CapabilitiesWebSearchProviding {
    public init() {}
    public func providerBackedSearchAvailable() async -> Bool { false }
}

/// MCP overlay facts used by the resolver. The MCPDomain implements the
/// shape so the capabilities projection stays consistent with the
/// connection lifecycle (never a second store). Both sets are keyed by the
/// ORIGINAL registration prefix scheme ("mcp_" + 10 lowercase uuid hex),
/// which is how namespaced tool names are minted (MCPRemoteToolSource
/// .namespacedName + MCPServerConfiguration.namespacePrefix) — the observer
/// owns the authoritative prefix↔server mapping; the resolver only does
/// prefix matching.
public protocol CapabilitiesMCPObserving: Sendable {
    /// Connected server namespace prefixes (only servers whose discovery
    /// legitimately completed register tools today). Actor-isolated async:
    /// the authoritative connection track lives in the MCPDomain.
    func activeServerPrefixes() async -> Set<String>
    /// Prefixes of servers configured with an auth mode whose credential
    /// does not currently resolve (typed NEEDS_CONFIGURATION reason).
    func prefixesNeedingCredential() async -> Set<String>
}

public struct CapabilitiesMCPUnbound: CapabilitiesMCPObserving {
    public init() {}
    public func activeServerPrefixes() async -> Set<String> { [] }
    public func prefixesNeedingCredential() async -> Set<String> { [] }
}

// MARK: - CapabilitiesDomain

public actor CapabilitiesDomain {

    public enum CapabilitiesRefusal: Error, Sendable, Equatable {
        case runtimeNotReady
        case modelStoreUnbound
    }

    private let registry: ToolRunnerRegistry
    private let models: ModelConfigurationStore?
    private let webSearch: any CapabilitiesWebSearchProviding
    private let mcp: any CapabilitiesMCPObserving
    private let hostContext: any SkillsHostContextProviding

    public struct Services: Sendable {
        public let database: DatabaseManager
        public let webSearch: any CapabilitiesWebSearchProviding
        public let mcp: any CapabilitiesMCPObserving
        public let hostContext: any SkillsHostContextProviding
        public let registry: ToolRunnerRegistry
        public init(database: DatabaseManager,
                    webSearch: any CapabilitiesWebSearchProviding,
                    mcp: any CapabilitiesMCPObserving,
                    hostContext: any SkillsHostContextProviding,
                    registry: ToolRunnerRegistry = .shared) {
            self.database = database
            self.webSearch = webSearch
            self.mcp = mcp
            self.hostContext = hostContext
            self.registry = registry
        }
    }

    public init(services: Services) {
        self.registry = services.registry
        self.models = ModelConfigurationStore(database: services.database)
        self.webSearch = services.webSearch
        self.mcp = services.mcp
        self.hostContext = services.hostContext
    }

    // MARK: capability.tools.list

    /// The REAL usable view. `modelId` projects the saved-model override
    /// (explicit capabilities are authoritative); without it the device-
    /// level usable inventory is projected. Pages are stop-at-budget with
    /// nextCursor/hasMore; a single oversized row is a typed failure, never
    /// truncated. Schemas are referenced by size + authorizationIdentity
    /// only — the config frame never dumps unbounded schema arrays
    /// (progressive discovery owns full schema delivery inside the run
    /// channel; contract bounded-array rule).
    public func list(modelID: String?, includeUnavailable: Bool,
                     cursor: String?) async throws -> sending [String: Any] {
        _ = try requireBinding()
        let searchAvailable = await webSearch.providerBackedSearchAvailable()
        let activePrefixes = await mcp.activeServerPrefixes()
        let credentialMissingPrefixes = await mcp.prefixesNeedingCredential()
        let modelFilter: ModelFilter?
        if let raw = modelID {
            guard let uuid = UUID(uuidString: raw) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "modelIDShape")
            }
            guard let models else {
                throw CapabilitiesRefusal.modelStoreUnbound
            }
            guard let profile = try await models.model(id: uuid) else {
                throw ConfigDomainError(code: .notFound, reason: "modelRowMissing")
            }
            modelFilter = ModelFilter(explicit: profile.explicitCapabilities,
                                      catalog: profile.capabilities)
        } else {
            modelFilter = nil
        }
        var items: [FacadeToolAvailabilityItem] = []
        for descriptor in registry.allDescriptors {   // availability-filtered
            items.append(availability(for: descriptor,
                                      searchAvailable: searchAvailable,
                                      activePrefixes: activePrefixes,
                                      credentialMissingPrefixes: credentialMissingPrefixes))
        }
        // Declared-but-currently-unusable families are projected honestly
        // (NOT_IMPLEMENTED / NEEDS_CONFIGURATION markers from the ORIGINAL
        // routing tables) so the UI explains gaps instead of silently
        // missing rows. No invented capabilities, no future claims.
        for extra in extraInventoryItems(searchAvailable: searchAvailable) {
            if !items.contains(where: { $0.descriptor.name == extra.descriptor.name }) {
                items.append(extra)
            }
        }
        items.sort { $0.descriptor.name < $1.descriptor.name }
        if let modelFilter, !modelFilter.offersTools {
            // The SAVED model explicitly decided it has no tool capability:
            // honest model-scoped projection (a refusal reason, not a
            // deletion — inventory remains explainable).
            items = items.map { item in
                guard item.availability == .available else { return item }
                return FacadeToolAvailabilityItem(
                    descriptor: item.descriptor,
                    availability: .unsupported,
                    prerequisites: [.init(kind: "modelOverride",
                                          reason: "explicitToolsOff")],
                    source: item.source,
                    temporaryCeilingIncluded: false)
            }
        }
        if !includeUnavailable {
            items = items.filter { $0.availability == .available }
        }
        let start = try SkillsDomain.cursorIndex(cursor, count: items.count)
        var objects: [[String: Any]] = []
        var bytes = 0
        var index = start
        while index < items.count, objects.count < ConfigPageBudget.maximumItemsPerPage {
            let object = items[index].jsonObject()
            let candidate = try SkillsDomain.canonicalData(object)
            let overhead = objects.isEmpty ? 2 : 1
            if bytes + candidate.count + overhead > ConfigPageBudget.maximumPageItemsBytes {
                if objects.isEmpty {
                    throw ConfigDomainError(code: .payloadTooLarge, reason: "itemDoesNotFitPage")
                }
                break
            }
            objects.append(object)
            bytes += candidate.count + overhead
            index += 1
        }
        let temporaryNames = TemporaryChatToolPolicy.allowedToolNames(
            from: registry.allDescriptors)
        return [
            "tools": objects,
            "hasMore": index < items.count,
            "nextCursor": index < items.count ? String(index) : NSNull(),
            "totalCandidates": items.count,
            "temporaryCeiling": [
                "names": temporaryNames.sorted(),
                "policy": "publicWebOnly.closedSet",
                "searchProviderConfigured": searchAvailable,
            ],
            "modelScoped": modelID != nil,
        ]
    }

    // MARK: Resolver (the concrete availability component)

    struct ModelFilter {
        let explicit: ModelCapabilities?
        let catalog: ModelCapabilities
        var offersTools: Bool {
            // `explicitCapabilities` nil = legacy catalog; an explicit
            // decision is authoritative and NEVER repaired here (the
            // ORIGINAL invariant, ModelProfile.swift:113-124).
            (explicit ?? catalog).contains(.tools)
        }
    }

    private func availability(for descriptor: ToolCatalog.Descriptor,
                              searchAvailable: Bool,
                              activePrefixes: Set<String>,
                              credentialMissingPrefixes: Set<String>)
        -> FacadeToolAvailabilityItem {
        let source = Self.classifySource(descriptor.name)
        let temporary = TemporaryChatToolPolicy.readOnlyDescriptor(descriptor) != nil
        // Provider-backed web.search gating: the two search names require an
        // enabled+configured provider (RB2 resolver state); web.fetch does
        // not (the ORIGINAL temporary-ceiling composition, Conversation
        // Center.temporaryToolCeiling(webSearchAvailable:) semantics).
        if TemporaryChatToolPolicy.providerBackedWebSearchToolNames.contains(descriptor.name),
           !searchAvailable {
            return FacadeToolAvailabilityItem(
                descriptor: descriptor, availability: .needsConfiguration,
                prerequisites: [.init(kind: "webSearchProvider", reason: "notConfigured")],
                source: source, temporaryCeilingIncluded: false)
        }
        // Backend routing honesty: linuxGuest/remoteHost families need the
        // G03 resolved environment/jobs. Never usable in G02.
        let decision = CapabilityExecutionRouter.decision(for: descriptor.name)
        switch decision.backend {
        case .linuxGuest, .remoteHost:
            return FacadeToolAvailabilityItem(
                descriptor: descriptor, availability: .notImplemented,
                prerequisites: [.init(kind: "g03Environment", reason: "backendUnresolved")],
                source: source, temporaryCeilingIncluded: false)
        case .nativeApple:
            break // compiled native path — continue with the overlay checks.
        @unknown default:
            return FacadeToolAvailabilityItem(
                descriptor: descriptor, availability: .unsupported,
                prerequisites: [.init(kind: "backendRouting", reason: "unknownRouting")],
                source: source, temporaryCeilingIncluded: false)
        }
        // MCP names: a registered remote tool legitimately implies a
        // completed discovery for its prefix. Prefix-level credential gaps
        // and stale/raced registrations fail closed NEEDS_CONFIGURATION;
        // the authoritative server facts stay in mcp.servers.list.
        if source == "mcp" {
            if let prefix = Self.matchingPrefix(of: descriptor.name, in: credentialMissingPrefixes) {
                return FacadeToolAvailabilityItem(
                    descriptor: descriptor, availability: .needsConfiguration,
                    prerequisites: [.init(kind: "mcpCredential",
                                          reason: "credentialUnavailable.\(prefix)")],
                    source: source, temporaryCeilingIncluded: temporary)
            }
            if Self.matchingPrefix(of: descriptor.name, in: activePrefixes) == nil {
                return FacadeToolAvailabilityItem(
                    descriptor: descriptor, availability: .needsConfiguration,
                    prerequisites: [.init(kind: "mcpConnection", reason: "notConnected")],
                    source: source, temporaryCeilingIncluded: false)
            }
        }
        // The registry ALREADY filtered isAvailable() (runner presence), so a
        // present native-route descriptor is genuinely usable right now.
        return FacadeToolAvailabilityItem(descriptor: descriptor, availability: .available,
                                          prerequisites: [], source: source,
                                          temporaryCeilingIncluded: temporary)
    }

    /// Declared-but-unregistered family markers from the ORIGINAL routing
    /// tables (closed set; exec.shell is the stable Linux-guest family the
    /// hub/UI vocabulary already knows). Marker rows carry NO usable claim:
    /// schemaBytes 0 (parametersJSON "{}"), never in any offer set, and the
    /// availability is NOT_IMPLEMENTED with the G03 reason.
    private func extraInventoryItems(searchAvailable: Bool)
        -> [FacadeToolAvailabilityItem] {
        var extras: [FacadeToolAvailabilityItem] = []
        let g03Names = ["exec.shell"]
        for name in g03Names where registry.descriptor(named: name) == nil {
            extras.append(FacadeToolAvailabilityItem(
                descriptor: ToolCatalog.Descriptor(name: name,
                                                   toolDescription: "Linux guest shell",
                                                   parametersJSON: "{}",
                                                   riskLabels: [.executesRemoteCommand],
                                                   isSideEffecting: true),
                availability: .notImplemented,
                prerequisites: [.init(kind: "g03Environment",
                                      reason: "linuxGuestUnresolved")],
                source: "native",
                temporaryCeilingIncluded: false))
        }
        // The D1 web closure names may be absent when the closure was not
        // registered by the host bind — reflect the policy names as honest
        // NEEDS_CONFIGURATION markers (the capability definition is kept).
        if registry.descriptor(named: "web.fetch") == nil {
            extras.append(FacadeToolAvailabilityItem(
                descriptor: ToolCatalog.Descriptor(name: "web.fetch",
                                                   toolDescription: "Public web fetch (D1 closure)",
                                                   parametersJSON: "{}",
                                                   riskLabels: [.networkAccess],
                                                   isSideEffecting: false),
                availability: .needsConfiguration,
                prerequisites: [.init(kind: "toolRegistration",
                                      reason: "closureNotRegistered")],
                source: "native",
                temporaryCeilingIncluded: false))
        }
        if !searchAvailable, registry.descriptor(named: "web.search") == nil {
            extras.append(FacadeToolAvailabilityItem(
                descriptor: ToolCatalog.Descriptor(name: "web.search",
                                                   toolDescription: "Public web search",
                                                   parametersJSON: "{}",
                                                   riskLabels: [.networkAccess],
                                                   isSideEffecting: false),
                availability: .needsConfiguration,
                prerequisites: [.init(kind: "webSearchProvider", reason: "notConfigured")],
                source: "native",
                temporaryCeilingIncluded: false))
        }
        return extras
    }

    private func requireBinding() throws -> FacadeRootGeneration {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.storeReady,
              let fingerprint = hostContext.rootFingerprint(epoch: pumps.epoch),
              let binding = FacadeRootGeneration(epoch: pumps.epoch,
                                                 rootFingerprint: fingerprint) else {
            throw CapabilitiesRefusal.runtimeNotReady
        }
        return binding
    }

    // MARK: Name/namespace helpers (the ORIGINAL mcp_<10hex> scheme)

    /// "mcp_" + 10 lowercase hex is the ONLY remote prefix shape (MCPServer
    /// Configuration.namespacePrefix :60-61 + register prefix+"_"
    /// MCPRemoteToolSource.swift:1012). The 10-hex prefix is NOT injective,
    /// so the resolver never maps name→serverID by parsing; the MCPDomain
    /// observer supplies the authoritative prefix sets and this matches
    /// against them.
    static func classifySource(_ name: String) -> String {
        name.hasPrefix("mcp_") ? "mcp" : "native"
    }

    static func mcpPrefix(forServerID serverID: UUID) -> String {
        let hex = serverID.uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "mcp_" + String(hex.prefix(10))
    }

    /// Longest-prefix membership check against the observer-supplied sets.
    static func matchingPrefix(of name: String, in prefixes: Set<String>) -> String? {
        prefixes
            .filter { name.hasPrefix($0 + "_") || name.hasPrefix($0) }
            .max(by: { $0.utf8.count < $1.utf8.count })
    }
}

extension ConfigDomainError {
    init(_ refusal: CapabilitiesDomain.CapabilitiesRefusal) {
        switch refusal {
        case .runtimeNotReady:
            self.init(code: .runtimeUnavailable, reason: "storeNotReady")
        case .modelStoreUnbound:
            self.init(code: .needsConfiguration, reason: "modelStoreUnbound")
        }
    }
}

// MARK: - RB4/RB5-facing ceiling composition (projection, no run loop)

/// The exact temporary-chat projection the runtime applies per run
/// (AgentRuntime.runtimeVisibleCatalogDescriptors :1547-1553): CURRENT
/// upstream public-web-only closed set, with per-call argument denial via
/// the ORIGINAL policy. RB4/RB5 bind this; RB6 never runs a model loop.
/// The ceiling gates descriptor visibility AND every execution path (the
/// denial helper is the executor-side fence, fails closed).
public enum FacadeTemporaryCeiling {
    public static func offeredNames(from descriptors: [ToolCatalog.Descriptor],
                                    webSearchConfigured: Bool) -> Set<String> {
        let base = TemporaryChatToolPolicy.allowedToolNames(from: descriptors)
        if !webSearchConfigured {
            return base.subtracting(TemporaryChatToolPolicy.providerBackedWebSearchToolNames)
        }
        return base
    }

    /// Executor-side denial for one concrete call (the ORIGINAL
    /// argument-aware fence, closed public-web names only).
    public static func denialReason(descriptor: ToolCatalog.Descriptor,
                                    arguments: Data) -> String? {
        TemporaryChatToolPolicy.denialReason(descriptor: descriptor, arguments: arguments)
    }
}
