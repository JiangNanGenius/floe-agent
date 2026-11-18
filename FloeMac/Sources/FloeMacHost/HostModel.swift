// Floe Mac M00 — mode host state shared by both entries.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Foundation

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var mode: AppMode
    @Published private(set) var source: ResolvedMode.Source
    @Published private(set) var isFirstRun: Bool
    @Published private(set) var roleSnapshot: RolePresentationSnapshot?
    @Published private(set) var autoApprovalStatus: AutoApprovalStatus = .reserved
    @Published var errorMessage: String?

    let store: ModePreferenceStore
    /// One instance. Agent and Bridge views both read and control this exact
    /// service; there is no second controller or second listener.
    let bridge: BridgeComponentController
    let agentUI: AgentUIComponentController
    let agentWorkspace: HostAgentWorkspace?
    /// Floe-owned policy provider. M00 reserves the seam; it never delegates
    /// approval decisions to OpenCode or to Bridge's separate permission path.
    let autoApproval: FloeAutoApprovalProviding
    private weak var window: NSWindow?
    private var didActivate = false
    private var terminationInProgress = false
    var modeDidChange: ((AppMode) -> Void)?

    init(
        store: ModePreferenceStore,
        resolved: ResolvedMode,
        bridgeDataRoot: URL = BridgeComponentController.defaultDataRoot,
        bridgeFixture: URL? = nil,
        autoApproval: FloeAutoApprovalProviding = ReservedAutoApprovalProvider(),
        bridgeController: BridgeComponentController? = nil,
        agentUIController: AgentUIComponentController? = nil,
        agentWorkspace: HostAgentWorkspace? = nil
    ) {
        self.store = store
        self.mode = resolved.mode
        self.source = resolved.source
        self.isFirstRun = resolved.isFirstRun
        self.bridge = bridgeController ?? BridgeComponentController(dataRoot: bridgeDataRoot, testFixture: bridgeFixture)
        self.agentUI = agentUIController ?? AgentUIComponentController()
        self.agentWorkspace = agentWorkspace
        self.autoApproval = autoApproval
    }

    func attach(window: NSWindow) {
        self.window = window
        applyRole()
        Task { await refreshAutoApprovalStatus() }
        guard !didActivate else { return }
        didActivate = true
        if !isFirstRun {
            activateCurrentMode()
        }
    }

    func completeFirstRun(_ mode: AppMode) {
        guard !terminationInProgress else { return }
        do {
            try store.save(mode)
            self.mode = mode
            self.source = .savedPreference
            self.isFirstRun = false
            applyRole()
            activateCurrentMode()
            modeDidChange?(mode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Changing the primary surface is a presentation decision. It never
    /// starts a second service, never stops the existing one, and never
    /// migrates or reruns a task.
    func switchMode(_ mode: AppMode) {
        guard !terminationInProgress else { return }
        guard mode != self.mode else { return }
        do {
            try store.save(mode)
            self.mode = mode
            self.source = .savedPreference
            self.isFirstRun = false
            applyRole()
            activateCurrentMode()
            modeDidChange?(mode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateCurrentMode() {
        guard !terminationInProgress else { return }
        switch mode {
        case .agent:
            // Agent mode includes a real Bridge card and may start/use the
            // same shared service. Do not auto-start it: Agent mode must work
            // without a Bridge and Bridge must work without Agent.
            break
        case .bridge:
            // Bridge mode initializes independently of any Agent core. If the
            // shared service is already running from Agent mode, this is a
            // no-op and the first origin remains visible.
            bridge.start(origin: .bridge)
        }
    }

    func applyRole() {
        let snapshot = RolePresentation.apply(mode, window: window)
        roleSnapshot = snapshot
        modeDidChange?(mode)
    }

    /// M00's provider reports `.reserved`; M02 replaces it with the existing
    /// Floe task/permission service. The status is read, not invented.
    func refreshAutoApprovalStatus() async {
        autoApprovalStatus = await autoApproval.status()
    }

    func startBridgeFromAgent() {
        guard !terminationInProgress else { return }
        bridge.start(origin: .agent)
    }

    func openAgentWorkspace() {
        guard !terminationInProgress else { return }
        switchMode(.agent)
        window?.makeKeyAndOrderFront(nil)
    }

    func stopBridgeExplicitly() {
        Task { await bridge.requestStop() }
    }

    func approveBridgeConsent() {
        Task { await bridge.approveConsent() }
    }

    func declineBridgeConsent() {
        Task { await bridge.declineConsent() }
    }

    func cancelBridgeConsent() {
        Task { await bridge.cancelConsent() }
    }

    func revokeBridgeClient(_ clientID: String) {
        Task { await bridge.revoke(clientID: clientID) }
    }

    /// Quitting is a full-exit decision, not a window close and not a mode
    /// switch. Active Bridge work keeps the service alive; the caller must not
    /// terminate the app until `canTerminate` is true.
    func prepareForTermination() async -> BridgeTerminationDecision {
        guard !terminationInProgress, bridge.beginHostTerminationFence() else {
            return BridgeTerminationDecision(canTerminate: false, message: String(localized: "host.exit.alreadyPreparing"))
        }
        if let agentWorkspace, !agentWorkspace.beginTermination() {
            bridge.cancelHostTerminationFence()
            return BridgeTerminationDecision(canTerminate: false, message: String(localized: "host.chat.quitBusy"))
        }
        terminationInProgress = true
        let reservation: BridgeHostExitReservation?
        switch await bridge.reserveForHostExit() {
        case .noService:
            reservation = nil
        case .reserved(let value):
            reservation = value
        case .refused(let message):
            bridge.cancelHostTerminationFence()
            agentWorkspace?.cancelTermination()
            terminationInProgress = false
            return BridgeTerminationDecision(canTerminate: false, message: message)
        }
        let restoreAgent = agentUI.userWantsAgentOpen
        if Task.isCancelled {
            return await cancelExit(reservation: reservation, restoreAgent: false,
                                    message: String(localized: "host.exit.cancelled"))
        }
        guard await agentUI.prepareForHostTermination() else {
            return await cancelExit(reservation: reservation, restoreAgent: restoreAgent,
                                    message: String(localized: "host.exit.agentNotClosed"))
        }
        if Task.isCancelled {
            return await cancelExit(reservation: reservation, restoreAgent: restoreAgent,
                                    message: String(localized: "host.exit.cancelled"))
        }
        if let reservation, !(await bridge.commitHostExit(reservation)) {
            // Commit may already have happened. The controller reconciles the
            // original connection; never issue a second commit or legacy stop.
            return await cancelExit(reservation: nil, restoreAgent: restoreAgent,
                                    message: String(localized: "host.exit.bridgeUnconfirmed"))
        }
        if Task.isCancelled {
            // A commit already sent cannot be withdrawn. The controller has
            // confirmed its outcome; keep the host open and restore its UI.
            let message: String
            switch reservation {
            case .none: message = String(localized: "host.exit.cancelled")
            case .some: message = String(localized: "host.exit.cancelledAfterBridgeStopped")
            }
            return await cancelExit(reservation: nil, restoreAgent: restoreAgent, message: message)
        }
        do {
            try await agentWorkspace?.finishTermination()
        } catch {
            return await cancelExit(reservation: nil, restoreAgent: restoreAgent,
                                    message: String(localized: "host.chat.quitUnconfirmed"))
        }
        return BridgeTerminationDecision(canTerminate: true, message: nil)
    }

    private func cancelExit(reservation: BridgeHostExitReservation?, restoreAgent: Bool,
                            message: String) async -> BridgeTerminationDecision {
        let released: Bool
        if let reservation {
            // Release is cleanup and must outlive cancellation of the caller.
            let cleanup = Task { @MainActor [bridge] in
                await bridge.cancelHostExit(reservation)
            }
            released = await cleanup.value
        } else {
            released = true
        }
        agentUI.cancelHostTermination()
        agentWorkspace?.cancelTermination()
        bridge.cancelHostTerminationFence()
        terminationInProgress = false
        if restoreAgent {
            let restoration = Task { @MainActor [agentUI] in await agentUI.restoreAfterCancelledHostTermination() }
            await restoration.value
        }
        return BridgeTerminationDecision(
            canTerminate: false,
            message: released ? message : String(localized: "host.exit.bridgeReleaseUnconfirmed"))
    }

    /// The window can close while the service continues. This only releases
    /// host handles; it never signals the helper.
    func shutdown() {
        bridge.detachForTermination()
        agentUI.terminateOwnedNow()
    }
}

struct BridgeTerminationDecision: Equatable, Sendable {
    var canTerminate: Bool
    var message: String?
}
