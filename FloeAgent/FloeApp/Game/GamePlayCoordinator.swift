// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeCore
import FloeGameAppIntegration
import FloeGameCore
import FloeGameIDEBridge
import FloeGameWebKit
import FloeGameTouch
import FloeGameRGSS
import FloeGameRGSSHostCore

/// Owns one project's active play interaction. It never creates a second
/// player: Web uses the existing `GameProjectWebRunPresentation` and legacy
/// RGSS uses the existing `RGSSGuestPlaySession`. The registry's `stopPlay`
/// coalesces stops per request and retains an unconfirmed RGSS session.
@MainActor @Observable
final class GamePlayCoordinator {
    let session: GameWorkspaceSession
    private unowned let registry: GameWorkspaceRegistry
    private(set) var starting = false
    private(set) var lastError: String?
    private(set) var rgssPresentation: GameProjectRGSSRunPresentation?

    init(session: GameWorkspaceSession, registry: GameWorkspaceRegistry) {
        self.session = session
        self.registry = registry
    }

    var webPresentation: GameProjectWebRunPresentation? { session.webPresentation }
    var rgssPlay: RGSSGuestPlaySession? { session.rgssPlay }
    var activeRequestID: UUID? { session.lastLaunchRequest?.id }

    var isRunning: Bool {
        session.rgssPlay != nil || session.webPresentation != nil
    }

    var phaseText: String {
        if let web = session.webPresentation {
            switch web.controller.phase {
            case .idle: return "idle"
            case .preparing: return "preparing"
            case .running: return "running"
            case .stopping: return "stopping"
            case .failed(let message): return "failed: " + message
            }
        }
        if let play = session.rgssPlay {
            return String(describing: play.phase)
        }
        return "idle"
    }

