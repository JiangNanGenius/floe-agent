// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — small provider implementations that close the
// ordinary-base dependency graph. Each conforms to an EXACT protocol owned
// by a delivered domain package; none reimplements a domain algorithm.
//
// Temporary-session and privacy adapters (web-search availability for the
// temp ceiling, grant-store adapters, event-drop bridge) live with their
// optional-domain extension successors through the G02DomainExtension seam;
// the ordinary base neither constructs nor advertises them.
import Foundation
#if canImport(Android)
import Android
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import GRDB
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
import FloeAndroidWebTools

// MARK: - RB2 config facade providers

/// One trusted host route binding: the native-issued router token/generation
/// frozen to the accepted Root epoch that minted it and to the App editor
/// incarnation (kind + editor identity + shared monotonic UI generation) that
/// owns the live editor sheet.
struct G02HostRouteBinding {
    let route: RouteBinding
    let rootEpoch: UInt64
    let editorKind: String
    let editorID: String
    let uiGeneration: UInt64
}

/// The trusted host route registry for provider/MCP/web-search secure
/// saves. This is the ONE native authority the three secure-ingress
/// consumers share (`ConfigRouteContextProviding` +
/// `SkillsMcpRouteContextProviding`): route tokens are minted here (never by
/// the App/editor, never from model-authored JSON) and are scoped to
///
///  * the CURRENT accepted native Root epoch (`G02NativeRootEpoch.readback()`
///    — the actual bootstrap generation, NOT a UI counter), captured by the
///    App AT EDITOR CREATION and asserted again at open, and
///  * ONE live editor incarnation: the App-wide shared UI generation plus the
///    editor identity/kind.
///
/// Linearization rules:
///  * `currentRoute()` answers ONLY while the binding's Root epoch is the
///    live accepted epoch and admissions are not fenced. Retirement clears
///    only its own epoch's binding, so a newer Root's route is untouched.
///  * `openEditorRoute` refuses a stale/foreign Root (expected epoch != live
///    accepted epoch), refuses any editor incarnation older than the newest
///    admission, is IDEMPOTENT for the currently admitted editor (same kind,
///    identity and shared UI generation) and otherwise admits a genuinely
///    newer incarnation. A late callback from an old editor can therefore
///    neither mint authority nor evict the newer editor's binding.
///  * `clearEditorRoute(token:)` removes the binding ONLY on the exact
///    minted token, and then discards that route's UNCONSUMED live vault
///    intents. Consumed (ACTIVE) leases belong to their handler until its
///    own terminal close and are never dropped here.
///  * `retireBoundRoute(epoch:)` performs the same exact-ownership clear +
///    live-slot sweep for the retiring Root epoch only.
///  * `submitBoundIntent` checks the live epoch AND the caller's own route
///    assertion under the SAME registry lock that retirement must take, so a
///    Root retire/open/submit race is linearized: a pre-fence admission is
///    ordered before the fence and its live intent is swept by that fence,
///    while a post-fence submit finds no binding and fails closed.
public final class G02HostRouteContextProvider: ConfigRouteContextProviding, SkillsMcpRouteContextProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var binding: G02HostRouteBinding?
    /// Last admitted editor incarnation. Survives its binding's close so a
    /// resurrected old callback can never be re-admitted after a newer
    /// editor was admitted (monotonic shared UI generation).
    private var lastEditorID: String?
    private var lastEditorKind: String?
    private var lastUIGeneration: UInt64 = 0
    private var generationCounter: UInt64 = 0
    /// Production: the ACTUAL accepted native Root epoch. Tests within this
    /// module can substitute a scripted epoch (component branches only; the
    /// actual bootstrap is exercised by the composition tests).
    private var epochOverride: (@Sendable () -> UInt64?)?

    public init() {}

    /// The closed editor kinds a trusted host editor may bind. The kind is
    /// also the subject kind the bound route may submit: a provider editor
    /// can never mint MCP or web-search authority and vice versa.
    static let editorKindSubject: [String: SubjectKind] = [
        "provider": .providerSave,
        "mcp": .mcpSave,
        "webSearch": .webSearchSave,
    ]

    private func acceptedEpochLocked() -> UInt64? {
        if let epochOverride { return epochOverride() }
        return G02NativeRootEpoch.readback()
    }

    /// Current accepted epoch snapshot for honest refusal classification.
    func acceptedEpochSnapshot() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedEpochLocked()
    }

    /// Atomically admit ONE live editor incarnation and mint its route.
    /// `expectedNativeRootEpoch` is the value the App captured when it
    /// created the editor; it must still be the live accepted epoch.
    /// Everything is validated BEFORE any mutation.
    public func openEditorRoute(editorKind: String, editorID: String,
                                uiGeneration: UInt64,
                                expectedNativeRootEpoch: UInt64) -> RouteBinding? {
        guard G02HostRouteContextProvider.editorKindSubject[editorKind] != nil,
              G02HostRouteContextProvider.isValidEditorID(editorID),
              uiGeneration > 0,
              expectedNativeRootEpoch > 0 else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard let epoch = acceptedEpochLocked(), epoch == expectedNativeRootEpoch else {
            // Stale or foreign Root callback: no mutation, no authority.
            return nil
        }
        if uiGeneration == lastUIGeneration {
            // Idempotent only for the CURRENTLY admitted editor (same kind,
            // identity and shared UI generation) while its binding is live.
            guard editorID == lastEditorID, editorKind == lastEditorKind,
                  let live = binding,
                  live.editorID == editorID, live.editorKind == editorKind else {
                return nil
            }
            return live.route
        }
        guard uiGeneration > lastUIGeneration else {
            // An older incarnation can never take over a newer one.
            return nil
        }
        // A genuinely NEWER editor takes the ONE live route: the replaced
        // route's UNCONSUMED live vault intents are retired WITH the
        // replacement (otherwise the old secret and its bounded LIVE slot
        // capacity would linger until TTL after its late close becomes a
        // no-op). ACTIVE claimed leases are never touched, and a failed or
        // replayed open returns before this point with zero mutation.
        if let previous = binding {
            discardLiveIntentsLocked(route: previous.route)
        }
        generationCounter &+= 1
        if generationCounter == 0 { generationCounter = 1 }
        let token = G02HostRouteContextProvider.makeRouteToken()
        let route = RouteBinding(token: token, generation: generationCounter)
        binding = G02HostRouteBinding(route: route, rootEpoch: epoch,
                                      editorKind: editorKind,
                                      editorID: editorID,
                                      uiGeneration: uiGeneration)
        lastEditorID = editorID
        lastEditorKind = editorKind
        lastUIGeneration = uiGeneration
        return route
    }

    /// Exact-ownership close. A token that no longer names the live binding
    /// is an idempotent no-op and can never clear a newer editor's route.
    /// The close also discards this route's UNCONSUMED live vault intents.
    @discardableResult
    public func clearEditorRoute(token: String) -> Bool {
        guard G02HostRouteContextProvider.isCanonicalRouteToken(token) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard let live = binding else { return true }
        guard live.route.token == token else { return true }
        binding = nil
        discardLiveIntentsLocked(route: live.route)
        // Editor close also owns its DRAFT probe work: cancel the real
        // adapter calls and retire the slots (late polls answer typed
        // routeUnavailable; the App's identity fence already ignores late
        // publications).
        G02HostDraftProbeRegistry.shared.cancelAll(routeToken: live.route.token)
        ProviderModelSetRegistry.shared.cancelAll(routeToken: live.route.token)
        return true
    }

    /// Root-retirement fence: clears ONLY the binding this exact epoch
    /// minted (its own unconsumed live intents included). A newer Root's
    /// binding is never touched, and ACTIVE leases are never dropped.
    public func retireBoundRoute(epoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let live = binding, live.rootEpoch == epoch else { return }
        binding = nil
        discardLiveIntentsLocked(route: live.route)
        // Root retirement sweeps this epoch's DRAFT probe work as well: the
        // owned adapter tasks are cancelled (real network cancellation) and
        // their slots retired, so no late callback can be read as current.
        G02HostDraftProbeRegistry.shared.cancelAll(routeToken: live.route.token)
        ProviderModelSetRegistry.shared.cancelAll(routeToken: live.route.token)
        ProviderModelSetRegistry.shared.cancelAll(rootEpoch: epoch)
    }

    private func discardLiveIntentsLocked(route: RouteBinding) {
        _ = SecretSaveIntentVault.shared.discardLiveSlots(routeToken: route.token,
                                                          routeGeneration: route.generation)
    }

    /// Trusted-host DRAFT probe assertion (no vault slot): answers the live
    /// binding ONLY when this exact token is the current admitted PROVIDER
    /// editor route and its Root epoch is still the accepted live epoch. The
    /// draft-probe registry calls this before any dispatch; it never mints
    /// authority itself. Lock order: caller takes NO probe-registry lock
    /// across this call (route → probe only).
    func assertLiveProviderRoute(token: String) -> G02HostRouteBinding? {
        guard G02HostRouteContextProvider.isCanonicalRouteToken(token) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let epoch = acceptedEpochLocked(), let live = binding,
              live.rootEpoch == epoch, live.route.token == token,
              live.editorKind == "provider" else {
            return nil
        }
        return live
    }

    public func currentRoute() -> RouteBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let binding else { return nil }
        guard let epoch = acceptedEpochLocked(), epoch == binding.rootEpoch else {
            return nil
        }
        return binding.route
    }

    /// The frozen one-shot credential submit for the bound HOST route. The
    /// caller supplies ONLY the closed intent core (subject/intent/candidate/
    /// baseRevision) plus the route token it was minted; the route pair is
    /// injected here from the live binding under the same lock that proves
    /// the epoch and the caller's ownership.
    func submitBoundIntent(intentCoreJSON: Data, routeAssertion: String,
                           secret: Data) throws -> String {
        guard !secret.isEmpty else { throw G02HostSecureIngressError.emptySecret }
        guard secret.count <= SecretSaveIntentLimits.maximumSecretBytes else {
            throw G02HostSecureIngressError.secretTooLarge
        }
        guard !intentCoreJSON.isEmpty else {
            throw G02HostSecureIngressError.invalidIntent
        }
        guard intentCoreJSON.count <= SecretSaveIntentLimits.maximumIntentJSONBytes else {
            throw G02HostSecureIngressError.intentTooLarge
        }
        guard let object = (try? JSONSerialization.jsonObject(with: intentCoreJSON))
                as? [String: Any] else {
            throw G02HostSecureIngressError.invalidIntent
        }
        // The App never carries route authority: a core intent that names a
        // route (or anything outside the closed core vocabulary) is refused
        // before any vault slot is stored.
        let coreKeys: Set<String> = ["subject", "intent", "candidate", "baseRevision"]
        guard Set(object.keys).isSubset(of: coreKeys),
              object["route"] == nil else {
            throw G02HostSecureIngressError.invalidIntent
        }
        guard let subject = object["subject"] as? [String: Any],
              let kindRaw = subject["kind"] as? String,
              let kind = SubjectKind(rawValue: kindRaw) else {
            throw G02HostSecureIngressError.invalidIntent
        }
        lock.lock()
        defer { lock.unlock() }
        guard let epoch = acceptedEpochLocked(), let live = binding,
              live.rootEpoch == epoch else {
            throw G02HostSecureIngressError.routeUnavailable
        }
        guard G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion),
              live.route.token == routeAssertion else {
            throw G02HostSecureIngressError.routeAssertionMismatch
        }
        guard G02HostRouteContextProvider.editorKindSubject[live.editorKind] == kind else {
            throw G02HostSecureIngressError.routeAssertionMismatch
        }
        var enriched = object
        enriched["route"] = [
            "token": live.route.token,
            "generation": live.route.generation,
        ] as [String: Any]
        guard let full = try? JSONSerialization.data(withJSONObject: enriched,
                                                     options: [.sortedKeys]) else {
            throw G02HostSecureIngressError.invalidIntent
        }
        return try SecretSaveIntentVault.shared.submit(intentJSON: full, secret: secret)
    }

    // MARK: Tokens / identities

    static func makeRouteToken() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        return "rt:v1:" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical host route handle: `rt:v1:` + 32 lowercase hex (38 bytes).
    static func isCanonicalRouteToken(_ value: String) -> Bool {
        let prefix = "rt:v1:"
        guard value.hasPrefix(prefix) else { return false }
        let hex = value.dropFirst(prefix.count)
        guard hex.count == 32 else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// Editor identity the C ABI accepts: 1...128 printable ASCII bytes.
    static func isValidEditorID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    }

    // MARK: Internal test control (never exposed over JNI or V3)

    func configureEpochForTesting(_ provider: (@Sendable () -> UInt64?)?) {
        lock.lock()
        epochOverride = provider
        lock.unlock()
    }

    func resetRouteForTesting() {
        lock.lock()
        binding = nil
        lastEditorID = nil
        lastEditorKind = nil
        lastUIGeneration = 0
        generationCounter = 0
        epochOverride = nil
        lock.unlock()
    }
}

