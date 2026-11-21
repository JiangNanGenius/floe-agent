// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit

public struct GameTouchAnchor: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw GameProjectError.invalidEdit
        }
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: container.decode(Double.self, forKey: .x),
                      y: container.decode(Double.self, forKey: .y))
    }

    private enum CodingKeys: CodingKey { case x, y }
}

public struct GameTouchButton: Codable, Equatable, Identifiable, Sendable {
    public typealias ID = GameTouchButtonID

    public enum Mode: String, Codable, CaseIterable, Hashable, Sendable {
        case hold, tap, toggle
    }

    public let id: ID
    public var binding: GameTouchBinding
    public var anchor: GameTouchAnchor?
    public var visible: Bool
    /// nil (or an empty App-side string) shows the actual key/chord title.
    public var label: String?
    /// Optional fixed control size. Both bounds are 44...320 points.
    public var width: Double?
    public var height: Double?
    public var mode: Mode

    public init(id: ID, binding: GameTouchBinding, anchor: GameTouchAnchor? = nil, visible: Bool = true,
                label: String? = nil, width: Double? = nil, height: Double? = nil, mode: Mode = .hold) {
        self.id = id
        self.binding = binding
        self.anchor = anchor
        self.visible = visible
        self.label = label
        self.width = width
        self.height = height
        self.mode = mode
    }

    public func validate() throws {
        if let label {
            guard label.count <= 64, label.utf8.count <= 256,
                  !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw GameProjectError.invalidEdit
            }
        }
        for value in [width, height].compactMap({ $0 }) {
            guard value.isFinite, (44...320).contains(value) else { throw GameProjectError.invalidEdit }
        }
        if case .chord(let chord) = binding { _ = try GameTouchChord(keys: chord.keys) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(ID.self, forKey: .id),
                  binding: try container.decode(GameTouchBinding.self, forKey: .binding),
                  anchor: try container.decodeIfPresent(GameTouchAnchor.self, forKey: .anchor),
                  visible: try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true,
                  label: try container.decodeIfPresent(String.self, forKey: .label),
                  width: try container.decodeIfPresent(Double.self, forKey: .width),
                  height: try container.decodeIfPresent(Double.self, forKey: .height),
                  mode: try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .hold)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(binding, forKey: .binding)
        try container.encodeIfPresent(anchor, forKey: .anchor)
        try container.encode(visible, forKey: .visible)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encode(mode, forKey: .mode)
    }

    private enum CodingKeys: String, CodingKey {
        case id, binding, anchor, visible, label, width, height, mode
    }
}

