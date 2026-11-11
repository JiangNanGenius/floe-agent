// FloeApp — on-demand local Linux screen.
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns ONE display of ONE resolved Linux environment for ONE owning
// conversation/workspace. The display is a supervised guest local service
// (image-provided `floe-display-start` running Xtigervnc + xterm) reached
// through the service's loopback slirp forward; the client is the shared
// `VNCSession`, so the model's existing vnc.* evidence contract
// (fresh-screenshot sha256 / 15 s freshness / frame revision) applies
// unchanged. Closing the viewer or ending tool demand releases CLIENT
// transport only: the guest service, the terminal and all compute keep
// running. The owned guest service stops only on an explicit user stop, on
// environment stop/delete (lease cancellation / lifecycle event), or on
// owner eviction — a viewer reopen reconnects the retained running service.
//
// First version is intentionally UI-started: model tools resolve an existing
// connected display session and fail closed otherwise; they never launch the
// guest display on demand (no hidden read-only guest launch). Remote SSH
// terminals and the global remote VNC path are untouched.
//
// Credentials: the owner generates a transient 8-character VNCAuth password,
// stages it as a 0600 INPUT file inside its OWN directory of the
// environment's writable layer, and hands the guest only the file PATH
// through the service environment (the service supervisor encodes the
// environment as `env KEY=VALUE` argv, so the plaintext password must never
// be placed there). The image-provided launcher encodes the file with
// `tigervncpasswd -f` into a 0600 runtime auth file, unlinks the input and
// removes the variable before spawning children. The host copy survives only
// until the VNCAuth handshake proves the launcher consumed it (a running
// snapshot only proves the PID is alive); every cleanup path removes it.

import Foundation
import Observation
import FloeCore
import FloeTools
import FloeExecution
import FloeVNC
import Darwin

// MARK: - Wiring seams (injected by AppEnvironment)

/// Guest-side display operations, all routed through the existing
/// `LinuxGuestLocalServiceControlling` / platform activation seams so task
/// ownership, cancellation and environment teardown behave exactly like every
/// other guest local service. Scripting these in tests replaces production
/// behavior; nothing here reaches a guest by itself.
struct LocalLinuxDisplayServices: Sendable {
    /// Starts a supervised guest service. Long activation (image install /
    /// guest boot) happens inside `activateGuest` BEFORE this is called.
    var startLocalService: @Sendable (_ environmentID: String, _ request: LinuxGuestLocalServiceRequest, _ cancellation: CancellationToken?) async throws -> LinuxGuestLocalServiceHandle
    var stopLocalService: @Sendable (LinuxGuestLocalServiceHandle) async -> Void
    var serviceSnapshot: @Sendable (LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot
    /// Lazy guest activation (may download/install the image) — owned by the
    /// platform service, never by a view lifetime.
    var activateGuest: @Sendable (_ environmentID: String, _ cancellation: CancellationToken?) async throws -> Void
    var environmentOwned: @Sendable (_ environmentID: String) async -> Bool
    /// Observed service ends (process exit / environment gone). Optional so
    /// scripted controllers stay source-compatible.
    var lifecycleEvents: @Sendable () async -> AsyncStream<LinuxGuestLocalServiceLifecycleEvent>?
    /// Accept only this display's terminal event; other service owners keep
    /// their durable pipeline acknowledgement.
    var acknowledgeLifecycle: @Sendable (LinuxGuestLocalServiceLifecycleEvent) async -> Void = { _ in }
}

/// Result of resolving the EXACT environment the local terminal/workspace
/// executes in. `resolver` reuses the app's existing
/// `EnvironmentExecutionCoordinator.acquire` path, so the identity is the
/// same one exec shells and model tools resolve — never an invented, first,
/// or global-project environment.
struct LocalLinuxDisplayBinding: Sendable {
    var environmentID: String
    var writableLayerURL: URL
    var isLinuxGuest: Bool
    /// Fired by the coordinator when the environment stops or is deleted;
    /// the owner joins its display + forward by stopping the owned service.
    var leaseCancellation: CancellationToken
    var endLease: @Sendable () async -> Void
}

typealias LocalLinuxDisplayResolver = @Sendable (_ conversationID: UUID?, _ workspaceRoot: URL) async throws -> LocalLinuxDisplayBinding

// MARK: - Owner

@MainActor
@Observable
final class LocalLinuxDisplayOwner {
    enum State: Equatable, Sendable {
        /// Identity not resolved yet.
        case resolving
        /// Resolved environment is not a Linux guest (e.g. mac bridge): the
        /// Screen entry stays hidden; remote paths are unaffected.
        case unavailable
        /// Linux guest, display not started. Started lazily on demand only —
        /// never at guest boot.
        case idle
        case starting
        case connecting
        /// Client transport connected and guest service running.
        case ready
        case stopping
        /// Unexpected end observed from the service lifecycle (bounded log tail).
        case ended(String)
        /// Start/connect failure with an actionable, non-secret message.
        case failed(String)
    }

