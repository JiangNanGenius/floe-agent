// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeGameCore
import FloeGameDeveloperCore
import FloeGameRGSS
import FloeGameRunKit
import FloeGameWebKit

/// Host-resolved immutable target for one staged run. The resolver belongs to
/// the Linux adapter; the guest run/home paths are exposed only for the
/// developer file bridge and diagnostics, never as a shell command.
public struct RGSSGuestTargetBinding: Sendable {
    public let resolver: any RGSSGuestTargetResolver
    public let guestRunDirectory: String
    public let guestHomeDirectory: String
    public let guestEngineBinary: String
    public let fileMapping: any RGSSGuestHostPathMapping

    public init(
        resolver: any RGSSGuestTargetResolver,
        guestRunDirectory: String,
        guestHomeDirectory: String,
        guestEngineBinary: String,
        fileMapping: any RGSSGuestHostPathMapping
    ) throws {
        guard guestRunDirectory.hasPrefix("/"), guestHomeDirectory.hasPrefix("/"),
              guestEngineBinary.hasPrefix("/"),
              !guestRunDirectory.contains(".."), !guestHomeDirectory.contains(".."),
              !guestEngineBinary.contains("..") else {
            throw RGSSGuestRunError.invalidRequest("guest target paths")
        }
        self.resolver = resolver
        self.guestRunDirectory = guestRunDirectory
        self.guestHomeDirectory = guestHomeDirectory
        self.guestEngineBinary = guestEngineBinary
        self.fileMapping = fileMapping
    }
}

/// Implemented by the Linux adapter. It re-resolves the same environment and
/// owner captured by the staged run; it must not choose a first/global path.
public protocol RGSSGuestTargetResolverProviding: Sendable {
    func makeTarget(for staged: RGSSGuestStagedRun,
                    display: RGSSGuestDisplayAttachment) async throws -> RGSSGuestTargetBinding
}

public enum RGSSGuestPlayPhase: Equatable, Sendable {
    case idle
    case preparing
    case attachingDisplay
    case starting
    case running
    case detached
    case stopping
    case stopped
    case failed(String)
}

public struct RGSSGuestStopOutcome: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case stopped
        case stopUnconfirmed
        case alreadyStopped
    }
    public let status: Status
    public let saves: RGSSGuestSaveCollection?
    public let error: String?

    public init(status: Status, saves: RGSSGuestSaveCollection?, error: String?) {
        self.status = status
        self.saves = saves
        self.error = error
    }
}

/// One owned RGSS play session. It composes:
/// - `RGSSGuestRunStager` (source copy + save layer),
/// - `RGSSGuestHostController` / `RGSSGuestRuntimeAdapter` (context fencing,
///   owned job stop, input lifecycle),
/// - the App's existing local display and scoped guest file service,
/// - the existing developer session/save repository.
///
/// Detaching a view releases this run's keys and the display client transport;
/// the game job keeps running. Stopping releases keys, stops only this owned
/// job, then collects standard saves into the owned save layer.
@MainActor
public final class RGSSGuestPlaySession: ObservableObject {
    public let request: RGSSGuestRunRequest
    public let stager: RGSSGuestRunStager
    public let displays: any RGSSGuestDisplayProviding
    public let targets: any RGSSGuestTargetResolverProviding
    public let jobs: any RGSSGuestJobService
    public let contexts: any GameRunContextHost

    @Published public private(set) var phase: RGSSGuestPlayPhase = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastStopOutcome: RGSSGuestStopOutcome?
    @Published public private(set) var staged: RGSSGuestStagedRun?
    @Published public private(set) var keymap: RGSSGuestKeymap?
    @Published public private(set) var saveManager: RGSSGuestSaveManager?
    @Published public private(set) var session: RGSSGuestSession?
    @Published public private(set) var displayServiceID: String?
    @Published public private(set) var developerInstalled = false

    private var controller: RGSSGuestHostController?
    private var inputProvider: RGSSGuestInputSessionProvider?
    private var display: RGSSGuestDisplayAttachment?
    private var target: RGSSGuestTargetBinding?
    private var developerHost: RGSSGuestDeveloperHost?
    private var pendingDeveloperOverlay: Data?
    private var generation: UInt64 = 0

    public init(
        request: RGSSGuestRunRequest,
        stager: RGSSGuestRunStager,
        displays: any RGSSGuestDisplayProviding,
        targets: any RGSSGuestTargetResolverProviding,
        jobs: any RGSSGuestJobService,
        contexts: any GameRunContextHost
    ) {
        self.request = request
        self.stager = stager
        self.displays = displays
        self.targets = targets
        self.jobs = jobs
        self.contexts = contexts
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        if case .detached = phase { return true }
        return false
    }

