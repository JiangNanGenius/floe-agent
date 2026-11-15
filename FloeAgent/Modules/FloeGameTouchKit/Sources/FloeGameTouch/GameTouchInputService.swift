// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeGameCore
import FloeGameWebKit

@MainActor public protocol GameTouchInputSink: AnyObject {
    func set(_ binding: GameTouchBinding, pressed: Bool) async throws
}

extension GameWebPlayer: GameTouchInputSink {
    public func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        switch binding {
        case .key(let value):
            try await key(value, pressed: pressed)
        case .chord(let chord):
            // The service atomizes chords into physical key events. This path
            // keeps the sink safe for external callers too: modifiers go down
            // first and come up last.
            let keys: [GameKeyboardKey] = pressed ? chord.keys : Array(chord.keys.reversed())
            var sent: [GameKeyboardKey] = []
            do {
                for key in keys {
                    try await self.key(key, pressed: pressed)
                    sent.append(key)
                }
            } catch {
                if pressed {
                    for key in sent.reversed() { try? await self.key(key, pressed: false) }
                }
                throw error
            }
        case .action(let value):
            if let direction = GameInputDirection(rawValue: value.rawValue) {
                try await input(direction, pressed: pressed)
            } else if let button = GameInputButton(rawValue: value.rawValue) {
                try await input(button, pressed: pressed)
            } else {
                throw GameWebPlayerError.unsupportedOperation
            }
        }
    }
}

public enum GameTouchPulseError: Error, Equatable, Sendable {
    case unavailable
    case invalidDuration
    case tooManyRequests
    case staleAttachment
    case deliveryFailed(String)
}

/// One bounded input queue, independent of View lifetime. Bindings are
/// flattened to physical keys; reference counting is by physical key, so two
/// overlapping chords (Ctrl+Z and Ctrl+X) or a separate held Ctrl cannot
/// release each other's modifier. Switching profile/player releases every held
/// input, including service-owned tap/toggle state.
@MainActor public final class GameTouchInputService: ObservableObject {
    @Published public private(set) var profile: GameTouchProfile
    @Published public private(set) var lastError: String?
    @Published public private(set) var isAttached = false
    @Published public private(set) var attachmentID: UUID?
    /// Buttons currently held, pulsing (tap), or latched (toggle). Useful for
    /// sticky visual feedback; the App does not need to mirror timers.
    @Published public private(set) var activeButtonIDs: Set<GameTouchButton.ID> = []

    private weak var sink: (any GameTouchInputSink)?
    private var sources: [String: Set<GameTouchBinding>] = [:]
    private var deliveredKeys: Set<GameKeyboardKey> = []
    private var deliveredActions: Set<GameTouchAction> = []
    private var draining: Task<Void, Never>?
    private var pulseTasks: [GameTouchButton.ID: Task<Void, Never>] = [:]
    private var pulseTokens: [GameTouchButton.ID: UUID] = [:]
    private var externalPulses: [UUID: Task<Void, Error>] = [:]
    private var generation = 0
    private var transition = 0
    private var transitioning = false

    public init(profile: GameTouchProfile) { self.profile = profile }

    public func attach(_ sink: any GameTouchInputSink) async {
        transition += 1
        let token = transition
        transitioning = true
        await releaseAll()
        guard token == transition else { return }
        generation += 1
        self.sink = sink
        attachmentID = UUID()
        isAttached = true
        lastError = nil
        transitioning = false
    }

    public func detach() async {
        transition += 1
        let token = transition
        transitioning = true
        await releaseAll()
        guard token == transition else { return }
        generation += 1
        sink = nil
        attachmentID = nil
        isAttached = false
        transitioning = false
    }

    public func updateProfile(_ value: GameTouchProfile) async {
        transition += 1
        let token = transition
        transitioning = true
        await releaseAll()
        guard token == transition else { return }
        // Old releases are fully drained. Fence every callback that captured
        // the previous profile/attachment and publish a fresh token before the
        // remapped controls can accept input.
        generation += 1
        profile = value
        if isAttached { attachmentID = UUID() }
        transitioning = false
    }

    public func stick(x: Double, y: Double, forAttachment id: UUID? = nil) {
        if let id, id != attachmentID { return }
        guard !transitioning, profile.enabled, profile.stick != .none else { return }
        guard x.isFinite, y.isFinite else {
            sources["stick"] = []
            refreshActiveButtons()
            schedule()
            return
        }
        let length = hypot(x, y)
        var pressed: Set<GameTouchBinding> = []
        if length >= profile.deadZone {
            let nx = x / length
            let ny = y / length
            if nx < -0.35 { insert(.left, into: &pressed) }
            if nx > 0.35 { insert(.right, into: &pressed) }
            if ny > 0.35 { insert(.up, into: &pressed) }
            if ny < -0.35 { insert(.down, into: &pressed) }
        }
        sources["stick"] = pressed
        schedule()
    }

