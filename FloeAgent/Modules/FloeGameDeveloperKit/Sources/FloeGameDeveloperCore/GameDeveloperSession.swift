// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeGameCore

public enum GameDeveloperSessionPhase: Equatable, Sendable {
    case idle
    case attaching
    case ready
    case reloading
    case failed(String)
    case detached

    public var isReady: Bool { if case .ready = self { return true }; return false }
    public var isActive: Bool {
        switch self {
        case .ready, .reloading: return true
        default: return false
        }
    }
}

/// One live development session bound to one project/root/run. Every mutation
/// creates a recoverable checkpoint first, validates the response, and applies
/// it only if the session generation still matches. No method writes project
/// files, Git state, environments or saves.
@MainActor
public final class GameDeveloperSession: ObservableObject {
    public let sessionID: UUID
    public let binding: GameDeveloperSessionBinding
    public let descriptor: GameDeveloperEngineDescriptor
    public let limits: GameDeveloperLimits

    @Published public private(set) var phase: GameDeveloperSessionPhase = .idle
    @Published public private(set) var capabilities: GameDeveloperCapabilities?
    @Published public private(set) var state: GameDeveloperRuntimeState?
    @Published public private(set) var history: [GameDeveloperHistoryEntry] = []
    @Published public private(set) var checkpoints: [GameDeveloperCheckpoint] = []
    @Published public private(set) var diagnostics = GameDeveloperDiagnostics()
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var lastScreenshot: Data?
    @Published public private(set) var lastError: GameDeveloperError?
    @Published public private(set) var snapshotLimitation: String?
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var attachment: GameDeveloperAttachReceipt?

    private let transport: any GameDeveloperTransport
    private var checkpointStore: GameDeveloperCheckpointStore
    private var generation = 0
    private var reloadTask: Task<Void, Never>?
    private var lastDiagnosticsAt: Date?
    private var lastCapabilitiesAt: Date?
    private var refreshCount = 0
    /// Bumped whenever a mutation starts. A poll that started before the
    /// mutation must not overwrite the mutation's read-back state.
    private var mutationEpoch = 0

    public init(transport: any GameDeveloperTransport,
                sessionID: UUID = UUID(),
                limits: GameDeveloperLimits = .default) throws {
        let binding = transport.binding
        _ = try GameDeveloperEngineCatalog.validated()
        let descriptor = try GameDeveloperEngineCatalog.descriptor(for: binding.engine)
        guard !binding.savedRevision.isEmpty, binding.savedRevision.utf8.count <= 256 else {
            throw GameDeveloperError.invalidConfiguration("saved revision")
        }
        self.sessionID = sessionID
        self.binding = binding
        self.descriptor = descriptor
        self.limits = limits
        self.transport = transport
        self.checkpointStore = .init(maximumCount: limits.maximumCheckpoints,
                                     maximumBytes: limits.maximumCheckpointBytes)
    }

    public var supports: GameDeveloperSupports? { capabilities?.supports }
    public var fields: [GameDeveloperFieldDescriptor] { capabilities?.fields ?? [] }
    public var actions: [GameDeveloperActionDescriptor] { capabilities?.actions ?? [] }
    public var baselineCheckpoint: GameDeveloperCheckpoint? { checkpointStore.baseline }
    public var canAttach: Bool {
        switch phase {
        case .idle, .detached, .failed: return true
        default: return false
        }
    }

    // MARK: - Attach / refresh

