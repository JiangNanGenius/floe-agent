// SPDX-License-Identifier: MPL-2.0
//
// G04WorkspaceDomainExtension — the REAL optional-domain extension that binds
// the closed workspace.read / workspace.write / workspace.activate commands to
// the accepted generation over MAIN's actual document/file authority.
//
// It follows the established `G02DomainExtension` seam exactly like the
// temporary and privacy packages:
//   * registered in the idle pre-bootstrap window
//     (`G04WorkspaceDomainRegistration.registerIfNeeded`);
//   * `attach` constructs the ONE root-owned facade over the SAME installed
//     cluster (one original DatabaseManager), the SAME live run domain
//     fences/deletion lifecycle and the REAL `G04LiveWorkspaceAccess`
//     resolver+authorizer pair built below — never an always-true
//     authorization placeholder;
//   * the three handlers are registered ONLY after every real service was
//     constructed, and `attach` self-rolls back on any refusal;
//   * `beginRetirement(epoch:)` is epoch-exact: it fences the facade,
//     preserves dirty drafts to verified native-owned recovery (or keeps them
//     honestly pending in this process-retained instance), expires the query
//     snapshots, and unregisters exactly the keys this extension bound. A
//     stale epoch can never touch a newer generation's graph.
//
// The ordinary product (provider configuration, chat, memory, history)
// installs and works INDEPENDENTLY: a workspace attach refusal leaves only
// the three workspace keys unregistered (the frozen fail-closed
// `runtimeUnavailable` refusal) and never gates ordinary use.
import Foundation
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkspace
import FloeAgentRuntime

// MARK: - Trusted composition of the live access port

/// Builds the REAL `G04LiveWorkspaceAccess` for the accepted generation. The
/// resolver and authorizer close over the SAME original installed cluster
/// only; imported content, model output and bridge payloads cannot install
/// or widen these closures.
enum G04WorkspaceComposition {
    static func liveAccess(epoch: UInt64,
                           installed: G02InstalledComposition) -> G04LiveWorkspaceAccess {
        G04LiveWorkspaceAccess(
            epoch: epoch,
            authorize: { owner, intent, target, cancellation in
                // Native validated ownership over the ORIGINAL records — this
                // is the mandatory authorizer, never `return`.
                try cancellation.throwIfCancelled()
                guard owner.epoch == epoch,
                      G02NativeRootEpoch.readback() == epoch,
                      let live = G02RuntimeComposition.shared.installedComposition,
                      live === installed, live.epoch == epoch
                else { throw G04DocumentError.retired }
                guard let conversation = try await live.cluster.conversationStore
                    .conversation(id: owner.taskID), conversation.purpose == .ordinary
                else { throw G04DocumentError.ownerChanged }
                try cancellation.throwIfCancelled()
                guard try await live.cluster.workspaceStore.workspaceID(conversationID: owner.taskID)
                        == owner.workspaceID,
                      let workspace = try await live.cluster.workspaceStore.workspace(id: owner.workspaceID),
                      workspace.kind == .privateTask
                else { throw G04DocumentError.ownerChanged }
                if let target, intent == .write || intent == .fileMutation {
                    // Independent containment proof re-derived from the
                    // ORIGINAL accepted-root identity (not from the payload
                    // or the guard's own state): the mutation endpoint must
                    // live inside the accepted private-task root of THIS
                    // conversation. A symlink swap under the root resolves to
                    // a physical path outside the canonical component and
                    // refuses here, in addition to the guard's own checks.
                    let canonical = URL(fileURLWithPath: live.cluster.identity.root.path)
                        .appendingPathComponent("Workspace/PrivateTasks", isDirectory: true)
                        .appendingPathComponent(owner.taskID.uuidString, isDirectory: true)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    let allowed = canonical.path
                    guard target.resolvedURL.path == allowed
                            || target.resolvedURL.path.hasPrefix(allowed + "/") else {
                        throw G04DocumentError.ownerChanged
                    }
                    // Native-owned durable recovery bytes are never a normal
                    // workspace payload's destructive target.
                    let logical = target.logicalPath
                    guard !logical.hasPrefix("Recovered Edits/") else {
                        throw G04DocumentError.ownerChanged
                    }
                }
                try cancellation.throwIfCancelled()
            },
            resolve: { owner, cancellation in
                // The exact persisted private-task shape via the ORIGINAL
                // authority. A managed/source (SAF/webdav/smb) write layer
                // requires its own ORIGINAL workspace record/source binding
                // through the trusted source coordinator; nothing here ever
                // reinterprets a `content://` as a POSIX path or guesses a
                // first project.
                return try await G04LiveWorkspaceAccess.privateTaskService(owner, cancellation: cancellation)
            })
    }
}