    public func button(_ id: GameTouchButton.ID, pressed: Bool, forAttachment attachment: UUID? = nil) {
        if let attachment, attachment != attachmentID { return }
        guard !transitioning, profile.enabled,
              let button = profile.buttons.first(where: { $0.id == id && $0.visible }) else { return }
        let source = Self.sourceKey(id)
        switch button.mode {
        case .hold:
            sources[source] = pressed ? Set([button.binding]) : []
            refreshActiveButtons()
            schedule()
        case .toggle:
            guard pressed else { return }
            if sources[source]?.isEmpty ?? true {
                sources[source] = Set([button.binding])
            } else {
                sources[source] = []
            }
            refreshActiveButtons()
            schedule()
        case .tap:
            guard pressed, pulseTasks[id] == nil else { return }
            let token = UUID()
            sources[source] = Set([button.binding])
            refreshActiveButtons()
            schedule()
            pulseTokens[id] = token
            pulseTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.flush()
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, self.pulseTokens[id] == token else { return }
                self.pulseTasks[id] = nil
                self.pulseTokens[id] = nil
                self.sources[source] = []
                self.refreshActiveButtons()
                self.schedule()
            }
        }
    }

    public func direction(_ action: GameTouchAction, pressed: Bool, forAttachment id: UUID? = nil) {
        if let id, id != attachmentID { return }
        guard !transitioning, profile.enabled, action.isDirection else { return }
        if pressed, let chord = profile.directionBinding(for: action) {
            sources["pad:" + action.rawValue] = Set([GameTouchBinding(chord: chord)])
        } else {
            sources["pad:" + action.rawValue] = []
        }
        refreshActiveButtons()
        schedule()
    }

    public func releaseAll() async {
        cancelPulses()
        sources.removeAll()
        refreshActiveButtons()
        schedule()
        if let draining { await draining.value }
    }

    public func releaseAll(forAttachment id: UUID) async {
        guard id == attachmentID else { return }
        await releaseAll()
    }

    public func flush() async {
        if let draining { await draining.value }
    }

    /// A finite AI/test keyboard pulse in the SAME ledger as touch controls.
    /// Shared modifiers/keys stay down until every owning source releases.
    /// Caller cancellation, profile change and detach all release this source.
    public func performPulse(_ binding: GameTouchBinding,
                             durationMilliseconds: Int = 80) async throws {
        guard (16...2_000).contains(durationMilliseconds) else {
            throw GameTouchPulseError.invalidDuration
        }
        guard !transitioning, profile.enabled, isAttached,
              let attachment = attachmentID, sink != nil else {
            throw GameTouchPulseError.unavailable
        }
        guard externalPulses.count < 32 else { throw GameTouchPulseError.tooManyRequests }
        if let lastError { throw GameTouchPulseError.deliveryFailed(lastError) }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { @MainActor [self] in
            try await runExternalPulse(binding, durationMilliseconds: durationMilliseconds,
                                       attachment: attachment, source: "external:" + id.uuidString)
        }
        externalPulses[id] = task
        defer { externalPulses.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runExternalPulse(_ binding: GameTouchBinding, durationMilliseconds: Int,
                                  attachment: UUID, source: String) async throws {
        try Task.checkCancellation()
        guard !transitioning, attachmentID == attachment, isAttached else {
            throw GameTouchPulseError.staleAttachment
        }
        sources[source] = [binding]
        schedule()
        do {
            await flush()
            try validateExternalPulse(attachment: attachment, source: source)
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
            try validateExternalPulse(attachment: attachment, source: source)
        } catch {
            await endExternalPulse(attachment: attachment, source: source)
            throw error
        }
        await endExternalPulse(attachment: attachment, source: source)
        guard attachmentID == attachment, !transitioning, isAttached else {
            throw GameTouchPulseError.staleAttachment
        }
        if let lastError { throw GameTouchPulseError.deliveryFailed(lastError) }
    }

    private func validateExternalPulse(attachment: UUID, source: String) throws {
        if let lastError { throw GameTouchPulseError.deliveryFailed(lastError) }
        try Task.checkCancellation()
        guard attachmentID == attachment, !transitioning, isAttached,
              sources[source] != nil else { throw GameTouchPulseError.staleAttachment }
    }

    private func endExternalPulse(attachment: UUID, source: String) async {
        // An old pulse can neither clear a newer attachment nor resolve its
        // sink. ReleaseAll already removed this source at a scope transition.
        guard attachmentID == attachment else { return }
        sources.removeValue(forKey: source)
        schedule()
        await flush()
    }

    private func insert(_ direction: GameTouchAction, into pressed: inout Set<GameTouchBinding>) {
        guard let chord = profile.directionBinding(for: direction) else { return }
        pressed.insert(GameTouchBinding(chord: chord))
    }

    private var desiredBindings: Set<GameTouchBinding> {
        sources.values.reduce(into: Set<GameTouchBinding>()) { $0.formUnion($1) }
    }

    private func refreshActiveButtons() {
        let next = Set(profile.buttons.compactMap { button -> GameTouchButton.ID? in
            guard let values = sources[Self.sourceKey(button.id)] else { return nil }
            return values.isEmpty ? nil : button.id
        })
        if next != activeButtonIDs { activeButtonIDs = next }
    }

    private static func sourceKey(_ id: GameTouchButton.ID) -> String { "button:" + id.rawValue }

    private func cancelPulses() {
        for task in pulseTasks.values { task.cancel() }
        pulseTasks.removeAll()
        pulseTokens.removeAll()
        for task in externalPulses.values { task.cancel() }
        externalPulses.removeAll()
    }

    private func schedule() {
        guard draining == nil, sink != nil else { return }
        let token = generation
        draining = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.draining = nil } }
            while token == self.generation, let sink = self.sink {
                guard let event = self.nextEvent() else { return }
                do {
                    try await sink.set(event.binding, pressed: event.pressed)
                } catch {
                    self.lastError = String(describing: error)
                    self.cancelPulses()
                    self.sources.removeAll()
                    self.refreshActiveButtons()
                    // The transport may have delivered the attempted down
                    // before its acknowledgement failed. Include it in this
                    // captured sink's compensation ledger as well.
                    if event.pressed {
                        switch event.binding {
                        case .key(let key): self.deliveredKeys.insert(key)
                        case .chord(let chord): self.deliveredKeys.formUnion(chord.keys)
                        case .action(let action): self.deliveredActions.insert(action)
                        }
                    }
                    // Explicit failure must not leave native keys down.
                    for key in self.deliveredKeys.filter({ !$0.isModifier }).sorted(by: Self.keyOrder) {
                        try? await sink.set(.key(key), pressed: false)
                    }
                    for key in self.deliveredKeys.filter({ $0.isModifier }).sorted(by: Self.keyOrder) {
                        try? await sink.set(.key(key), pressed: false)
                    }
                    for action in self.deliveredActions.sorted(by: { $0.rawValue < $1.rawValue }) {
                        try? await sink.set(.action(action), pressed: false)
                    }
                    self.deliveredKeys.removeAll()
                    self.deliveredActions.removeAll()
                    return
                }
                guard token == self.generation else { return }
                switch event.binding {
                case .key(let key):
                    if event.pressed { self.deliveredKeys.insert(key) } else { self.deliveredKeys.remove(key) }
                case .chord(let chord):
                    if event.pressed {
                        self.deliveredKeys.formUnion(chord.keys)
                    } else {
                        self.deliveredKeys.subtract(chord.keys)
                    }
                case .action(let action):
                    if event.pressed { self.deliveredActions.insert(action) } else { self.deliveredActions.remove(action) }
                }
            }
        }
    }

    /// Deterministic event plan: action releases, ordinary-key releases,
    /// modifier releases, modifier presses, ordinary-key presses, action
    /// presses. Modifiers therefore go down first and come up last.
    private func nextEvent() -> PendingEvent? {
        let target = desiredBindings
        var targetActions: Set<GameTouchAction> = []
        var targetKeys: Set<GameKeyboardKey> = []
        for binding in target {
            switch binding {
            case .action(let action): targetActions.insert(action)
            case .key(let key): targetKeys.insert(key)
            case .chord(let chord): targetKeys.formUnion(chord.keys)
            }
        }

        let releasedActions = deliveredActions.subtracting(targetActions)
        if let action = releasedActions.sorted(by: { $0.rawValue < $1.rawValue }).first {
            return PendingEvent(binding: .action(action), pressed: false)
        }
        let releasedKeys = deliveredKeys.subtracting(targetKeys)
        if let key = releasedKeys.filter({ !$0.isModifier }).sorted(by: Self.keyOrder).first {
            return PendingEvent(binding: .key(key), pressed: false)
        }
        if let key = releasedKeys.filter({ $0.isModifier }).sorted(by: Self.keyOrder).first {
            return PendingEvent(binding: .key(key), pressed: false)
        }
        let pressedKeys = targetKeys.subtracting(deliveredKeys)
        if let key = pressedKeys.filter({ $0.isModifier }).sorted(by: Self.keyOrder).first {
            return PendingEvent(binding: .key(key), pressed: true)
        }
        if let key = pressedKeys.filter({ !$0.isModifier }).sorted(by: Self.keyOrder).first {
            return PendingEvent(binding: .key(key), pressed: true)
        }
        let pressedActions = targetActions.subtracting(deliveredActions)
        if let action = pressedActions.sorted(by: { $0.rawValue < $1.rawValue }).first {
            return PendingEvent(binding: .action(action), pressed: true)
        }
        return nil
    }

    private static func keyOrder(_ lhs: GameKeyboardKey, _ rhs: GameKeyboardKey) -> Bool {
        lhs.modifierOrder == rhs.modifierOrder
            ? lhs.rawValue < rhs.rawValue
            : lhs.modifierOrder < rhs.modifierOrder
    }

    private struct PendingEvent {
        let binding: GameTouchBinding
        let pressed: Bool
    }
}