    public var activeJobID: UUID? { session?.jobID }

    /// Prepares the owned run copy and starts the owned guest job. The saved
    /// revision/root/environment/display are captured once; a newer start or a
    /// stop fences this call at every await.
    public func start() async throws {
        switch phase {
        case .preparing, .attachingDisplay, .starting, .running, .detached:
            throw RGSSGuestRunError.invalidRequest("a game run is already active")
        default:
            break
        }
        guard session == nil, controller == nil else {
            throw RGSSGuestRunError.invalidRequest(
                "stop the current game and confirm its owned job before starting again")
        }
        generation &+= 1
        let token = generation
        phase = .preparing
        lastError = nil
        lastStopOutcome = nil
        staged = nil
        keymap = nil
        developerInstalled = false
        var attachedDisplay: RGSSGuestDisplayAttachment?
        var startedSession: RGSSGuestSession?
        do {
            let staged = try await stager.stage(request)
            try fence(token)
            self.staged = staged
            if let overlay = pendingDeveloperOverlay {
                _ = try RGSSGuestDeveloperOverlay.apply(to: staged, overlayScript: overlay)
            }
            self.keymap = try RGSSGuestKeymap.load(from: staged)
            self.developerInstalled = RGSSGuestDeveloperOverlay.isInstalled(
                in: staged.runRoot, engine: request.engine)
            phase = .attachingDisplay
            let displayRequest = try RGSSGuestDisplayRequest(
                context: request.context, environmentID: request.environmentID,
                workspaceRoot: request.context.rootURL,
                displayServiceID: request.displayServiceID)
            let display = try await displays.attach(displayRequest)
            attachedDisplay = display
            guard display.environmentID == request.environmentID else {
                throw RGSSGuestRunError.displayUnavailable(
                    "the display belongs to another environment")
            }
            try fence(token)
            self.display = display
            self.displayServiceID = display.displayServiceID
            let keymap = self.keymap!
            let inputProvider = RGSSGuestInputSessionProvider(
                port: display.inputPort, keymap: keymap)
            self.inputProvider = inputProvider
            let target = try await targets.makeTarget(for: staged, display: display)
            self.target = target
            // Fail closed before spawning if the reviewed Tapir install/pin/
            // notice layout is absent. This is a read-only host check; it never
            // installs, downloads or executes the engine.
            let install = try RGSSGuestEngineInstall(
                engine: staged.request.engine, mapping: target.fileMapping)
            _ = try await Task.detached(priority: .userInitiated) {
                try install.preflight()
            }.value
            try fence(token)
            let controller = RGSSGuestHostController(
                targets: target.resolver,
                jobs: jobs,
                inputs: inputProvider,
                contexts: RGSSGuestContextAdapter(host: contexts))
            self.controller = controller
            phase = .starting
            let session = try await controller.start(
                context: staged.request.context,
                engine: staged.request.engine,
                displayServiceID: display.displayServiceID,
                sourceDigest: staged.sourceDigest)
            startedSession = session
            try fence(token)
            self.session = session
            self.saveManager = Self.makeSaveManager(staged: staged)
            phase = .running
        } catch {
            let startupError = error
            let publishFailure = token == generation
            // Controller/adapter retain a real owned handle even when input
            // attachment failed before start() could return a public session.
            var retained = startedSession ?? self.session
            if retained == nil, let controller { retained = await controller.retainedSession() }
            if let retained, self.controller != nil {
                self.session = retained
                if let staged { self.saveManager = Self.makeSaveManager(staged: staged) }
                let outcome = await stop()
                if outcome.status == .stopUnconfirmed {
                    let message = String(describing: startupError)
                        + "; " + (outcome.error ?? "owned startup cleanup is unconfirmed")
                    phase = .failed(message)
                    lastError = message
                    // Keep controller/session/display/input/target for retry.
                    throw startupError
                }
            } else {
                if let attachedDisplay { await displays.detach(attachedDisplay) }
                self.controller = nil
                self.session = nil
                self.display = nil
                self.inputProvider = nil
                self.target = nil
            }
            if publishFailure {
                let message = (startupError as? LocalizedError)?.errorDescription ?? String(describing: startupError)
                phase = .failed(message)
                lastError = message
            }
            throw startupError
        }
    }

    /// Sends an arbitrary project chord. Keys are physical keys from the
    /// project declaration or the engine-standard map.
    public func sendChord(_ keys: [GameKeyboardKey]) async throws {
        let input = try requireInput()
        try await input.sendPhysicalChord(keys)
    }

    /// Captures the current physical-input actor once for the touch sink.
    /// A late release must never look up another run's actor.
    public func touchInputSession() throws -> RGSSGuestPhysicalInputSession {
        try requireInput()
    }

