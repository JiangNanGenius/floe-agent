// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeGameTouch
import FloeGameWebKit

final class RGSSGuestKeyboardTests: XCTestCase {
    func testXPProfileMatchesTapirNativeDefaults() throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        XCTAssertEqual(Set(map.keys(for: .c)), Set([.c, .enter, .space]))
        XCTAssertEqual(Set(map.keys(for: .a)), Set([.z, .shift, .rightShift]))
        XCTAssertEqual(Set(map.keys(for: .b)), Set([.x, .escape]))
        XCTAssertEqual(map.keys(for: .l), [.q])
        XCTAssertEqual(map.keys(for: .r), [.w])
        XCTAssertTrue(map.keys(for: .c).contains(.c))
    }

    func testVXAndAceDoNotBindPhysicalCAsConfirm() throws {
        for engine in [GameEngineID.rpgMakerVX, .rpgMakerVXAce] {
            let map = try RGSSGuestKeymap.standard(engine: engine)
            XCTAssertEqual(Set(map.keys(for: .c)), Set([.z, .enter, .space]))
            XCTAssertEqual(Set(map.keys(for: .a)), Set([.shift, .rightShift]))
            XCTAssertFalse(map.keys(for: .c).contains(.c),
                           "physical C is unbound for VX/VX Ace")
        }
    }


    func testLegacyStandardDeclarationNormalizesToPerKeyButtons() throws {
        // Literal legacy writer output: this fixture must not track the newly
        // corrected single-key SDK standard and accidentally rename its IDs.
        let data = Data("""
        {"schemaVersion":1,"engine":"rpgMakerXP",
         "movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},
         "buttons":[{"id":"confirm","label":"C","keys":["c","enter","space"]},
          {"id":"cancel","label":"X","keys":["x","escape"]},
          {"id":"action1","label":"Z/Shift","keys":["z","shift"]},
          {"id":"action2","label":"Q","keys":["q"]},
          {"id":"action3","label":"W","keys":["w"]}]}
        """.utf8)
        let normalized = try XCTUnwrap(RGSSGuestInputDeclarationMigration.normalizedStandard(
            data, engine: .rpgMakerXP))
        let bindings = try GameTouchProjectBindings(json: normalized, engine: .rpgMakerXP)
        XCTAssertTrue(bindings.buttons.allSatisfy {
            ($0.binding.keyboardKeys ?? []).count == 1
        }, "alternative keys must not become one simultaneous chord")
        XCTAssertTrue(bindings.buttons.contains { $0.id.rawValue == "confirm.c" })
        XCTAssertTrue(bindings.buttons.contains { $0.id.rawValue == "confirm.enter" })
        XCTAssertTrue(bindings.buttons.contains { $0.id.rawValue == "confirm.space" })
    }

    func testCorrectedStandardDeclarationRetainsButtonIdentifiers() throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let data = try RGSSInputDeclaration.standard(for: engine).jsonData()
            XCTAssertNil(try RGSSGuestInputDeclarationMigration.normalizedStandard(data, engine: engine))
            let bindings = try GameTouchProjectBindings(json: data, engine: engine)
            XCTAssertEqual(bindings.buttons.first?.id.rawValue, "confirm")
            XCTAssertTrue(bindings.buttons.allSatisfy { $0.binding.keyboardKeys?.count == 1 })
        }
    }

    func testEngineStandardButtonsAreSingleKeysWithStablePrimaryChoice() async throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let map = try RGSSGuestKeymap.standard(engine: engine)
            XCTAssertTrue(map.standardButtons.allSatisfy { $0.keys.count == 1 })
            let confirm: GameKeyboardKey = engine == .rpgMakerXP ? .c : .z
            XCTAssertEqual(map.chord(forButtonID: "c"), [confirm])
            XCTAssertEqual(map.keys(for: .c).first, confirm)
            let port = RecordingInputPort()
            let input = RGSSGuestPhysicalInputSession(port: port, keymap: map)
            try await input.sendButton("c")
            let events = await port.events
            XCTAssertEqual(events, [.down(confirm)])
            await input.invalidate()
        }
    }

    func testCustomModifierChordDoesNotTriggerLegacyMigration() throws {
        let data = Data("""
        {"schemaVersion":1,"engine":"rpgMakerXP",
         "movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},
         "buttons":[{"id":"undo","label":"Undo","keys":["control","z"]}]}
        """.utf8)
        XCTAssertNil(try RGSSGuestInputDeclarationMigration.normalizedStandard(data, engine: .rpgMakerXP))
        let bindings = try GameTouchProjectBindings(json: data, engine: .rpgMakerXP)
        let map = try RGSSGuestKeymap(engine: .rpgMakerXP,
            profile: .standard(for: .rgss1), declaration: bindings)
        XCTAssertEqual(map.chord(forButtonID: "undo"), [.control, .z])
    }

    func testFailedKeyReleaseIsRetainedForRetryAndBlocksNewChord() async throws {
        let port = RetryReleaseInputPort()
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let input = RGSSGuestPhysicalInputSession(port: port, keymap: map)
        try await input.sendPhysicalChord([.z])
        await input.releaseAll()
        let held = await input.currentPressedKeys
        let failure = await input.lastReleaseError
        XCTAssertEqual(held, [.z])
        XCTAssertNotNil(failure)
        do { try await input.sendPhysicalChord([.right]); XCTFail("unreleased prior key") }
        catch {}
        let beforeRetry = await port.events
        XCTAssertEqual(beforeRetry, ["down:z", "up:z"])
        await input.releaseAll()
        let afterRetry = await input.currentPressedKeys
        let resolved = await input.lastReleaseError
        XCTAssertTrue(afterRetry.isEmpty)
        XCTAssertNil(resolved)
        try await input.sendPhysicalChord([.right])
        await input.invalidate()
    }

    func testLiftingOneButtonKeepsDirectionAndModifierHeld() async throws {
        let port = RecordingInputPort()
        let input = RGSSGuestPhysicalInputSession(port: port,
            keymap: try .standard(engine: .rpgMakerXP))
        try await input.sendPhysicalChord([.shift, .left, .z])
        try await input.setPhysicalKey(.z, pressed: false)
        let held = await input.currentPressedKeys
        let events = await port.events
        XCTAssertEqual(Set(held), Set([.shift, .left]))
        XCTAssertEqual(events.last, .up(.z))
        XCTAssertFalse(events.contains(.up(.left)))
        XCTAssertFalse(events.contains(.up(.shift)))
        await input.invalidate()
    }

    func testIndividualFailedReleaseCanRetryWithoutLiftingOtherControl() async throws {
        let port = RetryReleaseInputPort()
        let input = RGSSGuestPhysicalInputSession(port: port,
            keymap: try .standard(engine: .rpgMakerXP))
        try await input.sendPhysicalChord([.left, .z])
        do { try await input.setPhysicalKey(.z, pressed: false); XCTFail("failed transport") }
        catch {}
        let before = await input.currentPressedKeys
        XCTAssertEqual(Set(before), Set([.left, .z]))
        try await input.setPhysicalKey(.z, pressed: false)
        let after = await input.currentPressedKeys
        let releaseError = await input.lastReleaseError
        XCTAssertEqual(after, [.left])
        XCTAssertNil(releaseError)
        let events = await port.events
        XCTAssertFalse(events.contains("up:left"))
        await input.invalidate()
    }

    func testLateOldKeyUpCannotReleaseNewRunsIdenticalKey() async throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let oldPort = RecordingInputPort()
        let newPort = RecordingInputPort()
        let old = RGSSGuestPhysicalInputSession(port: oldPort, keymap: map)
        let newer = RGSSGuestPhysicalInputSession(port: newPort, keymap: map)
        try await old.setPhysicalKey(.z, pressed: true)
        await old.invalidate()
        try await newer.setPhysicalKey(.z, pressed: true)
        try await old.setPhysicalKey(.z, pressed: false)
        let held = await newer.currentPressedKeys
        let events = await newPort.events
        XCTAssertEqual(held, [.z])
        XCTAssertEqual(events, [.down(.z)])
        await newer.invalidate()
    }

    func testProjectDeclarationSupportsArbitraryKeysAndChords() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "engine": "rpgMakerXP",
          "movement": {
            "left": ["KeyA"],
            "right": ["KeyD"],
            "up": ["KeyW"],
            "down": ["KeyS"]
          },
          "buttons": [
            {"id": "confirm", "label": "Confirm", "keys": ["KeyZ"]},
            {"id": "dash", "label": "Dash", "keys": ["ShiftLeft", "KeyZ"]},
            {"id": "menu", "label": "Menu", "keys": ["F2"]}
          ]
        }
        """.utf8)
        let declaration = try GameTouchProjectBindings(json: json, engine: .rpgMakerXP)
        let profile = RGSSGuestInputProfile.standard(for: .rgss1)
        let map = try RGSSGuestKeymap(engine: .rpgMakerXP, profile: profile,
                                      declaration: declaration)
        XCTAssertEqual(map.chord(forButtonID: "confirm"), [.z])
        XCTAssertEqual(map.chord(forButtonID: "dash"), [.shift, .z],
                       "modifier is ordered before the key")
        XCTAssertEqual(map.chord(forButtonID: "menu"), [.f2])
        XCTAssertEqual(map.chord(forButtonID: "left"), [.a])
        XCTAssertTrue(map.allButtons.contains { $0.origin == .projectDeclaration })
    }

    func testInputSessionSendsHeldKeysAndReleasesOnlyItsOwnKeys() async throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let port = RecordingInputPort()
        let input = RGSSGuestPhysicalInputSession(port: port, keymap: map)
        try await input.sendPhysicalChord([.shift, .left])
        let downEvents = await port.events
        XCTAssertEqual(downEvents, [.down(.shift), .down(.left)])
        await input.releaseAll()
        let events = await port.events
        XCTAssertEqual(Array(events.suffix(2)), [.up(.left), .up(.shift)])
    }

    func testInputSessionCompensatesFailedKeyDown() async throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let port = RecordingInputPort(failOn: .z)
        let input = RGSSGuestPhysicalInputSession(port: port, keymap: map)
        do {
            try await input.sendPhysicalChord([.shift, .z])
            XCTFail("the failed key must throw")
        } catch {}
        let events = await port.events
        XCTAssertTrue(events.contains(.down(.shift)))
        XCTAssertTrue(events.contains(.up(.shift)),
                      "the attempted down is released after the failure")
        let pressed = await input.currentPressedKeys
        XCTAssertEqual(pressed, [])
    }

    func testInvalidatedInputRefusesNewKeys() async throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let input = RGSSGuestPhysicalInputSession(port: RecordingInputPort(), keymap: map)
        await input.invalidate()
        do {
            try await input.sendPhysicalChord([.z])
            XCTFail("invalidated input must refuse")
        } catch let error as RGSSGuestRunError {
            XCTAssertEqual(error, .sessionNotActive)
        }
    }

    func testUnknownProjectButtonIsRejected() async throws {
        let map = try RGSSGuestKeymap.standard(engine: .rpgMakerXP)
        let input = RGSSGuestPhysicalInputSession(port: RecordingInputPort(), keymap: map)
        do {
            try await input.sendButton("missing")
            XCTFail("unknown button must fail")
        } catch let error as RGSSGuestRunError {
            XCTAssertEqual(error, .inputUnavailable("unknown button missing"))
        }
    }
}

private actor RetryReleaseInputPort: RGSSGuestPhysicalInputPort {
    enum Failure: Error { case transport }
    private var failFirstRelease = true
    private(set) var events: [String] = []
    func keyDown(_ key: GameKeyboardKey) async throws { events.append("down:\(key.rawValue.lowercased())") }
    func keyUp(_ key: GameKeyboardKey) async throws {
        events.append("up:\(key.rawValue.lowercased())")
        if failFirstRelease { failFirstRelease = false; throw Failure.transport }
    }
    func releaseAll() async {}
}

private actor RecordingInputPort: RGSSGuestPhysicalInputPort {
    enum Event: Equatable, Sendable {
        case down(GameKeyboardKey)
        case up(GameKeyboardKey)
    }
    private(set) var events: [Event] = []
    private let failOn: GameKeyboardKey?

    init(failOn: GameKeyboardKey? = nil) {
        self.failOn = failOn
    }

    func keyDown(_ key: GameKeyboardKey) async throws {
        events.append(.down(key))
        if key == failOn {
            throw RGSSGuestRunError.inputUnavailable("synthetic failure")
        }
    }

    func keyUp(_ key: GameKeyboardKey) async throws {
        events.append(.up(key))
    }

    func releaseAll() async {}
}
