// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameRGSS
import FloeGameTouch
import FloeGameWebKit

/// One named physical chord presented by the host UI. Project declarations and
/// the engine-standard profile share this shape; a chord is always pressed
/// together, never treated as a list of alternatives.
public struct RGSSGuestButtonBinding: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Equatable {
        case engineStandard
        case projectDeclaration
    }

    public let id: String
    public let label: String
    public let keys: [GameKeyboardKey]
    public let origin: Origin

    public init(id: String, label: String, keys: [GameKeyboardKey], origin: Origin) throws {
        guard (1...8).contains(keys.count), Set(keys).count == keys.count else {
            throw RGSSGuestRunError.invalidRequest("button \(id) chord")
        }
        self.id = id
        self.label = label
        self.keys = Self.ordered(keys)
        self.origin = origin
    }

    public static func ordered(_ keys: [GameKeyboardKey]) -> [GameKeyboardKey] {
        keys.sorted { lhs, rhs in
            lhs.modifierOrder == rhs.modifierOrder
                ? lhs.rawValue < rhs.rawValue
                : lhs.modifierOrder < rhs.modifierOrder
        }
    }
}

/// Compatibility for the frozen RGSS template writer's standard declaration.
/// That declaration puts alternative confirm/cancel/action keys in one array,
/// while the TouchKit schema defines an array as one simultaneous chord. This
/// migration recognizes ONLY the exact shipped standard declaration and emits
/// one button per physical key. Custom declarations keep their declared chord
/// semantics and are never rewritten.
public enum RGSSGuestInputDeclarationMigration {
    public static func normalizedStandard(_ data: Data,
                                          engine: GameEngineID) throws -> Data? {
        let declaration: RGSSInputDeclaration
        do {
            declaration = try RGSSInputDeclaration.decode(data, expectedEngine: engine)
        } catch {
            return nil
        }
        guard declaration == legacyStandard(for: engine) else {
            return nil
        }
        let movement: [String: [String]] = [
            "left": declaration.movement.left,
            "right": declaration.movement.right,
            "up": declaration.movement.up,
            "down": declaration.movement.down,
        ]
        var buttons: [[String: Any]] = []
        for button in declaration.buttons {
            for key in button.keys {
                buttons.append([
                    "id": "\(button.id).\(key)",
                    "label": "\(button.label) \(key)",
                    "keys": [key],
                ])
            }
        }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "engine": engine.rawValue,
            "movement": movement,
            "buttons": buttons,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Match the old writer explicitly. The current SDK writer has corrected
    /// single-key defaults and must retain its original button identifiers.
    private static func legacyStandard(for engine: GameEngineID) -> RGSSInputDeclaration {
        let xp = engine == .rpgMakerXP
        return .init(engine: engine,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [
                .init(id: "confirm", label: xp ? "C" : "Z",
                      keys: xp ? ["c", "enter", "space"] : ["z", "enter", "space"]),
                .init(id: "cancel", label: "X", keys: ["x", "escape"]),
                .init(id: "action1", label: xp ? "Z/Shift" : "Shift",
                      keys: xp ? ["z", "shift"] : ["shift"]),
                .init(id: "action2", label: "Q", keys: ["q"]),
                .init(id: "action3", label: "W", keys: ["w"])
            ])
    }
}

/// Physical keyboard map for one RGSS run. `standard` follows the Tapir native
/// engine's version-specific key configuration; a project `floe-inputs.json`
/// (schema v1) overrides it with arbitrary physical keys/chords.
public struct RGSSGuestKeymap: Sendable, Equatable {
    public let engine: GameEngineID
    public let profile: RGSSGuestInputProfile
    public let declaration: GameTouchProjectBindings?
    public let standardButtons: [RGSSGuestButtonBinding]
    public let projectButtons: [RGSSGuestButtonBinding]

    public var allButtons: [RGSSGuestButtonBinding] {
        let overridden = Set(projectButtons.map(\.id))
        return projectButtons + standardButtons.filter { !overridden.contains($0.id) }
    }