public struct GameTouchProfile: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Stick: String, Codable, CaseIterable, Sendable {
        case none, joystick, directionPad
    }

    public enum MovementKeys: String, Codable, CaseIterable, Sendable {
        case engineDefault, arrows, wasd, custom
    }

    public let engine: GameEngineID
    public var enabled: Bool
    public var stick: Stick
    public var leftHanded: Bool
    public var movementKeys: MovementKeys
    public private(set) var scale: Double
    public private(set) var opacity: Double
    public private(set) var deadZone: Double
    public var stickAnchor: GameTouchAnchor?
    public private(set) var buttons: [GameTouchButton]
    /// Encoding only. Browser keyboard events by default; x11 is the existing
    /// owned Linux display adapter, not a separate execution environment.
    public var keyboardTransport: GameTouchKeyboardTransport
    public private(set) var directionBindings: GameTouchDirectionBindings
    public private(set) var defaultSource: GameTouchDefaultSource

    public init(engine: GameEngineID, enabled: Bool = true, stick: Stick = .joystick,
                leftHanded: Bool = false, movementKeys: MovementKeys = .engineDefault,
                scale: Double = 1, opacity: Double = 0.65, deadZone: Double = 0.18,
                stickAnchor: GameTouchAnchor? = nil, buttons: [GameTouchButton],
                keyboardTransport: GameTouchKeyboardTransport = .browser,
                directionBindings: GameTouchDirectionBindings = .init(),
                defaultSource: GameTouchDefaultSource = .engineDefault) throws {
        guard scale.isFinite, opacity.isFinite, deadZone.isFinite,
              (0.6...1.6).contains(scale), (0.15...1).contains(opacity), (0.05...0.5).contains(deadZone),
              buttons.count <= 64, Set(buttons.map(\.id)).count == buttons.count else {
            throw GameProjectError.invalidEdit
        }
        try directionBindings.validate()
        for button in buttons { try button.validate() }
        self.engine = engine
        self.enabled = enabled
        self.stick = stick
        self.leftHanded = leftHanded
        self.movementKeys = movementKeys
        self.scale = scale
        self.opacity = opacity
        self.deadZone = deadZone
        self.stickAnchor = stickAnchor
        self.buttons = buttons
        self.keyboardTransport = keyboardTransport
        self.directionBindings = directionBindings
        self.defaultSource = defaultSource
    }

    public func validate() throws {
        guard scale.isFinite, opacity.isFinite, deadZone.isFinite,
              (0.6...1.6).contains(scale), (0.15...1).contains(opacity), (0.05...0.5).contains(deadZone),
              buttons.count <= 64, Set(buttons.map(\.id)).count == buttons.count else {
            throw GameProjectError.invalidEdit
        }
        try directionBindings.validate()
        for button in buttons { try button.validate() }
    }

    public func button(id: GameTouchButton.ID) -> GameTouchButton? {
        buttons.first { $0.id == id }
    }

    public mutating func add(_ button: GameTouchButton) throws {
        try button.validate()
        guard buttons.count < 64, !buttons.contains(where: { $0.id == button.id }) else {
            throw GameProjectError.invalidEdit
        }
        buttons.append(button)
    }

    public mutating func update(_ button: GameTouchButton) throws {
        try button.validate()
        guard let index = buttons.firstIndex(where: { $0.id == button.id }) else {
            throw GameProjectError.invalidEdit
        }
        buttons[index] = button
    }

    public mutating func remove(id: GameTouchButton.ID) throws {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else {
            throw GameProjectError.invalidEdit
        }
        buttons.remove(at: index)
    }

    /// `index` is the final position in the array after the move.
    public mutating func move(id: GameTouchButton.ID, to index: Int) throws {
        guard (0..<buttons.count).contains(index),
              let current = buttons.firstIndex(where: { $0.id == id }) else {
            throw GameProjectError.invalidEdit
        }
        let button = buttons.remove(at: current)
        buttons.insert(button, at: index)
    }

    public mutating func adjust(scale: Double? = nil, opacity: Double? = nil, deadZone: Double? = nil) throws {
        let nextScale = scale ?? self.scale
        let nextOpacity = opacity ?? self.opacity
        let nextDeadZone = deadZone ?? self.deadZone
        guard nextScale.isFinite, nextOpacity.isFinite, nextDeadZone.isFinite,
              (0.6...1.6).contains(nextScale), (0.15...1).contains(nextOpacity),
              (0.05...0.5).contains(nextDeadZone) else {
            throw GameProjectError.invalidEdit
        }
        self.scale = nextScale
        self.opacity = nextOpacity
        self.deadZone = nextDeadZone
    }

    /// Effective direction binding. `.arrows` and `.wasd` are explicit
    /// convenience overrides; `.engineDefault` and `.custom` use the stored
    /// declaration/custom map. A nil result means unbound.
    public func directionBinding(for direction: GameTouchAction) -> GameTouchChord? {
        guard direction.isDirection else { return nil }
        switch movementKeys {
        case .arrows: return GameTouchDirectionBindings.arrows[direction]
        case .wasd: return GameTouchDirectionBindings.wasd[direction]
        case .engineDefault, .custom: return directionBindings[direction]
        }
    }

    /// Passing nil explicitly unbinds the direction and switches to `.custom`.
    public mutating func setDirectionBinding(_ chord: GameTouchChord?, for direction: GameTouchAction) throws {
        guard direction.isDirection else { throw GameProjectError.invalidEdit }
        try directionBindings.set(chord, for: direction)
        movementKeys = .custom
    }

    public mutating func clearDirectionBinding(for direction: GameTouchAction) throws {
        try setDirectionBinding(nil, for: direction)
    }

    /// Old call shape stays valid: `standard(engine)` or
    /// `standard(engine, keyboardTransport: .x11)`. Project declarations are
    /// applied only when their captured engine matches.
    public static func standard(_ engine: GameEngineID,
                                keyboardTransport: GameTouchKeyboardTransport = .browser,
                                projectBindings: GameTouchProjectBindings? = nil) -> Self {
        if let projectBindings, projectBindings.engine == engine {
            return try! Self(engine: engine,
                             enabled: true,
                             stick: projectBindings.movement.isEmpty ? .none : .directionPad,
                             leftHanded: false,
                             movementKeys: .engineDefault,
                             scale: 1,
                             opacity: 0.65,
                             deadZone: 0.18,
                             stickAnchor: nil,
                             buttons: projectBindings.buttons,
                             keyboardTransport: keyboardTransport,
                             directionBindings: projectBindings.movement,
                             defaultSource: .projectDeclaration)
        }
        let catalog = GameTouchDefaults.catalog(for: engine, keyboardTransport: keyboardTransport)
        return try! Self(engine: engine,
                         enabled: true,
                         stick: catalog.stick,
                         leftHanded: false,
                         movementKeys: .engineDefault,
                         scale: 1,
                         opacity: 0.65,
                         deadZone: 0.18,
                         stickAnchor: nil,
                         buttons: catalog.buttons,
                         keyboardTransport: keyboardTransport,
                         directionBindings: catalog.movement,
                         defaultSource: catalog.source)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasSchema = container.contains(.schemaVersion)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        guard version == Self.schemaVersion else { throw GameProjectError.invalidEdit }
        let engine = try container.decode(GameEngineID.self, forKey: .engine)
        let transport = try container.decodeIfPresent(GameTouchKeyboardTransport.self, forKey: .keyboardTransport) ?? .browser
        let movementKeys = try container.decodeIfPresent(MovementKeys.self, forKey: .movementKeys) ?? .engineDefault
        let decodedButtons = try container.decodeIfPresent([GameTouchButton].self, forKey: .buttons) ?? []
        let buttons = hasSchema ? decodedButtons : Self.migrateLegacy(decodedButtons)
        let directionBindings: GameTouchDirectionBindings
        if let stored = try container.decodeIfPresent(GameTouchDirectionBindings.self, forKey: .directionBindings) {
            directionBindings = stored
        } else {
            directionBindings = GameTouchDefaults.catalog(for: engine, keyboardTransport: transport).movement
        }
        let source = try container.decodeIfPresent(GameTouchDefaultSource.self, forKey: .defaultSource)
            ?? (hasSchema ? .engineDefault : .legacyMigration)
        let stick = try container.decodeIfPresent(Stick.self, forKey: .stick)
            ?? (directionBindings.isEmpty ? .none : .directionPad)
        try self.init(engine: engine,
                      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                      stick: stick,
                      leftHanded: try container.decodeIfPresent(Bool.self, forKey: .leftHanded) ?? false,
                      movementKeys: movementKeys,
                      scale: try container.decode(Double.self, forKey: .scale),
                      opacity: try container.decode(Double.self, forKey: .opacity),
                      deadZone: try container.decode(Double.self, forKey: .deadZone),
                      stickAnchor: try container.decodeIfPresent(GameTouchAnchor.self, forKey: .stickAnchor),
                      buttons: buttons,
                      keyboardTransport: transport,
                      directionBindings: directionBindings,
                      defaultSource: source)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(engine, forKey: .engine)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(stick, forKey: .stick)
        try container.encode(leftHanded, forKey: .leftHanded)
        try container.encode(movementKeys, forKey: .movementKeys)
        try container.encode(scale, forKey: .scale)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(deadZone, forKey: .deadZone)
        try container.encodeIfPresent(stickAnchor, forKey: .stickAnchor)
        try container.encode(buttons, forKey: .buttons)
        try container.encode(keyboardTransport, forKey: .keyboardTransport)
        try container.encode(directionBindings, forKey: .directionBindings)
        try container.encode(defaultSource, forKey: .defaultSource)
    }

    /// Old profiles used typed actions for every default button. The WebKit
    /// player already documents these exact keyboard fallbacks, so migrate
    /// those clear equivalents instead of showing gamepad names or dropping
    /// user buttons.
    private static func migrateLegacy(_ buttons: [GameTouchButton]) -> [GameTouchButton] {
        buttons.map { button in
            guard case .action(let action) = button.binding,
                  let key = action.legacyKeyboardKey else { return button }
            var copy = button
            copy.binding = .key(key)
            return copy
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, engine, enabled, stick, leftHanded, movementKeys, scale, opacity,
             deadZone, stickAnchor, buttons, keyboardTransport, directionBindings, defaultSource
    }
}

