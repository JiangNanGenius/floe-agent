// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserDomain — the REAL optional-domain extension that binds the
// controlled-browser / local-preview service graph to the accepted native
// generation, following the established `G02DomainExtension` seam exactly
// like the temporary, privacy and workspace packages:
//   * registered in the idle pre-bootstrap window
//     (`G04BrowserDomainRegistration.registerIfNeeded` — Main's one-line
//     mount delta beside the workspace registration);
//   * `attach` constructs the ACTUAL BrowserSessionCenter +
//     LocalPreviewCoordinator + BrowserDownloadCoordinator + BrowserToolSurface
//     over the SAME installed cluster, the SAME live run-domain fences, the
//     original WorkspaceFileService/PathGuard ownership ladder, the frozen
//     16 tool runners (registered ONLY after every dependency, renderer
//     proxy included, was constructed), and the trusted handoff routes;
//   * `attach` self-rolls back on any refusal; ordinary product stays live;
//   * `beginRetirement(epoch:)` is epoch-exact: tools lose availability
//     first, every composition-tracked owner is discarded through the
//     ORIGINAL lifecycle (previews stopped, downloads cancelled/released,
//     renderers released through the still-bound mailbox so real IO settles
//     or is honestly classified late), then the mailbox closes for the exact
//     epoch. No timeout pretends a quiescence the generation did not reach.
//
// Readiness honesty: this family is a TOOL surface, not a BridgeV3 command
// domain, so it adds no `G02DomainKey` case to the frozen matrix. Discovery
// reports exactly the runners whose `isAvailable` proves the live epoch AND
// a bound platform pump; before Main's Gradle/CMake/App mount (or before
// `floe_browser_bind`), the 16 names answer the original fail-closed
// "disabled or not configured" refusal — never a blanket ready. An optional
// additive `browserDomain` readiness key is proposed to Main as a separate
// ledger-counted delta (see the package handoff), not silently widened here.
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeWorkspace
import FloeAgentRuntime
import FloeBrowser

// MARK: - Live service handle (trusted host registry)

/// The exact-generation bundle the C ABI reads. Registration is one-live-
/// generation (`register` refuses while another epoch holds the slot) and
/// unregistration is epoch-exact, mirroring `G04WorkspaceHostRegistry`.
/// Nothing here fabricates authority: every field is the REAL service the
/// extension constructed.
public final class G04BrowserHostRegistry: @unchecked Sendable {
    public static let shared = G04BrowserHostRegistry()

    public struct Services: Sendable {
        public let epoch: UInt64
        public let center: BrowserSessionCenter
        public let policy: BrowserURLPolicy
        public let preview: LocalPreviewCoordinator
        public let downloads: BrowserDownloadCoordinator
        public let surface: BrowserToolSurface
    }

    private let lock = NSLock()
    private var live: Services?
    /// The live generation's tool routing (internal: consumed by the
    /// trusted-UI `toolSubmit` grammar exactly like the model path).
    private var liveRouting: G04BrowserToolRouting?

    @discardableResult
    fileprivate func register(_ services: Services, routing: G04BrowserToolRouting) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live == nil else { return false }   // one live generation; refusal is honest
        live = services
        liveRouting = routing
        return true
    }

    fileprivate func unregister(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if live?.epoch == epoch {
            live = nil
            liveRouting = nil
        }
    }

    public var current: Services? {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    var currentRouting: G04BrowserToolRouting? {
        lock.lock(); defer { lock.unlock() }
        return liveRouting
    }

    public func services(epoch: UInt64) -> Services? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live
    }
}

// MARK: - Mailbox-backed renderer proxy