/// The admitted runtime epoch for owned-work attach / save coordination.
/// Answers ONLY while the accepted generation is live and not draining.
public struct G02CompositionEpochProvider: ConfigRuntimeEpochProviding {
    public init() {}

    public func currentEpoch() -> UInt64? {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
              !pumps.mailbox.isAdmissionFenced else { return nil }
        return pumps.epoch
    }
}

/// Typed terminal config effects onto the generation's effect pump.
/// `json` is deliberately NOT persisted into effects: the frozen effect
/// vocabulary is identifier-only; the typed body rides the command's own
/// typed carrier. The sink therefore records the terminal kind + wire kind.
public struct G02ConfigEffectSink: ConfigOperationEffectRecording {
    private let effects: FacadeEffectPump

    public init(effects: FacadeEffectPump) {
        self.effects = effects
    }

    public func recordConfigEffect(operationReceiptID: String,
                                   kind: String,
                                   json: Data) {
        let mapped: RuntimeEffectItem.Kind
        switch kind {
        case "accepted": mapped = .accepted
        case "rejected": mapped = .rejected
        case "failed": mapped = .failed
        case "cancelled": mapped = .cancelled
        default: mapped = .accepted
        }
        effects.append(receipt: operationReceiptID, kind: mapped,
                       detail: ["wireKind": kind])
    }
}

