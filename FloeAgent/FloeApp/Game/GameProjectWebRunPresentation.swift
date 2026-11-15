// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import Observation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameWebKit
import FloeGameTouch
import FloeGamePlayIntegration
import FloeGameDeveloperCore
import FloeGameDeveloperWebKit

/// Owned by the project's run service. The player, save manager, touch queue
/// and development menu always refer to the same captured run and logical root.
@MainActor @Observable
final class GameProjectWebRunPresentation: Identifiable {
    struct StopReceipt: Sendable {
        let automaticSave: GameSaveAutomaticResult
        let closeAcknowledged: Bool
        let inputFailed: Bool
    }
    nonisolated let id: UUID
    let request: GameIDEProjectRunRequest
    let controller: GameProjectRunController
    let player: GameWebPlayer
    let saves: GameSaveManagementSession
    let developer: GameDeveloperSession
    let input: GameTouchInputService
    let profileStore: GameTouchProfileStore
    let keyboardCandidates: [GameProjectKeyboardDiscovery.Candidate]
    var draftProfile: GameTouchProfile
    var editingLayout = false
    private(set) var savedProfile: GameTouchProfile
    private(set) var defaultProfile: GameTouchProfile
    private(set) var keyboardSourceID: String?
    private(set) var inputDiagnostic: String?
    private(set) var controlsError: String?
    private(set) var savingControls = false
    private(set) var stopping = false
    private(set) var stopReceipt: StopReceipt?
    private var profileRevision: UInt64
    private let sink: GameTouchInputFailureFence
    private let cleanupOwnedRequest: @MainActor (UUID) async -> Void
    private var stopTask: Task<StopReceipt, Never>?
    private var inputIntent: UInt64 = 0
    private var inputTask: Task<Void, Never>?
    private var uiWantsInput = false
    private var aiInputRequests = 0
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var activityObserver: GameApplicationActivityObserver?

    private init(request: GameIDEProjectRunRequest, controller: GameProjectRunController,
                 player: GameWebPlayer, saves: GameSaveManagementSession, developer: GameDeveloperSession,
                 store: GameTouchProfileStore, defaults: GameTouchProfile, profile: GameTouchProfile,
                 revision: UInt64, candidates: [GameProjectKeyboardDiscovery.Candidate], sourceID: String?,
                 diagnostic: String?, cleanup: @escaping @MainActor (UUID) async -> Void) {
        id = request.id; self.request = request; self.controller = controller; self.player = player
        self.saves = saves; self.developer = developer; profileStore = store
        defaultProfile = defaults; draftProfile = profile; savedProfile = profile; profileRevision = revision
        keyboardCandidates = candidates; keyboardSourceID = sourceID; inputDiagnostic = diagnostic
        input = GameTouchInputService(profile: profile); sink = GameTouchInputFailureFence(sink: player)
        cleanupOwnedRequest = cleanup
        activityObserver = GameApplicationActivityObserver { [weak self] active in
            guard let self else { return }
            self.applicationIsActive = active
            self.requestInputEnabled(self.uiWantsInput)
        }
    }