    public func attach() async throws {
        guard canAttach else { throw GameDeveloperError.alreadyAttached }
        generation += 1
        let token = generation
        phase = .attaching
        lastError = nil
        snapshotLimitation = nil
        do {
            let receipt = try await transport.attach()
            try fence(token)
            guard receipt.binding == binding else {
                throw GameDeveloperError.contextMismatch("attach receipt belongs to another run")
            }
            guard receipt.bridgeToken != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
                throw GameDeveloperError.bridgeUnavailable("empty bridge token")
            }
            attachment = receipt
            let caps = try await loadCapabilities(token: token)
            guard caps.engine == descriptor.engine else {
                throw GameDeveloperError.contextMismatch("probe engine mismatch")
            }
            try fence(token)
            capabilities = caps
            diagnostics = caps.diagnostics
            lastCapabilitiesAt = Date()
            let current = try await loadState(token: token, capabilities: caps)
            try fence(token)
            state = current
            lastUpdated = Date()
            try await captureCheckpoint(kind: .baseline,
                                        label: "Session baseline", labelZhHans: "会话基线",
                                        token: token, requireSnapshot: false)
            try fence(token)
            phase = .ready
        } catch {
            let mappedError = mapped(error)
            if token == generation {
                phase = .failed(mappedError.localizedDescription)
                lastError = mappedError
            }
            throw mappedError
        }
    }

    /// Polls live state without taking over a mutation. A stale page response is
    /// discarded instead of being applied to the next run.
    public func refresh() async {
        guard phase.isActive, !isRefreshing, !isMutating, let caps = capabilities else { return }
        let token = generation
        let epoch = mutationEpoch
        isRefreshing = true
        defer { if token == generation { isRefreshing = false } }
        do {
            // Hooks/project bridges may register after the initial attach
            // (MV globals, built-engine push bridges). Re-probe periodically
            // so a late registration becomes usable without reopening the menu.
            if lastCapabilitiesAt.map({ Date().timeIntervalSince($0) > 5 }) ?? true {
                try? await refreshCapabilities()
            }
            let activeCaps = capabilities ?? caps
            let next: GameDeveloperRuntimeState
            do {
                next = try await loadState(token: token, capabilities: activeCaps)
            } catch let error as GameDeveloperError {
                guard case .invalidRequest = error else { throw error }
                try await refreshCapabilities()
                try fence(token)
                let updated = capabilities ?? activeCaps
                next = try await loadState(token: token, capabilities: updated)
            }
            try fence(token)
            guard mutationEpoch == epoch, !isMutating else { return }
            state = next
            lastUpdated = Date()
            refreshCount += 1
            if lastDiagnosticsAt.map({ Date().timeIntervalSince($0) > 2 }) ?? true {
                await refreshDiagnostics(token: token)
            }
            logs = Array(transport.logs().suffix(limits.maximumLogEntries))
            if phase == .reloading { phase = .ready }
            lastError = nil
        } catch let error as GameDeveloperError {
            if case .staleSession = error { return }
            if phase == .reloading { return }
            lastError = error
        } catch {
            if phase == .reloading { return }
            lastError = mapped(error)
        }
    }

    public func refreshCapabilities() async throws {
        guard phase.isActive else { throw GameDeveloperError.notAttached }
        let token = generation
        let next = try await loadCapabilities(token: token)
        try fence(token)
        if next != capabilities {
            capabilities = next
            diagnostics = next.diagnostics
        }
        lastCapabilitiesAt = Date()
    }

    public func refreshDiagnostics() async {
        guard phase.isActive else { return }
        await refreshDiagnostics(token: generation)
    }

    private func refreshDiagnostics(token: Int) async {
        let epoch = mutationEpoch
        do {
            let value = try await exchange(.diagnostics, payload: GameDeveloperWire.emptyPayload(), token: token)
            try fence(token)
            guard mutationEpoch == epoch, !isMutating else { return }
            let next = try GameDeveloperWire.decodeDiagnostics(value, limits: limits)
            diagnostics = next
            lastDiagnosticsAt = Date()
        } catch let error as GameDeveloperError {
            if case .staleSession = error { return }
            lastError = error
        } catch {
            lastError = mapped(error)
        }
    }

    // MARK: - Field writes

    @discardableResult
    public func write(_ changes: [GameDeveloperFieldChange]) async throws -> GameDeveloperActionOutcome {
        guard phase.isReady, let caps = capabilities else { throw GameDeveloperError.notAttached }
        guard !isMutating else { throw GameDeveloperError.busy }
        guard !changes.isEmpty, changes.count <= limits.maximumChangesPerRequest else {
            throw GameDeveloperError.invalidRequest("change count")
        }
        var seen = Set<String>()
        for change in changes {
            guard seen.insert(change.id).inserted else {
                throw GameDeveloperError.invalidRequest("duplicate field \(change.id)")
            }
            guard let field = caps.field(change.id) else {
                throw GameDeveloperError.invalidField("unknown field \(change.id)")
            }
            guard !field.isReadOnly, !field.kind.isReadOnly else {
                throw GameDeveloperError.invalidField("\(change.id) is read-only")
            }
            try GameDeveloperWire.validate(value: change.value, against: field, limits: limits)
        }
        let token = generation
        mutationEpoch &+= 1
        isMutating = true
        defer { if token == generation { isMutating = false } }
        let checkpoint = try await captureCheckpoint(
            kind: .beforeFieldWrite, label: "Before field update", labelZhHans: "字段修改前",
            token: token, requireSnapshot: false)
        do {
            let payload = try GameDeveloperWire.encodeChanges(changes, limits: limits)
            let value = try await exchange(.write, payload: payload, token: token)
            try fence(token)
            let outcome = try GameDeveloperWire.decodeOutcome(
                value, expectedActionID: "fields.write", capabilities: caps, limits: limits)
            if let next = outcome.state { state = next }
            lastUpdated = Date()
            record(outcome: outcome, label: "Update fields", labelZhHans: "修改字段",
                   checkpointID: checkpoint?.id)
            if outcome.status == .rejected {
                throw GameDeveloperError.transport(outcome.message.isEmpty ? "field write rejected" : outcome.message)
            }
            return outcome
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    // MARK: - Actions

    @discardableResult
    public func invoke(_ actionID: String, arguments: [String: GameDeveloperValue] = [:],
                       confirmed: Bool = false) async throws -> GameDeveloperActionOutcome {
        guard phase.isReady, let caps = capabilities else { throw GameDeveloperError.notAttached }
        guard !isMutating else { throw GameDeveloperError.busy }
        guard let action = caps.action(actionID) else {
            throw GameDeveloperError.invalidAction(actionID)
        }
        var resolved = arguments
        for parameter in action.parameters {
            if let value = resolved[parameter.id] {
                try GameDeveloperWire.validate(value: value, against: parameter, limits: limits)
            } else if let defaultValue = parameter.defaultValue {
                resolved[parameter.id] = defaultValue
            } else if parameter.isRequired {
                throw GameDeveloperError.invalidAction("missing parameter \(parameter.id)")
            }
        }
        guard Set(resolved.keys).isSubset(of: Set(action.parameters.map(\.id))) else {
            throw GameDeveloperError.invalidAction("unknown parameter")
        }
        if action.confirmation == .required, !confirmed {
            throw GameDeveloperError.confirmationRequired(action.label)
        }
        let token = generation
        mutationEpoch &+= 1
        isMutating = true
        defer { if token == generation { isMutating = false } }
        let needsSnapshot = action.role == .destructive || action.confirmation == .required
        let checkpoint = try await captureCheckpoint(
            kind: .beforeAction,
            label: "Before \(action.label)", labelZhHans: "执行前：\(action.labelZhHans)",
            token: token, requireSnapshot: needsSnapshot)
        do {
            let payload = try GameDeveloperWire.encodeInvoke(
                actionID: actionID, arguments: resolved, limits: limits)
            let value = try await exchange(.invoke, payload: payload, token: token)
            try fence(token)
            let outcome = try GameDeveloperWire.decodeOutcome(
                value, expectedActionID: actionID, capabilities: caps, limits: limits)
            if let next = outcome.state { state = next }
            lastUpdated = Date()
            record(outcome: outcome, label: action.label, labelZhHans: action.labelZhHans,
                   checkpointID: checkpoint?.id)
            if outcome.status == .reloading {
                phase = .reloading
                await waitForReload(token: token)
            }
            if outcome.status == .rejected || outcome.status == .unsupported {
                throw GameDeveloperError.transport(outcome.message.isEmpty ? "action rejected" : outcome.message)
            }
            return outcome
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    // MARK: - Checkpoints and snapshots

    @discardableResult
    public func checkpoint(label: String? = nil) async throws -> GameDeveloperCheckpoint {
        guard phase.isReady else { throw GameDeveloperError.notAttached }
        let token = generation
        let checkpoint = try await captureCheckpoint(
            kind: .manual,
            label: label ?? "Manual checkpoint",
            labelZhHans: label == nil ? "手动检查点" : (label ?? "手动检查点"),
            token: token, requireSnapshot: false)
        guard let checkpoint else {
            throw GameDeveloperError.checkpointUnavailable("no live state")
        }
        return checkpoint
    }

    public func snapshot() async throws -> GameDeveloperSnapshot {
        guard phase.isReady, let caps = capabilities, caps.supports.snapshot else {
            throw GameDeveloperError.snapshotUnavailable("this engine has no game debug snapshot hook")
        }
        let token = generation
        let value = try await exchange(.snapshot, payload: GameDeveloperWire.emptyPayload(), token: token)
        try fence(token)
        let data = try GameDeveloperWire.decodeSnapshot(
            value, expectedEngine: binding.engine, limits: limits)
        return GameDeveloperSnapshot(engine: binding.engine, data: data)
    }

    public func restore(_ snapshot: GameDeveloperSnapshot,
                        confirmed: Bool = false) async throws -> GameDeveloperActionOutcome {
        guard phase.isReady, let caps = capabilities else { throw GameDeveloperError.notAttached }
        guard snapshot.engine == binding.engine else {
            throw GameDeveloperError.contextMismatch("snapshot engine")
        }
        guard !isMutating else { throw GameDeveloperError.busy }
        guard caps.supports.restore else {
            throw GameDeveloperError.snapshotUnavailable("this engine has no restore hook")
        }
        if !confirmed {
            throw GameDeveloperError.confirmationRequired("restore replaces the current live state")
        }
        let token = generation
        mutationEpoch &+= 1
        isMutating = true
        defer { if token == generation { isMutating = false } }
        let checkpoint = try await captureCheckpoint(
            kind: .beforeRestore, label: "Before restore", labelZhHans: "恢复前",
            token: token, requireSnapshot: false)
        do {
            let payload = try GameDeveloperWire.encodeRestore(
                snapshot: snapshot.data, expectedEngine: binding.engine, limits: limits)
            let value = try await exchange(.restore, payload: payload, token: token)
            try fence(token)
            if let next = try GameDeveloperWire.decodeRestore(value, capabilities: caps, limits: limits) {
                state = next
            } else {
                let next = try await loadState(token: token, capabilities: caps)
                try fence(token)
                state = next
            }
            lastUpdated = Date()
            let outcome = GameDeveloperActionOutcome(
                actionID: "session.restore", status: .applied,
                message: "Restored the selected snapshot.", messageZhHans: "已恢复所选快照。",
                state: state)
            record(outcome: outcome, label: "Restore snapshot", labelZhHans: "恢复快照",
                   checkpointID: checkpoint?.id)
            return outcome
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    @discardableResult
    public func revert(to checkpointID: UUID) async throws -> GameDeveloperActionOutcome {
        guard phase.isReady, let caps = capabilities else { throw GameDeveloperError.notAttached }
        guard !isMutating else { throw GameDeveloperError.busy }
        guard let checkpoint = checkpointStore.checkpoint(checkpointID) else {
            throw GameDeveloperError.checkpointMissing(checkpointID)
        }
        let token = generation
        mutationEpoch &+= 1
        isMutating = true
        defer { if token == generation { isMutating = false } }
        if let snapshot = checkpoint.snapshot {
            do {
                let payload = try GameDeveloperWire.encodeRestore(
                    snapshot: snapshot, expectedEngine: binding.engine, limits: limits)
                let value = try await exchange(.restore, payload: payload, token: token)
                try fence(token)
                if let next = try GameDeveloperWire.decodeRestore(value, capabilities: caps, limits: limits) {
                    state = next
                } else {
                    let next = try await loadState(token: token, capabilities: caps)
                    try fence(token)
                    state = next
                }
                let outcome = GameDeveloperActionOutcome(
                    actionID: "session.revert", status: .applied,
                    message: "Reverted to \(checkpoint.label).",
                    messageZhHans: "已恢复到\(checkpoint.labelZhHans)。",
                    changedFieldIDs: Array(checkpoint.fieldValues.keys), state: state)
                record(outcome: outcome, label: "Revert", labelZhHans: "恢复检查点",
                       checkpointID: checkpoint.id)
                return outcome
            } catch {
                let mappedError = mapped(error)
                lastError = mappedError
                throw mappedError
            }
        }
        // Field-only checkpoint: only the fields captured at that time are
        // restored; the UI labels this limitation.
        var changes: [GameDeveloperFieldChange] = []
        for (id, value) in checkpoint.fieldValues.sorted(by: { $0.key < $1.key }) {
            guard let field = caps.field(id), !field.isReadOnly, !field.kind.isReadOnly else { continue }
            try GameDeveloperWire.validate(value: value, against: field, limits: limits)
            changes.append(.init(id: id, value: value))
        }
        guard !changes.isEmpty else {
            throw GameDeveloperError.checkpointUnavailable("the checkpoint has no restorable fields")
        }
        do {
            let payload = try GameDeveloperWire.encodeChanges(changes, limits: limits)
            let value = try await exchange(.write, payload: payload, token: token)
            try fence(token)
            let outcome = try GameDeveloperWire.decodeOutcome(
                value, expectedActionID: "fields.write", capabilities: caps, limits: limits)
            if let next = outcome.state { state = next }
            if outcome.status == .rejected || outcome.status == .unsupported {
                throw GameDeveloperError.transport(outcome.message.isEmpty ? "field revert rejected" : outcome.message)
            }
            let restored = GameDeveloperActionOutcome(
                actionID: "session.revert", status: outcome.status,
                message: "Reverted \(changes.count) field(s); this checkpoint has no game debug snapshot.",
                messageZhHans: "已恢复 \(changes.count) 个字段；该检查点没有游戏调试快照。",
                changedFieldIDs: changes.map(\.id), state: state)
            record(outcome: restored, label: "Revert fields", labelZhHans: "恢复字段",
                   checkpointID: checkpoint.id)
            return restored
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    @discardableResult
    public func reset(_ scope: GameDeveloperResetScope, confirmed: Bool) async throws -> GameDeveloperActionOutcome {
        guard phase.isReady, capabilities != nil else { throw GameDeveloperError.notAttached }
        guard confirmed else {
            throw GameDeveloperError.confirmationRequired("reset discards unsaved live state")
        }
        switch scope {
        case .baseline:
            guard let baseline = checkpointStore.baseline else {
                throw GameDeveloperError.snapshotUnavailable("no baseline checkpoint")
            }
            return try await revert(to: baseline.id)
        case .checkpoint(let id):
            return try await revert(to: id)
        case .restart, .reload:
            break
        }
        guard !isMutating else { throw GameDeveloperError.busy }
        let token = generation
        mutationEpoch &+= 1
        isMutating = true
        defer { if token == generation { isMutating = false } }
        _ = try? await captureCheckpoint(kind: .beforeAction,
                                         label: "Before reset", labelZhHans: "重置前",
                                         token: token, requireSnapshot: false)
        do {
            let mode = scope == .restart ? "restart" : "reload"
            let payload = try GameDeveloperWire.encodeReset(mode: mode, limits: limits)
            let value = try await exchange(.reset, payload: payload, token: token)
            try fence(token)
            let result = try GameDeveloperWire.decodeReset(value, limits: limits)
            let outcome = GameDeveloperActionOutcome(
                actionID: "session.reset", status: result.status == "applied" ? .applied : .reloading,
                message: result.message ?? "The game is restarting from its boot state.",
                messageZhHans: result.messageZhHans ?? "游戏正在从启动状态重新开始。",
                state: state)
            record(outcome: outcome, label: "Reset", labelZhHans: "重置",
                   checkpointID: baselineCheckpoint?.id)
            if outcome.status == .reloading {
                phase = .reloading
                lastError = nil
                await waitForReload(token: token)
            }
            return outcome
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    // MARK: - Screenshot, history, detach

    @discardableResult
    public func captureScreenshot() async throws -> Data {
        guard phase.isReady else { throw GameDeveloperError.notAttached }
        let token = generation
        do {
            let bytes = try await transport.captureScreenshot()
            try fence(token)
            guard !bytes.isEmpty, bytes.count <= 32 * 1_024 * 1_024 else {
                throw GameDeveloperError.payloadTooLarge("screenshot")
            }
            lastScreenshot = bytes
            return bytes
        } catch {
            let mappedError = mapped(error)
            lastError = mappedError
            throw mappedError
        }
    }

    public func clearError() { lastError = nil }
    public func clearHistory() { history.removeAll() }

    public func detach() {
        generation += 1
        reloadTask?.cancel()
        reloadTask = nil
        transport.detach()
        phase = .detached
        capabilities = nil
        state = nil
        diagnostics = GameDeveloperDiagnostics()
        logs = []
        lastScreenshot = nil
        attachment = nil
        lastError = nil
        lastUpdated = nil
        isRefreshing = false
        isMutating = false
        checkpointStore.removeAll()
        checkpoints = []
    }

    // MARK: - Internals

    private func loadCapabilities(token: Int) async throws -> GameDeveloperCapabilities {
        let value = try await exchange(.probe, payload: GameDeveloperWire.emptyPayload(), token: token)
        try fence(token)
        return try GameDeveloperWire.decodeCapabilities(
            value, expectedEngine: binding.engine, limits: limits)
    }

    private func loadState(token: Int, capabilities: GameDeveloperCapabilities) async throws -> GameDeveloperRuntimeState {
        let value = try await exchange(.read, payload: GameDeveloperWire.emptyPayload(), token: token)
        try fence(token)
        return try GameDeveloperWire.decodeState(value, capabilities: capabilities, limits: limits)
    }

    private func exchange(_ operation: GameDeveloperOperation, payload: Data,
                          token: Int) async throws -> Data {
        try fence(token)
        let requestID = UUID()
        let request = GameDeveloperTransportRequest(
            sessionID: sessionID, requestID: requestID,
            operation: operation, payload: payload)
        let response = try await transport.exchange(request)
        try fence(token)
        guard response.sessionID == sessionID,
              response.requestID == requestID,
              response.engine == binding.engine else {
            throw GameDeveloperError.staleSession
        }
        guard response.value.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("bridge response")
        }
        return response.value
    }

    private func fence(_ token: Int) throws {
        guard token == generation else { throw GameDeveloperError.staleSession }
    }

    @discardableResult
    private func captureCheckpoint(kind: GameDeveloperCheckpointKind,
                                   label: String, labelZhHans: String,
                                   token: Int, requireSnapshot: Bool) async throws -> GameDeveloperCheckpoint? {
        guard let current = state else {
            if requireSnapshot { throw GameDeveloperError.checkpointUnavailable("no live state") }
            return nil
        }
        var snapshot: Data?
        var reason: String?
        if capabilities?.supports.snapshot == true {
            do {
                let value = try await exchange(.snapshot, payload: GameDeveloperWire.emptyPayload(), token: token)
                try fence(token)
                snapshot = try GameDeveloperWire.decodeSnapshot(
                    value, expectedEngine: binding.engine, limits: limits)
                snapshotLimitation = nil
            } catch {
                let mappedError = mapped(error)
                reason = mappedError.localizedDescription
                if requireSnapshot {
                    throw GameDeveloperError.checkpointUnavailable(reason ?? "snapshot failed")
                }
            }
        } else if requireSnapshot {
            throw GameDeveloperError.checkpointUnavailable("this engine has no game debug snapshot hook")
        }
        if snapshot == nil, reason != nil {
            snapshotLimitation = reason
        }
        let byteCount = (snapshot?.count ?? 0) + current.values.reduce(0) { partial, item in
            partial + item.key.utf8.count + item.value.displayText.utf8.count + 8
        }
        guard byteCount <= limits.maximumCheckpointBytes else {
            if requireSnapshot {
                throw GameDeveloperError.checkpointUnavailable("checkpoint exceeds the byte limit")
            }
            return nil
        }
        let checkpoint = GameDeveloperCheckpoint(
            kind: kind, label: label, labelZhHans: labelZhHans,
            engine: binding.engine, snapshot: snapshot,
            fieldValues: current.values, byteCount: byteCount)
        checkpointStore.insert(checkpoint)
        checkpoints = checkpointStore.checkpoints
        return checkpoint
    }

    private func waitForReload(token: Int) async {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.generation == token, self.phase == .reloading else { return }
                do {
                    let caps = try await self.loadCapabilities(token: token)
                    guard self.generation == token else { return }
                    let next = try await self.loadState(token: token, capabilities: caps)
                    guard self.generation == token else { return }
                    self.capabilities = caps
                    self.state = next
                    self.diagnostics = caps.diagnostics
                    self.lastUpdated = Date()
                    self.lastError = nil
                    self.phase = .ready
                    self.logs = Array(self.transport.logs().suffix(self.limits.maximumLogEntries))
                    return
                } catch {
                    continue
                }
            }
            guard self.generation == token, self.phase == .reloading else { return }
            self.phase = .failed("The game did not report a new bridge after the reset.")
            self.lastError = .bridgeUnavailable("no bridge after reset")
        }
    }

    private func record(outcome: GameDeveloperActionOutcome,
                        label: String, labelZhHans: String,
                        checkpointID: UUID?) {
        let entry = GameDeveloperHistoryEntry(
            actionID: outcome.actionID, label: label, labelZhHans: labelZhHans,
            status: outcome.status, message: outcome.message,
            messageZhHans: outcome.messageZhHans, at: outcome.at,
            checkpointID: checkpointID)
        history.insert(entry, at: 0)
        if history.count > limits.maximumHistoryEntries {
            history.removeLast(history.count - limits.maximumHistoryEntries)
        }
    }

    private func mapped(_ error: Error) -> GameDeveloperError {
        if let error = error as? GameDeveloperError { return error }
        let text = String(describing: error)
        return .transport(String(text.prefix(1_024)))
    }
}
