// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameTouch

@MainActor private final class Sink: GameTouchInputSink {
    struct Event: Equatable {
        let binding: GameTouchBinding
        let pressed: Bool
        static func key(_ key: GameKeyboardKey, _ pressed: Bool) -> Event {
            .init(binding: .key(key), pressed: pressed)
        }
        static func action(_ action: GameTouchAction, _ pressed: Bool) -> Event {
            .init(binding: .action(action), pressed: pressed)
        }
    }
    var events: [Event] = []
    func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        events.append(.init(binding: binding, pressed: pressed))
    }
}

@MainActor final class TouchTests: XCTestCase {
    private func makeButton(_ id: String, _ binding: GameTouchBinding,
                            mode: GameTouchButton.Mode = .hold) throws -> GameTouchButton {
        GameTouchButton(id: try GameTouchButton.ID(id), binding: binding, mode: mode)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testEveryEngineHasRoundtrippableKeyboardDefaultsAndInvalidLayoutsAreRejected() throws {
        for engine in GameEngineID.allCases {
            let profile = GameTouchProfile.standard(engine)
            let decoded = try JSONDecoder().decode(GameTouchProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(profile, decoded, engine.rawValue)
            XCTAssertEqual(profile.defaultSource, GameTouchDefaults.catalog(for: engine).source, engine.rawValue)
            for button in profile.buttons {
                XCTAssertNotNil(button.binding.keyboardKeys, "\(engine.rawValue):\(button.id)")
                if case .action = button.binding { XCTFail("default action binding: \(engine.rawValue):\(button.id)") }
            }
        }
        let profile = GameTouchProfile.standard(.rpgMakerVX)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["scale"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(GameTouchProfile.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try GameTouchAnchor(x: .nan, y: 0.5))
    }

    func testStickDeadZoneDiagonalMovementAndRelease() async {
        let sink = Sink(), service = GameTouchInputService(profile: .standard(.godot))
        await service.attach(sink)
        service.stick(x: 0.1, y: 0.1); await service.flush(); XCTAssertTrue(sink.events.isEmpty)
        service.stick(x: 0.2, y: 0); await service.flush()
        XCTAssertEqual(sink.events, [.key(.right, true)])
        service.stick(x: 0, y: 0); await service.flush(); sink.events.removeAll()
        service.stick(x: 1, y: 1); await service.flush()
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertTrue(sink.events.contains(.key(.right, true)))
        XCTAssertTrue(sink.events.contains(.key(.up, true)))
        service.stick(x: 0, y: 0); await service.flush()
        XCTAssertEqual(sink.events.count, 4)
        XCTAssertTrue(sink.events.contains(.key(.right, false)))
        XCTAssertTrue(sink.events.contains(.key(.up, false)))
    }

    func testTwoFingersSharingAMappingCannotReleaseEachOther() async throws {
        var profile = GameTouchProfile.standard(.phaser)
        let first = try GameTouchButton.ID("test.first"), second = try GameTouchButton.ID("test.second")
        try profile.add(makeButton("test.first", .key(.space)))
        try profile.add(makeButton("test.second", .key(.space)))
        let sink = Sink(), service = GameTouchInputService(profile: profile); await service.attach(sink)
        service.button(first, pressed: true); await service.flush()
        service.button(second, pressed: true); await service.flush()
        service.button(first, pressed: false); await service.flush()
        XCTAssertEqual(sink.events, [.key(.space, true)])
        service.button(second, pressed: false); await service.flush()
        XCTAssertEqual(sink.events, [.key(.space, true), .key(.space, false)])
    }

    func testChangingGameReleasesOldControllerAndDoesNotTransferHeldInputs() async throws {
        var profile = GameTouchProfile.standard(.unity)
        let enter = try GameTouchButton.ID("test.enter")
        try profile.add(makeButton("test.enter", .key(.enter)))
        let old = Sink(), next = Sink(), service = GameTouchInputService(profile: profile)
        await service.attach(old)
        let oldAttachment = service.attachmentID!
        service.stick(x: 1, y: 0); await service.flush()
        XCTAssertEqual(old.events, [.key(.right, true)])
        await service.attach(next)
        XCTAssertEqual(old.events, [.key(.right, true), .key(.right, false)])
        XCTAssertTrue(next.events.isEmpty)
        service.stick(x: 1, y: 0, forAttachment: oldAttachment)
        await service.releaseAll(forAttachment: oldAttachment); await service.flush()
        XCTAssertTrue(next.events.isEmpty)
        service.button(enter, pressed: true); await service.flush(); await service.detach()
        XCTAssertEqual(next.events, [.key(.enter, true), .key(.enter, false)])
    }

    func testProfileChangeFencesOldAttachmentCallbacksAndRemapsSafely() async throws {
        var old = GameTouchProfile.standard(.godot)
        let action = try GameTouchButton.ID("test.action")
        try old.add(makeButton("test.action", .key(.space)))
        var remapped = old
        var button = try XCTUnwrap(remapped.button(id: action))
        button.binding = .key(.enter)
        try remapped.update(button)
        remapped.movementKeys = .wasd

        let sink = Sink(), service = GameTouchInputService(profile: old)
        await service.attach(sink)
        let oldToken = try XCTUnwrap(service.attachmentID)
        service.button(action, pressed: true, forAttachment: oldToken); await service.flush()
        XCTAssertEqual(sink.events, [.key(.space, true)])

        await service.updateProfile(remapped)
        let newToken = try XCTUnwrap(service.attachmentID)
        XCTAssertNotEqual(newToken, oldToken)
        XCTAssertEqual(sink.events, [.key(.space, true), .key(.space, false)])

        // Old in-flight callbacks must not press, release, move, or releaseAll
        // against the remapped controls.
        service.button(action, pressed: true, forAttachment: oldToken)
        service.button(action, pressed: false, forAttachment: oldToken)
        service.stick(x: 1, y: 0, forAttachment: oldToken)
        service.direction(.left, pressed: true, forAttachment: oldToken)
        await service.releaseAll(forAttachment: oldToken)
        await service.flush()
        XCTAssertEqual(sink.events.count, 2)

        service.button(action, pressed: true, forAttachment: newToken); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, true))
        service.button(action, pressed: false, forAttachment: oldToken); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, true))
        await service.releaseAll(forAttachment: oldToken); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, true))
        await service.detach()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, false))
    }

    func testSettingsPersistPerProjectWithCASAndOwnerIsolation() async throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = GameProjectOwner.space(recordID: id)
        let store = try GameTouchProfileStore(directory: root, projectID: id, owner: owner)
        var profile = GameTouchProfile.standard(.rpgMakerXP)
        profile.leftHanded = true
        try profile.adjust(opacity: 0.45)
        let revision = try await store.save(profile, expectedRevision: 0)
        let reopened = try GameTouchProfileStore(directory: root, projectID: id, owner: owner)
        let loaded = try await reopened.load(engine: .rpgMakerXP)
        XCTAssertEqual(loaded.profile, profile)
        XCTAssertEqual(loaded.revision, revision)
        do {
            _ = try await store.save(profile, expectedRevision: 0)
            XCTFail("Expected stale settings failure")
        } catch {
            XCTAssertEqual(error as? GameProjectError, .conflict(expected: "0", actual: "1"))
        }
        let other = try GameTouchProfileStore(directory: root, projectID: id,
                                              owner: .conversation(conversationID: UUID(), workspaceID: UUID()))
        let unrelated = try await other.load(engine: .rpgMakerXP)
        XCTAssertEqual(unrelated.revision, 0)
        XCTAssertFalse(unrelated.profile.leftHanded)
    }

    func testImportedGamesCanUseWASDWithoutAPlugin() async {
        var profile = GameTouchProfile.standard(.unity)
        profile.movementKeys = .wasd
        let sink = Sink(), service = GameTouchInputService(profile: profile); await service.attach(sink)
        service.stick(x: -1, y: 1); await service.flush()
        XCTAssertTrue(sink.events.contains(.key(.a, true)))
        XCTAssertTrue(sink.events.contains(.key(.w, true)))
        await service.detach()
        XCTAssertTrue(sink.events.contains(.key(.a, false)))
        XCTAssertTrue(sink.events.contains(.key(.w, false)))
    }

    func testCustomIDsSupportMoreThanSixButtonsRoundtripAndBounds() throws {
        var profile = GameTouchProfile.standard(.phaser)
        for index in 0..<12 {
            let id = try GameTouchButton.ID("custom.\(index)")
            try profile.add(GameTouchButton(id: id,
                                            binding: .chord(try GameTouchChord(keys: [.control, .z])),
                                            label: "Custom \(index)",
                                            width: 60, height: 48, mode: .toggle))
        }
        XCTAssertEqual(profile.buttons.count, 12)
        let decoded = try JSONDecoder().decode(GameTouchProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        let first = profile.buttons[0].id
        try profile.move(id: first, to: 5)
        XCTAssertEqual(profile.buttons[5].id, first)
        try profile.remove(id: first)
        XCTAssertNil(profile.button(id: first))
        XCTAssertThrowsError(try profile.add(GameTouchButton(id: profile.buttons[0].id, binding: .key(.space))))
        var invalid = profile.buttons[0]
        invalid.width = 43
        XCTAssertThrowsError(try profile.update(invalid))
        invalid.width = .infinity
        XCTAssertThrowsError(try profile.update(invalid))
        invalid.width = nil
        invalid.label = String(repeating: "x", count: 65)
        XCTAssertThrowsError(try profile.update(invalid))
        XCTAssertThrowsError(try profile.move(id: profile.buttons[0].id, to: profile.buttons.count))
        XCTAssertThrowsError(try GameTouchButton.ID("bad id"))
        XCTAssertThrowsError(try GameTouchButton.ID(""))
        let generated = GameTouchButton.ID.generated()
        XCTAssertNotNil(GameTouchButton.ID(rawValue: generated.rawValue))
        XCTAssertNotEqual(generated, GameTouchButton.ID.generated())
    }

    func testLegacyStringIDsAndActionBindingsDecodeAndMigrate() throws {
        let legacyButton = try JSONDecoder().decode(GameTouchButton.self,
            from: Data(#"{"id":"a","binding":{"action":{"_0":"confirm"}},"visible":true}"#.utf8))
        XCTAssertEqual(legacyButton.id, .a)
        XCTAssertEqual(legacyButton.binding, .action(.confirm))
        XCTAssertEqual(legacyButton.mode, .hold)

        let json = #"{"engine":"rpgMakerMZ","enabled":true,"stick":"directionPad","leftHanded":false,"movementKeys":"engineDefault","scale":1,"opacity":0.65,"deadZone":0.18,"buttons":[{"id":"a","binding":{"action":{"_0":"confirm"}},"visible":true},{"id":"b","binding":{"action":{"_0":"action1"}},"visible":true},{"id":"x","binding":{"key":{"_0":"z"}},"visible":false}]}"#
        let profile = try JSONDecoder().decode(GameTouchProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.defaultSource, .legacyMigration)
        XCTAssertEqual(profile.button(id: .a)?.binding, GameTouchBinding.key(.enter))
        XCTAssertEqual(profile.button(id: .b)?.binding, GameTouchBinding.key(.z))
        XCTAssertEqual(profile.button(id: .x)?.binding, GameTouchBinding.key(.z))
        XCTAssertEqual(profile.button(id: .x)?.visible, false)
        XCTAssertEqual(profile.directionBinding(for: .left)?.keys, [.left])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    }

    func testEngineKeyboardDefaultsDifferForRPGMakerTIC80WASM4AndRenPy() throws {
        let rpg = GameTouchProfile.standard(.rpgMakerMZ)
        XCTAssertEqual(rpg.buttons.map(\.binding), [.key(.z), .key(.x), .key(.shift), .key(.q), .key(.w)])
        XCTAssertEqual(rpg.buttons.map { $0.binding.keyCap }, ["Z", "X", "Shift", "Q", "W"])
        XCTAssertEqual(rpg.directionBinding(for: .left)?.keys, [.left])
        XCTAssertEqual(rpg.directionBinding(for: .right)?.keys, [.right])
        XCTAssertEqual(rpg.stick, .directionPad)
        XCTAssertEqual(rpg.keyboardTransport, .browser)

        let tic = GameTouchProfile.standard(.tic80)
        XCTAssertEqual(tic.buttons.map(\.binding), [.key(.z), .key(.x), .key(.a), .key(.s)])
        let wasm = GameTouchProfile.standard(.wasm4)
        XCTAssertEqual(wasm.buttons.map(\.binding), [.key(.x), .key(.z)])
        XCTAssertEqual(GameTouchDefaults.catalog(for: .wasm4).source, .engineDefault)

        let renpy = GameTouchProfile.standard(.renpy)
        XCTAssertEqual(renpy.stick, .none)
        XCTAssertNil(renpy.directionBinding(for: .left))
        XCTAssertEqual(renpy.buttons.map(\.binding),
                       [.key(.space), .key(.enter), .key(.escape), .key(.control), .key(.tab), .key(.pageUp), .key(.h)])
        XCTAssertEqual(GameTouchDefaults.catalog(for: .renpy).reference,
                       "https://www.renpy.org/doc/html/keymap.html")

        XCTAssertEqual(GameTouchDefaults.catalog(for: .phaser).source, .templateFallback)
        XCTAssertTrue(GameTouchDefaults.catalog(for: .phaser).buttons.isEmpty)
        XCTAssertEqual(GameTouchDefaults.catalog(for: .ink).source, .templateFallback)
        XCTAssertEqual(GameTouchDefaults.catalog(for: .rpgMakerXP).source, .engineDefault)
        // The reviewed RGSS1 keybindings.cpp maps Z to A and C to confirm;
        // RGSS2+ changes Z to confirm. Do not apply the MZ map to XP.
        XCTAssertEqual(GameTouchProfile.standard(.rpgMakerXP).buttons.first?.binding, .key(.c))
        XCTAssertEqual(GameTouchProfile.standard(.rpgMakerVX).buttons.first?.binding, .key(.z))
    }

    func testProjectDeclarationOverridesMovementAndEmptyButtons() throws {
        let json = #"{"schemaVersion":1,"engine":"phaser","movement":{"left":["KeyA"],"right":["d"],"up":[],"down":[]},"buttons":[]}"#
        let bindings = try GameTouchProjectBindings(json: Data(json.utf8), engine: .phaser)
        let profile = GameTouchProfile.standard(.phaser, projectBindings: bindings)
        XCTAssertEqual(profile.defaultSource, .projectDeclaration)
        XCTAssertEqual(profile.directionBinding(for: .left)?.keys, [.a])
        XCTAssertEqual(profile.directionBinding(for: .right)?.keys, [.d])
        XCTAssertNil(profile.directionBinding(for: .up))
        XCTAssertNil(profile.directionBinding(for: .down))
        XCTAssertTrue(profile.buttons.isEmpty)
        XCTAssertEqual(profile.stick, .directionPad)
        XCTAssertEqual(profile.movementKeys, .engineDefault)

        let empty = try GameTouchProjectBindings(
            json: Data(#"{"schemaVersion":1,"engine":"ink","movement":{},"buttons":[]}"#.utf8), engine: .ink)
        let narrative = GameTouchProfile.standard(.ink, projectBindings: empty)
        XCTAssertEqual(narrative.stick, .none)
        XCTAssertNil(narrative.directionBinding(for: .left))

        var custom = profile
        try custom.setDirectionBinding(nil, for: .left)
        XCTAssertEqual(custom.movementKeys, .custom)
        XCTAssertNil(custom.directionBinding(for: .left))
        let chord = try GameTouchChord(keys: [.z])
        XCTAssertThrowsError(try custom.setDirectionBinding(chord, for: .confirm))
    }

    func testProjectDeclarationParsesAliasesAndRejectsUnknownOrUnboundedContent() throws {
        let movementOnly = try GameTouchProjectBindings(
            json: Data(#"{"schemaVersion":1,"engine":"ink","movement":{"up":["up"],"down":[]},"buttons":[]}"#.utf8),
            engine: .ink)
        XCTAssertEqual(movementOnly.movement.up?.keys, [.up])
        XCTAssertNil(movementOnly.movement.down)
        XCTAssertTrue(movementOnly.buttons.isEmpty)

        let json = #"{"schemaVersion":1,"engine":"phaser","movement":{"left":["KeyA"],"right":["ArrowRight"]},"buttons":[{"id":"confirm","label":"Z","keys":["KeyZ"]},{"id":"chord","keys":["ShiftLeft","pageUp"]}]}"#
        let aliases = try GameTouchProjectBindings(json: Data(json.utf8), engine: .phaser)
        XCTAssertEqual(aliases.movement.left?.keys, [.a])
        XCTAssertEqual(aliases.movement.right?.keys, [.right])
        XCTAssertEqual(aliases.buttons[0].binding, GameTouchBinding.key(.z))
        XCTAssertEqual(aliases.buttons[1].binding, GameTouchBinding.chord(try GameTouchChord(keys: [.shift, .pageUp])))
        XCTAssertEqual(aliases.buttons[0].label, "Z")

        let invalid = [
            #"{"schemaVersion":1,"engine":"unity","movement":{},"buttons":[]}"#,
            #"{"schemaVersion":2,"engine":"phaser","movement":{},"buttons":[]}"#,
            #"{"schemaVersion":1,"engine":"phaser","movement":{},"buttons":[],"script":"run()"}"#,
            #"{"schemaVersion":1,"engine":"phaser","movement":{"jump":["space"]},"buttons":[]}"#,
            #"{"schemaVersion":1,"engine":"phaser","movement":{"left":["NotAKey"]},"buttons":[]}"#,
            #"{"schemaVersion":1,"engine":"phaser","movement":{},"buttons":[{"id":"confirm","keys":["z"]},{"id":"confirm","keys":["x"]}]}"#,
            #"{"schemaVersion":1,"engine":"phaser","movement":{},"buttons":[{"id":"confirm","keys":[],"extra":true}]}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try GameTouchProjectBindings(json: Data(json.utf8), engine: .phaser), json)
        }
        let tooLarge = Data(repeating: 0x20, count: GameTouchProjectBindings.maximumDeclarationBytes + 1)
        XCTAssertThrowsError(try GameTouchProjectBindings(json: tooLarge, engine: .phaser))
    }

    func testOverlappingChordsAndSeparateCtrlUsePhysicalKeyReferenceCounts() async throws {
        var profile = GameTouchProfile.standard(.godot)
        let ctrlZ = try GameTouchButton.ID("test.ctrlZ")
        let ctrlX = try GameTouchButton.ID("test.ctrlX")
        let ctrl = try GameTouchButton.ID("test.ctrl")
        try profile.add(GameTouchButton(id: ctrlZ, binding: .chord(try GameTouchChord(keys: [.control, .z]))))
        try profile.add(GameTouchButton(id: ctrlX, binding: .chord(try GameTouchChord(keys: [.control, .x]))))
        try profile.add(GameTouchButton(id: ctrl, binding: .key(.control)))
        let sink = Sink(), service = GameTouchInputService(profile: profile); await service.attach(sink)

        service.button(ctrlZ, pressed: true); await service.flush()
        service.button(ctrlX, pressed: true); await service.flush()
        XCTAssertEqual(sink.events, [.key(.control, true), .key(.z, true), .key(.x, true)])
        service.button(ctrlZ, pressed: false); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.z, false))
        service.button(ctrlX, pressed: false); await service.flush()
        XCTAssertEqual(sink.events.filter { $0.binding == .key(.control) },
                       [.key(.control, true), .key(.control, false)])
        XCTAssertEqual(sink.events.last, Sink.Event.key(.control, false))

        await service.releaseAll(); sink.events.removeAll()
        service.button(ctrl, pressed: true); await service.flush()
        service.button(ctrlZ, pressed: true); await service.flush()
        service.button(ctrlZ, pressed: false); await service.flush()
        XCTAssertEqual(sink.events.filter { $0.binding == .key(.control) }, [.key(.control, true)])
        service.button(ctrl, pressed: false); await service.flush()
        XCTAssertEqual(sink.events.filter { $0.binding == .key(.control) },
                       [.key(.control, true), .key(.control, false)])

        sink.events.removeAll()
        service.button(ctrlZ, pressed: true); await service.flush(); sink.events.removeAll()
        await service.releaseAll()
        XCTAssertEqual(sink.events, [.key(.z, false), .key(.control, false)])
    }

    func testCustomDirectionChordsAndUnboundAxesReachTheService() async throws {
        var profile = GameTouchProfile.standard(.godot)
        try profile.setDirectionBinding(try GameTouchChord(keys: [.control, .z]), for: .left)
        try profile.clearDirectionBinding(for: .right)
        XCTAssertEqual(profile.movementKeys, .custom)
        let sink = Sink(), service = GameTouchInputService(profile: profile); await service.attach(sink)
        service.direction(.left, pressed: true); await service.flush()
        XCTAssertEqual(sink.events, [.key(.control, true), .key(.z, true)])
        service.direction(.left, pressed: false); await service.flush()
        XCTAssertEqual(Array(sink.events.suffix(2)), [.key(.z, false), .key(.control, false)])
        sink.events.removeAll()
        service.direction(.right, pressed: true); await service.flush()
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testTapToggleModesPublishActiveStateAndReleaseOnDetach() async throws {
        var profile = GameTouchProfile.standard(.godot)
        let tapID = try GameTouchButton.ID("test.tap")
        let toggleID = try GameTouchButton.ID("test.toggle")
        try profile.add(GameTouchButton(id: tapID, binding: .key(.space), mode: .tap))
        try profile.add(GameTouchButton(id: toggleID, binding: .key(.enter), mode: .toggle))
        let sink = Sink(), service = GameTouchInputService(profile: profile); await service.attach(sink)

        service.button(tapID, pressed: true); await service.flush()
        XCTAssertEqual(sink.events, [.key(.space, true)])
        XCTAssertTrue(service.activeButtonIDs.contains(tapID))
        try await Task.sleep(for: .milliseconds(300))
        await service.flush()
        XCTAssertEqual(sink.events, [.key(.space, true), .key(.space, false)])
        XCTAssertFalse(service.activeButtonIDs.contains(tapID))

        service.button(toggleID, pressed: true); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, true))
        XCTAssertTrue(service.activeButtonIDs.contains(toggleID))
        service.button(toggleID, pressed: false); await service.flush()
        XCTAssertTrue(service.activeButtonIDs.contains(toggleID))
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, true))
        service.button(toggleID, pressed: true); await service.flush()
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, false))
        XCTAssertFalse(service.activeButtonIDs.contains(toggleID))

        service.button(toggleID, pressed: true); await service.flush()
        XCTAssertTrue(service.activeButtonIDs.contains(toggleID))
        await service.detach()
        XCTAssertFalse(service.activeButtonIDs.contains(toggleID))
        XCTAssertEqual(sink.events.last, Sink.Event.key(.enter, false))
    }

    func testSettingsAreSeparatePerEngineAndTransportWithPerSlotCAS() async throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = GameProjectOwner.space(recordID: id)
        let store = try GameTouchProfileStore(directory: root, projectID: id, owner: owner)
        var browser = GameTouchProfile.standard(.rpgMakerMZ)
        browser.leftHanded = true
        try browser.adjust(opacity: 0.4)
        var x11 = GameTouchProfile.standard(.rpgMakerMZ, keyboardTransport: .x11)
        x11.enabled = false
        var phaser = GameTouchProfile.standard(.phaser)
        phaser.leftHanded = true

        let browserRevision = try await store.save(browser, expectedRevision: 0)
        let x11Revision = try await store.save(x11, expectedRevision: 0)
        let phaserRevision = try await store.save(phaser, expectedRevision: 0)
        XCTAssertEqual(browserRevision, 1)
        XCTAssertEqual(x11Revision, 1)
        XCTAssertEqual(phaserRevision, 1)

        let loadBrowser = try await store.load(engine: .rpgMakerMZ, keyboardTransport: .browser)
        XCTAssertEqual(loadBrowser.profile, browser)
        XCTAssertEqual(loadBrowser.revision, 1)
        let loadX11 = try await store.load(engine: .rpgMakerMZ, keyboardTransport: .x11)
        XCTAssertEqual(loadX11.profile, x11)
        let loadPhaser = try await store.load(engine: .phaser)
        XCTAssertEqual(loadPhaser.profile, phaser)

        do {
            _ = try await store.save(browser, expectedRevision: 0)
            XCTFail("Expected per-slot stale settings failure")
        } catch {
            XCTAssertEqual(error as? GameProjectError, .conflict(expected: "0", actual: "1"))
        }
    }

    func testCallerDefaultsAreReturnedButNeverOverwriteUserSettings() async throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = GameProjectOwner.space(recordID: id)
        let store = try GameTouchProfileStore(directory: root, projectID: id, owner: owner)
        let json = #"{"schemaVersion":1,"engine":"phaser","movement":{"left":["KeyA"],"right":["KeyD"]},"buttons":[{"id":"jump","label":"Space","keys":["space"]}]}"#
        let declared = try GameTouchProjectBindings(json: Data(json.utf8), engine: .phaser)
        let projectDefault = GameTouchProfile.standard(.phaser, projectBindings: declared)

        let first = try await store.load(engine: .phaser, defaults: projectDefault)
        XCTAssertEqual(first.profile, projectDefault)
        XCTAssertEqual(first.revision, 0)
        var custom = first.profile
        custom.enabled = false
        let savedRevision = try await store.save(custom, expectedRevision: 0)
        XCTAssertEqual(savedRevision, 1)
        let second = try await store.load(engine: .phaser, defaults: projectDefault)
        XCTAssertEqual(second.profile, custom)
        XCTAssertEqual(second.revision, 1)
        XCTAssertTrue(projectDefault.enabled)

        do {
            _ = try await store.load(engine: .godot, defaults: projectDefault)
            XCTFail("Expected mismatched defaults to be rejected")
        } catch {
            XCTAssertEqual(error as? GameProjectError, .invalidContext)
        }
    }

    func testLegacySingleFileProfileIsReadMigratedAndNeverDeleted() async throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = GameProjectOwner.space(recordID: id)
        let legacy = try FileGameSaveRepository(directory: root, projectID: id, owner: owner, maximumStateBytes: 262_144)
        let json = #"{"engine":"rpgMakerMZ","enabled":true,"stick":"directionPad","leftHanded":false,"movementKeys":"engineDefault","scale":1,"opacity":0.65,"deadZone":0.18,"buttons":[{"id":"a","binding":{"action":{"_0":"confirm"}},"visible":true},{"id":"b","binding":{"key":{"_0":"z"}},"visible":true}]}"#
        _ = try await legacy.save(Data(json.utf8), expectedRevision: 0)

        let store = try GameTouchProfileStore(directory: root, projectID: id, owner: owner)
        let loaded = try await store.load(engine: .rpgMakerMZ)
        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(loaded.profile.defaultSource, .legacyMigration)
        XCTAssertEqual(loaded.profile.button(id: .a)?.binding, GameTouchBinding.key(.enter))
        XCTAssertEqual(loaded.profile.button(id: .b)?.binding, GameTouchBinding.key(.z))
        XCTAssertEqual(loaded.profile.directionBinding(for: .left)?.keys, [.left])

        let savedRevision = try await store.save(loaded.profile, expectedRevision: 0)
        XCTAssertEqual(savedRevision, 1)
        let legacyAfter = try await legacy.load()
        let legacyCheckpoint = try XCTUnwrap(legacyAfter)
        let legacyProfile = try JSONDecoder().decode(GameTouchProfile.self, from: legacyCheckpoint.state)
        XCTAssertEqual(legacyProfile.engine, .rpgMakerMZ)
        XCTAssertEqual(legacyCheckpoint.revision, 1)
        let reloaded = try await store.load(engine: .rpgMakerMZ)
        XCTAssertEqual(reloaded.revision, 1)
        XCTAssertEqual(reloaded.profile, loaded.profile)
    }
}