    /// Owning conversation when known; also the model-side owner identity.
    let conversationID: UUID?
    /// The SAME workspace root the local terminal for this surface uses.
    let workspaceRoot: URL
    /// Guest RFB port reserved for this owner for its whole lifetime (unique
    /// among live owners: the guest AND the host loopback share this number
    /// through the service forward). Assigned by the center.
    private(set) var displayPort: Int

    private let resolver: LocalLinuxDisplayResolver
    private let services: LocalLinuxDisplayServices
    /// Distinguishes this environment/screen from any other owner's; the
    /// model provider matches on exactly (environmentID, ownerID).
    private(set) var environmentID: String?
    private(set) var ownerID: String
    private(set) var state: State = .resolving
    private(set) var isLinuxGuest = false

    /// One client session serves the viewer and the model tools as separate
    /// demand clients of the same display.
    private(set) var clientSession: VNCSession?
    /// Public identity of the current display generation (tool status output).
    private(set) var displaySessionID = UUID()
    private(set) var forwardHost = "127.0.0.1"
    private(set) var forwardPort: Int?

    /// Drives the terminal header's Screen entry (embedded + full-screen):
    /// visible only once the resolved environment is confirmed to be exactly
    /// a Linux guest — never for mac-bridge or remote environments.
    var screenEntryAvailable: Bool { isLinuxGuest }
    var canStop: Bool { !stopping && (startTask != nil || serviceHandle != nil || clientSession != nil) }
    /// The Screen button starts a display from these states; from `.ready`
    /// without a client it reconnects the retained running service.
    var canStart: Bool {
        switch state {
        case .idle, .failed, .ended: return true
        case .ready: return clientSession == nil
        default: return false
        }
    }

    private var binding: LocalLinuxDisplayBinding?
    private var serviceHandle: LinuxGuestLocalServiceHandle?
    private var password: String?
    private var stagedDirectory: URL?
    private var sessionGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var startGeneration = UUID()
    private var startToken = CancellationToken()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    private var prepareGeneration = UUID()
    private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    private var viewerClients = 0
    /// Sticky tool demand: set by an explicit local vnc.connect and held until
    /// vnc.disconnect — NOT per-read counting, so concurrent screenshot/input
    /// calls need no paired release and evidence freshness is unaffected.
    private var toolDemandActive = false
    private var stopping = false
    private let stagingID = UUID().uuidString
    private var ownsReservedPort = false
    var reservePort: (@MainActor () throws -> Int)?
    var releasePort: (@MainActor () -> Void)?
    /// Set by the center: an explicit local UI open clears any remote-routing
    /// override recorded for this owner.
    var onLocalDemand: (@MainActor @Sendable () -> Void)?

    init(
        conversationID: UUID?,
        workspaceRoot: URL,
        displayPort: Int = LocalLinuxDisplayCenter.defaultGuestPort,
        resolver: @escaping LocalLinuxDisplayResolver,
        services: LocalLinuxDisplayServices
    ) {
        self.conversationID = conversationID
        self.workspaceRoot = workspaceRoot
        self.ownerID = Self.ownerID(conversationID: conversationID, workspaceRoot: workspaceRoot)
        self.displayPort = displayPort
        self.resolver = resolver
        self.services = services
    }

    /// Stable cross-surface owner identity. With a conversation it is the
    /// conversation UUID (both the UI and the model ToolContext carry it);
    /// without one it is derived from the NORMALIZED workspace root — the
    /// same value the tool provider computes from `context.workspaceRootURL`,
    /// so workspace-scoped owners match exactly instead of never matching.
    static func ownerID(conversationID: UUID?, workspaceRoot: URL) -> String {
        if let conversationID { return conversationID.uuidString }
        return "workspace:" + Self.normalizedRootPath(workspaceRoot)
    }