/// Swift-side `BrowserRenderer` implementation that ONLY submits bounded
/// host tickets. All WebView semantics (thread rules, exactly-once replies,
/// cookie/JS gates) live in feature/browser + Main's pump; this proxy never
/// blocks a page thread, never inspects page content for trust, and maps
/// every host refusal onto the original typed `BrowserRendererError` so the
/// session produces real BrowserResult statuses.
final class G04BrowserRendererProxy: BrowserRenderer, @unchecked Sendable {
    private let owner: BrowserOwnerID
    private let mailbox = G04BrowserMailbox.shared
    /// The owning conversation doubles as the routing key (session identity
    /// == task identity in the original design).
    private var conversation: UUID { owner.taskID }

    init(owner: BrowserOwnerID) {
        self.owner = owner
    }

    private func descriptor(_ fields: [String: String]) -> [String: String] {
        var out = fields
        out["taskID"] = owner.taskID.uuidString
        out["workspaceID"] = owner.workspaceID.uuidString
        out["rootEpoch"] = String(owner.rootEpoch)
        return out
    }

    private func submit(_ operation: G04BrowserTicketKind,
                        tabID: UUID? = nil,
                        extra: [String: String] = [:],
                        staged: Data,
                        budgetMillis: Int) async throws -> Data {
        var fields = extra
        if let tabID { fields["tabID"] = tabID.uuidString }
        do {
            return try await mailbox.submit(operation, expectedEpoch: owner.rootEpoch, conversation: conversation,
                                            descriptor: descriptor(fields),
                                            staged: staged,
                                            budgetMillis: budgetMillis,
                                            cancellation: nil)
        } catch let error as G04BrowserMailboxError {
            throw error.rendererError
        }
    }

    func createTab(tabID: UUID, probeSource: String) async throws {
        _ = try await submit(.rendererCreateTab, tabID: tabID,
                             staged: Data(probeSource.utf8), budgetMillis: 15_000)
    }

    func destroyTab(tabID: UUID) async {
        _ = try? await mailbox.submit(.rendererDestroyTab, expectedEpoch: owner.rootEpoch, conversation: conversation,
                                      descriptor: descriptor(["tabID": tabID.uuidString]),
                                      staged: Data(), budgetMillis: 10_000,
                                      cancellation: nil)
    }

    func navigate(tabID: UUID, url: URL) async throws {
        _ = try await submit(.rendererNavigate, tabID: tabID,
                             extra: ["url": url.absoluteString],
                             staged: Data(), budgetMillis: 15_000)
    }

    func goBack(tabID: UUID) async throws {
        _ = try await submit(.rendererGoBack, tabID: tabID, staged: Data(),
                             budgetMillis: 10_000)
    }

    func goForward(tabID: UUID) async throws {
        _ = try await submit(.rendererGoForward, tabID: tabID, staged: Data(),
                             budgetMillis: 10_000)
    }

    func reload(tabID: UUID) async throws {
        _ = try await submit(.rendererReload, tabID: tabID, staged: Data(),
                             budgetMillis: 10_000)
    }

    func stopLoading(tabID: UUID) async {
        _ = try? await mailbox.submit(.rendererStopLoading, expectedEpoch: owner.rootEpoch, conversation: conversation,
                                      descriptor: descriptor(["tabID": tabID.uuidString]),
                                      staged: Data(), budgetMillis: 5_000,
                                      cancellation: nil)
    }

    func state(tabID: UUID) async throws -> BrowserRendererTabState {
        let value = try await submit(.rendererState, tabID: tabID, staged: Data(),
                                     budgetMillis: 5_000)
        guard let state = try? JSONDecoder().decode(BrowserRendererTabState.self, from: value)
        else { throw BrowserRendererError.failed("the host returned an unreadable tab state") }
        return state
    }

    func evaluate(tabID: UUID, expression: String,
                  timeoutMilliseconds: Int) async throws -> String {
        let budget = min(40_000, max(1_000, timeoutMilliseconds) + 5_000)
        let value = try await submit(.rendererEvaluate, tabID: tabID,
                                     extra: ["timeoutMilliseconds": String(timeoutMilliseconds)],
                                     staged: Data(expression.utf8),
                                     budgetMillis: budget)
        return String(decoding: value, as: UTF8.self)
    }

