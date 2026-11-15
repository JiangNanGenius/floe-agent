// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeGameDeveloperCore

@MainActor
public final class GameDeveloperMenuModel: ObservableObject {
    public struct PendingAction: Identifiable, Equatable {
        public let action: GameDeveloperActionDescriptor
        public let arguments: [String: GameDeveloperValue]
        public var id: String { action.id }
    }

    public let session: GameDeveloperSession
    public let locale: GameDeveloperLocale
    public let strings: GameDeveloperStrings

    @Published public var searchText = ""
    @Published public var actionSheet: GameDeveloperActionDescriptor?
    @Published public var pendingConfirmation: PendingAction?
    @Published public var showResetConfirmation = false
    @Published public var screenshot: Data?
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?
    @Published public var localBusy = false

    public init(session: GameDeveloperSession,
                locale: GameDeveloperLocale = .automatic) {
        self.session = session
        self.locale = locale
        self.strings = GameDeveloperStrings(locale: locale)
    }

    /// A 1 Hz read poll must not disable a focused text field. Only a real
    /// mutation or a local menu operation marks the editable controls busy.
    public var isBusy: Bool { localBusy || session.isMutating }
    public var errorText: String? { errorMessage ?? strings.error(session.lastError) }
    public var successText: String? { statusMessage }
    public var speedField: GameDeveloperFieldDescriptor? {
        guard let field = ["engine.speed", "engine.timescale", "scene.timescale"]
            .compactMap({ session.capabilities?.field($0) })
            .first,
              !field.isReadOnly, !field.kind.isReadOnly else { return nil }
        return field
    }