// MARK: - RB6 host context / websearch availability

public struct G02SkillsHostContextProvider: SkillsHostContextProviding {
    private let rootFingerprint: String

    public init(rootFingerprint: String) {
        self.rootFingerprint = rootFingerprint
    }

    public func appVersion() -> String? {
        // Trusted host binds the real semantic version at integration;
        // nil keeps catalog/official flows fail-closed typed.
        nil
    }

    public func rootFingerprint(epoch: UInt64) -> String? {
        // Fingerprint is epoch-independent process-local truth; the caller
        // validates the epoch itself.
        rootFingerprint
    }
}

/// capability.tools.list websearch availability: true only when an enabled
/// provider exists whose credential resolves (or needs none) — RB2
/// `WebSearchProviderState` semantics.
public struct G02CapabilitiesWebSearchProvider: CapabilitiesWebSearchProviding {
    private let facade: ModelConfigurationFacade

    public init(facade: ModelConfigurationFacade) {
        self.facade = facade
    }

    public func providerBackedSearchAvailable() async -> Bool {
        do {
            let reply = try await facade.getWebSearch()
            return reply.states.contains { state in
                state.configuration.enabled &&
                    (state.credentialState == .available ||
                     state.credentialState == .noCredentialRequired)
            }
        } catch {
            return false
        }
    }
}