    func captureScreenshot(tabID: UUID) async throws -> BrowserScreenshotData {
        let value = try await submit(.rendererScreenshot, tabID: tabID, staged: Data(),
                                     budgetMillis: 25_000)
        struct Wire: Decodable {
            let jpeg: String
            let pixelWidth: Int
            let pixelHeight: Int
            let state: BrowserRendererTabState
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: value),
              let jpeg = Data(base64Encoded: wire.jpeg) else {
            throw BrowserRendererError.failed("the host returned an unreadable screenshot")
        }
        return BrowserScreenshotData(jpeg: jpeg, pixelWidth: wire.pixelWidth,
                                     pixelHeight: wire.pixelHeight, state: wire.state)
    }

    func release() async {
        _ = try? await mailbox.submit(.rendererRelease, expectedEpoch: owner.rootEpoch, conversation: conversation,
                                      descriptor: descriptor([:]),
                                      staged: Data(), budgetMillis: 10_000,
                                      cancellation: nil)
    }
}

// MARK: - Mailbox-backed preview transport proxy

/// The `BrowserPreviewTransport` half of the loopback preview: Kotlin owns
/// the raw 127.0.0.1 listener; all adjudication returns to Swift through
/// `floe_browser_preview_adjudicate` / `..._read_chunk`. `stop` claims the
/// pump's JOINED teardown (listener closed + accept thread joined) before
/// the coordinator disposes the grant.
final class G04BrowserPreviewTransportProxy: BrowserPreviewTransport, @unchecked Sendable {
    private let mailbox = G04BrowserMailbox.shared
    private let epoch: UInt64
    init(epoch: UInt64) { self.epoch = epoch }
    /// The lease UUID doubles as the mailbox routing key; the pump keeps a
    /// transport per serverID and reports its bound OS port back honestly.
    func start(lease: BrowserPreviewLeaseRequest) async throws -> BrowserPreviewEndpoint {
        struct Answer: Decodable { let port: Int }
        let value: Data
        do {
            // The TOKEN rides only this trusted ticket (never page content,
            // never UI text); the pump names its transport by leaseID and
            // has ZERO authorization logic — adjudication always returns to
            // Swift with the raw header block.
            value = try await mailbox.submit(.transportStart, expectedEpoch: epoch,
                                             conversation: lease.leaseID,
                                             descriptor: [
                                                 "operation": G04BrowserTicketKind.transportStart.rawValue,
                                                 "conversationID": lease.leaseID.uuidString,
                                                 "leaseID": lease.leaseID.uuidString,
                                                 "token": lease.token,
                                             ],
                                             staged: Data(),
                                             budgetMillis: 90_000,
                                             cancellation: nil)
        } catch let error as G04BrowserMailboxError {
            switch error {
            case .remoteFailed(let code) where code == "localNetworkPermissionDenied":
                throw BrowserPreviewTransportError.startFailed(
                    "local network permission denied for this explicit preview start")
            default:
                throw BrowserPreviewTransportError.startFailed(error.userVisibleReason)
            }
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: value),
              (1024...65_535).contains(answer.port) else {
            throw BrowserPreviewTransportError.startFailed(
                "the host returned an unreadable preview endpoint")
        }
        return BrowserPreviewEndpoint(port: answer.port)
    }

    func stop(leaseID: UUID) async {
        _ = try? await mailbox.submit(.transportStop, expectedEpoch: epoch, conversation: leaseID,
                                      descriptor: [
                                          "operation": G04BrowserTicketKind.transportStop.rawValue,
                                          "conversationID": leaseID.uuidString,
                                          "leaseID": leaseID.uuidString,
                                      ],
                                      staged: Data(), budgetMillis: 20_000,
                                      cancellation: nil)
    }
}

// MARK: - Error vocabularies