    static func normalizedRootPath(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    deinit {
        lifecycleTask?.cancel()
        leaseTask?.cancel()
        prepareTask?.cancel()
    }

    // MARK: Resolve (same identity as the terminal/exec path)

    /// Resolves the exact environment. Single-flight: concurrent callers join
    /// the in-flight resolution instead of taking two leases. After a stop
    /// (which ends the execution lease) the next start re-resolves, so the
    /// identity can never go stale across an environment switch.
    func prepare() async {
        guard binding == nil, state != .unavailable, !stopping else { return }
        if let prepareTask { await prepareTask.value; return }
        let generation = UUID()
        prepareGeneration = generation
        let task = Task { await self.performPrepare(generation: generation) }
        prepareTask = task
        await task.value
    }

    private func performPrepare(generation: UUID) async {
        defer { if generation == prepareGeneration { prepareTask = nil } }
        do {
            let binding = try await resolver(conversationID, workspaceRoot)
            guard generation == prepareGeneration, !Task.isCancelled, !stopping else {
                // Never retain a lease the caller no longer wants.
                await binding.endLease()
                return
            }
            self.binding = binding
            self.environmentID = binding.environmentID
            self.isLinuxGuest = binding.isLinuxGuest
            if binding.isLinuxGuest {
                switch state {
                case .resolving, .failed, .unavailable: state = .idle
                default: break
                }
                // Environment stop/delete cancels/joins the owned display and
                // its forward before the layers disappear.
                leaseTask?.cancel()
                let cancellation = binding.leaseCancellation
                leaseTask = Task { [weak self] in
                    while !Task.isCancelled {
                        if cancellation.isCancelled {
                            await self?.joinEnvironmentStop()
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            } else {
                state = .unavailable
                self.binding = nil
                await binding.endLease()
            }
        } catch {
            if generation == prepareGeneration, !Task.isCancelled, !stopping {
                state = .failed(Self.truncated(error.localizedDescription))
            }
        }
    }

    // MARK: Demand entries

    /// Viewer demand: starts the display on first open and keeps the client
    /// session alive for the view's lifetime. Cancelling the calling task
    /// (panel close, full-screen transition) ends ONLY this demand: the guest
    /// service and compute keep running.
    func beginViewerDemand() async {
        onLocalDemand?()
        viewerClients += 1
        await startDisplay()
    }

    func endViewerDemand() {
        viewerClients = max(0, viewerClients - 1)
        reconcileClientTransport()
    }

    /// Read-only model tool resolution: requires an already-connected display
    /// for this exact (environment, owner) and never connects or launches.
    /// Demand is sticky (see `toolDemandActive`); this call does not count.
    func acquireToolClient() throws -> VNCSessionHandle {
        guard state == .ready, let session = clientSession, session.isConnected else {
            throw FloeError.validationFailed(Self.displayUnavailableMessage(state: state))
        }
        return VNCSessionHandle(id: displaySessionID, session: session)
    }

    /// Explicit local vnc.connect/vnc.reconnect: reconnects the RETAINED
    /// running guest service (restarting client transport only — never a
    /// second guest launch) and holds sticky tool demand until
    /// vnc.disconnect.
    func reconnectToolClient() async throws -> VNCSessionHandle {
        guard serviceHandle != nil else {
            throw FloeError.validationFailed(Self.displayUnavailableMessage(state: state))
        }
        toolDemandActive = true
        do {
            await startDisplay(allowServiceLaunch: false)
            guard state == .ready, let session = clientSession, session.isConnected else {
                throw FloeError.validationFailed(Self.displayUnavailableMessage(state: state))
            }
            return VNCSessionHandle(id: displaySessionID, session: session)
        } catch {
            toolDemandActive = false
            reconcileClientTransport()
            throw error
        }
    }

    func releaseToolClient() {
        toolDemandActive = false
        reconcileClientTransport()
    }

    /// After any demand ends: keep the client transport only while a client
    /// remains. The guest service is never torn down here.
    private func reconcileClientTransport() {
        guard viewerClients == 0, !toolDemandActive else { return }
        sessionGeneration = UUID()
        clientSession?.disconnect()
        clientSession = nil
    }

    // MARK: Start / stop

    /// Serialized, generation-guarded start. Concurrent starters join the
    /// in-flight start instead of racing a second guest service.
    func startDisplay(allowServiceLaunch: Bool = true) async {
        if let stopTask { await stopTask.value }
        guard !Task.isCancelled else { return }
        if allowServiceLaunch { onLocalDemand?() }
        if let startTask { await startTask.value; return }
        let generation = UUID()
        startGeneration = generation
        startToken = CancellationToken()
        let task = Task { await self.performStart(generation: generation, allowServiceLaunch: allowServiceLaunch) }
        startTask = task
        await task.value
    }

    private func performStart(generation: UUID, allowServiceLaunch: Bool) async {
        defer {
            if startGeneration == generation { startTask = nil }
        }
        let token = startToken
        do {
            try token.throwIfCancelled()
            if binding == nil { await prepare() }
            try token.throwIfCancelled()
            guard generation == startGeneration, !Task.isCancelled else { return }
            // Reopen: a retained running service is reconnected — starting a
            // second service would collide on the reserved port and orphan
            // the first renderer.
            if let handle = serviceHandle {
                if let clientSession, clientSession.isConnected { state = .ready; return }
                state = .connecting
                try await connectClient(handle: handle, generation: generation, token: token)
                return
            }
            guard allowServiceLaunch else {
                throw FloeError.validationFailed(Self.displayUnavailableMessage(state: state))
            }
            guard let binding, binding.isLinuxGuest, let environmentID else {
                state = .failed(Self.truncated(String(localized: "display.error.not_linux")))
                return
            }
            guard await services.environmentOwned(environmentID) else {
                state = .failed(Self.truncated(String(localized: "display.error.environment_unavailable")))
                return
            }
            state = .starting
            if !ownsReservedPort, let reservePort {
                displayPort = try reservePort()
                ownsReservedPort = true
            }
            try await services.activateGuest(environmentID, token)
            guard generation == startGeneration, !token.isCancelled, !Task.isCancelled else { return }

            let staged = try Self.stageDisplayFiles(binding: binding, owner: self)
            stagedDirectory = staged.directory
            password = staged.password
            let request = LinuxGuestLocalServiceRequest(
                entry: staged.entryWrapper.path,
                runtime: .shell,
                arguments: [],
                workingDirectory: binding.writableLayerURL.path,
                port: displayPort,
                logFile: staged.logFile,
                environment: [
                    // PATH only — the plaintext password is never placed in
                    // the service environment (it is encoded into guest argv).
                    Self.passwordFileVariable: staged.guestPasswordPath,
                    Self.geometryVariable: Self.defaultGeometry,
                ]
            )
            let handle = try await services.startLocalService(environmentID, request, token)
            // Transfer ownership even when stop arrived while spawn awaited:
            // the stop joins this task, then confirms the returned handle ended.
            serviceHandle = handle
            forwardPort = Int(handle.forward.hostPort)
            guard generation == startGeneration, !token.isCancelled, !Task.isCancelled else {
                return
            }
            observeLifecycleIfNeeded()
            // The credential INPUT file stays until the VNCAuth handshake
            // proves the launcher consumed it — a running snapshot only
            // proves the PID is alive (interpreter delays).

            let snapshot = try await awaitRunningSnapshot(handle: handle, generation: generation, token: token)
            guard generation == startGeneration, !token.isCancelled else { return }
            guard snapshot.state == "running" else {
                state = .failed(Self.serviceFailureMessage(snapshot: snapshot))
                await cleanupService()
                return
            }
            try await connectClient(handle: handle, generation: generation, token: token)
            // Authenticated ⇒ the launcher consumed and unlinked the input.
            try? FileManager.default.removeItem(at: staged.passwordInput)
        } catch FloeError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            guard generation == startGeneration else { return }
            state = .failed(Self.truncated(error.localizedDescription))
            await cleanupService()
        }
    }

    private func awaitRunningSnapshot(
        handle: LinuxGuestLocalServiceHandle,
        generation: UUID,
        token: CancellationToken
    ) async throws -> LinuxGuestLocalServiceSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            try token.throwIfCancelled()
            guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
            let snapshot = await services.serviceSnapshot(handle)
            switch snapshot.state {
            case "running":
                return snapshot
            case "stopped", "failed", "notFound":
                return snapshot
            default:
                try await Task.sleep(for: .seconds(2))
            }
        }
        return await services.serviceSnapshot(handle)
    }

    /// Connects the client with a bounded retry: the interpreter can take
    /// longer than one TCP window before RFB is ready. Transport-level
    /// failures (refused/unreachable/timeout) retry while the owned service
    /// stays running; an authentication failure fails closed immediately.
    private func connectClient(handle: LinuxGuestLocalServiceHandle, generation: UUID, token: CancellationToken) async throws {
        guard let password else {
            throw FloeError.internalError("Display password missing after staging")
        }
        let overallDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while true {
            try token.throwIfCancelled()
            guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
            state = .connecting
            let session = VNCSession(host: handle.forward.hostAddress, port: handle.forward.hostPort, password: password)
            let sessionGeneration = UUID()
            self.sessionGeneration = sessionGeneration
            session.onStateChange { [weak self] newState in
                Task { @MainActor in
                    self?.noteClientState(newState, generation: sessionGeneration)
                }
            }
            session.connect()
            var failure: VNCConnectionFailure?
            let attemptDeadline = ContinuousClock.now.advanced(by: .seconds(8))
            poll: while ContinuousClock.now < attemptDeadline {
                guard generation == startGeneration, !token.isCancelled, !Task.isCancelled else {
                    session.disconnect()
                    throw CancellationError()
                }
                switch session.currentState {
                case .connected:
                    clientSession = session
                    displaySessionID = UUID()
                    state = .ready
                    return
                case .failed(let observed):
                    failure = observed
                    break poll
                default:
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            session.disconnect()
            if let failure {
                // Wrong credential or auth policy: never retry, never fall back.
                if failure.category == .authenticationFailed || failure.category == .credentialMissing {
                    throw FloeError.validationFailed(Self.truncated(failure.toolSummary))
                }
            }
            guard ContinuousClock.now < overallDeadline else {
                throw FloeError.validationFailed(Self.truncated(String(localized: "display.error.connect_timeout")))
            }
            // Only keep retrying while the owned service is still alive.
            let snapshot = await services.serviceSnapshot(handle)
            if snapshot.state != "running" {
                throw FloeError.validationFailed(Self.serviceFailureMessage(snapshot: snapshot))
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func noteClientState(_ newState: VNCSessionState, generation: UUID) {
        guard generation == sessionGeneration else { return }
        switch newState {
        case .failed(let failure):
            clientSession?.disconnect()
            clientSession = nil
            if !stopping { state = .failed(Self.truncated(failure.toolSummary)) }
        case .disconnected:
            clientSession = nil
            if !stopping, state == .ready {
                state = .ended(Self.truncated(String(localized: "display.error.client_disconnected")))
            }
        default:
            break
        }
    }

    /// Explicit user stop (Back-to-terminal only ends viewer demand; this
    /// tears the display down). Stop/join ordering: invalidate the start
    /// generation and cancel the start token FIRST so a start crossing its
    /// awaits can never publish a service after cleanup; join the in-flight
    /// start task; then stop the owned service (supervisor kill + forward
    /// removal + launcher trap), remove staged files, end the lease and drop
    /// the password. Terminal and compute are untouched.
    func stopDisplay() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { await self.performStop(environmentEnded: false) }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop(environmentEnded: Bool) async {
        stopping = true
        state = .stopping
        startGeneration = UUID()
        prepareGeneration = UUID()
        startToken.cancel()
        startTask?.cancel()
        prepareTask?.cancel()
        if let startTask {
            await startTask.value
        }
        if let prepareTask { await prepareTask.value }
        startTask = nil
        prepareTask = nil
        let confirmed = await cleanupService()
        if !confirmed {
            state = .failed(Self.truncated(String(localized: "display.error.stop_pending")))
        } else {
            state = environmentEnded
                ? .ended(Self.truncated(String(localized: "display.error.environment_stopped")))
                : .idle
        }
        stopping = false
    }

    private func joinEnvironmentStop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { await self.performStop(environmentEnded: true) }
        stopTask = task
        await task.value
        stopTask = nil
    }

    /// Retries a failed/ended display on the same resolved environment.
    func restartDisplay() async {
        guard environmentID != nil else { return }
        await stopDisplay()
        await startDisplay()
    }

    @discardableResult
    private func cleanupService() async -> Bool {
        sessionGeneration = UUID() // stale session callbacks become no-ops
        lifecycleTask?.cancel()
        lifecycleTask = nil
        clientSession?.disconnect()
        clientSession = nil
        toolDemandActive = false
        if let handle = serviceHandle {
            await services.stopLocalService(handle)
            let snapshot = await services.serviceSnapshot(handle)
            guard !snapshot.alive, snapshot.state == "notFound" || snapshot.state == "stopped" else {
                // The supervisor deliberately retains handles on an unknown
                // stop. Keep this owner's lease, port and auth files as well.
                observeLifecycleIfNeeded()
                return false
            }
        }
        leaseTask?.cancel()
        leaseTask = nil
        let endedHandle = serviceHandle
        serviceHandle = nil
        let directory = stagedDirectory
        stagedDirectory = nil
        let lease = binding
        binding = nil
        let releaseReservation = ownsReservedPort
        ownsReservedPort = false
        password = nil
        forwardPort = nil
        // Stop/join the owned service FIRST so a hard-killed guest can never
        // observe partial host cleanup; staged files follow unconditionally.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if releaseReservation { releasePort?() }
        if let lease { await lease.endLease() }
        if let endedHandle {
            // The reporting contract permits idempotent acknowledgement by
            // owned handle even if a buffered terminal notice was not read.
            await services.acknowledgeLifecycle(.init(handle: endedHandle, reason: .hostStopRequested))
        }
        return true
    }

    // MARK: Lifecycle observation

    private func observeLifecycleIfNeeded() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let stream = await self?.services.lifecycleEvents() else { return }
            for await event in stream {
                guard let self else { return }
                await self.handleLifecycleEvent(event)
            }
        }
    }

    private func handleLifecycleEvent(_ event: LinuxGuestLocalServiceLifecycleEvent) async {
        guard event.handle.token == serviceHandle?.token else { return }
        switch event.reason {
        case .hostStopRequested:
            // Routed through our own stop or the environment-level stop.
            break
        case .processExited, .environmentGone:
            guard !stopping, stopTask == nil else {
                await services.acknowledgeLifecycle(event)
                return
            }
            await joinEnvironmentStop()
            state = .ended(Self.truncated(String(localized: "display.error.service_ended")))
            await services.acknowledgeLifecycle(event)
        }
    }

    // MARK: Staging (per-owner directory; secret-free except the 0600 input)

    private struct StagedDisplay {
        var directory: URL
        var entryWrapper: URL
        var logFile: URL
        var passwordInput: URL
        var guestPasswordPath: String
        var password: String
    }

    /// One software framebuffer window by default (the GPU path is opt-in
    /// via the launcher's render-node hook once the Venus chain is proven);
    /// no desktop; no boot-time server.
    static let defaultGeometry = "1024x768"
    static let passwordFileVariable = "FLOE_DISPLAY_PASSWORD_FILE"
    static let geometryVariable = "FLOE_DISPLAY_GEOMETRY"

    /// Deterministic, secret-free service entry. The launcher itself ships in
    /// the Linux image at /usr/local/libexec/floe-display-start; a missing
    /// launcher is a concise, actionable service failure — never a fallback
    /// to a host-side renderer.
    static let entryWrapperContents = """
    #!/bin/sh
    # Floe display service entry. Host-staged, secret-free; the real launcher
    # ships in the Linux image at /usr/local/libexec/floe-display-start.
    exec /usr/local/libexec/floe-display-start "$@"
    """

    /// Per-owner directory inside the shared environment layer, created
    /// 0700 before any secret is written. Cleanup only ever touches THIS
    /// owner's directory — another owner's staged files are left alone.
    static func ownerDirectoryName(owner: LocalLinuxDisplayOwner) -> String {
        "floe-display-" + owner.stagingID
    }

    private static func stageDisplayFiles(binding: LocalLinuxDisplayBinding, owner: LocalLinuxDisplayOwner) throws -> StagedDisplay {
        let directory = binding.writableLayerURL
            .appendingPathComponent("display", isDirectory: true)
            .appendingPathComponent(ownerDirectoryName(owner: owner), isDirectory: true)
        // 0700 from creation: the plaintext credential never exists under a
        // default-permissions directory.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: directory) } }
        removeStagedArtifacts(in: directory)
        let entryWrapper = directory.appendingPathComponent("floe-display-entry.sh")
        try entryWrapperContents.write(to: entryWrapper, atomically: true, encoding: .utf8)

        // 0600 from creation (no atomic-rename temp at default permissions):
        // create the file with the secret bytes and the mode in one step.
        let password = makePassword()
        let passwordInput = directory.appendingPathComponent("floe-display-\(UUID().uuidString).pass")
        guard FileManager.default.createFile(
            atPath: passwordInput.path,
            contents: Data(password.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw FloeError.internalError("Could not stage the display credential input")
        }

        let logFile = directory.appendingPathComponent("floe-display.log")
        let guestPasswordPath = LinuxGuestMountPoint.environment + "/display/"
            + ownerDirectoryName(owner: owner) + "/" + passwordInput.lastPathComponent
        staged = true
        return StagedDisplay(
            directory: directory,
            entryWrapper: entryWrapper,
            logFile: logFile,
            passwordInput: passwordInput,
            guestPasswordPath: guestPasswordPath,
            password: password
        )
    }

    private static func removeStagedArtifacts(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("floe-display-") || name.hasPrefix(".floe-display-") || name.hasPrefix(".floe-xvnc-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func removeStagedFiles() {
        guard let stagedDirectory else { return }
        Self.removeStagedArtifacts(in: stagedDirectory)
    }

    /// Transient per-display VNCAuth password (the protocol maximum is 8
    /// characters). Loopback-only forward + per-display generation + immediate
    /// removal keep the exposure bounded.
    static func makePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    // MARK: Messages (bounded, non-secret, actionable)

    static func truncated(_ message: String, limit: Int = 300) -> String {
        message.count > limit ? String(message.prefix(limit)) + "…" : message
    }

    private static func serviceFailureMessage(snapshot: LinuxGuestLocalServiceSnapshot) -> String {
        let tail = truncated(snapshot.stdout.replacingOccurrences(of: "\n", with: " "), limit: 220)
        let base = String(localized: "display.error.service_failed")
        return tail.isEmpty ? base : "\(base)\n\(tail)"
    }

    private static func displayUnavailableMessage(state: State) -> String {
        switch state {
        case .starting, .connecting:
            return String(localized: "display.error.starting")
        case .idle, .ended, .failed:
            return String(localized: "display.error.open_screen_first")
        default:
            return String(localized: "display.error.unavailable")
        }
    }
}

// MARK: - Center

/// App-lifetime registry of display owners. Terminal surfaces ask for their
/// owner here; the scoped VNC provider resolves through the same registry, so
/// UI demand and tool demand are two clients of one scoped owner. No eager
/// display is created at guest boot. Guest RFB ports are reserved uniquely
/// per owner from a bounded range — the shared guest and the host loopback
/// use the same number through the service forward, so collisions would
/// otherwise cross projects.
@MainActor
final class LocalLinuxDisplayCenter {
    struct Wiring: Sendable {
        var resolver: LocalLinuxDisplayResolver
        var services: LocalLinuxDisplayServices
        /// True only when the environment record is exactly a Linux guest
        /// (`effectiveExecutionBackend == .linuxVM`); decides whether a tool
        /// context is scoped-local (fail closed) or not (existing path).
        var isLocalLinuxEnvironment: @Sendable (String) async -> Bool
    }

    /// Reserved guest RFB ports (5900 stays untouched; the bound caps the
    /// number of concurrently open screens per app process).
    static let guestPortRange = 5901...5999
    static let defaultGuestPort = 5900

    private let wiring: Wiring
    private var owners: [String: LocalLinuxDisplayOwner] = [:]
    private var reservedPorts: [String: Int] = [:] // owner key -> port
    private var nextPortIndex = 0
    /// Task-scoped routing: after an EXPLICIT targeted remote connect, these
    /// task keys keep using the global remote provider until the local screen
    /// is opened for the owner (or the task ends). Never a global
    /// environment-first fallback.
    private var remoteRoutingOverrides: Set<String> = []

    init(wiring: Wiring) { self.wiring = wiring }

    private func key(conversationID: UUID?, workspaceRoot: URL) -> String {
        LocalLinuxDisplayOwner.ownerID(conversationID: conversationID, workspaceRoot: workspaceRoot)
    }

    /// Cached owner for one terminal surface. A changed workspace for the
    /// same key evicts and closes the previous owner (awaited before reuse).
    func owner(conversationID: UUID?, workspaceRoot: URL) -> LocalLinuxDisplayOwner {
        let key = self.key(conversationID: conversationID, workspaceRoot: workspaceRoot)
        if let existing = owners[key], existing.workspaceRoot == workspaceRoot { return existing }
        if let previous = owners[key] {
            Task { await previous.stopDisplay() }
        }
        let reservation = UUID().uuidString
        let owner = LocalLinuxDisplayOwner(
            conversationID: conversationID,
            workspaceRoot: workspaceRoot,
            displayPort: 0,
            resolver: wiring.resolver,
            services: wiring.services
        )
        owner.reservePort = { [weak self] in
            guard let self else { throw FloeError.cancelled }
            return try self.allocatePort(key: reservation)
        }
        owner.releasePort = { [weak self] in self?.reservedPorts.removeValue(forKey: reservation) }
        owner.onLocalDemand = { [weak self] in
            guard let self else { return }
            self.remoteRoutingOverrides = self.remoteRoutingOverrides.filter {
                !$0.hasSuffix("\u{0}" + key)
            }
        }
        owners[key] = owner
        return owner
    }

    private func allocatePort(key: String) throws -> Int {
        if let existing = reservedPorts[key] { return existing }
        let taken = Set(reservedPorts.values)
        let candidates = Array(Self.guestPortRange)
        for offset in candidates.indices {
            let index = (nextPortIndex + offset) % candidates.count
            let port = candidates[index]
            if !taken.contains(port), Self.loopbackPortAvailable(port) {
                reservedPorts[key] = port
                nextPortIndex = (index + 1) % candidates.count
                return port
            }
        }
        throw FloeError.validationFailed(String(localized: "display.error.capacity"))
    }

    private static func loopbackPortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func owner(environmentID: String, ownerID: String) -> LocalLinuxDisplayOwner? {
        owners.values.first { $0.environmentID == environmentID && $0.ownerID == ownerID }
    }

    // MARK: Scoped VNC tool seams (wired into registerVNCTools)

    private func taskKey(for context: ToolContext) -> String {
        let owner = context.conversationID?.uuidString
            ?? context.workspaceRootURL.map { LocalLinuxDisplayOwner.ownerID(conversationID: nil, workspaceRoot: $0) }
            ?? "run:" + context.runID.uuidString
        return (context.environmentID ?? context.environment?.id ?? "") + "\u{0}" + owner
    }

    /// Called by the app after a successful EXPLICIT targeted remote connect
    /// (vnc.connect/vnc.reconnect with hostID+connectionID): subsequent tool
    /// calls from this task keep the remote session even while its execution
    /// environment is a local Linux guest.
    func markRemoteRouting(for context: ToolContext) {
        remoteRoutingOverrides.insert(taskKey(for: context))
    }

    /// Read-only resolution for observe/click/type/... . nil → not a
    /// scoped-local context (or an explicit remote override): the existing
    /// global provider runs unchanged. Throws → scoped-local context without
    /// a usable display: the call fails closed and never falls back to
    /// another task's or the global remote screen. Never connects or launches.
    func sessionHandle(for context: ToolContext) async throws -> VNCSessionHandle? {
        if remoteRoutingOverrides.contains(taskKey(for: context)) { return nil }
        guard let environmentID = context.environmentID ?? context.environment?.id else { return nil }
        guard await wiring.isLocalLinuxEnvironment(environmentID) else { return nil }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                #"{"category":"policyDenied","reason":"The local Linux screen is not available in a temporary or read-only chat.","retryable":false,"stage":"configuration","status":"connectionFailed"}"#
            )
        }
        let ownerID = context.conversationID?.uuidString
            ?? context.workspaceRootURL.map { LocalLinuxDisplayOwner.ownerID(conversationID: nil, workspaceRoot: $0) }
        guard let ownerID, let owner = owner(environmentID: environmentID, ownerID: ownerID) else {
            throw FloeError.validationFailed(Self.noDisplayMessage)
        }
        return try owner.acquireToolClient()
    }

    /// Mutating resolution for vnc.connect/vnc.reconnect only: reconnects the
    /// retained running guest service (no second launch); absent local display
    /// fails closed unless an explicit remote override exists.
    func connectHandle(for context: ToolContext) async throws -> VNCSessionHandle? {
        if remoteRoutingOverrides.contains(taskKey(for: context)) { return nil }
        guard let environmentID = context.environmentID ?? context.environment?.id else { return nil }
        guard await wiring.isLocalLinuxEnvironment(environmentID) else { return nil }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                #"{"category":"policyDenied","reason":"The local Linux screen is not available in a temporary or read-only chat.","retryable":false,"stage":"configuration","status":"connectionFailed"}"#
            )
        }
        let ownerID = context.conversationID?.uuidString
            ?? context.workspaceRootURL.map { LocalLinuxDisplayOwner.ownerID(conversationID: nil, workspaceRoot: $0) }
        guard let ownerID, let owner = owner(environmentID: environmentID, ownerID: ownerID) else {
            throw FloeError.validationFailed(Self.noDisplayMessage)
        }
        return try await owner.reconnectToolClient()
    }

    func toolStatus(for context: ToolContext) async -> VNCToolConnectionStatus? {
        if remoteRoutingOverrides.contains(taskKey(for: context)) { return nil }
        guard let environmentID = context.environmentID ?? context.environment?.id else { return nil }
        guard await wiring.isLocalLinuxEnvironment(environmentID) else { return nil }
        let ownerID = context.conversationID?.uuidString
            ?? context.workspaceRootURL.map { LocalLinuxDisplayOwner.ownerID(conversationID: nil, workspaceRoot: $0) }
        guard let ownerID, let owner = owner(environmentID: environmentID, ownerID: ownerID) else {
            return VNCToolConnectionStatus(
                state: .unconfigured,
                configuredEndpointCount: 0,
                target: "local-linux",
                transport: "rfb-loopback",
                toolManaged: true,
                failure: VNCConnectionFailure(
                    category: .configurationMissing,
                    stage: .configuration,
                    retryable: false,
                    host: "127.0.0.1",
                    port: Self.defaultGuestPort,
                    message: "No local Linux screen is open for this task."
                )
            )
        }
        return owner.toolStatus()
    }

    /// Releases sticky tool demand on the scoped display. nil → the existing
    /// global disconnect runs unchanged.
    func releaseToolSession(for context: ToolContext) async -> VNCToolConnectionStatus? {
        if remoteRoutingOverrides.contains(taskKey(for: context)) { return nil }
        guard let environmentID = context.environmentID ?? context.environment?.id else { return nil }
        guard await wiring.isLocalLinuxEnvironment(environmentID) else { return nil }
        let ownerID = context.conversationID?.uuidString
            ?? context.workspaceRootURL.map { LocalLinuxDisplayOwner.ownerID(conversationID: nil, workspaceRoot: $0) }
        guard let ownerID, let owner = owner(environmentID: environmentID, ownerID: ownerID) else {
            return await toolStatus(for: context)
        }
        owner.releaseToolClient()
        return owner.toolStatus()
    }

    private static let noDisplayMessage =
        #"{"category":"configurationMissing","reason":"No local Linux screen is connected for this task. Open the screen from the local terminal first.","retryable":false,"stage":"configuration","status":"connectionFailed"}"#
}

extension LocalLinuxDisplayOwner {
    /// Secret-free status for vnc.status in a scoped-local context.
    func toolStatus() -> VNCToolConnectionStatus {
        let mapped: VNCToolConnectionStatus.State
        switch state {
        case .ready: mapped = clientSession?.isConnected == true ? .connected : .disconnected
        case .starting, .connecting, .stopping: mapped = .connecting
        case .failed, .ended: mapped = .failed
        case .idle, .resolving, .unavailable: mapped = .disconnected
        }
        let failureMessage: String?
        switch state {
        case .failed(let message), .ended(let message): failureMessage = message
        default: failureMessage = nil
        }
        return VNCToolConnectionStatus(
            state: mapped,
            configuredEndpointCount: 0,
            sessionID: displaySessionID,
            target: forwardPort.map { "local-linux:127.0.0.1:\($0)" } ?? "local-linux",
            transport: "rfb-loopback",
            toolManaged: true,
            failure: failureMessage.map {
                VNCConnectionFailure(
                    category: .networkUnreachable,
                    stage: .transport,
                    retryable: true,
                    host: forwardHost,
                    port: forwardPort ?? LocalLinuxDisplayCenter.defaultGuestPort,
                    message: $0
                )
            }
        )
    }
}