// MARK: - RB3b content ports

/// Personalization content staging over the per-generation RB1 content
/// reader (the ONLY byte store; personalization owns no bytes of its own).
public struct G02PersonalizationContentPort: PersonalizationContentStoring {
    private let content: FacadeContentReader

    public init(content: FacadeContentReader) {
        self.content = content
    }

    public func stage(_ bytes: Data) async -> PersonalizationContentStage {
        switch content.stage(bytes) {
        case .staged(let handle): return .staged(handle: handle)
        case .rejected(.contentSaturated): return .contentSaturated
        case .rejected(.emptyContent): return .emptyContent
        }
    }

    public func read(handle: String, offset: Int,
                     maxBytes: Int) async -> PersonalizationContentSlice {
        switch content.read(handle: handle, offset: offset, maxBytes: maxBytes) {
        case .slice(let bytes, let nextOffset, let complete):
            return .slice(bytes: bytes, nextOffset: nextOffset, complete: complete)
        case .notFound: return .notFound
        case .invalidOffset: return .invalidOffset
        }
    }

    public func release(handle: String) async {
        content.release(handle: handle)
    }
}

// MARK: - RB3 content ports

/// RB3 `ConversationContentPublishing` over the same per-generation reader.
public struct G02ConversationContentPublisher: ConversationContentPublishing {
    private let content: FacadeContentReader