extension G04BrowserMailboxError {
    /// Every mailbox refusal maps onto a typed renderer failure the session
    /// already knows how to report; no refusal is ever swallowed into a
    /// "success" string.
    var rendererError: BrowserRendererError {
        switch self {
        case .hostUnbound: return .unavailable
        case .hostFenced: return .released
        case .saturated: return .failed("the browser host queue is saturated")
        case .oversized: return .failed("the renderer payload exceeded its bound")
        case .remoteFailed(let code):
            if code == "hostBudget" { return .timedOut }
            return .failed(code)
        }
    }

    var userVisibleReason: String {
        switch self {
        case .hostUnbound: return "the browser host pump is not bound"
        case .hostFenced: return "the browser generation was retired"
        case .saturated: return "the browser host queue is saturated"
        case .oversized: return "the payload exceeded its bound"
        case .remoteFailed(let code): return code
        }
    }
}

extension G04BrowserMailboxError: LocalizedError {
    public var errorDescription: String? { userVisibleReason }
}

// MARK: - Download ticket routing (signals -> owning binding)

/// Bounded ticket -> owning conversation map so coordinator signals reach
/// the right Kotlin binding even though onProgress/onFailed only carry the
/// ticket identity and onCommitted only carries the receipt. FIFO eviction
/// (256) with an honest counter; a signal for an evicted ticket routes to
/// the global key and is never presented as another task's file.
final class G04BrowserSignalRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UUID: UUID] = [:]
    private var order: [UUID] = []
    private var committedPaths: [String: UUID] = [:]
    private var committedOrder: [String] = []
    private(set) var evictedCount = 0

    func record(ticket: UUID, conversation: UUID) {
        lock.lock()
        owners[ticket] = conversation
        order.append(ticket)
        while order.count > 256 {
            let old = order.removeFirst()
            owners.removeValue(forKey: old)
            evictedCount += 1
        }
        lock.unlock()
    }

    func conversation(for ticket: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return owners[ticket]
    }

    func forget(ticket: UUID) {
        lock.lock()
        owners.removeValue(forKey: ticket)
        order.removeAll { $0 == ticket }
        lock.unlock()
    }

    func rememberCommit(path: String, conversation: UUID) {
        lock.lock()
        committedPaths[path] = conversation
        committedOrder.append(path)
        while committedOrder.count > 256 {
            committedPaths.removeValue(forKey: committedOrder.removeFirst())
        }
        lock.unlock()
    }

    func conversation(forCommit path: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return committedPaths[path]
    }

    func reset() {
        lock.lock()
        owners.removeAll()
        order.removeAll()
        committedPaths.removeAll()
        committedOrder.removeAll()
        lock.unlock()
    }
}

// MARK: - Projection / signal sinks

/// Routes the center's projection updates and the coordinator's download
/// signals into the bound mailbox as coalesced delivery events. Pure
/// plumbing: it never decides anything.
enum G04BrowserProjectionSink {
    static let globalKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static let lock = NSLock()
    nonisolated(unsafe) private static var router: G04BrowserSignalRouter?
    nonisolated(unsafe) private static var attachedEpoch: UInt64 = 0
    nonisolated(unsafe) private static var tracker: (@Sendable (UUID) -> Void)?

    static func attach(epoch: UInt64, router: G04BrowserSignalRouter,
                       tracker: (@Sendable (UUID) -> Void)?) {
        lock.lock(); self.attachedEpoch = epoch; self.router = router; self.tracker = tracker; lock.unlock()
    }

    static func detach(epoch: UInt64) {
        lock.withLock {
            if attachedEpoch == epoch { attachedEpoch = 0; router = nil; tracker = nil }
        }
    }

