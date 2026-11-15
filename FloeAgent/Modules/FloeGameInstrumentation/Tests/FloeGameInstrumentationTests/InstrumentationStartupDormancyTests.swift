// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameInstrumentation

@Test func unityMissingStartupHostCheckCannotBeInstalled() async throws {
    let base = try GameDeveloperInstrumentationTemplates()
    let original = try #require(String(data: base.unityBehaviour.data, encoding: .utf8))
    let changed = original.replacingOccurrences(of: "!FloeDeveloperBridge.HostAvailable", with: "false")
    let templates = try InstrumentationFixture.templates(unityBehaviour: Data(changed.utf8))
    #expect(throws: GameDeveloperInstrumentationError.self) { try templates.dormancy(for: .unity) }
}

@Test func godotMissingInitialProcessingDisableCannotBeInstalled() async throws {
    let base = try GameDeveloperInstrumentationTemplates()
    let original = try #require(String(data: base.godotAutoload.data, encoding: .utf8))
    let changed = original.replacingOccurrences(of: "set_process(false)", with: "set_process(true)")
    let templates = try InstrumentationFixture.templates(godot: Data(changed.utf8))
    #expect(throws: GameDeveloperInstrumentationError.self) { try templates.dormancy(for: .godot) }
}