    public init(engine: GameEngineID,
                profile: RGSSGuestInputProfile,
                declaration: GameTouchProjectBindings?) throws {
        guard RGSSEngineProfiles.isRGSS(engine), profile.version.rawValue == Self.version(for: engine) else {
            throw RGSSGuestRunError.invalidEngine(engine)
        }
        if let declaration {
            guard declaration.engine == engine else {
                throw RGSSGuestRunError.invalidRequest("floe-inputs.json engine mismatch")
            }
        }
        var standard: [RGSSGuestButtonBinding] = []
        for action in Self.allActions {
            let alternatives = profile.bindings
                .filter { $0.value == action }
                .map(\.key)
                .compactMap(Self.keyboardKey)
                .sorted { $0.rawValue < $1.rawValue }
            guard !alternatives.isEmpty else { continue }
            let preferred: GameKeyboardKey?
            switch action {
            case .c: preferred = engine == .rpgMakerXP ? .c : .z
            case .b: preferred = .x
            case .a: preferred = .shift
            default: preferred = nil
            }
            let keys = alternatives.sorted { lhs, rhs in
                let leftPriority = lhs == preferred ? 0 : 1
                let rightPriority = rhs == preferred ? 0 : 1
                return leftPriority == rightPriority
                    ? lhs.rawValue < rhs.rawValue : leftPriority < rightPriority
            }
            for (index, key) in keys.enumerated() {
                // Each standard alternative is a separate button. Only an
                // explicit project declaration can request a multi-key chord.
                let id = index == 0 ? action.rawValue : "\(action.rawValue).\(key.rawValue)"
                standard.append(try .init(id: id, label: key.rawValue,
                                          keys: [key], origin: .engineStandard))
            }
        }
        var project: [RGSSGuestButtonBinding] = []
        if let declaration {
            for direction in [GameTouchAction.left, .right, .up, .down] {
                guard let chord = declaration.movement[direction] else { continue }
                project.append(try .init(id: direction.rawValue, label: direction.rawValue,
                                         keys: chord.keys, origin: .projectDeclaration))
            }
            for button in declaration.buttons {
                guard let keys = button.binding.keyboardKeys else {
                    throw RGSSGuestRunError.invalidRequest(
                        "project button \(button.id.rawValue) uses a legacy action binding")
                }
                project.append(try .init(id: button.id.rawValue,
                                         label: button.label ?? button.id.rawValue,
                                         keys: keys, origin: .projectDeclaration))
            }
        }
        self.engine = engine
        self.profile = profile
        self.declaration = declaration
        self.standardButtons = standard
        self.projectButtons = project
    }

    public static func standard(engine: GameEngineID) throws -> RGSSGuestKeymap {
        let profile = RGSSGuestInputProfile.standard(for: try RGSSEngineProfiles.profile(for: engine).version)
        return try .init(engine: engine, profile: profile, declaration: nil)
    }

    /// Loads the project declaration from the owned run copy. The run copy is
    /// used so an explicit developer change can be tested without rewriting the
    /// imported source; the source remains the persisted revision.
    public static func load(from staged: RGSSGuestStagedRun) throws -> RGSSGuestKeymap {
        let profile = RGSSGuestInputProfile.standard(for: staged.plan.version)
        let declarationURL = staged.runRoot.appendingPathComponent("floe-inputs.json")
        guard FileManager.default.fileExists(atPath: declarationURL.path) else {
            return try .init(engine: staged.request.engine, profile: profile, declaration: nil)
        }
        let data = try RGSSGuestSafeTree.readFile(
            rootURL: staged.runRoot, relative: "floe-inputs.json",
            maximumBytes: GameTouchProjectBindings.maximumDeclarationBytes)
        let normalized = try RGSSGuestInputDeclarationMigration.normalizedStandard(
            data, engine: staged.request.engine) ?? data
        let declaration = try GameTouchProjectBindings(json: normalized,
                                                       engine: staged.request.engine)
        return try .init(engine: staged.request.engine, profile: profile, declaration: declaration)
    }

    /// Keys for one engine action. Alternatives are exposed as separate
    /// selectable keys; send exactly one of them unless the caller explicitly
    /// constructs a chord.
    public func keys(for action: RGSSGuestInputAction) -> [GameKeyboardKey] {
        standardButtons.filter {
            $0.id == action.rawValue || $0.id.hasPrefix(action.rawValue + ".")
        }.flatMap(\.keys)
    }

