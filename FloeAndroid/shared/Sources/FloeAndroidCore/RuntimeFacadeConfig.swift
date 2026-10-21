// SPDX-License-Identifier: MPL-2.0
//
// RB2 — ModelConfigurationFacade: the ACTUAL typed backend for the existing
// applicationConfiguration commands. REPAIR successor of
// job-d02beb16bd1840a9 per MAIN_SOURCE_REVIEW_20261019.json (MC-R1 durable
// provider-revision CAS via the store mirror + advanced-revision replies;
// MC-R3 deletion-intent honesty; MC-R4 shared trusted-context ownership +
// individual physical settlement retention/reconciliation). (private source
// candidate; NOT compiled, NOT executed; see REPORT.md "authored vs not run"
// and "source-only limitations").
//
// Commands implemented (names/labels taken VERBATIM from the frozen 57-entry
// matrix, FloeAndroidCore BridgeEnvelopeV3.swift:106-128 — this package adds
// NOTHING to the vocabulary and registers NOTHING itself):
//   config.providers.list   config.provider.save   config.provider.delete
//   config.provider.probe   config.models.list     config.model.save
//   config.catalog.search   config.preferences.get config.preferences.save
//   config.websearch.get    config.websearch.save
// Excluded ON PURPOSE: settings agent defaults / running input / verify
// final answer and global usage (separate FacadeSettingsDefaultsAdapter /
// FacadeUsageAdapter source), MCP/Skills (RB6), and everything outside G02.
//
// Authority: ONLY the original stores/runners/factories/gateway ingress.
// * FloePersistence ModelConfigurationStore (symlinked unmodified) is the
//   single durable configuration DB (schema 46; no second business DB).
// * FloeCore ProviderSaveDraft.makeRequest + ProviderSaveRunner phases are
//   the save authority (consumed in file 5).
// * SecretGatewayNaming opaque references + the frozen registry + the
//   one-shot SecretSaveIntentVault lease are the credential authority; raw
//   secret bytes NEVER enter command/event JSON, saved state, logs or
//   prompts (only the bounded binary ingress / typed lease).
// * ProviderCatalogIndex.validated(from:) is the ONLY catalog decoder; the
//   document arrives as injected bytes from the trusted host resource
//   handoff (≤2 MiB). A bare .so has no usable Bundle.module (service-map
//   "gate"/"probecatalog"), so this facade NEVER falls back to a bundle or
//   fabricates a catalog.
// * SQLiteSettingsStore (FloePersistence SettingsStore.swift:45-99) is the
//   web-search settings backend for the ORIGINAL WebSearchProvider
//   Configuration/WebSearchCredential shapes; secrets are fetched by the
//   original credentialAccount through the gateway and are NEVER serialized
//   into persisted JSON. The minimal web lane (FloeAndroidWebTools) is
//   consumed through its actual symbols; nothing here reimplements search/
//   HTTP or imports full FloeExecution/shell/SSH/VM surfaces.
//
// Narrow SQL mirrors in this file exist ONLY where the ORIGINAL public API
// cannot gate atomically, each with exact provenance + equivalence notes:
// * Preferences CAS: the original savePreferences has NO revision gate
//   (ModelConfigurationStore.swift:339-391; the syncRevision increment is a
//   caller-side convention at ConversationCenter.swift:7176-7177 and
//   LocalModelsSettingsView.swift:106/140). The mirror reuses the EXACT
//   original INSERT/UPSERT column list and adds only
//   `WHERE model_preferences.sync_revision = ?` plus a changeCount check,
//   executed inside the ONE original writer transaction. In-transaction
//   validation reproduces ConfigurationCodec.validate(preferences:in:)
//   (:625-689) predicates via the PUBLIC ModelProfile capability properties,
//   decoding rows with the narrow provenance mirrors of codec
//   model(from:) (:558-592) / preferences(from:) (:594-623). No original
//   source/schema change, no second DB, no timestamp-only or fake revisions.
// * Web-search save CAS gates on the digest of the actual persisted
//   value_json inside one writer transaction, using the exact original
//   SettingsStore upsert statement (:64-73).

import Foundation
import GRDB
import Crypto
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWebTools

// MARK: - Trusted host injection seams

/// Route context for one-shot save-intent consumption. The ROUTE token and
/// generation come ONLY from the trusted host route registry — never from
/// the command envelope or model content (BRIDGE_V3_MAIN_DECISIONS
/// credentialGatewayDownstreamIngress: host route/generation binding).
public protocol ConfigRouteContextProviding: Sendable {
    func currentRoute() -> RouteBinding?
}

public struct ConfigRouteContextUnavailable: ConfigRouteContextProviding {
    public init() {}
    public func currentRoute() -> RouteBinding? { nil }
}

/// Transport/product admission gate for live network probes. Main's separate
/// qualification gate (transport lane job-ca18980891c043b5 is ACTIVE but
/// UNQUALIFIED; product-UID/network/TLS acceptance pending) sets this bit.
/// DEFAULT CLOSED: probes return typed transportUnavailable until the actual
/// gate grants admission.
public protocol ProviderTransportAdmitting: Sendable {
    var admitsCloudNetwork: Bool { get }
}

public struct TransportAdmissionClosed: ProviderTransportAdmitting {
    public init() {}
    public var admitsCloudNetwork: Bool { false }
}

/// Optional effect recorder for long-lived operations. The RB1 effect pump
/// conforms; RB2 records ONLY typed terminal outcomes under the host-issued
/// operationReceiptID (floe.effect-cursor/3 semantics — applicationCon-
/// figuration scope, no fake run/env/job identities).
public protocol ConfigOperationEffectRecording: Sendable {
    func recordConfigEffect(operationReceiptID: String,
                            kind: String,
                            json: Data)
}

/// Adapter factory seam. The real path uses the ACTUAL original
/// ProviderAdapterFactory (FloeProviders ProviderAdapterFactory.swift:13-34);
/// qualification tests bind a counting fake to prove auth-before-network and
/// admission ordering. NOTHING here builds a second transport: adapters use
/// the overlay-patched StreamingTransport path (transport lane overlay copy
/// — ProviderAdapter.swift :307,:416,:435,:573 #if os(Linux) || os(Android);
/// buffered data(for:) removed). Until the separate gate admits, RB2 refuses
/// dispatch with transportUnavailable and NEVER uses a shared URLSession or
/// a buffered fake stream.
public protocol ProviderAdapterProviding: Sendable {
    func adapter(for profile: ProviderProfile) -> any ProviderAdapter
}

public struct OriginalProviderAdapterFactory: ProviderAdapterProviding {
    private let factory = ProviderAdapterFactory()
    public init() {}
    public func adapter(for profile: ProviderProfile) -> any ProviderAdapter {
        factory.adapter(for: profile)
    }
}

// MARK: - Facade