    public func setPhysicalKey(_ key: GameKeyboardKey, pressed: Bool) async throws {
        let input = try requireInput()
        try await input.setPhysicalKey(key, pressed: pressed)
    }

    /// Sends one declared/standard button by id. A multi-key binding is one
    /// chord, never an alternatives list.
    public func sendButton(_ id: String) async throws {
        let input = try requireInput()
        try await input.sendButton(id)
    }

    public func sendAction(_ action: RGSSGuestInputAction) async throws {
        let input = try requireInput()
        try await input.sendAction(action)
    }

    /// Releases every key this session pressed. Safe on background/navigation;
    /// the job keeps running.
    public func releaseAll() async {
        guard let session, let input = inputProvider?.input(for: session.jobID) else { return }
        await input.releaseAll()
    }

    /// View close/detach: release keys, then release the display client
    /// transport. The owned game job and the display service keep running.
    public func detachView() async {
        guard let session else { return }
        do { try await controller?.detachInput(session) }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        if let display { await displays.detach(display) }
        if phase == .running { phase = .detached }
    }

    /// Reconnect the client transport for a still-running job. The display
    /// provider must return a stable input port for the same owned display;
    /// the job already has the guest DISPLAY and is not restarted.
    public func reattachDisplay() async throws {
        guard phase == .detached else {
            throw RGSSGuestRunError.invalidRequest("detach the game view before reattaching")
        }
        guard let session else { throw RGSSGuestRunError.sessionNotActive }
        let displayRequest = try RGSSGuestDisplayRequest(
            context: request.context, environmentID: request.environmentID,
            workspaceRoot: request.context.rootURL,
            displayServiceID: display?.displayServiceID ?? request.displayServiceID)
        let display = try await displays.attach(displayRequest)
        guard display.environmentID == request.environmentID else {
            await displays.detach(display)
            throw RGSSGuestRunError.displayUnavailable(
                "the display belongs to another environment")
        }
        self.display = display
        self.displayServiceID = display.displayServiceID
        guard session.jobID == self.session?.jobID else {
            throw RGSSGuestRunError.staleSession
        }
        phase = .running
    }