// MARK: - The extension

final class G04WorkspaceDomainExtension: G02DomainExtension, @unchecked Sendable {
    let id = G02DomainExtensionKey.workspace
    let domains: [G02DomainKey] = [.workspaceDomain]

    private var facade: G04WorkspaceFacade?
    private var attachedEpoch: UInt64?
    private var registeredKeys: [String] = []
    private var attachedComposition: G02InstalledComposition?
    /// Synchronous mirror of `attachedEpoch` for the pre-drain gate (the
    /// bootstrap adoption reads it OUTSIDE any actor hop; only the same
    /// install/retirement sequence writes both).
    private let gateLock = NSLock()
    private var gateEpoch: UInt64?
    /// A retired-but-unsettled facade is kept ONLY when the ORIGINAL close
    /// path already completed without a proven settlement (the bounded
    /// `retireFailed` edge order — the normal gated shutdown cannot reach
    /// `beginRetirement` while the lease is held). Its honestly-pending
    /// drafts stay REFERENCED (never dropped, never claimed durable) and the
    /// next live attach re-drives the same verified pass BEFORE handlers
    /// bind; explicit successful deletion discards them there.
    private var unsettledFacade: G04WorkspaceFacade?

    init() {}

    func expectedHandlerKeys(for domain: G02DomainKey) -> [String] {
        guard domain == .workspaceDomain else { return [] }
        return Self.handlerKeys
    }

    static var handlerKeys: [String] {
        [
            BridgeV3.handlerKey(scope: .conversationLifecycle, command: "workspace.read"),
            BridgeV3.handlerKey(scope: .conversationLifecycle, command: "workspace.write"),
            BridgeV3.handlerKey(scope: .conversationLifecycle, command: "workspace.activate"),
        ]
    }