public actor ModelConfigurationFacade {
    // Original stores (ONE database; constructed exactly like service-map
    // nodes "modelconfig"/"db": ModelConfigurationStore(database:) is the
    // documented constructor).
    private let database: DatabaseManager
    private let store: ModelConfigurationStore
    private let settings: SQLiteSettingsStore
    private let secretStore: AndroidProviderSecretStore
    private let saveExecutor: ProviderSaveExecutor
    private let committer: ModelConfigurationCommitter
    private let cleanup: ProviderSecretCleanup
    private let presetSidecar: ProviderPresetSidecar
    /// MC-WEBSEARCH-3: the secure web-search credential ingress engine
    /// (Set/Clear with shared-coordinator ownership, ACTUAL RB1 registry
    /// lease, individual physical receipt and the durable web-search
    /// cleanup journal). Shares the SAME `ownership` coordinator and
    /// `ownedWork` lifecycle as the provider lane, so a web-search effect
    /// and a provider effect on the SAME UUID never interleave and root
    /// close waits both.
    private let webSearchEngine: WebSearchSecretSaveEngine

    private let gateway: any SecretGatewayServicing
    private let adapters: any ProviderAdapterProviding
    private let transportAdmission: any ProviderTransportAdmitting
    private let routeContext: any ConfigRouteContextProviding
    /// Owned-operation coordination (CV-R1/RB1-f692/07f0d seam + MC-R4
    /// repair). Production resolves the SHARED context coordinator:
    /// ProviderOperationCoordinatorRegistry keyed by the ACTUAL
    /// DatabaseManager instance identity, so two facades constructed over
    /// one trusted root context COORDINATE OR REJECT for one provider id.
    /// The FINAL trusted root/epoch-owned API from the vault-owned-
    /// operations correction lane (job-07f0d672e3854e17, Main-review
    /// PENDING — not a consumable publication) binds at integration
    /// through this SAME protocol before Main publication. There is
    /// deliberately NO default no-op coordinator and no dependency stall:
    /// the resolved coordinator is a real mutual-exclusion machine with
    /// exact-ticket identity, pending owner retention and physical-truth
    /// reconciliation.
    private let ownership: any ProviderOperationOwning
    /// ACTUAL runtime owned-work lifecycle (composed over the reviewed RB1
    /// `RuntimeOwnedWorkRegistry` port). Until the trusted host supplies the
    /// admitted epoch provider, every EFFECT-carrying path fails closed at
    /// attach — quiescence is never faked.
    private let ownedWork: ConfigOwnedWorkLifecycle

    // Catalog (injected bytes → the ONE original decoder; never fabricated).
    private enum CatalogSlot {
        case unavailable(reason: String)
        case ready(ProviderCatalogIndex, ConfigCatalogSnapshot)
    }
    private var catalog: CatalogSlot

    /// Optional terminal-effect recorder (RB1's effect pump conforms). Held
    /// as the typed protocol; RB2 records ONLY under host-issued opaque
    /// operationReceiptIDs (floe.effect-cursor/3 semantics).
    private let effectSink: (any ConfigOperationEffectRecording)?

    /// Probe single-flight per provider (mirror of the runner's rule for
    /// the read path; contract duplicateInFlight).
    private var probesInFlight: Set<UUID> = []

    // MARK: Init

    /// `catalogBytes`: the trusted host resource handoff of the bundled
    /// provider catalog JSON (source-pinned asset, license retained inside
    /// the document itself; RB2 records its digest). nil ⇒ catalog commands
    /// answer typed needsConfiguration — no fallback, no fake.
    ///
    /// `epochProvider`: the trusted host's CURRENT admitted runtime epoch.
    /// Default `ConfigRuntimeEpochNotAdmitted()` fail-closes every effect-
    /// carrying path at owned-work attach until Main binds the real host
    /// seam (integration precondition; never a fake zero).
    /// `ownedWorkRegistry`: defaults to the ACTUAL reviewed
    /// `RuntimeOwnedWorkRegistry.shared`; tests bind a scripted port with
    /// identical outcome shapes.
    public init(database: DatabaseManager,
                gateway: any SecretGatewayServicing = SecretGatewayRegistry.shared,
                catalogBytes: Data?,
                transportAdmission: any ProviderTransportAdmitting = TransportAdmissionClosed(),
                routeContext: any ConfigRouteContextProviding = ConfigRouteContextUnavailable(),
                adapters: any ProviderAdapterProviding = OriginalProviderAdapterFactory(),
                ownership: (any ProviderOperationOwning)? = nil,
                epochProvider: any ConfigRuntimeEpochProviding = ConfigRuntimeEpochNotAdmitted(),
                ownedWorkRegistry: (any OwnedWorkRegistryPort)? = nil,
                effectSink: (any ConfigOperationEffectRecording)? = nil) {
        // MC-R4: the DEFAULT is the ACTUAL SHARED coordinator resolved by
        // trusted database-context identity (not a per-instance gate; the
        // parent's per-instance default is what Main's MC-R4 finding
        // forbids at runtime). An injected `ownership` (explicit owner, or
        // a qualification test's dedicated ProviderOperationOwnership /
        // ProviderOperationCoordinator instance) still bypasses the
        // registry — Main's 07f0d final API binds through the same seam.
        let ownership = ownership
            ?? ProviderOperationCoordinatorRegistry.shared.coordinator(for: database)
        self.ownership = ownership
        self.ownedWork = ConfigOwnedWorkLifecycle(
            registry: ownedWorkRegistry ?? RuntimeOwnedWorkRegistry.shared,
            epochProvider: epochProvider)
        self.database = database
        self.store = ModelConfigurationStore(database: database)
        self.settings = SQLiteSettingsStore(database: database)
        self.gateway = gateway
        self.secretStore = AndroidProviderSecretStore(gateway: gateway)
        self.committer = ModelConfigurationCommitter(database: database)
        self.presetSidecar = ProviderPresetSidecar(database: database)
        self.cleanup = ProviderSecretCleanup(database: database)
        self.saveExecutor = ProviderSaveExecutor(database: database,
                                                 gateway: gateway,
                                                 ownership: ownership,
                                                 ownedWork: self.ownedWork)
        self.webSearchEngine = WebSearchSecretSaveEngine(database: database,
                                                         gateway: gateway,
                                                         ownership: ownership,
                                                         ownedWork: self.ownedWork)
        self.transportAdmission = transportAdmission
        self.routeContext = routeContext
        self.adapters = adapters
        if let catalogBytes {
            switch ConfigCatalogValidator.validate(catalogBytes) {
            case .success(let index):
                self.catalog = .ready(index, ConfigCatalogValidator.snapshot(index, data: catalogBytes))
            case .failure(let error):
                self.catalog = .unavailable(reason: error.reason)
            }
        } else {
            self.catalog = .unavailable(reason: "catalogNotInjected")
        }
        self.effectSink = effectSink
    }

    // MARK: - Catalog metadata (trusted provenance for the report)

    public func catalogMetadata() -> [String: Any]? {
        if case .ready(_, let snapshot) = catalog {
            return [
                "entryCount": snapshot.entryCount,
                "documentDigest": snapshot.documentDigest,
                "sourceLicense": snapshot.sourceLicense,
                "sourceProject": snapshot.sourceProject,
                "sourceURL": snapshot.sourceURL,
                "fetchedAt": snapshot.fetchedAt,
            ]
        }
        return nil
    }

    // MARK: - Bootstrap hooks for RB1

    /// Replay the provider cleanup ledger BEFORE domain commands (same
    /// position as the original AppEnvironment bootstrap drain
    /// :1716). Returns honest entry outcomes (no secrets, no paths). Each
    /// entry attempt takes the SAME per-provider `.cleanup` reservation the
    /// save/delete paths use, so an actively-owned provider can never be
    /// drained out from under a live save (CV-R1 both-direction gate).
    public func drainProviderCleanup() async throws -> ProviderSecretCleanupDrainResult {
        try await cleanup.drain(gateway: gateway,
                                ownership: ownership,
                                ownedWork: ownedWork,
                                reconciler: saveExecutor)
    }

    /// MC-R4 public typed reconciliation seam: ONE bounded pass over the
    /// INDIVIDUAL physical signal for a provider's durable pending owner.
    /// Never a timeout, never a re-read-as-settlement, never a fake
    /// compensation — the caller learns the honest pending state.
    public func reconcileProviderRecovery(providerID: UUID) async -> ProviderRecoveryOutcome {
        await saveExecutor.reconcileProviderRecovery(providerID: providerID)
    }

    /// Bounded diagnostic surface for retirement-adjacent qualification
    /// (counts only, never provider identities or content).
    public func providerOperationActiveCount() async -> Int {
        await ownership.activeOperationCount()
    }

    /// Bounded ADDITIVE OUTPUT projection (Main decision
    /// MAIN_CONFIG_READ_PAGING_DECISION_20261021): one page document
    /// `{"rows":[…],"nextCursor":"<index>|null","hasMore":bool}` built from
    /// the ORIGINAL `ConfigPageComposer` result. The cursor representation,
    /// ownership and non-advancing behaviour are the composer's (decimal item
    /// index into the read snapshot); command names, envelope, scopes,
    /// budgets and row DTOs are unchanged. Carriers pass OBJECT pages through
    /// untouched, and older readers keep consuming the unchanged `rows` key.
    private static func projectPage(_ composed: ConfigPageComposer.Composed) throws -> Data {
        let rows = (try? JSONSerialization.jsonObject(with: composed.data)) ?? [Any]()
        var object: [String: Any] = ["rows": rows, "hasMore": composed.hasMore]
        object["nextCursor"] = composed.nextCursor as Any
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Parses the closed OPTIONAL continuation member of the three config
    /// read payloads. Exact format only: a decimal item index (the composer's
    /// own representation). Absent = first page; malformed/foreign/
    /// negative-coerced values refuse typed and NEVER fall back to page 1.
    nonisolated static func pageCursor(from payload: [String: Any]?) throws -> Int? {
        guard let raw = payload?["cursor"] else { return nil }
        guard let string = raw as? String else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorFormat")
        }
        guard !string.isEmpty, string.count <= 9,
              string.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !(string.count > 1 && string.hasPrefix("0")),
              let value = Int(string), value >= 0 else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorFormat")
        }
        return value
    }

    // MARK: - config.providers.list

    /// Read binding EXACTLY `ModelConfigurationStore.providers()` (contract
    /// config.providers.list); paged with ACTUAL serialized-byte budgeting.
    /// Secret bodies are NEVER read here: the projection carries presence +
    /// the deterministic opaque reference + persisted sync status only.
    public func listProviders(cursor: Int? = nil) async throws -> Data {
        let providers: [ProviderProfile]
        do {
            providers = try await store.providers()
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "providersQuery")
        }
        // The persisted catalog preset identity lives in the ORIGINAL preset
        // sidecar (written by the original save from the frozen request's
        // profile.presetID). ONE bounded read, joined by provider id against
        // live rows, so the projection carries the REAL persisted mapping —
        // never a guess from the first model/role.
        let presetIDs: [UUID: String]
        do {
            presetIDs = try await presetSidecar.presetIDsByProvider()
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "presetJoinFailed")
        }
        let objects = providers.map {
            $0.configSummary(presetID: presetIDs[$0.id]).jsonObject()
        }
        return try Self.projectPage(ConfigPageComposer.compose(objects,
                                                               cursor: cursor,
                                                               itemBudget: ConfigPageBudget.maximumPageItemsBytes))
    }

    // MARK: - config.models.list

    /// Read binding EXACTLY `models(providerID:)` (contract config.models.
    /// list). Each item is the ORIGINAL ModelProfile JSON plus its CAS
    /// digest token so a later config.model.save revision is the ACTUAL
    /// snapshot hash (id/displayName/remoteModelID stay distinct; remote
    /// network calls elsewhere use remoteModelID only — the ORIGINAL
    /// adapters already do this, e.g. ModelDiscovery request paths).
    ///
    /// ADDITIVE OPT-IN (job-7d4d4e41017f4391, gap
    /// MAIN_MODEL_SINGLE_ROW_READ_BUDGET_GAP_20261021.json): a closed
    /// `modelRead` member (parsed/whitelisted at the actual binding
    /// boundary) additionally lets ONE legally-saved oversized original row
    /// — the exact row the legacy composer refuses with `itemDoesNotFitPage`
    /// — stream as deterministic, byte-exact chunks of its canonical page
    /// bytes on this SAME command. `modelRead == nil` (every legacy call)
    /// keeps the byte-identical legacy behavior including that refusal;
    /// normal opted-in pages that contain no oversized row are IDENTICAL
    /// pages. No payload/page/frame budget is raised, no second store or
    /// registry exists, and full pricing precision / useSurfaces /
    /// nil-or-zero capabilities / reasoning / unknown fields / the native
    /// CAS revision survive byte-exactly inside the carrier.
    public func listModels(providerID: UUID? = nil,
                           cursor: Int? = nil,
                           modelRead: ConfigModelReadRequest? = nil) async throws -> Data {
        let models: [ModelProfile]
        do {
            models = try await store.models(providerID: providerID)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelsQuery")
        }
        var objects: [[String: Any]] = []
        objects.reserveCapacity(models.count)
        for model in models {
            var object = try ConfigModelSnapshot.jsonObject(model)
            object["revision"] = ["resourceID": "model.\(model.id.uuidString)",
                                  "version": try ConfigModelSnapshot.digest(model)]
            objects.append(object)
        }
        switch modelRead {
        case .continuation(let modelID, let digest, let offset):
            // Continuation rides the SAME provider filter and the SAME
            // row-index payload cursor (existing semantics; the GLOBAL
            // envelope cursor is not reinterpreted).
            guard let index = cursor else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "modelReadCursorRequired")
            }
            return try Self.modelReadDetailPage(objects: objects,
                                                index: index,
                                                providerID: providerID,
                                                offset: offset,
                                                identity: (modelID, digest))
        case .begin:
            // The chunk path fires ONLY under the exact legacy throw
            // condition: the first unreturned row ALONE exceeds the page
            // item budget. Everything else composes the unchanged page.
            let start = cursor ?? 0
            if start >= 0, start < objects.count,
               let canonical = ConfigJSON.canonicalData(objects[start]),
               canonical.count + 2 > ConfigPageBudget.maximumPageItemsBytes {
                return try Self.modelReadDetailPage(objects: objects,
                                                    index: start,
                                                    providerID: providerID,
                                                    offset: 0,
                                                    identity: nil)
            }
        case nil:
            break
        }
        return try Self.projectPage(ConfigPageComposer.compose(objects,
                                                               cursor: cursor,
                                                               itemBudget: ConfigPageBudget.maximumPageItemsBytes))
    }

    // MARK: config.models.list full-row detail chunk page

    /// Builds ONE deterministic chunk page for the original row at `index`.
    /// The store was just re-read through the ORIGINAL binding, so the
    /// carrier bytes are the CURRENT canonical page bytes for that row;
    /// the optional `identity` (id + opaque read digest supplied by an
    /// upgraded reader) must match BEFORE any chunk text is produced.
    /// A changed/deleted/reordered row is a typed `staleRevision` refusal
    /// — never a mixed snapshot, never a silent effect.
    private static func modelReadDetailPage(objects: [[String: Any]],
                                            index: Int,
                                            providerID: UUID?,
                                            offset: Int,
                                            identity: (modelID: UUID,
                                                        digest: String)?) throws -> Data {
        guard index >= 0, index < objects.count else {
            throw ConfigDomainError(code: .staleRevision, reason: "modelReadRowMissing")
        }
        let object = objects[index]
        guard let rowID = object["id"] as? String,
              UUID(uuidString: rowID) != nil else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadRowShape")
        }
        if let identity {
            guard UUID(uuidString: rowID) == identity.modelID else {
                throw ConfigDomainError(code: .staleRevision, reason: "modelReadRowIdentity")
            }
        }
        if let providerID {
            guard let rowProvider = object["providerID"] as? String,
                  UUID(uuidString: rowProvider) == providerID else {
                throw ConfigDomainError(code: .staleRevision, reason: "modelReadRowProvider")
            }
        }
        let detail = try ConfigModelRowReader.detail(of: object)
        if let identity {
            // Same-read consistency (the digest protects consistency, not
            // permission): the CURRENT canonical bytes must hash equal to
            // the digest the reader is continuing under.
            guard detail.readDigest == identity.digest else {
                throw ConfigDomainError(code: .staleRevision, reason: "modelReadRowChanged")
            }
            try ConfigModelRowReader.validateChainOffset(detail, rowID: rowID, offset: offset)
        } else {
            guard offset == 0 else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "modelReadOffsetRequiresIdentity")
            }
        }
        let chunk = try ConfigModelRowReader.chunk(detail, rowID: rowID, at: offset)
        guard let markerData = ConfigJSON.canonicalData(
            chunk.marker(rowID: rowID, digest: detail.readDigest)) else {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "modelReadMarkerEncode")
        }
        var body = Data()
        body.append(0x5B) // "["
        body.append(markerData)
        body.append(0x5D) // "]"
        precondition(body.count <= ConfigPageBudget.maximumPageItemsBytes,
                     "model-read chunk exceeded the existing page item budget")
        let nextCursor: String?
        let hasMore: Bool
        if chunk.next != nil {
            // Truthful logical row cursor: the numeric continuation to the
            // NEXT row advances ONLY after this row is fully reconstructed.
            nextCursor = String(index)
            hasMore = true
        } else {
            let advance = index + 1
            nextCursor = advance < objects.count ? String(advance) : nil
            hasMore = advance < objects.count
        }
        return try Self.projectPage(ConfigPageComposer.Composed(data: body,
                                                                nextCursor: nextCursor,
                                                                hasMore: hasMore))
    }

    // MARK: - config.provider.save (Set/Keep/Clear)

    /// Set: the payload carries ONLY the opaque `int:v1:` ingress handle
    /// (+ optional envelope revision). The frozen candidate/secret are read
    /// EXCLUSIVELY from the one-shot lease (file 5); model-authored JSON
    /// never carries the candidate body or any secret.
    ///
    /// Consumption honesty (CV-R4): the lease consume is one-shot. If the
    /// per-provider ownership reservation then refuses the chain, the
    /// intent is reported spent (typed duplicateInFlight at the "ownership"
    /// phase) — it is never "freed", never presented as if no secret write
    /// could follow, and never retried with the same token; a new save-tap
    /// mints a NEW int:v1: intent.
    public func saveProviderSet(ingressToken: String,
                                envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        guard let route = routeContext.currentRoute() else {
            return .failed(.init(error: ConfigDomainError(code: .runtimeUnavailable,
                                                          reason: "routeContextUnavailable"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false,
                                 phase: "route",
                                 leaseAdmissionCloseFailed: false))
        }
        return await saveExecutor.saveSet(token: ingressToken,
                                         route: route,
                                         envelopeRevision: envelopeRevision)
    }

    /// Keep: same draft WITHOUT a new key; the ORIGINAL connection-bound
    /// credential-reuse rules in makeRequest decide (a changed connection
    /// requires a fresh Set; a Keep never writes any secret).
    public func saveProviderKeep(candidateJSON: Data,
                                 envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        await saveExecutor.saveKeep(candidateJSON: candidateJSON,
                                    envelopeRevision: envelopeRevision)
    }

    /// Clear: bundle commit drops the persisted reference; the deterministic
    /// old-account delete goes through the cleanup ledger so
    /// errors/cancellation/unknown outcomes stay recoverable and NEVER
    /// destroy a newer Set's key (drain re-resolves the live row).
    public func saveProviderClear(candidateJSON: Data,
                                  envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        await saveExecutor.saveClear(candidateJSON: candidateJSON,
                                     envelopeRevision: envelopeRevision)
    }

    /// Compact existing-row KEEP metadata variant of the SAME command
    /// (Main MAIN_PROVIDER_COMPACT_METADATA_DECISION_20261021): flips ONLY
    /// the persisted provider row's enabled flag under the SAME per-provider
    /// save ownership + Root-owned lease + durable writer CAS. It never
    /// serializes/rewrites model rows, never performs a secret read or
    /// write, and never touches the preset sidecar, preferences or the
    /// cleanup ledger. The reply carries the ACTUAL committed advanced
    /// revision; a pending physical reconciliation is rejected, not bypassed.
    public func saveProviderMetadataEnabled(providerID: UUID,
                                            isEnabled: Bool,
                                            envelopeRevision: ConfigRevision?) async
        -> ProviderSaveExecution
    {
        await saveExecutor.saveMetadataEnabled(providerID: providerID,
                                               isEnabled: isEnabled,
                                               envelopeRevision: envelopeRevision)
    }

    // MARK: - config.provider.delete

    /// Contract binding: "deleteProvider + deletion ordering: pendingDeletion
    /// enqueue -> gateway.delete(reference) -> completeDeletion | record
    /// failure; bootstrap drain replays" — implemented here as the
    /// INDEPENDENT provider-scoped ledger (file 4 provenance: the original
    /// trigger-fed credential_deletion_queue belongs to the tool-vault lane
    /// and cannot express provider deletes; accounts are prefix-disjoint).
    public struct ProviderDeleteResult: Sendable, Equatable {
        public let providerID: UUID
        public enum SecretCleanup: Sendable, Equatable {
            case noneConfigured
            /// The delete attempt's OWN committed completion (authoritative).
            case removed
            /// MC-R3: reachable ONLY through an authoritative reference-
            /// absent completion of the exact reference. Pre-ticket
            /// validation rejections (invalidReference/invalidValue) never
            /// map here; they report queuedForRetry with the durable entry
            /// preserved. (Keystore delete is idempotent-complete, so today
            /// this channel stays empty by construction — kept honestly
            /// rather than faked from a validation refusal.)
            case provablyAbsent(reason: String)
            case queuedForRetry(reason: String)
        }
        public let secretCleanup: SecretCleanup
    }

    public func deleteProvider(revision: ConfigRevision) async throws -> ProviderDeleteResult {
        guard revision.resourceID.hasPrefix("provider."),
              let providerID = UUID(uuidString: String(revision.resourceID.dropFirst("provider.".count)))
        else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "deleteRevisionResource")
        }
        guard Int64(revision.version) != nil else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "deleteRevisionVersion")
        }
        // Owned-operation reservation (CV-R1 + MC-R4 exact ticket): the
        // whole row-read -> durable CAS -> enqueue -> DB delete -> gateway
        // delete -> compare-and-finalize chain holds the `.delete` gate, so
        // no save/keep/clear or cleanup-drain attempt can interleave on
        // this provider. No time-based release; an unsettled physical
        // lifetime parks the ticket + retained registry lease.
        var ticket: ProviderOperationTicket?
        switch await ownership.beginOperation(providerID: providerID, kind: .delete) {
        case .attached(let attached):
            ticket = attached
        case .conflict:
            throw ConfigDomainError(code: .duplicateInFlight, reason: "providerOperationActive")
        case .capacityUnavailable:
            // MC-CAPACITY-1: the bounded reservation refused BEFORE any
            // effect (nothing was read, enqueued, deleted or leased).
            throw ConfigDomainError(code: .mailboxSaturated,
                                    reason: "providerOperationCapacityUnavailable")
        case .pendingReconciliation:
            _ = await saveExecutor.reconcileProviderRecovery(providerID: providerID)
            if case .attached(let attached) = await ownership.beginOperation(
                providerID: providerID, kind: .delete) {
                ticket = attached
            } else {
                throw ConfigDomainError(code: .duplicateInFlight,
                                        reason: "providerPendingReconciliation")
            }
        }
        guard let ownedTicket = ticket else {
            throw ConfigDomainError(code: .runtimeUnavailable, reason: "ownershipNotAttached")
        }
        // ACTUAL runtime owned-work lease (kind .vaultMaintenance) across
        // the whole awaited delete chain (row delete + Keystore delete +
        // ledger finalization). Attach failure fails closed BEFORE any
        // effect; the reservation is released without proceeding.
        let ownedLease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .vaultMaintenance, ownerID: providerID.uuidString) {
        case .failure(let rejection):
            await ownership.endOperation(ownedTicket)
            throw ProviderSaveExecutor.ownedWorkAttachError(rejection)
        case .success(let lease):
            ownedLease = lease
        }
        do {
            let outcome = try await runDelete(providerID: providerID, revision: revision)
            if outcome.requiresOwnerRetention {
                // MC-R4: unsettled individual physical lifetime -> the
                // delete ticket + registry lease are PARKED (MC-CAPACITY-1:
                // the reservation was taken at begin, so an exact-ticket
                // park always retains the receipt/lease — the reconciler
                // can settle this owner after REAL completion without a
                // restart). The durable providerDelete entry already
                // recorded the intent; nothing is released, nothing is
                // claimed.
                // TRANSFER the flow's exact witness into the pending record
                // and clear the transient per-provider slot.
                let witness = await secretStore.consumeWitness(providerID: providerID)
                let parked = await ownership.parkPending(
                    ownedTicket,
                    intent: .providerDelete,
                    receipt: outcome.receipt,
                    lease: ownedLease,
                    witness: witness)
                _ = parked
                return outcome.result
            }
            // Terminal delete: no observer reference may outlive the flow.
            _ = await secretStore.consumeWitness(providerID: providerID)
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ownedTicket)
            return outcome.result
        } catch {
            // Deterministic pre-effect refusals (stale revision, foreign
            // account, notFound, ledger corruption) have NO physical
            // secret trail: the awaited chain terminated before any secret
            // effect, so releasing the gate + lease here is truthful.
            _ = await secretStore.consumeWitness(providerID: providerID)
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ownedTicket)
            throw error
        }
    }

    private struct DeleteOutcome {
        let result: ProviderDeleteResult
        let requiresOwnerRetention: Bool
        let receipt: PhysicalOperationReceipt?
    }

    private func runDelete(providerID: UUID,
                           revision: ConfigRevision) async throws -> DeleteOutcome {
        let current: ProviderProfile?
        do {
            current = try await store.provider(id: providerID)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "providerRowQuery")
        }
        guard let row = current else {
            throw ConfigDomainError(code: .notFound, reason: "providerRowMissing")
        }
        guard ConfigRevision.provider(id: row.id, syncRevision: row.syncRevision).version == revision.version else {
            throw ConfigDomainError(code: .staleRevision, reason: "providerDeleteRevision")
        }
        let account = row.secretRef?.keychainAccount
        if let account,
           account != ConfigSecretIdentity.providerAccount(providerID: providerID) {
            // Foreign/corrupt account string in the providers row: abort
            // typed with ZERO effect (never destructive reuse of a foreign
            // namespace member; the row and its reference are untouched).
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "persistedAccountOwnership")
        }
        if let account {
            try await cleanup.enqueue(.init(providerID: providerID,
                                            account: account,
                                            intent: .providerDelete))
        }
        do {
            // MC-R1: the durable same-writer CAS delete — the FK-cascade
            // (ModelConfigurationStore.swift:322-327 original semantics)
            // runs ONLY if the row STILL carries the revision we observed,
            // inside the same DatabaseManager.writer transaction. A stale
            // sequential delete mutates NOTHING.
            try await store.deleteProvider(id: providerID, expectedSyncRevision: row.syncRevision)
        } catch is ModelConfigurationRevisionConflict {
            // The row advanced since the caller read it: typed stale, and
            // the just-enqueued intent is unrecorded again (compare-and-
            // delete, CV-R2). The live row still owns its secret.
            _ = try? await cleanup.dequeueMatching(providerID: providerID,
                                                   intent: .providerDelete)
            throw ConfigDomainError(code: .staleRevision, reason: "providerDeleteCAS")
        } catch {
            // FK/other delete failure: the provider (and its models/secret
            // ownership) SURVIVE — honest zero DB effect. Best-effort
            // unrecord of our just-enqueued intent (compare-and-delete,
            // CV-R2); if the unrecord itself fails, the drain's row-present
            // branch discards it WITHOUT deleting on the next pass. The
            // preset sidecar entry is NOT removed here (the provider lives).
            _ = try? await cleanup.dequeueMatching(providerID: providerID,
                                                   intent: .providerDelete)
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "providerDeleteFailed")
        }
        // Sidecar removal only AFTER the row is gone (dangling entries are
        // also filtered by the configuredPresetIDs live join). A sidecar
        // failure no longer masquerades as a delete failure (the row IS
        // gone); the live-join filter keeps reads honest meanwhile.
        try? await presetSidecar.remove(providerID: providerID)
        guard let account else {
            return DeleteOutcome(result: ProviderDeleteResult(providerID: providerID,
                                                              secretCleanup: .noneConfigured),
                                 requiresOwnerRetention: false,
                                 receipt: nil)
        }
        try await secretStore.bindAccount(account, providerID: providerID)
        let assessment = await secretStore.deleteBoundSecret(providerID: providerID)
        await secretStore.releaseAccountBinding(providerID: providerID)
        switch assessment.disposition {
        case .committed:
            let finalized = (try? await cleanup.dequeueMatching(providerID: providerID,
                                                                intent: .providerDelete)) ?? false
            if finalized {
                return DeleteOutcome(result: ProviderDeleteResult(providerID: providerID,
                                                                  secretCleanup: .removed),
                                     requiresOwnerRetention: false,
                                     receipt: assessment.receipt)
            }
            // Entry identity advanced under us (should be impossible while
            // the reservation is held): report honestly, do not claim
            // removal against uncertainty.
            return DeleteOutcome(result: ProviderDeleteResult(
                providerID: providerID,
                secretCleanup: .queuedForRetry(reason: "entryIntentAdvanced")),
                requiresOwnerRetention: false,
                receipt: assessment.receipt)
        case .effectAbsent(let reason):
            // MC-R3: NOTHING here proves the secret was absent. A pre-ticket
            // validation rejection (invalidReference/invalidValue) means no
            // ticket existed; an authoritative store rejection means this
            // attempt did not remove anything. The secret may still exist
            // while the row no longer references it: the durable entry
            // STAYS for honest drain retry (the Keystore delete is
            // idempotent-complete, so convergence is guaranteed once the
            // backend answers). provablyAbsent is NOT used for these
            // rejections.
            _ = reason
            return DeleteOutcome(result: ProviderDeleteResult(
                providerID: providerID,
                secretCleanup: .queuedForRetry(reason: "attemptRejected.\(reason)")),
                requiresOwnerRetention: assessment.requiresOwnerRetention,
                receipt: assessment.receipt)
        case .outcomeUnknown(let reason):
            // Entry STAYS for the next drain; deletion is never claimed.
            // MC-R4: with an unsettled individual physical lifetime the
            // owner gate + registry lease are retained (park) — the delete
            // is durably recorded, so a process restart also reconciles.
            _ = reason
            return DeleteOutcome(result: ProviderDeleteResult(
                providerID: providerID,
                secretCleanup: .queuedForRetry(reason: "outcomeUnknown.\(reason)")),
                requiresOwnerRetention: assessment.requiresOwnerRetention,
                receipt: assessment.receipt)
        }
    }

    // MARK: - config.provider.probe

    /// Typed async probe mirroring the ORIGINAL editor validation flow
    /// (buildProfile → resolveCredentials → adapter(for:).testConnection →
    /// listModels — ProviderEditorViewModel.swift:891-935) with the RB2
    /// gates:
    /// 1. real stored profile (never a wire-forged one);
    /// 2. TYPED credential resolution FIRST;
    /// 3. auth-required provider with unavailable secret →
    ///    credentialUnavailable BEFORE any network dispatch (call counters
    ///    prove zero adapter invocations);
    /// 4. only an explicit supported no-auth style may dispatch anonymously;
    /// 5. trusted transport admission gate; default false → typed
    ///    transportUnavailable (no buffered fake, no shared URLSession, no
    ///    trust bypass — the overlay adapter path is StreamingTransport-
    ///    patched and stays the only network route);
    /// 6. runs under the facade's service lifetime with real cancellation
    ///    (not a ViewModel Task); the outcome is the typed terminal effect.
    public func probe(providerID: UUID) async throws -> ConfigProbeOutcome {
        guard !probesInFlight.contains(providerID) else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "probeInFlight")
        }
        probesInFlight.insert(providerID)
        defer { probesInFlight.remove(providerID) }
        let profile: ProviderProfile?
        do {
            profile = try await store.provider(id: providerID)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "providerRowQuery")
        }
        guard let profile else {
            throw ConfigDomainError(code: .notFound, reason: "providerRowMissing")
        }
        // 2) Typed credential resolution FIRST.
        let resolution = await secretStore.resolve(provider: profile)
        switch resolution {
        case .unavailable(let availability):
            // 3) BEFORE network: typed credentialUnavailable.
            throw ConfigDomainError(code: .credentialUnavailable,
                                    reason: availability.rawValue)
        case .apiKey(let key):
            return try await dispatchProbe(profile: profile,
                                           credentials: ProviderCredentials(apiKey: key))
        case .anonymousAuthorized:
            // 4) explicit no-auth style ONLY authorizes the anonymous pass
            //    (authStyle "none": ProviderConnectionIdentity.authStyle
            //    (for:) == "none" / ProviderPreset.AuthStyle.none at
            //    ProviderAdapterFactory.swift:175).
            return try await dispatchProbe(profile: profile,
                                           credentials: ProviderCredentials(apiKey: nil))
        }
    }

    private func dispatchProbe(profile: ProviderProfile,
                               credentials: ProviderCredentials) async throws
        -> ConfigProbeOutcome
    {
        // 5) Trusted admission gate. Until Main's actual transport/TLS/
        // product-UID gate grants admission: typed transportUnavailable.
        guard transportAdmission.admitsCloudNetwork else {
            throw ConfigDomainError(code: .transportUnavailable,
                                    reason: "transportGateClosed")
        }
        let adapter = adapters.adapter(for: profile)
        do {
            try await adapter.testConnection(provider: profile, credentials: credentials)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let redacted = SecretRedactor.redact(error.localizedDescription)
            let compact = redacted.utf8.count <= 128 ? redacted : "connectionFailed"
            throw ConfigDomainError(code: .runtimeUnavailable, reason: "probeFailed(\(compact))")
        }
        let models: [ModelProfile]
        do {
            models = try await adapter.listModels(provider: profile, credentials: credentials)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let redacted = SecretRedactor.redact(error.localizedDescription)
            let compact = redacted.utf8.count <= 128 ? redacted : "discoveryFailed"
            throw ConfigDomainError(code: .runtimeUnavailable, reason: "probeDiscoveryFailed(\(compact))")
        }
        // Discovery results are REPORTED ONLY; nothing is auto-installed
        // (no preset/model auto-install; the editor selection owns saves).
        return ConfigProbeOutcome(providerID: profile.id, status: .connected,
                                  modelCount: models.count,
                                  discoveredModels: models, failureReason: nil)
    }

    /// Cancellation-aware wrapper for the RB1 drain path: the caller owns a
    /// Task; when it is cancelled BEFORE dispatch, the outcome is typed
    /// `cancelled` (read-only probe: provably no local effect). A cancel
    /// AFTER dispatch keeps the service-owned operation going to its real
    /// typed outcome (the model stream/HTTP work is separately bounded;
    /// probe results are never auto-installed).
    public func probeForEffect(providerID: UUID) async -> ConfigProbeOutcome {
        do {
            return try await probe(providerID: providerID)
        } catch is CancellationError {
            return ConfigProbeOutcome(providerID: providerID, status: .cancelled,
                                      modelCount: 0, discoveredModels: [],
                                      failureReason: "cancelled")
        } catch let error as ConfigDomainError {
            return ConfigProbeOutcome(providerID: providerID, status: .failed,
                                      modelCount: 0, discoveredModels: [],
                                      failureReason: "\(error.code.rawValue):\(error.reason)")
        } catch {
            return ConfigProbeOutcome(providerID: providerID, status: .failed,
                                      modelCount: 0, discoveredModels: [],
                                      failureReason: "probeRejected")
        }
    }

    // MARK: - Trusted-host DRAFT probe/discovery (no persisted provider)

    /// Probe/discover an UNSAVED or CHANGED editor draft through the
    /// ORIGINAL provider adapter — the required parity behavior from
    /// MAIN_CONFIG_DRAFT_PROBE_PARITY_DECISION (never auto-save, never a
    /// shadow provider, never testing the old stored profile about a changed
    /// draft).
    ///
    /// Inputs are the EXACT closed `ProviderSaveCandidate` the editor would
    /// commit (frozen from RAM at the human editor action by the App's own
    /// save-candidate builder, so protocol/auth/model mapping can never
    /// diverge from a real save) plus the bounded ephemeral credential typed
    /// in that same editor session. The candidate is mapped through the SAME
    /// ORIGINAL `ProviderSaveDraft.makeRequest()` builder used by the save
    /// chain, then dispatched through the SAME `dispatchProbe` gate
    /// (transport admission → original adapter testConnection/listModels →
    /// redacted typed errors). Nothing is persisted: no provider/model row,
    /// no vault intent, no credential-store write, no preset sidecar.
    ///
    /// Single-flight shares the SAME per-provider probe set as the saved
    /// probe, so a draft probe and a saved probe for one provider can never
    /// race. Cancellation is caller-driven (the host seam owns the Task) and
    /// a cancelled dispatch settles as the typed cancellation, never a fake
    /// success.
    public func probeDraftCandidate(_ candidateJSON: Data,
                                    secret: Data?) async throws -> ConfigProbeOutcome {
        guard !candidateJSON.isEmpty else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "emptyCandidate")
        }
        guard candidateJSON.count <= SecretSaveIntentLimits.maximumIntentJSONBytes else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "candidateTooLarge")
        }
        let parsed: ProviderSaveCandidate
        do {
            parsed = try ProviderSaveCandidate.parse(ConfigJSON.object(from: candidateJSON))
        } catch let error as ConfigDomainError {
            throw error
        } catch {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidateParse")
        }
        // A staged large-profile draft candidate BORROWS the same frozen
        // immutable set: provider/epoch/route/seal/digest are re-checked
        // exactly like a save, but the probe never consumes the stage and
        // never reaches any DB/secret effect (probe is read-only; the CAS
        // axes only bind an actual save later). Malformed/stale/foreign/
        // unsealed/tampered refs refuse BEFORE any dispatch.
        let candidate: ProviderSaveCandidate
        do {
            if let models = try ProviderModelSetConsumer.resolveIfReferenced(
                parsed,
                context: .init(providerID: parsed.providerID,
                               createIntent: parsed.createIntent,
                               baseRevision: nil,
                               isDraftProbe: true)) {
                candidate = parsed.withResolvedModels(models)
            } else {
                candidate = parsed
            }
        } catch let error as ConfigDomainError {
            throw error
        }
        guard !probesInFlight.contains(candidate.providerID) else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "probeInFlight")
        }
        probesInFlight.insert(candidate.providerID)
        defer { probesInFlight.remove(candidate.providerID) }

        var entered = ""
        if let secret, !secret.isEmpty {
            guard secret.count <= SecretSaveIntentLimits.maximumSecretBytes else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "secretTooLarge")
            }
            guard let text = String(data: secret, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "secretNotBoundedText")
            }
            entered = text
        }
        // No persisted row participates: the draft's own connection fields are
        // the probe target (existingSecretRef stays nil so no stored key can
        // silently stand in for the entered/absent draft key).
        let draft = candidate.makeDraft(existingRow: nil,
                                        enteredAPIKey: entered,
                                        dropExistingSecret: true)
        let request: ProviderSaveRequest
        switch draft.makeRequest() {
        case .success(let value):
            request = value
        case .failure(let report):
            let issue = report.issues.first.map { String(describing: $0.problem) } ?? "unknown"
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "draftValidation.\(issue)")
        }
        let profile = request.profile
        let credentials: ProviderCredentials
        if profile.secretRef != nil {
            credentials = ProviderCredentials(apiKey: entered)
        } else if ProviderConfigurationValidation.ProviderConnectionIdentity
            .authStyle(for: profile.kind) == "none" {
            // Same rule as the saved probe: an explicit supported no-auth
            // style is the ONLY anonymous path.
            credentials = ProviderCredentials(apiKey: nil)
        } else {
            throw ConfigDomainError(code: .credentialUnavailable,
                                    reason: "secretMissing")
        }
        return try await dispatchProbe(profile: profile, credentials: credentials)
    }

    // MARK: - config.catalog.search

    /// Bounded search over the injected, decoder-validated catalog with the
    /// ACTUAL configured-preset ids from the real store (sidecar joined
    /// against live provider rows). NO preset auto-install.
    public func catalogSearch(query: String,
                              filter: ProviderCatalogFilter,
                              cursor: Int? = nil) async throws -> Data {
        guard case .ready(let index, _) = catalog else {
            if case .unavailable(let reason) = catalog {
                throw ConfigDomainError(code: .needsConfiguration, reason: reason)
            }
            throw ConfigDomainError(code: .needsConfiguration, reason: "catalogNotInjected")
        }
        let configured: Set<String>
        do {
            configured = try await presetSidecar.configuredPresetIDs()
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "presetJoinFailed")
        }
        let results = index.search(query: query, filter: filter,
                                  configuredPresetIDs: configured)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var objects: [[String: Any]] = []
        objects.reserveCapacity(min(results.count, ConfigPageBudget.maximumCatalogResultsPerPage + 1))
        for entry in results.prefix(ConfigPageBudget.maximumCatalogResultsPerPage * 2) {
            guard let data = try? encoder.encode(entry),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            objects.append(object)
        }
        let composed = try ConfigPageComposer.compose(objects,
                                                      cursor: cursor,
                                                      itemBudget: ConfigPageBudget.maximumPageItemsBytes)
        return try Self.projectPage(composed)
    }

    /// Accepts the closed filter wire strings from the ORIGINAL enum
    /// (ProviderCatalogFilter: all|configured|available|local).
    public static func catalogFilter(from raw: String?) throws -> ProviderCatalogFilter {
        guard let raw else { return .all }
        guard let filter = ProviderCatalogFilter(rawValue: raw) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "catalogFilter")
        }
        return filter
    }

    // MARK: - config.preferences.get / save

    public struct PreferencesReply: Sendable {
        public let revision: ConfigRevision
        public let valueJSON: Data
    }

    public func getPreferences() async throws -> PreferencesReply {
        let current: ModelSelectionPreferences
        do {
            current = try await store.preferences()
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "preferencesQuery")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let valueJSON = try encoder.encode(current)
        return PreferencesReply(
            revision: ConfigRevision.preferences(syncRevision: current.syncRevision),
            valueJSON: valueJSON
        )
    }

    /// CAS save. Server-owned fields are recomputed exactly like the
    /// original call sites (increment-only syncRevision + updatedAt); the
    /// durable write is the proven narrow mirror of
    /// ModelConfigurationStore.swift:342-390 + `WHERE
    /// model_preferences.sync_revision = ?` + changeCount, with
    /// in-transaction assignment validation reproducing
    /// ConfigurationCodec.validate(preferences:in:) (:625-689) via the
    /// PUBLIC capability properties. Stale revisions write NOTHING
    /// (zero-overwrite); unknown model ids are typed notFound; a stored
    /// model that is disabled fails the same role rules as the original.
    public func savePreferences(payload: Data,
                                revision: ConfigRevision) async throws -> PreferencesReply {
        guard revision.resourceID == "preferences" else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "preferencesRevisionResource")
        }
        let expectedRevision: Int64
        guard let value = Int64(revision.version), value >= 0 else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "preferencesRevisionValue")
        }
        expectedRevision = value
        let dictionary = try ConfigJSON.object(from: payload)
        let decoded = try ConfigJSON.decodeCanonical(ModelSelectionPreferences.self,
                                                     from: dictionary,
                                                     context: "preferences")
        let updated = try ConfigPreferencesRules.applyServerOwnership(decoded,
                                                                      expectedRevision: expectedRevision)

        struct WriteOutcome: Sendable {
            let storedJSON: Data
            let storedRevision: Int64
        }
        let outcome: WriteOutcome
        do {
            outcome = try await database.writer { db -> WriteOutcome in
                // 1) Current snapshot (narrow provenance mirror of
                //    ConfigurationCodec.preferences(from:) :594-623).
                let currentRow = try Row.fetchOne(
                    db, sql: "SELECT * FROM model_preferences WHERE id = 'default'")
                let currentPrefs: ModelSelectionPreferences
                if let currentRow {
                    currentPrefs = try Self.decodePreferencesRow(currentRow)
                } else {
                    currentPrefs = ModelSelectionPreferences()
                }
                // 2) Full-snapshot CAS BEFORE validation (stale revision or
                //    any divergence from the revision the client read →
                //    zero overwrite). syncRevision is the exact equality
                //    gate; the payload was already required to carry it.
                guard currentPrefs.syncRevision == expectedRevision else {
                    throw ConfigDomainError(code: .staleRevision, reason: "preferencesCasGate")
                }
                // 3) In-transaction assignment validation — reproduces the
                //    ORIGINAL rules (ConfigurationCodec.validate
                //    (preferences:in:) :625-689) using PUBLIC model
                //    properties and the SAME "SELECT ... AND is_enabled = 1"
                //    fetch, with unchanged-route skipping like the original.
                try Self.validateAssignments(updated,
                                             previous: currentPrefs,
                                             in: db)
                // 4) The narrow mirror of the ORIGINAL upsert (:344-389)
                //    with the atomic revision gate added. Column order,
                //    values and SET list match the original EXACTLY; only
                //    `WHERE model_preferences.sync_revision = ?` +
                //    changeCount are added.
                try db.execute(sql: Self.preferencesCASUpsert,
                               arguments: [
                                   updated.onboardingStatus.rawValue,
                                   updated.defaultAgentModelID?.uuidString,
                                   updated.generalAuxiliaryLLMModelID?.uuidString,
                                   updated.canvasAgentModelID?.uuidString,
                                   updated.visionModelID?.uuidString,
                                   updated.canvasVisionModelID?.uuidString,
                                   updated.approvalModelID?.uuidString,
                                   updated.packageReviewModelID?.uuidString,
                                   updated.auxiliaryImageMode.rawValue,
                                   updated.sharedImageModelID?.uuidString,
                                   updated.imageGenerationModelID?.uuidString,
                                   updated.imageEditingModelID?.uuidString,
                                   updated.defaultVideoModelID?.uuidString,
                                   updated.autonomousImageRouting ?? false,
                                   Self.encodeDate(updated.updatedAt),
                                   updated.syncRevision,
                                   expectedRevision, // CAS token
                               ])
                guard db.changesCount == 1 else {
                    // Another write landed between gate and update inside a
                    // future relaxed path; today DatabaseManager has ONE
                    // writer, so this stays as defense-in-depth honesty.
                    throw ConfigDomainError(code: .staleRevision, reason: "preferencesCasChanges")
                }
                let readBack = try Row.fetchOne(
                    db, sql: "SELECT * FROM model_preferences WHERE id = 'default'")
                guard let readBackRow = readBack else {
                    throw ConfigDomainError(code: .persistenceUnavailable,
                                            reason: "preferencesReadbackMissing")
                }
                let stored = try Self.decodePreferencesRow(readBackRow)
                // Created INSIDE the transaction block: JSONEncoder is not
                // Sendable and must never cross the @Sendable boundary.
                let storedEncoder = JSONEncoder()
                storedEncoder.outputFormatting = [.sortedKeys]
                let storedJSON = try storedEncoder.encode(stored)
                return WriteOutcome(storedJSON: storedJSON,
                                    storedRevision: stored.syncRevision)
            }
        } catch let error as ConfigDomainError {
            throw error
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "preferencesWrite")
        }
        return PreferencesReply(
            revision: ConfigRevision.preferences(syncRevision: outcome.storedRevision),
            valueJSON: outcome.storedJSON
        )
    }

    // MARK: Preferences CAS mirror SQL (exact original + atomic gate)

    /// Provenance: ModelConfigurationStore.swift:344-389 (column list,
    /// VALUES and DO UPDATE SET are reproduced verbatim). ADDED only:
    /// the trailing `WHERE model_preferences.sync_revision = ?` gate.
    /// NO other change; the table/schema is untouched (46 stays 46).
    static let preferencesCASUpsert = """
        INSERT INTO model_preferences (
            id, onboarding_status, default_agent_model_id, general_auxiliary_llm_model_id,
            canvas_agent_model_id, vision_model_id, canvas_vision_model_id,
            approval_model_id, package_review_model_id,
            auxiliary_image_mode, shared_image_model_id,
            image_generation_model_id, image_editing_model_id,
            default_video_model_id, autonomous_image_routing,
            updated_at, sync_revision
        ) VALUES ('default', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            onboarding_status = excluded.onboarding_status,
            default_agent_model_id = excluded.default_agent_model_id,
            general_auxiliary_llm_model_id = excluded.general_auxiliary_llm_model_id,
            canvas_agent_model_id = excluded.canvas_agent_model_id,
            vision_model_id = excluded.vision_model_id,
            canvas_vision_model_id = excluded.canvas_vision_model_id,
            approval_model_id = excluded.approval_model_id,
            package_review_model_id = excluded.package_review_model_id,
            auxiliary_image_mode = excluded.auxiliary_image_mode,
            shared_image_model_id = excluded.shared_image_model_id,
            image_generation_model_id = excluded.image_generation_model_id,
            image_editing_model_id = excluded.image_editing_model_id,
            default_video_model_id = excluded.default_video_model_id,
            autonomous_image_routing = excluded.autonomous_image_routing,
            updated_at = excluded.updated_at,
            sync_revision = excluded.sync_revision
        WHERE model_preferences.sync_revision = ?
        """

    /// Reproduces ConfigurationCodec.date encoding (:403-420 encode/decode
    /// pair) for the CAS write + row decode.
    static func encodeDate(_ date: Date) -> String {
        ConfigTimestampCodec.encode(date)
    }

    static func decodeDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "preferencesDateCorrupt")
        }
        return date
    }

    /// Narrow provenance mirror of ConfigurationCodec.preferences(from:)
    /// (ModelConfigurationStore.swift:594-623) for use INSIDE the CAS
    /// transaction (the codec is internal to FloePersistence; the original
    /// public API cannot serve an atomic revision gate).
    static func decodePreferencesRow(_ row: Row) throws -> ModelSelectionPreferences {
        guard let onboardingStatus = OnboardingStatus(rawValue: row["onboarding_status"]),
              let imageMode = AuxiliaryImageMode(rawValue: row["auxiliary_image_mode"]) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "preferencesCorrupt")
        }
        func uuid(_ column: String) -> UUID? {
            let value: String? = row[column]
            return value.flatMap(UUID.init(uuidString:))
        }
        return ModelSelectionPreferences(
            onboardingStatus: onboardingStatus,
            defaultAgentModelID: uuid("default_agent_model_id"),
            generalAuxiliaryLLMModelID: uuid("general_auxiliary_llm_model_id"),
            canvasAgentModelID: uuid("canvas_agent_model_id"),
            visionModelID: uuid("vision_model_id"),
            canvasVisionModelID: uuid("canvas_vision_model_id"),
            approvalModelID: uuid("approval_model_id"),
            packageReviewModelID: uuid("package_review_model_id"),
            autonomousImageRouting: row["autonomous_image_routing"],
            auxiliaryImageMode: imageMode,
            sharedImageModelID: uuid("shared_image_model_id"),
            imageGenerationModelID: uuid("image_generation_model_id"),
            imageEditingModelID: uuid("image_editing_model_id"),
            defaultVideoModelID: uuid("default_video_model_id"),
            updatedAt: try decodeDate(row["updated_at"]),
            syncRevision: row["sync_revision"]
        )
    }

    /// Reproduces ConfigurationCodec.validate(_:preferences:in:) predicate
    /// EQUIVALENCE (:625-689) through the PUBLIC ModelProfile properties
    /// and the SAME "SELECT * FROM models WHERE id = ? AND is_enabled = 1"
    /// fetch; unchanged routes skip exactly like the original ("An
    /// unrelated setting must not be held hostage by a stale route").
    static func validateAssignments(_ preferences: ModelSelectionPreferences,
                                    previous: ModelSelectionPreferences,
                                    in db: Database) throws {
        func model(for key: KeyPath<ModelSelectionPreferences, UUID?>) throws -> ModelProfile? {
            let id = preferences[keyPath: key]
            if previous[keyPath: key] == id { return nil }
            guard let id else { return nil }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM models WHERE id = ? AND is_enabled = 1",
                arguments: [id.uuidString]
            ) else {
                throw ConfigDomainError(code: .notFound,
                                        reason: "preferencesModelUnavailable")
            }
            return try decodeModelRow(row)
        }
        if let selected = try model(for: \.generalAuxiliaryLLMModelID),
           !selected.supportsGeneralAuxiliaryLLM {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "generalAuxiliaryLLMText")
        }
        if let selected = try model(for: \.defaultAgentModelID),
           !selected.supportsChatAgentSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "defaultAgentText")
        }
        if let selected = try model(for: \.canvasAgentModelID),
           !(selected.supportsChatAgentSurface && selected.capabilities.contains(.tools)) {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "canvasAgentTools")
        }
        if let selected = try model(for: \.visionModelID),
           !selected.supportsAuxiliaryVisionSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "visionSurface")
        }
        if let selected = try model(for: \.canvasVisionModelID),
           !selected.supportsAuxiliaryVisionSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "canvasVisionSurface")
        }
        if let selected = try model(for: \.approvalModelID),
           !selected.supportsApprovalSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "approvalText")
        }
        if let selected = try model(for: \.packageReviewModelID),
           !selected.supportsApprovalSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "packageReviewText")
        }
        if let selected = try model(for: \.sharedImageModelID),
           !(selected.supportsImageGenerationSurface
                && selected.capabilities.contains(.imageGeneration)
                && selected.capabilities.contains(.imageEditing)) {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "sharedImageModes")
        }
        if let selected = try model(for: \.imageGenerationModelID),
           !(selected.supportsImageGenerationSurface
                && selected.capabilities.contains(.imageGeneration)) {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "imageGenerationCap")
        }
        if let selected = try model(for: \.imageEditingModelID),
           !(selected.supportsImageGenerationSurface
                && selected.capabilities.contains(.imageEditing)) {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "imageEditingCap")
        }
        if let selected = try model(for: \.defaultVideoModelID),
           !selected.supportsVideoGenerationSurface {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "videoGenerationCap")
        }
    }

    /// Narrow provenance mirror of ConfigurationCodec.model(from:)
    /// (:558-592) — required only for the in-transaction assignment check.
    static func decodeModelRow(_ row: Row) throws -> ModelProfile {
        guard let id = UUID(uuidString: row["id"]),
              let providerID = UUID(uuidString: row["provider_id"]) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelRowCorrupt")
        }
        let pricing: PricingMetadata?
        if let pricingJSON: String = row["pricing_json"] {
            guard let decoded = try? JSONDecoder().decode(PricingMetadata.self,
                                                          from: Data(pricingJSON.utf8)) else {
                throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelPricingCorrupt")
            }
            pricing = decoded
        } else {
            pricing = nil
        }
        return ModelProfile(
            id: id,
            providerID: providerID,
            remoteModelID: row["remote_model_id"],
            displayName: row["display_name"],
            limits: ModelLimits(
                contextTokens: row["context_tokens"],
                maxOutputTokens: row["max_output_tokens"]
            ),
            pricing: pricing,
            capabilities: ModelCapabilities(rawValue: row["capabilities"]),
            useSurfaces: (row["use_surfaces"] as Int?).map(ModelUseSurfaces.init(rawValue:)),
            reasoningEffort: (row["reasoning_effort"] as String?).flatMap(ModelReasoningEffort.init(rawValue:)),
            isEnabled: row["is_enabled"],
            isHiddenFromPrimaryPicker: row["is_hidden_from_primary_picker"],
            explicitCapabilities: (row["explicit_capabilities"] as Int?)
                .map(ModelCapabilities.init(rawValue:))
        )
    }

    // MARK: - config.model.save

    /// CAS save through the ORIGINAL `saveModel(_:expected:)` full-snapshot
    /// compare-and-swap (:53-65). The client's expected snapshot is bound
    /// via the envelope revision digest; a stale digest writes NOTHING, an
    /// unknown id is typed notFound. The reply carries the ACTUAL canonical
    /// stored model (the original codec merges by provider+remoteModelID
    /// preserving stable local UUIDs, :504-513 — "reuse split identity")
    /// plus its new revision digest. Capability JSON shape, user overrides
    /// (explicitCapabilities NULL-vs-0 semantics) and validation rules are
    /// the original ones: the request decodes through the original
    /// ModelProfile Codable and is validated by the original store rules.
    public struct ModelSaveReply: Sendable {
        public let canonicalModel: ModelProfile
        public let revision: ConfigRevision
    }

    public func saveModel(payload: Data, revision: ConfigRevision) async throws -> ModelSaveReply {
        let dictionary = try ConfigJSON.object(from: payload)
        let incoming = try ConfigModelSnapshot.decode(dictionary, context: "model")
        guard revision.resourceID == "model.\(incoming.id.uuidString)" else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelRevisionResource")
        }
        // Validate FIRST through the ORIGINAL public rules so a malformed
        // model never reaches the store as a "stale" confusion
        // (ConfigurationCodec.validate shares FloeError.invalidConfiguration
        // with the CAS rejection; ModelConfigurationStore.swift:53-65,:498-
        // 502). Closed identifiers only (problem rawValues), never message
        // bodies.
        let shapeIssues = ProviderConfigurationValidation.issues(for: incoming)
        guard shapeIssues.isEmpty else {
            let problems = shapeIssues.map { $0.problem.rawValue }
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "modelValidation[\(problems.prefix(8).joined(separator: ","))]")
        }
        let current: ModelProfile?
        do {
            current = try await store.model(id: incoming.id)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelRowQuery")
        }
        guard let current else {
            throw ConfigDomainError(code: .notFound, reason: "modelRowMissing")
        }
        // Revision digest gate (client read snapshot), THEN the durable CAS
        // with the exact persisted snapshot as `expected` — zero overwrite
        // under races; the store throws and writes NOTHING on mismatch.
        let currentDigest = try ConfigModelSnapshot.digest(current)
        guard revision.version == currentDigest else {
            throw ConfigDomainError(code: .staleRevision, reason: "modelSnapshotDigest")
        }
        // Identity invariants: internal id, displayName and remoteModelID
        // stay distinct (contract PRV-IDENTITY-WIRE-SPLIT-AND); the id may
        // not mutate through this path, and the provider must exist and
        // cannot be reassigned.
        guard incoming.id == current.id else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelIDMutation")
        }
        guard incoming.providerID == current.providerID else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelProviderMutation")
        }
        do {
            let provider = try await store.provider(id: incoming.providerID)
            guard provider != nil else {
                throw ConfigDomainError(code: .notFound, reason: "modelProviderMissing")
            }
        } catch let error as ConfigDomainError {
            throw error
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelProviderQuery")
        }
        do {
            try await store.saveModel(incoming, expected: current)
        } catch let error as ConfigDomainError {
            throw error
        } catch {
            // Validation already passed through the original public rules
            // (deterministic), so a throw here is the ORIGINAL full-
            // snapshot CAS rejection (:56-61: nothing was written).
            throw ConfigDomainError(code: .staleRevision, reason: "modelStoreCAS")
        }
        // Canonical readback. The original codec merges by
        // provider+remoteModelID preserving the STABLE existing local UUID
        // (:504-513): editing remoteModelID onto another existing row
        // rebinds the canonical identity ("reuse split identity"), so the
        // reply is the ACTUAL persisted row looked up first by id, then by
        // the canonical provider+remote pair.
        let persisted: ModelProfile?
        do {
            if let direct = try await store.model(id: incoming.id),
               direct.remoteModelID == incoming.remoteModelID {
                persisted = direct
            } else {
                let models = try await store.models(providerID: incoming.providerID)
                persisted = models.first { $0.remoteModelID == incoming.remoteModelID }
            }
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadback")
        }
        guard let canonical = persisted else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadbackMissing")
        }
        return ModelSaveReply(
            canonicalModel: canonical,
            revision: ConfigRevision.model(id: canonical.id,
                                           snapshotDigest: try ConfigModelSnapshot.digest(canonical))
        )
    }

    // MARK: - config.websearch.get / save

    public struct WebSearchReply: Sendable {
        public let revision: ConfigRevision
        public let states: [WebSearchProviderState]
    }

    /// Reads the persisted configurations (ONE app_settings key under the
    /// fixed whitelist) and probes typed credential availability through
    /// the gateway by the ORIGINAL credentialAccount. Secret VALUES are
    /// never serialized into the reply or persisted JSON.
    public func getWebSearch() async throws -> WebSearchReply {
        let (configs, rawText) = try await loadWebSearchConfigurations()
        var states: [WebSearchProviderState] = []
        states.reserveCapacity(configs.count)
        for config in configs {
            if !config.kind.requiresCredential {
                states.append(WebSearchProviderState(configuration: config,
                                                     credentialState: .noCredentialRequired))
                continue
            }
            let reference = ConfigSecretIdentity.webSearchOpaqueReference(
                credentialAccount: config.credentialAccount)
            let status = await secretStore.webSearchCredential(reference: reference)
            let state: WebSearchProviderState.CredentialState
            switch status {
            case .success(let bytes):
                if (try? JSONDecoder().decode(WebSearchCredential.self, from: bytes)) != nil {
                    state = .available
                } else {
                    state = .secretInvalidated
                }
            case .failure(.unavailable(let availability)):
                state = switch availability {
                case .gatewayUnregistered: .gatewayUnregistered
                case .secretMissing: .secretMissing
                case .secretLocked: .secretLocked
                case .secretInvalidated: .secretInvalidated
                }
            case .failure(.configured), .failure(.outcomeUnknown):
                state = .outcomeUnknown
            }
            states.append(WebSearchProviderState(configuration: config, credentialState: state))
        }
        return WebSearchReply(revision: ConfigRevision.webSearch(digest: Self.webSearchDigest(rawText)),
                              states: states)
    }

    /// CAS save of the configuration list (envelope revision version = the
    /// digest returned by get). Payload structure validation uses the
    /// ORIGINAL Codable shapes; credential VALUES can never ride this path
    /// (the closed type has no such field, and raw-credential map-key
    /// refusal guards `options`). NO iCloud/CloudKit/Android-account
    /// permissions are involved: storage stays the single schema-46
    /// app_settings row.
    ///
    /// MC-WEBSEARCH-3: the SAME frozen command now also accepts the closed
    /// optional `credential:{configurationID,intent:keep|set|clear,
    /// saveIntentToken?}` entry (legacy omission == keep, byte-preserved).
    /// Set consumes the one-shot vault lease (expectedSubject webSearchSave)
    /// and writes the ORIGINAL WebSearchCredential bytes at the exact
    /// namespace reference; Clear deletes the current stored/validated
    /// account's secret; both run inside the engine's coordinated chain and
    /// commit the metadata CAS only with their effect (see
    /// WebSearchSecretSaving.swift). No new command, permission or store.
    public func saveWebSearch(payload: Data, revision: ConfigRevision) async throws -> WebSearchReply {
        let dictionary = try ConfigJSON.object(from: payload)
        try ConfigJSON.closed(dictionary,
                              allowed: ["configurations", "credential"],
                              required: ["configurations"],
                              context: "websearch")
        guard let array = dictionary["configurations"] as? [Any] else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchConfigurations")
        }
        guard array.count <= ConfigWebSearchLimits.maximumProviders else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "websearchCount")
        }
        var configs: [WebSearchProviderConfiguration] = []
        configs.reserveCapacity(array.count)
        var seenIDs = Set<UUID>()
        var seenAccounts = Set<String>()
        for element in array {
            let config = try ConfigJSON.decodeCanonical(WebSearchProviderConfiguration.self,
                                                        from: element,
                                                        context: "websearchConfig")
            guard config.id.uuidString.count == 36, config.displayName.utf8.count <= 256,
                  !config.credentialAccount.isEmpty,
                  config.credentialAccount.utf8.count <= 128 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchBounds")
            }
            guard seenIDs.insert(config.id).inserted,
                  seenAccounts.insert(config.credentialAccount).inserted else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchDuplicates")
            }
            try ConfigJSON.assertNoCredentialMapKeys(config.options, context: "websearch.options")
            configs.append(config)
        }
        let credentialRequest = try WebSearchCredentialRequestParser.parse(
            dictionary["credential"], validConfigurationIDs: nil)
        if let request = credentialRequest, request.intent != .clear,
           !seenIDs.contains(request.configurationID) {
            // Set/Keep may only name a configuration submitted in this list;
            // Clear resolves its target from the CURRENT stored list.
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "websearchCredentialTarget")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let normalized = String(decoding: try encoder.encode(configs), as: UTF8.self)
        guard normalized.utf8.count <= ConfigWebSearchLimits.maximumConfigurationJSONBytes else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "websearchJSON")
        }
        // The ONE metadata CAS commit, shared by every intent. Runs inside
        // the caller's chain at the exact point its effect has committed.
        let commit: @Sendable (String) async throws -> Void = { [database] normalizedList in
            try await Self.commitWebSearchList(database: database,
                                               normalized: normalizedList,
                                               expectedDigest: revision.version)
        }
        if let request = credentialRequest, request.intent != .keep {
            // Pre-effect CAS currency probe (mirrors the provider row-read
            // guard): an obviously stale revision refuses BEFORE the lease
            // is consumed or any secret effect runs. The writer transaction
            // re-checks the digest authoritatively at commit time.
            let currentDigest = Self.webSearchDigest(
                try await loadWebSearchConfigurations().1)
            guard currentDigest == revision.version else {
                throw ConfigDomainError(code: .staleRevision, reason: "websearchCasGate")
            }
        }
        switch credentialRequest?.intent {
        case .none, .some(.keep):
            // Keep (or legacy omission): zero secret effects — but the
            // ORIGINAL metadata path still persists the submitted
            // configuration list through the SAME digest-CAS commit. (The
            // first runtime execution of this suite caught the missing
            // commit: the reply re-projected the OLD list.)
            try await commit(normalized)
        case .some(.set):
            guard let request = credentialRequest, let token = request.saveIntentToken else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialTokenMissing")
            }
            // Route comes ONLY from the trusted host registry (never the
            // command envelope); without it the lease is NOT consumed.
            guard let route = routeContext.currentRoute() else {
                throw ConfigDomainError(code: .runtimeUnavailable,
                                        reason: "routeContextUnavailable")
            }
            let lease: SaveIntentLease
            do {
                lease = try SecretSaveIntentVault.shared.consume(
                    token: token, route: route, expectedSubject: .webSearchSave)
            } catch {
                throw SaveIntentConsumption.mapRejection(error)
            }
            guard let target = configs.first(where: { $0.id == request.configurationID }) else {
                _ = lease.close()
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialTarget")
            }
            let outcome = await webSearchEngine.set(configuration: target,
                                                    normalizedList: normalized,
                                                    lease: lease,
                                                    commit: commit)
            switch outcome {
            case .written:
                break // metadata committed by the engine; re-project below
            case .noEffect, .removed:
                // Unreachable for Set; treat as an honest internal refusal.
                throw ConfigDomainError(code: .runtimeUnavailable,
                                        reason: "websearchSetOutcomeUnexpected")
            case .retainedPending(let reason):
                throw ConfigDomainError(code: .runtimeUnavailable,
                                        reason: "websearchSecretPending.\(reason)")
            case .failed(let error):
                throw error
            }
        case .some(.clear):
            guard let request = credentialRequest else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialMissing")
            }
            // Clear targets the CURRENT stored account: read the persisted
            // list (pre-CAS) so the delete aims at what is live NOW.
            let current = try await loadWebSearchConfigurations().0
            let outcome = await webSearchEngine.clear(
                configurationID: request.configurationID,
                incoming: configs,
                current: current,
                normalizedList: normalized,
                commit: commit)
            switch outcome {
            case .removed:
                break
            case .noEffect, .written:
                throw ConfigDomainError(code: .runtimeUnavailable,
                                        reason: "websearchClearOutcomeUnexpected")
            case .retainedPending(let reason):
                throw ConfigDomainError(code: .runtimeUnavailable,
                                        reason: "websearchClearPending.\(reason)")
            case .failed(let error):
                throw error
            }
        }
        // Re-project through get (typed availability included).
        return try await getWebSearch()
    }

    /// The single metadata CAS writer for the web-search configurations row:
    /// digest gate on the EXACT persisted bytes inside ONE writer
    /// transaction, the exact original SettingsStore upsert
    /// (SettingsStore.swift:64-73), then an in-transaction readback check.
    private static func commitWebSearchList(database: DatabaseManager,
                                            normalized: String,
                                            expectedDigest: String) async throws {
        let key = ConfigSettingsKeys.webSearchConfigurations
        do {
            try await database.writer { db -> Void in
                let raw = try Row.fetchOne(
                    db,
                    sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [key]
                )
                let currentText: String? = raw?["value_json"]
                let currentDigest = webSearchDigest(currentText)
                guard currentDigest == expectedDigest else {
                    throw ConfigDomainError(code: .staleRevision, reason: "websearchCasGate")
                }
                // Exact original SettingsStore upsert
                // (SettingsStore.swift:64-73), ONE fixed key.
                try db.execute(
                    sql: """
                        INSERT INTO app_settings (key, value_json, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET
                            value_json = excluded.value_json,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [key, normalized, encodeDate(Date())]
                )
                let readBack = try Row.fetchOne(
                    db,
                    sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [key]
                )
                let stored: String? = readBack?["value_json"]
                guard stored == normalized else {
                    throw ConfigDomainError(code: .persistenceUnavailable,
                                            reason: "websearchReadbackMismatch")
                }
            }
        } catch let error as ConfigDomainError {
            throw error
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchWrite")
        }
    }

    // MARK: - Web-search bootstrap drain + privacy participation (MC-WEBSEARCH-3)

    /// Replays the durable web-search cleanup journal BEFORE domain commands
    /// (same bootstrap position as the provider drain). Entries are
    /// coordinated through the SAME shared ownership gate; outcomes are
    /// honest and secret-free.
    public func drainWebSearchCleanup() async throws -> WebSearchSecretCleanupDrainResult {
        try await webSearchEngine.cleanup.drain(gateway: gateway,
                                                ownership: ownership,
                                                ownedWork: ownedWork,
                                                reconciler: webSearchEngine)
    }

    /// MC-R4 public typed reconciliation seam for a web-search pending owner
    /// (individual physical truth only).
    public func reconcileWebSearchRecovery(configurationID: UUID) async
        -> ProviderRecoveryOutcome
    {
        await webSearchEngine.reconcileWebSearchRecovery(configurationID: configurationID)
    }

    /// Metadata-only privacy inventory (adapter delta for the later privacy
    /// qualifier — see WebSearchSecretSaving.swift header).
    public func webSearchPrivacyInventory() async -> WebSearchPrivacyInventory {
        let (configurations, rawPresent): ([WebSearchProviderConfiguration], Bool)
        do {
            let (list, raw) = try await loadWebSearchConfigurations()
            configurations = list
            rawPresent = raw != nil
        } catch {
            configurations = []
            rawPresent = false
        }
        // entries() throws on a corrupt journal (bytes preserved); the
        // inventory reports presence/count only and treats unreadable as
        // "present, count unknown" via -1 → max(0, ·) = 0 plus a dedicated
        // flag is overkill: the corrupt state surfaces through the drain.
        let journalEntries: Int
        do {
            journalEntries = try await webSearchEngine.cleanup.entries().count
        } catch {
            journalEntries = -1
        }
        return WebSearchPrivacyInventory(
            configurationsPresent: rawPresent,
            configurationCount: configurations.count,
            cleanupJournalPresent: journalEntries >= 0,
            cleanupJournalEntries: max(0, journalEntries),
            credentialBearingCount: configurations.filter { $0.kind.requiresCredential }.count)
    }

    /// Records durable clear intents for every credential-bearing configured
    /// account so a privacy clear-all participates in the ordinary
    /// coordinated recovery discipline (bounded, recoverable, owner-gated) —
    /// never a broad unaccountable wipe, and never touching provider/MCP
    /// namespaces. Returns the number of intents recorded.
    @discardableResult
    public func enqueueWebSearchRetentionClears() async throws -> Int {
        let configurations = try await loadWebSearchConfigurations().0
        // Only intents NEWLY recorded are counted (a durable intent that
        // already owns the configuration is idempotent, not new work).
        let existing = try await webSearchEngine.cleanup.entries()
        var recorded = 0
        for configuration in configurations where configuration.kind.requiresCredential {
            let entry = WebSearchSecretCleanupEntry(
                configurationID: configuration.id,
                account: configuration.credentialAccount,
                intent: .secretClear)
            if existing.contains(where: {
                $0.configurationID == entry.configurationID && $0.intent == entry.intent
            }) {
                continue
            }
            try await webSearchEngine.cleanup.enqueue(entry)
            recorded += 1
        }
        return recorded
    }

    /// Reads via the ORIGINAL `SQLiteSettingsStore.value(forKey:)` public
    /// API (SettingsStore.swift:52-60) — the same single-key SELECT, so the
    /// read path is the untouched original symbol, not a reimplementation.
    private func loadWebSearchConfigurations() async throws -> ([WebSearchProviderConfiguration], String?) {
        let raw: String?
        do {
            raw = try await settings.value(forKey: ConfigSettingsKeys.webSearchConfigurations)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchQuery")
        }
        guard let raw else { return ([], nil) }
        guard raw.utf8.count <= ConfigWebSearchLimits.maximumConfigurationJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchCorrupt")
        }
        guard let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self,
                                                      from: Data(raw.utf8)) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchCorrupt")
        }
        return (decoded, raw)
    }

    /// Revision token for websearch = sha256 over the EXACT persisted
    /// value_json, or the fixed digest of the marker when the row is absent
    /// (real row content gates the CAS; never timestamp-only).
    static func webSearchDigest(_ storedText: String?) -> String {
        if let storedText {
            return ConfigJSON.sha256Hex(Data(storedText.utf8))
        }
        return ConfigJSON.sha256Hex(Data("floe.websearch.absent.v1".utf8))
    }

    // MARK: - Web-search resolver factory (D1/RB6 wiring input)

    /// The ACTUAL `WebSearchConfigurationResolver` closure for
    /// FloeAndroidWebTools WebSearchService, fed by the ORIGINAL
    /// SQLiteSettingsStore rows + gateway secrets fetched by the ORIGINAL
    /// credentialAccount (WebRetrievalModels.swift resolver typealias;
    /// service-map "webtools": "Android resolver = SQLiteSettingsStore +
    /// gateway secret fetch by credentialAccount"). Unreadable/undecodable
    /// credentials are SKIPPED — never fabricated, never anonymous
    /// fallback. Values never persist/log/prompt.
    public func makeWebSearchConfigurationResolver() -> WebSearchConfigurationResolver {
        let store = self
        return {
            await store.resolvedWebSearchConfigurations()
        }
    }

    func resolvedWebSearchConfigurations() async -> [(WebSearchProviderConfiguration, WebSearchCredential)] {
        let configs: [WebSearchProviderConfiguration]
        do {
            configs = try await loadWebSearchConfigurations().0
        } catch {
            return []
        }
        var ready: [(WebSearchProviderConfiguration, WebSearchCredential)] = []
        for config in configs where config.enabled {
            if !config.kind.requiresCredential {
                ready.append((config, WebSearchCredential(values: [:])))
                continue
            }
            let reference = ConfigSecretIdentity.webSearchOpaqueReference(
                credentialAccount: config.credentialAccount)
            switch await secretStore.webSearchCredential(reference: reference) {
            case .success(let bytes):
                guard let credential = try? JSONDecoder().decode(WebSearchCredential.self,
                                                                 from: bytes) else { continue }
                ready.append((config, credential))
            case .failure:
                continue
            }
        }
        return ready
    }

    // MARK: - Provider secret status (typed, no command name invented)

    public func providerSecretStatus(providerID: UUID) async throws -> ConfigSecretStatus {
        let profile: ProviderProfile?
        do {
            profile = try await store.provider(id: providerID)
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "providerRowQuery")
        }
        guard let profile else {
            throw ConfigDomainError(code: .notFound, reason: "providerRowMissing")
        }
        if ProviderConfigurationValidation.ProviderConnectionIdentity.authStyle(for: profile.kind) == "none" {
            return .configured // explicit no-auth: the presence question is void
        }
        guard let account = profile.secretRef?.keychainAccount else {
            return .unavailable(.secretMissing)
        }
        return await secretStore.secretStatus(account: account)
    }

    // MARK: - Recording helper

    func recordEffect(receipt: String, kind: String, json: Data) {
        effectSink?.recordConfigEffect(operationReceiptID: receipt,
                                       kind: kind,
                                       json: json)
    }
}
