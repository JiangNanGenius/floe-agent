// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameDeveloperCore
import FloeGameCore

@Test func catalogContainsEveryEngineExactlyOnce() throws {
    let descriptors = try GameDeveloperEngineCatalog.validated()
    #expect(descriptors.count == GameEngineID.authoringEngines.count)
    #expect(Set(descriptors.map(\.engine)) == Set(GameEngineID.authoringEngines))
    for descriptor in descriptors {
        #expect(descriptor.hookID == descriptor.engine.rawValue)
        #expect(!descriptor.instrumentation.summary.isEmpty)
        #expect(!descriptor.instrumentation.steps.isEmpty)
        #expect(!descriptor.instrumentation.limitations.isEmpty)
        #expect(!descriptor.instrumentation.officialDocumentation.isEmpty)
        #expect(!descriptor.notes.isEmpty)
    }
}

@Test func everyEngineHasAHostHookAndReferencedTemplate() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FloeGameDeveloperKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FloeGameDeveloperKit
    let hooks = packageRoot
        .deletingLastPathComponent()
        .appendingPathComponent("FloeGameKit/Sources/FloeGameWebKit/Resources/Developer/Hooks")
    let project = packageRoot.appendingPathComponent("Sources/FloeGameDeveloperCore/Resources/Project")
    for descriptor in try GameDeveloperEngineCatalog.validated() {
        let hook = hooks.appendingPathComponent(descriptor.engine.rawValue + ".js")
        let text = try String(contentsOf: hook, encoding: .utf8)
        #expect(text.contains("FloeDeveloper"))
        for file in descriptor.instrumentation.files {
            if let template = file.templateResource {
                let url = project.appendingPathComponent(template.replacingOccurrences(of: "Project/", with: ""))
                let bytes = try Data(contentsOf: url)
                #expect(!bytes.isEmpty, "template \(template) for \(descriptor.engine.rawValue)")
            }
        }
    }
}

@Test func legacyRGPMakerUsesTheRealGuestBridge() throws {
    for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
        let descriptor = try GameDeveloperEngineCatalog.descriptor(for: engine)
        #expect(descriptor.support == .guestRuntimeBridge)
        #expect(descriptor.expectedSupports.liveState)
        #expect(descriptor.expectedSupports.fields)
        #expect(descriptor.expectedSupports.actions)
        #expect(descriptor.expectedSupports.snapshot)
        #expect(descriptor.expectedSupports.screenshot == false)
        #expect(descriptor.instrumentation.requiresRebuild)
    }
}

@Test func builtEnginesReportWorkingPushBridges() throws {
    for engine in [GameEngineID.godot, .unity, .gdevelop, .cocosCreator] {
        let descriptor = try GameDeveloperEngineCatalog.descriptor(for: engine)
        #expect(descriptor.support == .hostBuildHook)
        #expect(descriptor.expectedSupports.liveState)
        #expect(descriptor.expectedSupports.fields)
        #expect(descriptor.expectedSupports.actions)
        #expect(descriptor.instrumentation.requiresRebuild)
        #expect(descriptor.instrumentation.files.contains { $0.templateResource != nil })
    }
}

@Test func matrixJSONIsStableAndDecodable() throws {
    let data = GameDeveloperEngineCatalog.matrixJSON
    let matrix = try JSONDecoder().decode(GameDeveloperCapabilityMatrix.self, from: data)
    #expect(matrix.engineCount == 20)
    #expect(matrix.catalogVersion == GameDeveloperEngineCatalog.version)
    #expect(matrix.engines.count == 20)
}