    static func publish(_ projection: BrowserProjection, epoch: UInt64) {
        guard let data = try? JSONEncoder().encode(projection) else { return }
        let conversation = projection.visibleTaskID
            ?? projection.presentationRequest?.conversationID
            ?? projection.handoff?.conversationID
        let routeKey = conversation ?? globalKey
        G04BrowserMailbox.shared.submitEvent(.uiProjection, expectedEpoch: epoch, conversation: routeKey,
                                             payload: data,
                                             coalesceKey: routeKey.uuidString)
        if let conversation {
            lock.withLock { attachedEpoch == epoch ? tracker : nil }?(conversation)
        }
    }

    static func downloadSignal(_ object: [String: String], conversation: UUID?, epoch: UInt64) {
        guard let data = try? JSONEncoder().encode(object) else { return }
        let route = conversation ?? globalKey
        G04BrowserMailbox.shared.submitEvent(.uiDownloadSignal, expectedEpoch: epoch, conversation: route,
                                             payload: data, coalesceKey: nil)
    }

    static func uiEvent(_ kind: G04BrowserTicketKind, conversation: UUID,
                        payload: Data, epoch: UInt64) {
        G04BrowserMailbox.shared.submitEvent(kind, expectedEpoch: epoch, conversation: conversation,
                                             payload: payload, coalesceKey: nil)
    }
}

// MARK: - The domain extension

final class G04BrowserDomainExtension: G02DomainExtension, @unchecked Sendable {
    let id = G02DomainExtensionKey.browser
    /// Tool family, not a BridgeV3 command domain: it owns no frozen
    /// readiness key (see the file header).
    let domains: [G02DomainKey] = []

    private let stateLock = NSLock()
    private var liveEpochValue: UInt64?
    private var attachedEpochValue: UInt64?

    private var center: BrowserSessionCenter?
    private var preview: LocalPreviewCoordinator?
    private var downloads: BrowserDownloadCoordinator?
    private var sink: G04BrowserWorkspaceDownloadSink?
    private let signalRouter = G04BrowserSignalRouter()
    /// Conversations the composition actually saw (tool admission, trusted
    /// binds, projections). Retirement discards EXACTLY these through the
    /// original center lifecycle; anything else stays honestly fenced by the
    /// center's own tombstones and the cancelled runs' contexts.
    private var trackedOrder: [UUID] = []
    private var trackedSet: Set<UUID> = []

    init() {}

    func expectedHandlerKeys(for domain: G02DomainKey) -> [String] { [] }

    private var retired: Bool {
        stateLock.lock(); let value = liveEpochValue == nil; stateLock.unlock(); return value
    }