    func attach(to installed: G02InstalledComposition,
                gen: AndroidRuntimeBootstrap.Generation) async -> Bool {
        let epoch = gen.epoch
        guard attachedEpoch == nil else { return false }
        // The workspace lifecycle is conversation-owned: absent run domain is
        // an honest fail-closed attach refusal (ordinary base stays live).
        guard let (runDomain, _) = RunDomainFacade.current(epoch: epoch) else { return false }
        let access = G04WorkspaceComposition.liveAccess(epoch: epoch, installed: installed)
        let facade = G04WorkspaceFacade(epoch: epoch, installed: installed,
                                        runDomain: runDomain, access: access)
        // Bind the original Git tools at the first isolated step (Swift 6
        // actor init cannot capture self): strictly BEFORE the transport
        // attach, handler registration and every registry publication below,
        // so no published facade ever lacks its fourteen guarded tools.
        await facade.bindGitTools()
        // The SAF provider transport port is REAL from attach on: tickets
        // dispatch only once Main's Kotlin gateway pump binds the SAME epoch
        // through `floe_g04_source_bind`; until then every provider-touching
        // call answers typed transportNotBound (no fake granted/written
        // callbacks, no success string).
        guard await facade.source.attachTransport(G04WorkspaceSourceMailboxTransport()) else {
            return false
        }
        // Re-drive a previously unsettled retirement FIRST (before handlers
        // become visible): same verified write + read-back against THIS live
        // composition; deleted conversations discard, unproven bytes stay
        // referenced on the old facade — never advertised as recovered.
        if let unsettled = unsettledFacade, await unsettled.retirementPreservationPass() {
            unsettledFacade = nil
        }
        let keys = Self.registerHandlers(gen: gen, facade: facade)
        guard keys.count == Self.handlerKeys.count else {
            Self.unregister(keys)
            // Rollback fences the fresh facade; its own pass settles or keeps
            // the drafts referenced — a refused attach owns nothing else.
            await facade.beginRetirement()
            return false
        }
        G04TerminalRuntimeRegistry.shared.register(epoch: epoch, facade: facade)
        guard G04TerminalRuntimeRegistry.shared.authority(epoch: epoch) != nil else {
            Self.unregister(keys)
            await facade.beginRetirement()
            return false
        }
        // Trusted host registry: Main's SAF/JNI adapter reaches the live
        // source coordinator ONLY through this epoch-exact seam (same
        // pattern as PrivacyHostConfirmationRegistry), never from a bridge
        // payload. Interrupted journal-47 `writing` receipts stay honestly
        // pending until the platform transport is attached.
        let sourceCoordinator = await facade.source
        G04WorkspaceHostRegistry.shared.register(epoch: epoch, source: sourceCoordinator)
        guard G04NetworkWorkspaceHostRegistry.shared.attach(
            epoch: epoch, installed: installed, coordinator: sourceCoordinator
        ) else {
            Self.unregister(keys)
            G04WorkspaceHostRegistry.shared.unregister(epoch: epoch)
            G04TerminalRuntimeRegistry.shared.unregister(epoch: epoch)
            await facade.beginRetirement()
            return false
        }
        installed.registeredHandlerKeys.append(contentsOf: keys)
        self.facade = facade
        self.registeredKeys = keys
        self.attachedComposition = installed
        self.attachedEpoch = epoch
        gateLock.g04Locked { gateEpoch = epoch }
        return true
    }

    func beginRetirement(epoch: UInt64) async {
        guard attachedEpoch == epoch else { return }
        // Unregister FIRST so no new workspace admission arrives, then fence
        // the facade and preserve/carry dirty drafts exactly as above.
        Self.unregister(registeredKeys)
        G04WorkspaceHostRegistry.shared.unregister(epoch: epoch)
        G04TerminalRuntimeRegistry.shared.unregister(epoch: epoch)
        G04GitTrustHostAPI.retire(epoch: epoch)
        // Exact-epoch host-pump fence: waiters settle typed, claimed tickets
        // remain for honest late classification (never a fake detach).
        G04WorkspaceSourceMailbox.shared.close(epoch: epoch)
        await G04NetworkWorkspaceHostRegistry.shared.detach(epoch: epoch)
        let settled = await facade?.beginRetirement() ?? true
        if !settled, let facade {
            // Unreachable on the gated shutdown order (the attached lease
            // holds the drain until settlement); retireFailed edge backstop.
            unsettledFacade = facade
        }
        facade = nil
        attachedComposition = nil
        registeredKeys = []
        attachedEpoch = nil
        gateLock.g04Locked { gateEpoch = nil }
    }

    // MARK: - Pre-drain retirement preservation (Main 2026-10-24 gate)

    /// True only while THIS extension is attached for exactly this epoch —
    /// the only window in which unproven dirty drafts may hold the original
    /// drain via the retirement gate lease.
    func requiresRetirementPreservation(epoch: UInt64) -> Bool {
        gateLock.lock(); defer { gateLock.unlock() }
        return gateEpoch == epoch
    }