    static func make(request: GameIDEProjectRunRequest, controller: GameProjectRunController,
                     repository: FileGameProjectRepository, supportDirectory: URL,
                     cleanupOwnedRequest: @escaping @MainActor (UUID) async -> Void) async throws -> GameProjectWebRunPresentation {
        guard let player = controller.player else { throw GameProjectError.invalidArtifact }
        let artifact = player.package.prepared
        guard artifact.source == request.context, artifact.engine == request.engine,
              artifact.gameRoot == (request.gameRoot?.value ?? ".") else { throw GameProjectError.invalidArtifact }
        let project = try await repository.open(request.context.projectID, owner: request.context.owner)
        guard project.revision == request.context.savedRevision else {
            throw GameProjectError.conflict(expected: request.context.savedRevision, actual: project.revision)
        }
        var sources: [GameProjectKeyboardDiscovery.Source] = [], total = 0
        for file in project.files where GameProjectKeyboardDiscovery.isSupported(path: file.path, engine: request.engine) {
            if let root = request.gameRoot, !file.path.value.hasPrefix(root.value + "/") { continue }
            guard sources.count < 128, file.bytes <= 2_097_152, total <= 8_388_608 - file.bytes else {
                throw GameProjectError.limitExceeded("keyboard declarations")
            }
            let bytes = try await repository.read(project.projectID, owner: project.owner,
                revision: project.revision, path: file.path)
            total += bytes.count; sources.append(.init(path: file.path, data: bytes))
        }
        var candidates: [GameProjectKeyboardDiscovery.Candidate] = [], diagnostic: String?
        do { candidates = try GameProjectKeyboardDiscovery.discover(engine: request.engine, sources: sources) }
        catch {
            diagnostic = IDELanguageRunText.t("工程键位声明无法识别，当前使用引擎默认键位。", "The project's key declaration could not be read. Engine defaults are in use.")
        }
        let declarationPath = request.gameRoot.map { $0.value + "/floe-inputs.json" } ?? "floe-inputs.json"
        let explicit = candidates.first { $0.source.value == declarationPath }
        let chosen = explicit ?? (candidates.count == 1 ? candidates.first : nil)
        let bindings = try chosen?.bindings(engine: request.engine)
        let defaults = GameTouchProfile.standard(request.engine, keyboardTransport: .browser, projectBindings: bindings)
        if chosen == nil, candidates.count > 1 {
            diagnostic = IDELanguageRunText.t("工程有多套键位，可在键位设置中选择。", "The project has multiple key maps. Choose one in Controls.")
        } else if chosen?.warnings.isEmpty == false {
            diagnostic = IDELanguageRunText.t("部分工程键位需要手动补充。", "Some project bindings need manual setup.")
        }
        let identity = try artifact.storageIdentity()
        let store = try GameTouchProfileStore(directory: supportDirectory
            .appendingPathComponent("InputProfiles", isDirectory: true)
            .appendingPathComponent(identity.originHost, isDirectory: true), projectID: identity.projectID, owner: identity.owner)
        let loaded = try await store.load(engine: request.engine, keyboardTransport: .browser, defaults: defaults)
        let saves = try GameSaveManagementSession(player: player,
            directory: supportDirectory.appendingPathComponent("GameSaves", isDirectory: true))
        let developer = try GameDeveloperSession(transport: GameWebPlayerDeveloperTransport(player: player,
            projectID: project.projectID, owner: project.owner, savedRevision: project.revision, runID: request.id))
        return .init(request: request, controller: controller, player: player, saves: saves, developer: developer,
            store: store, defaults: defaults, profile: loaded.profile, revision: loaded.revision,
            candidates: candidates, sourceID: chosen?.id, diagnostic: diagnostic, cleanup: cleanupOwnedRequest)
    }

    var hasControlChanges: Bool { draftProfile != savedProfile }
    var stopped: Bool { stopReceipt?.closeAcknowledged == true }

    /// Capture the intent synchronously at the UI lifecycle boundary. A queued
    /// foreground callback cannot reattach after a later panel/stop/background.
    func requestInputEnabled(_ enabled: Bool) {
        uiWantsInput = enabled
        inputIntent &+= 1
        let intent = inputIntent
        inputTask?.cancel()
        inputTask = Task { @MainActor in
            guard !Task.isCancelled, self.inputIntent == intent else { return }
            await self.applyInputEnabled(enabled)
        }
    }

    private func applyInputEnabled(_ enabled: Bool) async {
        if (enabled || aiInputRequests > 0), !stopping, stopReceipt == nil,
           !editingLayout, applicationIsActive,
           player.canSimulateInput, !sink.failed, !sink.invalidated {
            if !input.isAttached { await input.attach(sink) }
        } else { await input.detach() }
    }

