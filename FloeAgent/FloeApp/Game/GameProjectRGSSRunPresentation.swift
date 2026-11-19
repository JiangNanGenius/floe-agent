// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import Observation
import FloeGameCore
import FloeGameTouch
import FloeGamePlayIntegration
import FloeGameRGSSHostCore

/// The guest run uses the same controls/settings service as a Web run. All
/// keyboard traffic is captured by actual job/owner identity, including AI
/// pulses; a view reconstruction never selects another display or job.
@MainActor @Observable
final class GameProjectRGSSRunPresentation {
    let play: RGSSGuestPlaySession
    let jobID: UUID
    let input: GameTouchInputService
    let defaultProfile: GameTouchProfile
    var draftProfile: GameTouchProfile
    var editingLayout = false
    private(set) var savedProfile: GameTouchProfile
    private(set) var controlsError: String?
    private(set) var savingControls = false
    private(set) var stopping = false
    private let store: GameTouchProfileStore
    private var revision: UInt64
    private let capturedSink: RGSSGuestTouchInputSink
    private let sink: GameTouchInputFailureFence
    private var uiWantsInput = false
    private var covered = false
    private var aiInputRequests = 0
    private var inputEpoch: UInt64 = 0
    private var inputTask: Task<Void, Never>?
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var activityObserver: GameApplicationActivityObserver?

    private init(play: RGSSGuestPlaySession, store: GameTouchProfileStore,
                 defaults: GameTouchProfile, profile: GameTouchProfile, revision: UInt64,
                 capturedSink: RGSSGuestTouchInputSink, jobID: UUID) {
        self.play = play; self.store = store; defaultProfile = defaults
        self.jobID = jobID
        draftProfile = profile; savedProfile = profile; self.revision = revision
        self.capturedSink = capturedSink
        sink = GameTouchInputFailureFence(sink: capturedSink)
        input = GameTouchInputService(profile: profile)
        activityObserver = GameApplicationActivityObserver { [weak self] active in
            guard let self else { return }
            self.applicationIsActive = active
            self.requestInputEnabled(self.uiWantsInput)
        }
    }

    static func make(play: RGSSGuestPlaySession, support: URL) async throws -> GameProjectRGSSRunPresentation {
        let request = play.request
        guard let job = play.session, play.phase == .running else { throw RGSSGuestRunError.sessionNotActive }
        let sink = try RGSSGuestTouchInputSink(play: play)
        let identity = try GameWebStorageIdentity(context: request.context, engine: request.engine,
                                                gameRoot: request.rootRelative)
        let store = try GameTouchProfileStore(directory: support.appendingPathComponent("InputProfiles", isDirectory: true)
            .appendingPathComponent(identity.originHost, isDirectory: true),
            projectID: request.context.projectID, owner: request.context.owner)
        let defaults = GameTouchProfile.standard(request.engine, keyboardTransport: .x11,
                                                 projectBindings: play.keymap?.declaration)
        let loaded = try await store.load(engine: request.engine, keyboardTransport: .x11, defaults: defaults)
        guard play.session?.jobID == job.jobID, play.session?.ownerToken == job.ownerToken,
              play.phase == .running else { throw RGSSGuestRunError.staleSession }
        return .init(play: play, store: store, defaults: defaults, profile: loaded.profile,
                     revision: loaded.revision, capturedSink: sink, jobID: job.jobID)
    }

    var hasControlChanges: Bool { draftProfile != savedProfile }
    var inputFailed: Bool { sink.failed || sink.invalidated }

    func setCovered(_ value: Bool) {
        covered = value
        requestInputEnabled(uiWantsInput)
    }

    func requestInputEnabled(_ enabled: Bool) {
        uiWantsInput = enabled
        inputEpoch &+= 1
        let epoch = inputEpoch
        inputTask?.cancel()
        inputTask = Task { @MainActor in
            guard !Task.isCancelled, self.inputEpoch == epoch else { return }
            await self.reconcileInput()
        }
    }

    private func reconcileInput() async {
        let enabled = (uiWantsInput || aiInputRequests > 0) && !covered && !editingLayout && !stopping
            && play.phase == .running && applicationIsActive
        if enabled, !sink.failed, !sink.invalidated {
            if !input.isAttached { await input.attach(sink) }
        } else { await input.detach() }
    }

    func pulse(_ binding: GameTouchBinding, durationMilliseconds: Int = 80) async throws {
        guard !stopping, !covered, play.phase == .running,
              applicationIsActive else { throw GameTouchPulseError.unavailable }
        aiInputRequests += 1
        await reconcileInput()
        do {
            try await input.performPulse(binding, durationMilliseconds: durationMilliseconds)
        } catch {
            aiInputRequests -= 1; await reconcileInput(); throw error
        }
        aiInputRequests -= 1
        await reconcileInput()
    }

    func previewControls(_ profile: GameTouchProfile) async {
        do {
            try profile.validate()
            guard profile.engine == play.request.engine, profile.keyboardTransport == .x11 else {
                throw GameProjectError.invalidContext
            }
            guard draftProfile == profile else { return }
            await input.updateProfile(profile)
            controlsError = nil
            await reconcileInput()
        } catch { controlsError = error.localizedDescription }
    }

    func moveControl(_ id: GameTouchButton.ID?, to anchor: GameTouchAnchor) {
        do {
            if let id {
                guard var button = draftProfile.button(id: id) else { throw GameProjectError.invalidEdit }
                button.anchor = anchor; try draftProfile.update(button)
            } else { draftProfile.stickAnchor = anchor }
        } catch { controlsError = error.localizedDescription }
    }

    @discardableResult func saveControls() async -> Bool {
        guard !savingControls else { return false }
        savingControls = true; defer { savingControls = false }
        let captured = draftProfile
        do {
            try captured.validate()
            revision = try await store.save(captured, expectedRevision: revision)
            savedProfile = captured; controlsError = nil
            if draftProfile == captured { await previewControls(captured) }
            return draftProfile == captured
        } catch { controlsError = error.localizedDescription; return false }
    }

    func discardControlChanges() async {
        draftProfile = savedProfile
        await previewControls(savedProfile)
    }

    /// Called before the request-specific job stop. Failed stops keep this
    /// presentation and its draft for retry; input does not rearm meanwhile.
    func prepareForStop() async {
        stopping = true; uiWantsInput = false; inputEpoch &+= 1
        inputTask?.cancel()
        await input.detach()
        sink.invalidate(); capturedSink.invalidate()
    }
}
#endif