    /// Runs BEFORE the first `waitForLifecycleDrain` pass. The facade's pass
    /// settles every dirty draft through the ORIGINAL private-task authority
    /// with a verified read-back; only when nothing remains unproven is the
    /// REAL gate token exact-released. Otherwise the token stays attached:
    /// the existing bounded drain then times out into `failedDrainPending`,
    /// the root stays owned, and the existing watch-retry control re-invokes
    /// this same pass. No fake lease, no silent drop, no success claim.
    func runRetirementPreservationIO(epoch: UInt64) async {
        guard requiresRetirementPreservation(epoch: epoch),
              G04WorkspaceRetirementGate.shared.claim(epoch: epoch) else { return }
        let settled = await facade?.retirementPreservationPass() ?? true
        if settled {
            G04WorkspaceRetirementGate.shared.release(epoch: epoch)
        }
    }

    // MARK: Handler registration (exact three closed keys)

    private static func registerHandlers(
        gen: AndroidRuntimeBootstrap.Generation,
        facade: G04WorkspaceFacade
    ) -> [String] {
        var keys: [String] = []
        func bind(_ command: String,
                  _ body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult) {
            G02DomainBinder.registerSubmitHandler(scope: .conversationLifecycle,
                                                  command: command, configurationScope: nil)
            let key = BridgeV3.handlerKey(scope: .conversationLifecycle, command: command)
            G02DomainBinder.registerProcessor(gen.registry, handlerKey: key, body: body)
            keys.append(key)
        }

        bind("workspace.read") { job in
            await settle(facade.execute(command: "workspace.read",
                                        taskID: G02DomainBinder.taskID(job),
                                        payload: G02DomainBinder.settingsPayload(job) ?? .null))
        }
        bind("workspace.write") { job in
            await settle(facade.execute(command: "workspace.write",
                                        taskID: G02DomainBinder.taskID(job),
                                        payload: G02DomainBinder.settingsPayload(job) ?? .null))
        }
        bind("workspace.activate") { job in
            await settle(facade.activate(taskID: G02DomainBinder.taskID(job),
                                         payload: G02DomainBinder.settingsPayload(job) ?? .null))
        }
        return keys
    }

    private static func settle(_ reply: G04WorkspaceReply) -> RuntimeCommandResult {
        switch reply {
        case .completed(let document):
            return G02DomainBinder.completedValue(document)
        case .refused(let code, let reason):
            return G02DomainBinder.wireError(code, reason: reason)
        }
    }

    private static func unregister(_ keys: [String]) {
        let binder = RuntimeCommandBinder.shared
        for key in keys { binder.unregister(key) }
    }
}

/// Trusted-host registration hook called exactly once in the pre-bootstrap
/// idle window (next to the temporary/privacy packages). `registerExtension`
/// refuses while a generation is installing/live, so repeated calls are
/// idempotent.
enum G04WorkspaceDomainRegistration {
    static func registerIfNeeded() {
        _ = G02RuntimeComposition.shared.registerExtension(
            G04WorkspaceDomainExtension())
    }
}

/// Process-local trusted host registry for the live workspace source
/// coordinator. Epoch-exact: `unregister` clears ONLY the binding THIS
/// retirement owns, and a stale epoch can never read or replace a newer
/// generation's coordinator. Main's JNI/C-ABI handoff reads
/// `currentCoordinator`/`coordinator(epoch:)` to attach the platform
/// transport exactly once; nothing here fabricates grants.
public final class G04WorkspaceHostRegistry: @unchecked Sendable {
    public static let shared = G04WorkspaceHostRegistry()
    private let lock = NSLock()
    private var live: (epoch: UInt64, source: G04WorkspaceSourceCoordinator)?

    fileprivate func register(epoch: UInt64, source: G04WorkspaceSourceCoordinator) {
        lock.lock(); defer { lock.unlock() }
        guard live == nil else { return }   // one live generation; refusal is honest
        live = (epoch, source)
    }

    fileprivate func unregister(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if live?.epoch == epoch { live = nil }
    }

    public func coordinator(epoch: UInt64) -> G04WorkspaceSourceCoordinator? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live.source
    }

    public var currentCoordinator: G04WorkspaceSourceCoordinator? {
        lock.lock(); defer { lock.unlock() }
        return live?.source
    }
}
