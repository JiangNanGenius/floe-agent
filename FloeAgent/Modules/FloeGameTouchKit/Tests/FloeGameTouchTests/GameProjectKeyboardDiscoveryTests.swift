// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameWebKit
@testable import FloeGameTouch

struct GameProjectKeyboardDiscoveryTests {
    private func source(_ path: String, _ text: String) throws -> GameProjectKeyboardDiscovery.Source {
        .init(path: try GameRelativePath(path), data: Data(text.utf8))
    }
    private func json(_ candidate: GameProjectKeyboardDiscovery.Candidate) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: candidate.declaration) as? [String: Any])
    }
    @Test func readsGodotPhysicalKeysAndModifiersWithoutLoadingResources() throws {
        let project = """
        config_version=5
        [input]
        move_left={"events":[Object(InputEventKey,"physical_keycode":65,"keycode":0)]}
        move_right={"events":[Object(InputEventKey,"physical_keycode":68,"keycode":0)]}
        move_up={"events":[Object(InputEventKey,"physical_keycode":87,"keycode":0)]}
        move_down={"events":[Object(InputEventKey,"physical_keycode":83,"keycode":0)]}
        interact={"events":[Object(InputEventKey,"physical_keycode":69,"ctrl_pressed":true,"resource_name":"quoted ) , \\"keycode\\":90","script":Resource("never-load.gd"))]}
        [rendering]
        renderer/rendering_method="gl_compatibility"
        """
        let candidates = try GameProjectKeyboardDiscovery.discover(engine: .godot, sources: [source("nested/project.godot", project)])
        let result = try json(#require(candidates.first))
        #expect(candidates.count == 1)
        #expect(result["movement"] as? [String: [String]] == ["left": ["a"], "right": ["d"], "up": ["w"], "down": ["s"]])
        let buttons = try #require(result["buttons"] as? [[String: Any]])
        #expect(buttons.last?["keys"] as? [String] == ["control", "e"])
        #expect(buttons.last?["label"] as? String == "interact")
    }
    @Test func recognizesLegacyGodotAndDoesNotMergeAlternativeKeysIntoChord() throws {
        let text = """
        [input]
        confirm={"events":[Object(InputEventKey,"scancode":90,"physical_scancode":0),Object(InputEventKey,"scancode":16777221)]}
        rollback={"events":[Object(InputEventKey,"scancode":16777235,"shift":true)]}
        fake={"description":"Object(InputEventKey,\\"scancode\\":88)","events":[]}
        """
        let candidate = try #require(GameProjectKeyboardDiscovery.discover(engine: .godot, sources: [source("project.godot", text)]).first)
        let buttons = try #require(json(candidate)["buttons"] as? [[String: Any]])
        #expect(buttons.count == 3)
        #expect(buttons[0]["keys"] as? [String] == ["z"])
        #expect(buttons[1]["keys"] as? [String] == ["enter"])
        #expect(buttons[2]["keys"] as? [String] == ["shift", "pageUp"])
    }
    @Test func preservesUnityActionMapChoiceAndReadsComposites() throws {
        let asset: [String: Any] = ["maps": [
            ["name": "Player", "bindings": [
                ["action": "Move", "path": "2DVector", "isComposite": true],
                ["action": "Move", "name": "up", "path": "<Keyboard>/w", "isPartOfComposite": true],
                ["action": "Move", "name": "down", "path": "<Keyboard>/s", "isPartOfComposite": true],
                ["action": "Move", "name": "left", "path": "<Keyboard>/a", "isPartOfComposite": true],
                ["action": "Move", "name": "right", "path": "<Keyboard>/d", "isPartOfComposite": true],
                ["action": "Use", "path": "OneModifier", "isComposite": true],
                ["action": "Use", "name": "Modifier", "path": "<Keyboard>/leftCtrl", "isPartOfComposite": true],
                ["action": "Use", "name": "Binding", "path": "<Keyboard>/e", "isPartOfComposite": true],
                ["action": "Jump", "path": "<Gamepad>/buttonSouth"]
            ]],
            ["name": "UI", "bindings": [["action": "Submit", "path": "<Keyboard>/enter"]]]
        ]]
        let file = GameProjectKeyboardDiscovery.Source(path: try GameRelativePath("Assets/Controls.inputactions"), data: try JSONSerialization.data(withJSONObject: asset))
        let candidates = try GameProjectKeyboardDiscovery.discover(engine: .unity, sources: [file])
        #expect(candidates.count == 2)
        #expect(candidates[0].id != candidates[1].id)
        let result = try json(candidates[0])
        #expect((result["movement"] as? [String: [String]])?["left"] == ["a"])
        let buttons = try #require(result["buttons"] as? [[String: Any]])
        #expect(buttons.last?["keys"] as? [String] == ["control", "e"])
        #expect((try json(candidates[1])["buttons"] as? [[String: Any]])?.count == 1)
    }
    @Test func readsUnityLegacyAxesAndKeepsProjectAlternatives() throws {
        let yaml = """
        %YAML 1.1
        --- !u!13 &1
        InputManager:
          m_Axes:
          - serializedVersion: 3
            m_Name: Horizontal
            negativeButton: left
            positiveButton: right
            altNegativeButton: a
            altPositiveButton: d
            type: 0
          - serializedVersion: 3
            m_Name: Vertical
            negativeButton: down
            positiveButton: up
            type: 0
          - serializedVersion: 3
            m_Name: Jump
            positiveButton: space
            type: 0
          - serializedVersion: 3
            m_Name: Gamepad
            positiveButton: joystick button 0
            type: 2
        """
        let candidate = try #require(GameProjectKeyboardDiscovery.discover(engine: .unity, sources: [source("ProjectSettings/InputManager.asset", yaml)]).first)
        #expect(candidate.warnings.contains(.multipleMovementBindings))
        let result = try json(candidate)
        #expect((result["movement"] as? [String: [String]])?["left"] == ["left"])
        #expect((result["buttons"] as? [[String: Any]])?.last?["keys"] as? [String] == ["space"])
    }
    @Test func rejectsOversizeAndMismatchedEngineInsteadOfRunningCode() throws {
        let bytes = Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)
        #expect(throws: GameProjectKeyboardDiscovery.Failure.limitExceeded) {
            _ = try GameProjectKeyboardDiscovery.discover(engine: .godot, sources: [.init(path: GameRelativePath("project.godot"), data: bytes)])
        }
        let mismatch = try source("floe-inputs.json", #"{"schemaVersion":1,"engine":"unity","movement":{},"buttons":[]}"#)
        #expect(throws: (any Error).self) { _ = try GameProjectKeyboardDiscovery.discover(engine: .godot, sources: [mismatch]) }
        let unbalanced = try source("project.godot", "[input]\nleft={\"events\":[Object(InputEventKey,\"keycode\":65)]\n")
        #expect(throws: GameProjectKeyboardDiscovery.Failure.malformedDeclaration) {
            _ = try GameProjectKeyboardDiscovery.discover(engine: .godot, sources: [unbalanced])
        }
    }
}