    /// AI pulses share the same ledger as touch and keep the captured sink
    /// attached only while needed. Background and Stop fence the normal queue.
    func pulse(_ binding: GameTouchBinding, durationMilliseconds: Int = 80) async throws {
        guard !stopping, stopReceipt == nil, player.canSimulateInput,
              applicationIsActive else { throw GameTouchPulseError.unavailable }
        aiInputRequests += 1
        await applyInputEnabled(uiWantsInput)
        do {
            try await input.performPulse(binding, durationMilliseconds: durationMilliseconds)
        } catch {
            aiInputRequests -= 1; await applyInputEnabled(uiWantsInput); throw error
        }
        aiInputRequests -= 1
        await applyInputEnabled(uiWantsInput)
    }

    func previewControls(_ profile: GameTouchProfile) async {
        guard !stopping, !stopped else { return }
        do { try profile.validate(); await input.updateProfile(profile) }
        catch { controlsError = error.localizedDescription }
    }

    /// Explicitly applies one discovered action map. It never guesses which
    /// Unity map is active or overwrites the persisted profile until Save.
    func useKeyboardSource(_ id: String) async {
        guard let candidate = keyboardCandidates.first(where: { $0.id == id }) else { return }
        do {
            let defaults = GameTouchProfile.standard(request.engine, keyboardTransport: .browser,
                projectBindings: try candidate.bindings(engine: request.engine))
            keyboardSourceID = id; defaultProfile = defaults; draftProfile = defaults
            await previewControls(defaults)
        } catch { controlsError = error.localizedDescription }
    }

    func moveControl(_ id: GameTouchButton.ID?, to anchor: GameTouchAnchor) {
        do {
            if let id {
                guard var button = draftProfile.button(id: id) else { throw GameProjectError.invalidEdit }
                button.anchor = anchor; try draftProfile.update(button)
            } else { draftProfile.stickAnchor = anchor }
            let current = draftProfile
            Task { await self.previewControls(current) }
        } catch { controlsError = error.localizedDescription }
    }

    @discardableResult func saveControls() async -> Bool {
        guard !savingControls else { return false }
        savingControls = true; defer { savingControls = false }
        let captured = draftProfile
        do {
            try captured.validate()
            let revision = try await profileStore.save(captured, expectedRevision: profileRevision)
            profileRevision = revision; savedProfile = captured; controlsError = nil
            // An edit made while the store was awaiting remains a visible draft.
            if draftProfile == captured { await previewControls(captured) }
            return draftProfile == captured
        } catch { controlsError = error.localizedDescription; return false }
    }

    func discardControlChanges() async {
        draftProfile = savedProfile; controlsError = nil
        await previewControls(savedProfile)
    }

    func stop() async -> StopReceipt {
        if let stopReceipt, stopReceipt.closeAcknowledged { return stopReceipt }
        if let stopTask { return await stopTask.value }
        let task = Task { @MainActor in await self.finishStopping() }
        stopTask = task
        let receipt = await task.value
        stopTask = nil
        return receipt
    }

    private func finishStopping() async -> StopReceipt {
        stopping = true
        inputIntent &+= 1; inputTask?.cancel()
        await input.detach()
        sink.invalidate()
        let automatic: GameSaveAutomaticResult
        if let previous = stopReceipt { automatic = previous.automaticSave }
        else {
            automatic = await saves.saveAutomaticIfSupported()
            saves.invalidate(); developer.detach()
        }
        // Capture the actual close acknowledgement. The jobs service then
        // removes its own record; its repeated request-specific stop is safe.
        let acknowledged: Bool
        if controller.player === player { acknowledged = await controller.stop(runID: request.id) }
        else {
            // A controller that dropped a reference after an unconfirmed stop
            // is not proof of closure. Retry the exact captured actual player.
            acknowledged = await player.stop()
        }
        // A pending profile/foreground transition cannot leave a new attachment
        // behind the completed stop. The player has already fenced its replies.
        await input.detach()
        if acknowledged { await cleanupOwnedRequest(request.id) }
        let receipt = StopReceipt(automaticSave: automatic, closeAcknowledged: acknowledged, inputFailed: sink.failed)
        stopReceipt = receipt; stopping = false
        return receipt
    }
}

#endif