    public init(content: FacadeContentReader) {
        self.content = content
    }

    public func stage(_ bytes: Data) async -> ConversationContentStageResult {
        switch content.stage(bytes) {
        case .staged(let handle): return .staged(handle: handle)
        case .rejected(.contentSaturated): return .saturated
        case .rejected(.emptyContent): return .rejectedEmpty
        }
    }

    public func read(handle: String, offset: Int,
                     maxBytes: Int) async -> ConversationContentSliceOutcome {
        switch content.read(handle: handle, offset: offset, maxBytes: maxBytes) {
        case .slice(let bytes, let nextOffset, let complete):
            return .slice(bytes: bytes, nextOffset: nextOffset, complete: complete)
        case .notFound: return .notFound
        case .invalidOffset: return .invalidOffset
        }
    }

    public func release(handle: String) async {
        content.release(handle: handle)
    }
}

/// Memory lane's conversations-label delegate: serves the shared
/// `content.read` applicationConfiguration key by delegating to the RB3
/// domain (resolved lazily so either construction order is safe).
public struct G02ConversationContentReadDelegate: ConversationContentReadDelegate {
    private let domainProvider: @Sendable () async -> FacadeConversationDomain?

    public init(domainProvider: @escaping @Sendable () async -> FacadeConversationDomain?) {
        self.domainProvider = domainProvider
    }

    public func readConversationsScopedContent(
        payload: SettingsDomainV1.JSONValue) async throws -> DesignJSONValue {
        guard let domain = await domainProvider() else {
            throw ConversationDomainError.runtimeUnavailable("conversationDomainUnbound")
        }
        let reply = try await domain.readContentFromConversationsLabel(
            configurationScope: "conversations", payload: payload)
        return DesignJSONValue.from(foundation: reply.wireObject)
    }
}

// MARK: - RB3 history ports