    func attach(to installed: G02InstalledComposition,
                gen: AndroidRuntimeBootstrap.Generation) async -> Bool {
        let epoch = gen.epoch
        let alreadyAttached = stateLock.g04Locked { attachedEpochValue != nil }
        guard !alreadyAttached else { return false }
        // Browser sessions are ordinary-task owned: an absent live run domain
        // is an honest fail-closed attach refusal (the ordinary base stays).
        guard RunDomainFacade.current(epoch: epoch) != nil else { return false }

        let ladder = G04BrowserWorkspaceLadder(epoch: epoch, installed: installed)
        let policy = BrowserURLPolicy()
        let resourcePort = G04BrowserPreviewResourcePort(ladder: ladder)
        let transportProxy = G04BrowserPreviewTransportProxy(epoch: epoch)
        let sink = G04BrowserWorkspaceDownloadSink(ladder: ladder)
        let router = signalRouter

        let center = BrowserSessionCenter(
            configuration: BrowserCenterConfiguration(
                artifactsDirectory: URL(fileURLWithPath: installed.cluster.identity.root.path,
                                        isDirectory: true)
                    .appendingPathComponent("Browser", isDirectory: true),
                receiptsDirectory: URL(fileURLWithPath: installed.cluster.identity.root.path,
                                       isDirectory: true)
                    .appendingPathComponent("Browser", isDirectory: true)),
            rendererFactory: { owner in G04BrowserRendererProxy(owner: owner) as any BrowserRenderer },
            policy: policy,
            deliverHandoff: { event, shouldContinue in
                try await G04BrowserHandoffDeliverer.deliver(event, shouldContinue: shouldContinue)
            },
            handoffRun: { conversationID in
                G04BrowserHandoffBridge.shared.recordedRun(for: conversationID)
            },
            ownerReleaseHook: { conversationID in
                G04BrowserHandoffBridge.shared.ownerReleased(conversationID)
            },
            projectionUpdate: { projection in
                G04BrowserProjectionSink.publish(projection, epoch: epoch)
            },
            ownerAuthority: { owner in
                await G04BrowserOwnerAuthority.revalidate(owner: owner)
            })
        let preview = LocalPreviewCoordinator(
            browser: center,
            transport: transportProxy,
            resource: resourcePort,
            policy: policy)
        let downloads = BrowserDownloadCoordinator(
            policy: policy,
            sink: sink,
            signals: BrowserDownloadCoordinator.DownloadSignals(
                onStart: { ticket in
                    router.record(ticket: ticket.id, conversation: ticket.taskID)
                    G04BrowserProjectionSink.downloadSignal([
                        "kind": "started",
                        "ticketID": ticket.id.uuidString,
                        "taskID": ticket.taskID.uuidString,
                        "relativeDirectory": ticket.relativeDirectory,
                        "fileName": ticket.fileName,
                        "maximumBytes": String(ticket.maximumBytes),
                    ], conversation: ticket.taskID, epoch: epoch)
                },
                onProgress: { ticketID, received in
                    let conversation = router.conversation(for: ticketID)
                    G04BrowserProjectionSink.downloadSignal([
                        "kind": "progress",
                        "ticketID": ticketID.uuidString,
                        "received": String(received),
                    ], conversation: conversation, epoch: epoch)
                },
                onCommitted: { receipt in
                    let conversation = router.conversation(forCommit: receipt.relativePath)
                    G04BrowserProjectionSink.downloadSignal([
                        "kind": "committed",
                        "relativePath": receipt.relativePath,
                        "byteCount": String(receipt.byteCount),
                        "sha256": receipt.sha256,
                    ], conversation: conversation, epoch: epoch)
                },
                onFailed: { ticketID, message in
                    let conversation = router.conversation(for: ticketID)
                    router.forget(ticket: ticketID)
                    G04BrowserProjectionSink.downloadSignal([
                        "kind": "failed",
                        "ticketID": ticketID.uuidString,
                        "message": message,
                    ], conversation: conversation, epoch: epoch)
                }))
        let surface = BrowserToolSurface(center: center, policy: policy, preview: preview)

        let routing = G04BrowserToolRouting(
            epoch: epoch,
            center: center,
            surface: surface,
            bridge: G04BrowserHandoffBridge.shared,
            ladder: ladder,
            isLive: { [weak self] in
                self?.liveFlagMatches(epoch) ?? false
            })

        // Register ONLY now that every real dependency exists (renderer proxy
        // included). A refused host-registration below unregisters exactly
        // these names — no partial advertisement survives a failed attach.
        let registry = installed.runComponents.registry
        G04BrowserToolRegistration.register(routing, registry: registry)
        let services = G04BrowserHostRegistry.Services(
            epoch: epoch, center: center, policy: policy,
            preview: preview, downloads: downloads, surface: surface)
        guard G04BrowserHostRegistry.shared.register(services, routing: routing) else {
            G04BrowserToolRegistration.unregister(registry: registry)
            return false
        }
        G04BrowserHandoffBridge.shared.register(epoch: epoch, center: center)
        G04BrowserProjectionSink.attach(epoch: epoch, router: router, tracker: { [weak self] conversationID in
            self?.trackOwner(conversationID)
        })
        sink.commitProofNote = { path, conversation in
            router.rememberCommit(path: path, conversation: conversation)
        }
        stateLock.g04Locked {
            liveEpochValue = epoch
            attachedEpochValue = epoch
        }
        self.center = center
        self.preview = preview
        self.downloads = downloads
        self.sink = sink
        return true
    }