    public func chord(forButtonID id: String) -> [GameKeyboardKey]? {
        allButtons.first(where: { $0.id == id })?.keys
    }

    public func button(_ id: String) -> RGSSGuestButtonBinding? {
        allButtons.first(where: { $0.id == id })
    }

    /// Maps the SDK's smaller key vocabulary into the full physical key table
    /// used by the existing display adapter.
    public static func keyboardKey(_ key: RGSSGuestInputKey) -> GameKeyboardKey? {
        switch key {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .enter: .enter
        case .escape: .escape
        case .space: .space
        case .tab: .tab
        case .backspace: .backspace
        case .a: .a
        case .b: .b
        case .c: .c
        case .d: .d
        case .q: .q
        case .s: .s
        case .w: .w
        case .x: .x
        case .y: .y
        case .z: .z
        case .shift: .shift
        case .rightShift: .rightShift
        case .control: .control
        case .alt: .alt
        }
    }

    private static let allActions: [RGSSGuestInputAction] = [
        .down, .left, .right, .up, .a, .b, .c, .x, .y, .z, .l, .r,
        .shift, .control, .alt,
    ]

    private static func version(for engine: GameEngineID) -> Int {
        switch engine {
        case .rpgMakerXP: 1
        case .rpgMakerVX: 2
        case .rpgMakerVXAce: 3
        default: 0
        }
    }
}

/// Physical key phases over the existing owned display input session. It is a
/// narrower contract than a keyboard event injector: the display adapter owns
/// the VNC/X11 transport and the guest owns the focused window.
public protocol RGSSGuestPhysicalInputPort: Sendable {
    func keyDown(_ key: GameKeyboardKey) async throws
    func keyUp(_ key: GameKeyboardKey) async throws
    func releaseAll() async
}

/// Per-run held-key ledger. It serializes chords, compensates a failed down
/// with a release, and never sends a key after invalidation. The type also
/// conforms to the frozen SDK's `RGSSGuestInputSession` so the existing
/// `RGSSGuestHostController` lifecycle can drive it.
public actor RGSSGuestPhysicalInputSession: RGSSGuestInputSession {
    public let port: any RGSSGuestPhysicalInputPort
    public let keymap: RGSSGuestKeymap
    private var pressed: [GameKeyboardKey] = []
    private var generation: UInt64 = 0
    private var invalidated = false
    private var tail: Task<Void, Never>?
    public private(set) var lastReleaseError: String?
    private var failedReleases: Set<GameKeyboardKey> = []

    public init(port: any RGSSGuestPhysicalInputPort, keymap: RGSSGuestKeymap) {
        self.port = port
        self.keymap = keymap
    }

    public var currentPressedKeys: [GameKeyboardKey] { pressed }
    public var isInvalidated: Bool { invalidated }

    /// SDK-compatible entry used by `RGSSGuestHostController`.
    public func sendChord(_ keys: [RGSSGuestInputKey]) async throws {
        let mapped = keys.compactMap(RGSSGuestKeymap.keyboardKey)
        guard mapped.count == keys.count, !mapped.isEmpty else {
            throw RGSSGuestRunError.inputUnavailable("unmapped RGSS key")
        }
        try await sendPhysicalChord(mapped)
    }

    public func sendPhysicalChord(_ keys: [GameKeyboardKey]) async throws {
        guard !invalidated else { throw RGSSGuestRunError.sessionNotActive }
        guard (1...8).contains(keys.count), Set(keys).count == keys.count else {
            throw RGSSGuestRunError.inputUnavailable("invalid chord")
        }
        try Task.checkCancellation()
        let previous = tail
        let captured = generation
        let operation = Task { [self] in
            await previous?.value
            try await performChord(keys, generation: captured)
        }
        tail = Task { _ = try? await operation.value }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Per-key phases for GameTouchInputService, which already reference
    /// counts overlapping controls. Releasing Z must not release a held arrow
    /// or the shared Ctrl of another control.
    public func setPhysicalKey(_ key: GameKeyboardKey, pressed isDown: Bool) async throws {
        if isDown {
            try await sendPhysicalChord([key])
            return
        }
        let previous = tail
        let captured = generation
        let operation = Task { [self] in
            await previous?.value
            guard generation == captured else { throw RGSSGuestRunError.sessionNotActive }
            guard pressed.contains(key) else { return }
            do { try await port.keyUp(key) }
            catch {
                failedReleases.insert(key)
                lastReleaseError = error.localizedDescription
                throw error
            }
            pressed.removeAll { $0 == key }
            failedReleases.remove(key)
            if failedReleases.isEmpty { lastReleaseError = nil }
        }
        tail = Task { _ = try? await operation.value }
        // A key-up remains owned cleanup even if its caller is cancelled.
        // It cannot resolve another input session or affect a newer run.
        try await operation.value
    }

    public func sendButton(_ id: String) async throws {
        guard let keys = keymap.chord(forButtonID: id) else {
            throw RGSSGuestRunError.inputUnavailable("unknown button \(id)")
        }
        try await sendPhysicalChord(keys)
    }

    public func sendAction(_ action: RGSSGuestInputAction) async throws {
        let keys = keymap.keys(for: action)
        guard let key = keys.first else {
            throw RGSSGuestRunError.inputUnavailable("no key for action \(action.rawValue)")
        }
        try await sendPhysicalChord([key])
    }

    private func performChord(_ keys: [GameKeyboardKey], generation captured: UInt64) async throws {
        guard !invalidated, generation == captured else {
            throw RGSSGuestRunError.sessionNotActive
        }
        guard lastReleaseError == nil else {
            throw RGSSGuestRunError.inputUnavailable("release the previous held keys before sending more input")
        }
        for key in RGSSGuestButtonBinding.ordered(keys) where !pressed.contains(key) {
            try Task.checkCancellation()
            pressed.append(key)
            do {
                try await port.keyDown(key)
                try Task.checkCancellation()
                guard !invalidated, generation == captured else {
                    throw RGSSGuestRunError.sessionNotActive
                }
            } catch {
                await performRelease()
                throw error
            }
        }
    }

    public func releaseAll() async {
        generation &+= 1
        let previous = tail
        let operation = Task { [self] in
            await previous?.value
            await performRelease()
        }
        tail = operation
        await operation.value
    }

    private func performRelease() async {
        let release = Array(pressed.reversed())
        pressed.removeAll()
        lastReleaseError = nil
        failedReleases.removeAll()
        for key in release {
            do { try await port.keyUp(key) }
            catch {
                // Keep only this run's failed releases available for retry.
                pressed.insert(key, at: 0)
                failedReleases.insert(key)
                lastReleaseError = error.localizedDescription
            }
        }
    }

    public func invalidate() async {
        invalidated = true
        await releaseAll()
    }
}

/// Factory and per-job registry. The frozen host controller only sees the
/// `RGSSGuestInputSession` existential; the play session keeps the concrete
/// session so the App can send arbitrary project chords and release them.
public final class RGSSGuestInputSessionProvider: RGSSGuestInputPortProviding, @unchecked Sendable {
    private let port: any RGSSGuestPhysicalInputPort
    private let keymap: RGSSGuestKeymap
    private let lock = NSLock()
    private var sessions: [UUID: RGSSGuestPhysicalInputSession] = [:]

    public init(port: any RGSSGuestPhysicalInputPort, keymap: RGSSGuestKeymap) {
        self.port = port
        self.keymap = keymap
    }

    public func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        let input = RGSSGuestPhysicalInputSession(port: port, keymap: keymap)
        lock.withLock { sessions[session.jobID] = input }
        return input
    }

    public func input(for jobID: UUID) -> RGSSGuestPhysicalInputSession? {
        lock.withLock { sessions[jobID] }
    }

    public func remove(jobID: UUID) {
        lock.withLock { sessions.removeValue(forKey: jobID) }
    }

    /// Explicit release for background/navigation. The job keeps running; only
    /// keys owned by this run are released.
    public func releaseInput(for jobID: UUID) async {
        if let input = input(for: jobID) { await input.releaseAll() }
    }
}