/// Conversation row revision reader for the RB4 launch CAS.
public struct G02ConversationRevisionReader: RunConversationRevisionReading {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func digest(conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try ConversationRowRevision.digest(db: db, conversationID: conversationID)
        }
    }

    /// Repair (G06, 2026-10-30): the documented contract is "exists AND
    /// purpose 'ordinary'". The previous body answered `digest != nil`, which
    /// also proved a `notes`/`temporary` row at the ordinary wire pre-check
    /// (the launch writer's own purpose check refused it later, so the leak was
    /// never an execution path — but the proof was wrong). Read the REAL
    /// purpose through the same reader; every ordinary row keeps the identical
    /// answer and every non-ordinary row answers exactly like absence.
    public func ordinaryExists(conversationID: UUID) async throws -> Bool {
        try await purpose(of: conversationID) == .ordinary
    }

    /// The row's real durable purpose, or nil when the row is absent.
    public func purpose(of conversationID: UUID) async throws -> ConversationPurpose? {
        try await database.reader { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT purpose FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]) else { return nil }
            return ConversationPurpose(rawValue: raw)
        }
    }
}

/// Workspace private-task directory cleanup bounded to the trusted root.
///
/// R5 truth: the previous implementation standardized the caller's
/// relative path through `URL(fileURLWithPath:)` — which resolves a
/// relative path against the process CWD and is therefore ALWAYS absolute —
/// and then rejected every absolute result as traversal. Every real cleanup
/// deterministically failed and was reported as the opaque
/// `privateWorkspaceCleanupUnavailable`. This implementation validates the
/// RAW relative input component-wise, enforces the materializer's owned
/// shape `PrivateTasks/<conversation uuid>` (WorkspaceStore.swift /
/// RunLaunchStore.swift), and resolves strictly inside
/// `<root>/Workspace`. The on-disk effect is reported truthfully:
/// `.removed` (an owned directory was actually deleted), `.absent` (nothing
/// existed; the lifecycle goal was already satisfied), or a typed refusal
/// with the filesystem untouched (traversal, wrong shape, or a foreign
/// entry — symlink/regular file — whose destination or content is never
/// touched).
///
/// G02-R7 containment repair: the managed root and EVERY intermediate
/// component (`Workspace`, `Workspace/PrivateTasks`, then the final owned
/// entry) are validated with non-following `lstat` metadata. A symlink at
/// any of those levels — including a symlink whose destination is external
/// user data — is a typed `workspaceTargetForeign` refusal that preserves
/// the link and its destination. Only an authoritative `ENOENT` is reported
/// as `.absent`; every other errno (EACCES, EIO, ENOTDIR, ...) is a typed
/// failure so a permission or I/O problem can never masquerade as "nothing
/// to clean". The caller's raw relative path is never used as an absolute
/// path and an embedded NUL is refused before any filesystem call.
public struct G02WorkspaceCleaning: ConversationOwnedWorkspaceCleaning {
    private let root: RuntimeStorageRoot

    public init(root: RuntimeStorageRoot) {
        self.root = root
    }

    /// Non-following kind of one path component. `.absent` is ONLY returned
    /// for an authoritative `ENOENT`; a missing/foreign parent directory in
    /// the middle of the path (`ENOTDIR`) is a containment problem, never
    /// absence.
    private enum EntryKind {
        case directory
        case symbolicLink
        case other
        case absent
    }