    /// Stops only this owned job, then collects standard saves. A stop that
    /// cannot be confirmed leaves the session owned for retry and performs no
    /// save read while the process may still be writing.
    @discardableResult
    public func stop() async -> RGSSGuestStopOutcome {
        generation &+= 1
        let token = generation
        let capturedController = controller
        var capturedSession = session
        if capturedSession == nil, let capturedController {
            capturedSession = await capturedController.retainedSession()
        }
        guard let controller = capturedController, let session = capturedSession else {
            // A stop during preparation fences a later launch even though the
            // owned session does not exist yet.
            phase = .stopped
            let outcome = RGSSGuestStopOutcome(status: .alreadyStopped, saves: nil, error: nil)
            lastStopOutcome = outcome
            return outcome
        }
        phase = .stopping
        var contextStopError: String?
        do {
            try await controller.stop(session)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // The SDK adapter stops the owned job before it reports a context
            // mismatch. That case is still a confirmed process stop; collect
            // saves and report the context change instead of losing progress.
            if let runtimeError = error as? RGSSRuntimeError,
               runtimeError == .guestContextMismatch {
                contextStopError = message
            } else {
                // The frozen port forgets its environment record before the
                // host stop settles. The job service retains its own owner
                // record, so a direct stop of this exact captured handle can
                // still confirm the process before we report a failure.
                do {
                    try await jobs.stopOwnedJob(RGSSGuestJobHandle(
                        jobID: session.jobID, ownerToken: session.ownerToken))
                    contextStopError = "primary stop reported: \(message); direct owned stop confirmed"
                } catch {
                    if token == generation {
                        phase = .failed(message)
                        lastError = message
                    }
                    let outcome = RGSSGuestStopOutcome(status: .stopUnconfirmed,
                                                       saves: nil, error: message)
                    lastStopOutcome = outcome
                    return outcome
                }
            }
        }
        var collected: RGSSGuestSaveCollection?
        var saveError: String?
        if let staged {
            do {
                collected = try await stager.collectSaves(from: staged)
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
        developerHost?.detach()
        developerHost = nil
        if let display { await displays.detach(display) }
        inputProvider?.remove(jobID: session.jobID)
        self.controller = nil
        self.session = nil
        self.display = nil
        self.inputProvider = nil
        self.target = nil
        phase = .stopped
        let combinedError = [contextStopError, saveError]
            .compactMap { $0 }
            .joined(separator: " ")
        if !combinedError.isEmpty { lastError = combinedError }
        let outcome = RGSSGuestStopOutcome(
            status: .stopped, saves: collected,
            error: combinedError.isEmpty ? nil : combinedError)
        lastStopOutcome = outcome
        return outcome
    }

    /// Late close from an old view: only the currently owned session may be
    /// stopped. A stale handle is a no-op.
    public func closeIfActive() async {
        guard session != nil else { return }
        _ = await stop()
    }

    public func refreshStatus() async throws -> RGSSGuestJobStatus {
        guard let controller, let session else { throw RGSSGuestRunError.sessionNotActive }
        return try await controller.status(session)
    }

    public func captureScreenshot() async throws -> Data? {
        guard let display else { throw RGSSGuestRunError.displayUnavailable("no display attached") }
        return try await display.captureScreenshot()
    }

    /// Explicit development menu attachment. A missing overlay is an
    /// actionable error; no shell/Ruby evaluator is created.
    @discardableResult
    public func openDeveloperMenu() async throws -> GameDeveloperSession {
        guard let staged, let target else { throw RGSSGuestRunError.stagedRunMissing }
        guard RGSSGuestDeveloperOverlay.isInstalled(in: staged.runRoot,
                                                     engine: staged.request.engine) else {
            throw RGSSGuestRunError.developerOverlayMissing
        }
        let host = try RGSSGuestDeveloperHost(
            staged: staged,
            guestRunDirectory: target.guestRunDirectory,
            mapping: target.fileMapping)
        try await host.attach()
        developerHost = host
        return host.session
    }

    public func closeDeveloperMenu() {
        developerHost?.detach()
        developerHost = nil
    }

    /// Installs the overlay only into the owned run copy for immediate
    /// development. The imported source stays byte-identical.
    @discardableResult
    /// Queues the overlay for the next start and, when a prepared run copy
    /// already exists, applies it immediately. It never touches the imported
    /// source. A running Tapir process does not reload scripts, so an active
    /// session must be stopped before this call.
    public func installDeveloperOverlay(script: Data) throws -> RGSSGuestDeveloperOverlay.Plan {
        guard session == nil else {
            throw RGSSGuestRunError.invalidRequest(
                "stop the game before changing its loaded script archive")
        }
        pendingDeveloperOverlay = script
        if let staged {
            let plan = try RGSSGuestDeveloperOverlay.apply(to: staged, overlayScript: script)
            developerInstalled = RGSSGuestDeveloperOverlay.isInstalled(
                in: staged.runRoot, engine: request.engine)
            return plan
        }
        let selected = try RGSSGuestRootResolver.resolve(
            root: request.context.rootURL,
            relativeRoot: request.rootRelative,
            limits: .default)
        return try RGSSGuestDeveloperOverlay.projectRevisionChanges(
            sourceRoot: selected, engine: request.engine, overlayScript: script)
    }

    /// Stops applying the overlay to future run copies. It does not delete an
    /// overlay already written into a project revision or a prepared copy.
    public func clearDeveloperOverlay() {
        pendingDeveloperOverlay = nil
    }

    /// Returns a write set for a new project revision. It does not commit;
    /// the caller uses the existing repository/history service.
    public func developerOverlayProjectChanges(script: Data) throws -> RGSSGuestDeveloperOverlay.Plan {
        let selected: URL
        if let staged {
            selected = staged.selectedRoot
        } else {
            selected = try RGSSGuestRootResolver.resolve(
                root: request.context.rootURL,
                relativeRoot: request.rootRelative,
                limits: .default)
        }
        return try RGSSGuestDeveloperOverlay.projectRevisionChanges(
            sourceRoot: selected,
            engine: request.engine,
            overlayScript: script)
    }

    private func requireInput() throws -> RGSSGuestPhysicalInputSession {
        guard let session, let input = inputProvider?.input(for: session.jobID) else {
            throw RGSSGuestRunError.inputUnavailable("the game input session is not active")
        }
        return input
    }

    private func fence(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw RGSSGuestRunError.staleSession }
    }

    private static func makeSaveManager(staged: RGSSGuestStagedRun) -> RGSSGuestSaveManager? {
        guard let store = try? RGSSGuestSaveStore(
            root: staged.saveRoot, engine: staged.request.engine,
            sourceRoot: staged.sourceRoot) else { return nil }
        let checkpointDirectory = staged.saveRoot.appendingPathComponent("Checkpoints",
                                                                         isDirectory: true)
        let repository = try? FileGameSaveRepository(
            directory: checkpointDirectory,
            projectID: staged.request.context.projectID,
            owner: staged.request.context.owner,
            maximumStateBytes: 4_194_304)
        return RGSSGuestSaveManager(store: store, checkpointRepository: repository)
    }
}

private struct RGSSGuestContextAdapter: RGSSGuestContextHost {
    let host: any GameRunContextHost
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext {
        try await host.currentContext(for: captured)
    }
}