/// Read-only starting-preset information so hosts can distinguish documented
/// engine key maps from Floe template fallbacks.
public struct GameTouchDefaultCatalog: Equatable, Sendable {
    public let engine: GameEngineID
    public let keyboardTransport: GameTouchKeyboardTransport
    public let source: GameTouchDefaultSource
    public let summary: String
    public let reference: String?
    public let stick: GameTouchProfile.Stick
    public let movement: GameTouchDirectionBindings
    public let buttons: [GameTouchButton]

    public init(engine: GameEngineID, keyboardTransport: GameTouchKeyboardTransport,
                source: GameTouchDefaultSource, summary: String, reference: String?,
                stick: GameTouchProfile.Stick, movement: GameTouchDirectionBindings,
                buttons: [GameTouchButton]) {
        self.engine = engine
        self.keyboardTransport = keyboardTransport
        self.source = source
        self.summary = summary
        self.reference = reference
        self.stick = stick
        self.movement = movement
        self.buttons = buttons
    }
}

public enum GameTouchDefaults {
    public static func catalog(for engine: GameEngineID,
                               keyboardTransport: GameTouchKeyboardTransport = .browser) -> GameTouchDefaultCatalog {
        switch engine {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ:
            return rpgMaker(engine, keyboardTransport)
        case .tic80:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .engineDefault,
                summary: "TIC-80 keyboard preset: arrows move; Z/X/A/S map to A/B/X/Y buttons.",
                reference: "https://tic80.com/learn",
                stick: .directionPad, movement: .arrows,
                buttons: [button("tic.a", .z), button("tic.b", .x), button("tic.x", .a), button("tic.y", .s)]
            )
        case .wasm4:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .engineDefault,
                summary: "WASM-4 player 1 keyboard preset: arrows move; X is button 1 and Z is button 2.",
                reference: "https://wasm4.org/docs/guides/multiplayer/",
                stick: .directionPad, movement: .arrows,
                buttons: [button("wasm4.button1", .x), button("wasm4.button2", .z)]
            )
        case .renpy:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .engineDefault,
                summary: "Ren'Py default keymap: Space/Enter dismiss, Esc menu, Ctrl skip, Tab toggle skip, PageUp rollback, H hide windows.",
                reference: "https://www.renpy.org/doc/html/keymap.html",
                stick: .none, movement: .init(),
                buttons: [
                    button("renpy.dismiss.space", .space),
                    button("renpy.dismiss.enter", .enter),
                    button("renpy.menu", .escape),
                    button("renpy.skip", .control),
                    button("renpy.toggleSkip", .tab),
                    button("renpy.rollback", .pageUp),
                    button("renpy.hideWindows", .h)
                ]
            )
        case .tyranoScript:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .templateFallback,
                summary: "Uses the imported game's touch controls and key configuration.",
                reference: nil, stick: .none, movement: .init(), buttons: []
            )
        case .ink, .twine:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .templateFallback,
                summary: "Floe narrative wrapper; its key map still needs runtime-owner verification. Declare floe-inputs.json or add keys explicitly.",
                reference: nil,
                stick: .none, movement: .init(), buttons: []
            )
        case .phaser, .kaplay, .godot, .babylon, .playcanvas, .love, .gdevelop, .cocosCreator, .microStudio, .unity:
            return GameTouchDefaultCatalog(
                engine: engine, keyboardTransport: keyboardTransport, source: .templateFallback,
                summary: "Project-defined input. Declare floe-inputs.json (or discover Godot/Unity actions); Floe samples implement arrow-key movement only, so no action buttons are assumed.",
                reference: nil,
                stick: .directionPad, movement: .arrows, buttons: []
            )
        }
    }

    private static func rpgMaker(_ engine: GameEngineID,
                                 _ keyboardTransport: GameTouchKeyboardTransport) -> GameTouchDefaultCatalog {
        let summary: String
        switch engine {
        case .rpgMakerMZ:
            summary = "RPG Maker MZ keyMapper: arrows, Z ok, X escape/cancel, Shift dash, Q pageup, W pagedown."
        case .rpgMakerMV:
            summary = "RPG Maker MV/MZ-family keyboard preset: arrows, Z confirm, X cancel/menu, Shift dash, Q/W page."
        case .rpgMakerXP:
            summary = "RPG Maker XP/RGSS1 keyboard preset: arrows, C confirm (Enter/Space alternatives), X cancel/menu, Shift action A, Q/W page. Z is an A key in this generation, not the MV/MZ confirm key. Project/runtime declarations override this baseline."
        default:
            summary = "RPG Maker VX/Ace keyboard preset: arrows, Z confirm, X cancel/menu, Shift dash, Q/W page."
        }
        return GameTouchDefaultCatalog(
            engine: engine, keyboardTransport: keyboardTransport, source: .engineDefault,
            summary: summary,
            reference: engine == .rpgMakerXP
                ? "https://github.com/pulsejet/mkxp-web/blob/e0437fdc5be29507e78d148a2b3f02d26ee1c779/src/keybindings.cpp"
                : "https://rpgmakerofficial.com/product/MV_Help/page/01_06.html; https://developer.rpgmakerweb.com/rpg-maker-mz/Input.js.html",
            stick: .directionPad, movement: .arrows,
            buttons: [
                button("rpg.confirm", engine == .rpgMakerXP ? .c : .z),
                button("rpg.cancel", .x),
                button("rpg.dash", .shift),
                button("rpg.pageUp", .q),
                button("rpg.pageDown", .w)
            ]
        )
    }

    private static func button(_ id: String, _ key: GameKeyboardKey) -> GameTouchButton {
        GameTouchButton(id: try! GameTouchButton.ID(id), binding: .key(key))
    }
}