    /// Launches through the same IDE extension used by the toolbar. The
    /// registry's launch callback captures the exact request ID and creates
    /// the Web presentation or RGSS play session.
    @discardableResult
    func start() async throws -> GameRunReceipt {
        guard !session.closed, !session.closing else {
            throw GameWorkspaceRegistryError.workStopUnconfirmed(session.closeFailure ?? "")
        }
        guard !starting else { throw GameWorkspaceRegistryError.editorBusy }
        starting = true
        defer { starting = false }
        lastError = nil
        let extensionValue = try await registry.makeRunExtension(for: session)
        do {
            try await extensionValue.run { true }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        guard let request = session.lastLaunchRequest else {
            throw GameWorkspaceRegistryError.noSavedRun
        }
        if let play = session.rgssPlay {
            return GameRunReceipt(projectID: request.context.projectID, runID: request.id,
                action: "run", phase: String(describing: play.phase), stopConfirmed: nil,
                automaticSave: nil, screenshotSHA256: nil, logs: nil, diagnostic: play.lastError)
        }
        if let presentation = session.webPresentation {
            return GameRunReceipt(projectID: request.context.projectID, runID: request.id,
                action: "run", phase: phaseText, stopConfirmed: nil,
                automaticSave: nil, screenshotSHA256: nil, logs: nil,
                diagnostic: presentation.inputDiagnostic)
        }
        throw GameWorkspaceRegistryError.noSavedRun
    }

    @discardableResult
    func stop() async -> GameRunReceipt {
        let requestID = session.lastLaunchRequest?.id
        guard isRunning || requestID != nil else {
            return GameRunReceipt(projectID: session.key.projectID, runID: nil,
                action: "stop", phase: "idle", stopConfirmed: nil,
                automaticSave: nil, screenshotSHA256: nil, logs: nil,
                diagnostic: "No game run was active.")
        }
        await rgssPresentation?.prepareForStop()
        await registry.stopPlay(session, requestID: requestID)
        return session.lastStopReceipt ?? GameRunReceipt(
            projectID: session.key.projectID, runID: requestID, action: "stop",
            phase: "idle", stopConfirmed: nil, automaticSave: nil,
            screenshotSHA256: nil, logs: nil, diagnostic: "The run service returned no stop receipt.")
    }

    func prepareRGSSControls() async throws -> GameProjectRGSSRunPresentation {
        guard let play = session.rgssPlay else { throw GameWorkspaceRegistryError.noSavedRun }
        if let existing = rgssPresentation, existing.play === play,
           existing.jobID == play.session?.jobID, !existing.inputFailed { return existing }
        await rgssPresentation?.prepareForStop()
        let value = try await GameProjectRGSSRunPresentation.make(play: play, support: session.support)
        rgssPresentation = value
        return value
    }

    /// Finite AI/test pulses share the Touch service's reference-counted key
    /// ledger. Cancellation releases this source, preserving user-held keys.
    func sendChord(_ keys: [GameKeyboardKey], durationMilliseconds: Int = 80) async throws {
        guard !keys.isEmpty else { throw GameToolContractError.invalidChord }
        let ordered = GameKeyboardKey.orderedChord(keys)
        try await pulse(GameTouchBinding(chord: try GameTouchChord(keys: ordered)),
                        durationMilliseconds: durationMilliseconds)
    }

    func sendButton(_ id: String) async throws {
        let profile = try await currentInputProfile()
        let aliases: [String: String] = ["confirm": "rpg.confirm", "cancel": "rpg.cancel",
            "action1": "rpg.dash", "action2": "rpg.pageUp", "action3": "rpg.pageDown"]
        let names = [id, aliases[id]].compactMap { $0 }
        if let button = profile.buttons.first(where: { names.contains($0.id.rawValue) }) {
            try await pulse(button.binding)
        } else if let keys = session.rgssPlay?.keymap?.chord(forButtonID: id) {
            try await sendChord(keys)
        } else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "控件不存在。请使用当前控件 ID 或指定键盘按键。",
                "This control is unavailable. Use its current ID or explicit keyboard keys."))
        }
    }

    func sendAction(_ name: String) async throws {
        let profile = try await currentInputProfile()
        if let action = GameTouchAction(rawValue: name), action.isDirection,
           let binding = profile.directionBinding(for: action) {
            try await pulse(GameTouchBinding(chord: binding))
        } else { try await sendButton(name) }
    }

    private func currentInputProfile() async throws -> GameTouchProfile {
        if session.rgssPlay != nil {
            let presentation = try await prepareRGSSControls()
            return presentation.input.profile
        }
        guard let web = session.webPresentation else { throw GameWorkspaceRegistryError.noSavedRun }
        return web.input.profile
    }

    private func pulse(_ binding: GameTouchBinding, durationMilliseconds: Int = 80) async throws {
        if session.rgssPlay != nil {
            let presentation = try await prepareRGSSControls()
            try await presentation.pulse(binding, durationMilliseconds: durationMilliseconds)
        } else if let web = session.webPresentation {
            try await web.pulse(binding, durationMilliseconds: durationMilliseconds)
        } else { throw GameWorkspaceRegistryError.noSavedRun }
    }

    func screenshot() async throws -> Data {
        if let play = session.rgssPlay {
            guard let data = try await play.captureScreenshot() else {
                throw RGSSGuestRunError.displayUnavailable("no screenshot is available")
            }
            return data
        }
        guard let presentation = session.webPresentation else { throw GameWorkspaceRegistryError.noSavedRun }
        return try await presentation.player.capturePNG()
    }

    func logs() async throws -> String {
        if let presentation = session.webPresentation {
            let rows = presentation.player.logs.suffix(200)
            return rows.joined(separator: "\n")
        }
        if let play = session.rgssPlay ?? rgssPresentation?.play, let staged = play.staged {
            let captured = play.request.id
            let jobID = play.session?.jobID
            let text = try await Task.detached(priority: .utility) {
                try RGSSGuestLogReader.tail(of: staged.logFile)
            }.value
            let current = session.rgssPlay ?? rgssPresentation?.play
            guard current?.request.id == captured, current?.session?.jobID == jobID else {
                throw RGSSGuestRunError.staleSession
            }
            return text
        }
        return ""
    }

    /// Detach only the display/client; the guest job keeps running.
    func detachViewer() async {
        rgssPresentation?.requestInputEnabled(false)
        await rgssPresentation?.input.detach()
        await session.rgssPlay?.detachView()
    }

    func reattachViewer() async throws {
        try await session.rgssPlay?.reattachDisplay()
    }

    /// Retains the actual save outcome; the stop path already did the automatic
    /// save. This is used by the tool's explicit save action while running.
    func saveSnapshot() async throws -> String {
        if let presentation = session.webPresentation {
            let result = await presentation.saves.saveAutomaticIfSupported()
            switch result {
            case .saved(let slot): return "saved:" + slot.title
            case .unchanged(let slot): return "unchanged:" + slot.title
            case .disabled: return "disabled"
            case .notRunning: return "notRunning"
            case .unsupported: return "unsupported"
            case .busy: return "busy"
            case .invalidated: return "invalidated"
            case .failed(let error): return "failed:" + String(describing: error)
            }
        }
        if let play = session.rgssPlay, let saves = play.saveManager {
            guard play.phase == .stopped else {
                throw FloeError.validationFailed(IDELanguageRunText.t(
                    "请先在游戏内保存，再停止运行收集存档。当前运行不支持通用即时存档。",
                    "Save inside the game, then stop to collect the files. A universal live snapshot is unavailable for this run."))
            }
            guard try await saves.checkpoint() != nil else { return "unsupported" }
            return "checkpoint"
        }
        throw GameWorkspaceRegistryError.noSavedRun
    }
}

extension GameKeyboardKey {
    static func fromToolName(_ value: String) -> GameKeyboardKey? {
        let alias: [String: GameKeyboardKey] = [
            "esc": .escape, "return": .enter, "ctrl": .control,
            "cmd": .meta, "command": .meta, "opt": .alt, "option": .alt,
            "del": .delete, "pgup": .pageUp, "pgdn": .pageDown,
            "spacebar": .space, "": .space
        ]
        if let direct = GameKeyboardKey(rawValue: value) { return direct }
        return alias[value.lowercased()]
    }

    /// Modifiers first, remaining keys in stable input order, duplicates
    /// removed. A chord is pressed together; it is not a list of alternatives.
    static func orderedChord(_ keys: [GameKeyboardKey]) -> [GameKeyboardKey] {
        var seen = Set<GameKeyboardKey>()
        return keys.filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.modifierOrder == rhs.modifierOrder
                    ? lhs.rawValue < rhs.rawValue
                    : lhs.modifierOrder < rhs.modifierOrder
            }
    }
}
#endif