    /// Tools answer available ONLY while THIS epoch is the live one AND the
    /// trusted Kotlin pump has bound the same epoch through the C ABI.
    private func liveFlagMatches(_ epoch: UInt64) -> Bool {
        stateLock.lock()
        let current = liveEpochValue
        stateLock.unlock()
        guard current == epoch else { return false }
        return G04BrowserMailbox.shared.boundEpoch == epoch
    }

    func beginRetirement(epoch: UInt64) async {
        let claimed = stateLock.g04Locked { () -> Bool in
            guard attachedEpochValue == epoch else { return false }
            liveEpochValue = nil
            return true
        }
        guard claimed else { return }
        // 1. Availability OFF first: discovery cannot advertise runners of a
        //    retiring generation even for the instant before removal.
        if let installed = G02RuntimeComposition.shared.installedComposition,
           installed.epoch == epoch {
            G04BrowserToolRegistration.unregister(registry: installed.runComponents.registry)
        }
        // 2. Discard every tracked owner through the ORIGINAL center
        //    lifecycle (fences + ownerReleaseHook -> preview stop +
        //    download release + renderer release; tickets still go through
        //    the open mailbox so real IO settles or is honestly classified
        //    late).
        let owners = stateLock.g04Locked { () -> [UUID] in
            let snapshot = trackedOrder
            trackedOrder.removeAll()
            trackedSet.removeAll()
            return snapshot
        }
        for conversationID in owners {
            await center?.discard(conversationID: conversationID, notifyHook: true)
        }
        // 3. Exact-epoch host fence: waiters settle typed; claimed tickets
        //    remain classified for late settle. No detach, no fake green.
        G04BrowserMailbox.shared.close(epoch: epoch)
        G04BrowserHostRegistry.shared.unregister(epoch: epoch)
        G04BrowserHandoffBridge.shared.unregister(epoch: epoch)
        G04BrowserProjectionSink.detach(epoch: epoch)
        signalRouter.reset()
        sink?.commitProofNote = nil
        // Staging files owned by unfinished tickets stay HONESTLY pending:
        // `cancel`/`releaseOwner` above discarded every settled ticket, and
        // anything still mid-IO is dropped by its own actor-serialized
        // discard when the fetch task notices cancellation. Nothing here
        // deletes bytes whose IO has not proven settled.
        center = nil
        preview = nil
        downloads = nil
        sink = nil
        stateLock.g04Locked { attachedEpochValue = nil }
    }

    func trackOwner(_ conversationID: UUID) {
        stateLock.lock()
        guard !trackedSet.contains(conversationID) else { stateLock.unlock(); return }
        trackedSet.insert(conversationID)
        trackedOrder.append(conversationID)
        while trackedOrder.count > 512 {
            let old = trackedOrder.removeFirst()
            trackedSet.remove(old)
        }
        stateLock.unlock()
    }

    /// The tool/preview/UI admission hook: the routing and the C ABI record
    /// the exact owner conversation so retirement can drain it.
    func noteAdmission(_ conversationID: UUID) {
        trackOwner(conversationID)
    }
}

// MARK: - Pre-bootstrap registration (Main's one-line mount)

/// Trusted host hook called exactly once in the idle pre-bootstrap window
/// (next to the temporary/privacy/workspace packages). `registerExtension`
/// refuses while a generation is installing/live, so repeated calls are
/// idempotent.
enum G04BrowserDomainRegistration {
    static func registerIfNeeded() {
        _ = G02RuntimeComposition.shared.registerExtension(G04BrowserDomainExtension())
    }
}

extension G02DomainExtensionKey {
    /// The browser family's own extension identity. This is NOT a readiness
    /// matrix key (no `G02DomainKey` case was added): it only names the
    /// registered package inside the composition's extension registry.
    public static let browser = G02DomainExtensionID("browser")
}