/// Per-project settings. Each engine/transport is an independent CAS slot
/// under the existing bounded save component. The old single-file settings
/// location is read for migration and is never deleted or overwritten.
public actor GameTouchProfileStore {
    private let directory: URL
    private let projectID: UUID
    private let owner: GameProjectOwner
    private let legacyStore: FileGameSaveRepository
    private var slots: [String: FileGameSaveRepository] = [:]
    private static let maximumStateBytes = 256 * 1_024

    public init(directory: URL, projectID: UUID, owner: GameProjectOwner) throws {
        guard directory.isFileURL else { throw GameProjectError.invalidContext }
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.directory = canonical
        self.projectID = projectID
        self.owner = owner
        self.legacyStore = try FileGameSaveRepository(directory: canonical, projectID: projectID,
                                                      owner: owner, maximumStateBytes: Self.maximumStateBytes)
    }

    public func load(engine: GameEngineID,
                     keyboardTransport: GameTouchKeyboardTransport = .browser,
                     defaults: GameTouchProfile? = nil) async throws -> (profile: GameTouchProfile, revision: UInt64) {
        if let defaults {
            guard defaults.engine == engine, defaults.keyboardTransport == keyboardTransport else {
                throw GameProjectError.invalidContext
            }
            try defaults.validate()
        }
        let slot = try repository(for: engine, transport: keyboardTransport)
        if let saved = try await slot.load() {
            let profile = try JSONDecoder().decode(GameTouchProfile.self, from: saved.state)
            guard profile.engine == engine, profile.keyboardTransport == keyboardTransport else {
                throw GameProjectError.corruptStorage
            }
            try profile.validate()
            return (profile, saved.revision)
        }
        // Legacy browser settings are read once as a migration source. Return
        // revision 0 so the first explicit save creates the new slot; the old
        // file stays untouched and readable.
        if keyboardTransport == .browser, let saved = try await legacyStore.load() {
            let profile = try JSONDecoder().decode(GameTouchProfile.self, from: saved.state)
            if profile.engine == engine { return (profile, 0) }
        }
        return (defaults ?? .standard(engine, keyboardTransport: keyboardTransport), 0)
    }

    public func save(_ profile: GameTouchProfile, expectedRevision: UInt64) async throws -> UInt64 {
        try profile.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profile)
        guard data.count <= Self.maximumStateBytes else { throw GameProjectError.limitExceeded("gameTouchSettings") }
        let slot = try repository(for: profile.engine, transport: profile.keyboardTransport)
        return try await slot.save(data, expectedRevision: expectedRevision).revision
    }

    private func repository(for engine: GameEngineID,
                            transport: GameTouchKeyboardTransport) throws -> FileGameSaveRepository {
        let key = "keyboard-" + engine.rawValue + "-" + transport.rawValue
        if let repository = slots[key] { return repository }
        let repository = try FileGameSaveRepository(
            directory: directory.appendingPathComponent(key, isDirectory: true),
            projectID: projectID,
            owner: owner,
            maximumStateBytes: Self.maximumStateBytes
        )
        slots[key] = repository
        return repository
    }
}