    private func entryKind(_ path: String) throws -> EntryKind {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            switch errno {
            case ENOENT:
                return .absent
            case ENOTDIR:
                // An ancestor is not a directory (a file or a replaced
                // component): the owned shape no longer holds.
                throw ConversationDomainError.sessionFenced(
                    "workspaceTargetForeign")
            default:
                // Permission/I/O/other: NOT absence.
                throw ConversationDomainError.runtimeUnavailable(
                    "workspaceTargetUnreadable")
            }
        }
        let mode = info.st_mode & mode_t(S_IFMT)
        if mode == mode_t(S_IFLNK) { return .symbolicLink }
        if mode == mode_t(S_IFDIR) { return .directory }
        return .other
    }

    /// Validates ONE owned path component. Missing -> `false` (the caller
    /// reports authoritative absence); non-directory/link -> typed foreign
    /// refusal with nothing touched.
    private func requireDirectory(_ path: String) throws -> Bool {
        switch try entryKind(path) {
        case .directory:
            return true
        case .absent:
            return false
        case .symbolicLink, .other:
            throw ConversationDomainError.sessionFenced(
                "workspaceTargetForeign")
        }
    }

    public func removePrivateTaskDirectory(relativePath: String) async throws
        -> PrivateTaskDirectoryRemoval
    {
        // 1. The RAW input must be a plain relative path. Anything absolute,
        //    carrying traversal/dot components or an embedded NUL refuses
        //    BEFORE any filesystem call. (`URL(fileURLWithPath:)` may NOT be
        //    used for this check: it resolves relatives against the CWD,
        //    and POSIX would silently truncate at NUL.)
        guard !relativePath.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ConversationDomainError.invalidEnvelope("workspacePathTraversal")
        }
        guard !relativePath.hasPrefix("/") else {
            throw ConversationDomainError.invalidEnvelope("workspacePathTraversal")
        }
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains("."),
              !components.contains("") else {
            throw ConversationDomainError.invalidEnvelope("workspacePathTraversal")
        }
        // 2. Owned-shape guard: the ONLY materialized private-task layout is
        //    exactly `PrivateTasks/<conversation uuid>`. This blocks
        //    arbitrary model-supplied URLs/prefixes by construction and can
        //    never express a project repo, a shared/base environment
        //    resource, Notes/Canvas data, an SAF document or an exported
        //    user file — none of those live under the managed root.
        guard components.count == 2,
              components[0] == "PrivateTasks",
              UUID(uuidString: components[1]) != nil else {
            throw ConversationDomainError.invalidEnvelope("workspacePathShape")
        }
        // The trusted root path is host-supplied and already validated. We
        // never walk the whole absolute prefix (a platform root such as
        // /var may legitimately be a link); the managed components below it
        // are the ones this port must prove.
        let workspaceRoot = URL(fileURLWithPath: root.path)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
        let privateTasksRoot = workspaceRoot
            .appendingPathComponent("PrivateTasks", isDirectory: true)
        let target = privateTasksRoot
            .appendingPathComponent(components[1], isDirectory: true)
        // 3. Containment: defense in depth behind the component guards.
        guard target.standardizedFileURL.path
            .hasPrefix(workspaceRoot.path + "/") else {
            throw ConversationDomainError.invalidEnvelope("workspacePathTraversal")
        }
        // 4. Entry-type truth with NON-FOLLOWING metadata at every managed
        //    level. A symlink at the managed root or at PrivateTasks may
        //    point at external user data: refuse typed and touch NOTHING
        //    (do not unlink the link, do not read/write the destination).
        //    Only an authoritative ENOENT is `.absent`.
        guard try requireDirectory(workspaceRoot.path) else { return .absent }
        guard try requireDirectory(privateTasksRoot.path) else { return .absent }
        switch try entryKind(target.path) {
        case .directory:
            break
        case .absent:
            return .absent
        case .symbolicLink, .other:
            throw ConversationDomainError.sessionFenced(
                "workspaceTargetForeign")
        }
        // 5. Re-validate the SAME non-following facts immediately before the
        //    effect. The app-private root is not shared with other apps; this
        //    second check narrows the window in which an in-process replace
        //    could redirect the path resolution.
        guard try requireDirectory(workspaceRoot.path),
              try requireDirectory(privateTasksRoot.path) else {
            return .absent
        }
        switch try entryKind(target.path) {
        case .directory:
            break
        case .absent:
            return .absent
        case .symbolicLink, .other:
            throw ConversationDomainError.sessionFenced(
                "workspaceTargetForeign")
        }
        // 6. Bounded recursive removal of the OWNED directory only.
        //    `removeItem` never follows symlinks inside the tree (it
        //    unlinks them), so an embedded link can never redirect the
        //    deletion outside the owned directory. A mid-removal failure
        //    throws: partial contents stay recoverable and the durable V36
        //    queue row survives for the retry sweep.
        try FileManager.default.removeItem(at: target)
        return .removed
    }
}