    public func connect() {
        guard session.canAttach else { return }
        localBusy = true
        Task { @MainActor in
            defer { localBusy = false }
            do {
                try await session.attach()
                statusMessage = locale.isChinese ? "已连接到运行中的游戏。" : "Connected to the running game."
                errorMessage = nil
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func dismissError() {
        errorMessage = nil
        session.clearError()
    }

    public func dismissStatus() { statusMessage = nil }

    public func perform(_ action: GameDeveloperActionDescriptor) {
        if action.confirmation == .required {
            pendingConfirmation = .init(action: action, arguments: [:])
            if !action.parameters.isEmpty { actionSheet = action }
        } else if !action.parameters.isEmpty {
            actionSheet = action
        } else {
            run(action, arguments: [:])
        }
    }

    public func submit(action: GameDeveloperActionDescriptor,
                       arguments: [String: GameDeveloperValue]) {
        if action.confirmation == .required {
            pendingConfirmation = .init(action: action, arguments: arguments)
        } else {
            run(action, arguments: arguments)
        }
    }

    public func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        run(pending.action, arguments: pending.arguments)
    }

    public func cancelPendingAction() { pendingConfirmation = nil }

    private func run(_ action: GameDeveloperActionDescriptor,
                     arguments: [String: GameDeveloperValue]) {
        localBusy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                let outcome = try await session.invoke(action.id, arguments: arguments, confirmed: true)
                if outcome.status == .applied || outcome.status == .reloading {
                    session.clearError()
                    statusMessage = strings.status(outcome.status) + " · " + (locale.isChinese ? outcome.messageZhHans : outcome.message)
                } else {
                    errorMessage = strings.status(outcome.status) + " · " + (locale.isChinese ? outcome.messageZhHans : outcome.message)
                }
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func write(field: GameDeveloperFieldDescriptor, value: GameDeveloperValue) {
        guard !field.isReadOnly, !field.kind.isReadOnly else { return }
        localBusy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                _ = try await session.write([.init(id: field.id, value: value)])
                session.clearError()
                statusMessage = locale.isChinese ? "已更新。" : "Updated."
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func setSpeed(_ value: Double) {
        guard let field = speedField else { return }
        let clamped = min(max(value, field.minimum ?? 0.25), field.maximum ?? 8)
        write(field: field, value: .number(clamped))
    }

    public func createCheckpoint() {
        localBusy = true
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                _ = try await session.checkpoint()
                session.clearError()
                statusMessage = locale.isChinese ? "已创建检查点。" : "Checkpoint created."
                errorMessage = nil
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func revert(to checkpoint: GameDeveloperCheckpoint) {
        localBusy = true
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                let outcome = try await session.revert(to: checkpoint.id)
                session.clearError()
                statusMessage = locale.isChinese ? outcome.messageZhHans : outcome.message
                errorMessage = nil
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func takeScreenshot() {
        localBusy = true
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                screenshot = try await session.captureScreenshot()
                session.clearError()
                statusMessage = locale.isChinese ? "已截取游戏画面。" : "Screenshot captured."
                errorMessage = nil
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public func reset(scope: GameDeveloperResetScope) {
        showResetConfirmation = false
        localBusy = true
        statusMessage = nil
        Task { @MainActor in
            defer { localBusy = false }
            do {
                let outcome = try await session.reset(scope, confirmed: true)
                session.clearError()
                statusMessage = locale.isChinese ? outcome.messageZhHans : outcome.message
                errorMessage = nil
            } catch {
                errorMessage = strings.error(error as? GameDeveloperError) ?? error.localizedDescription
            }
        }
    }

    public var filteredFields: [GameDeveloperFieldDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return session.fields.filter { !isPageDiagnostic($0) }
        }
        return session.fields.filter {
            $0.id.lowercased().contains(query) ||
            $0.label.lowercased().contains(query) ||
            $0.labelZhHans.lowercased().contains(query) ||
            $0.group.lowercased().contains(query) ||
            $0.groupZhHans.lowercased().contains(query)
        }
    }

    public var diagnosticFields: [GameDeveloperFieldDescriptor] {
        session.fields.filter(isPageDiagnostic)
    }

    private func isPageDiagnostic(_ field: GameDeveloperFieldDescriptor) -> Bool {
        let ids: Set<String> = [
            "page.title", "page.viewport", "page.visibility", "page.readyState",
            "page.canvases", "page.webAssembly", "runtime.fps", "runtime.frames", "runtime.uptime"
        ]
        return ids.contains(field.id) && (field.isReadOnly || field.kind.isReadOnly)
    }

    public var filteredActions: [GameDeveloperActionDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return session.actions }
        return session.actions.filter {
            $0.id.lowercased().contains(query) ||
            $0.label.lowercased().contains(query) ||
            $0.labelZhHans.lowercased().contains(query) ||
            $0.group.lowercased().contains(query) ||
            $0.groupZhHans.lowercased().contains(query)
        }
    }

    public func fieldGroups(_ fields: [GameDeveloperFieldDescriptor]) -> [(name: String, fields: [GameDeveloperFieldDescriptor])] {
        var order: [String] = []
        var grouped: [String: [GameDeveloperFieldDescriptor]] = [:]
        for field in fields {
            let name = strings.fieldGroup(field)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(field)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    public func actionGroups(_ actions: [GameDeveloperActionDescriptor]) -> [(name: String, actions: [GameDeveloperActionDescriptor])] {
        var order: [String] = []
        var grouped: [String: [GameDeveloperActionDescriptor]] = [:]
        for action in actions {
            let name = strings.actionGroup(action)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(action)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    public func currentValue(_ field: GameDeveloperFieldDescriptor) -> GameDeveloperValue? {
        session.state?.values[field.id]
    }

    public func quickAction(_ id: String) -> GameDeveloperActionDescriptor? {
        session.capabilities?.action(id)
    }

    public func parse(_ text: String, field: GameDeveloperFieldDescriptor) -> GameDeveloperValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let value: GameDeveloperValue
            switch field.kind {
            case .integer:
                guard let number = Int(trimmed) else { return nil }
                value = .integer(number)
            case .number:
                guard let number = Double(trimmed), number.isFinite else { return nil }
                value = .number(number)
            case .text:
                value = .text(trimmed)
            case .choice:
                value = .text(trimmed)
            default:
                return nil
            }
            try GameDeveloperWire.validate(value: value, against: field, limits: session.limits)
            return value
        } catch {
            return nil
        }
    }

    public func parse(_ text: String, parameter: GameDeveloperActionParameterDescriptor) -> GameDeveloperValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let value: GameDeveloperValue
            switch parameter.kind {
            case .integer:
                guard let number = Int(trimmed) else { return nil }
                value = .integer(number)
            case .number:
                guard let number = Double(trimmed), number.isFinite else { return nil }
                value = .number(number)
            case .text, .choice:
                value = .text(trimmed)
            case .boolean:
                return nil
            default:
                return nil
            }
            try GameDeveloperWire.validate(value: value, against: parameter, limits: session.limits)
            return value
        } catch {
            return nil
        }
    }
}
