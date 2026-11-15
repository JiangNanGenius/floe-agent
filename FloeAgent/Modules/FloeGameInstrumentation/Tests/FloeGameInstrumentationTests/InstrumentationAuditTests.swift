// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameDeveloperCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

@Test func auditCoversEveryEngineWithAnExplicitGap() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: ["README.md": Data("fixture\n".utf8)])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let audit = try await instrumenter.audit()
    #expect(audit.entries.count == 20)
    #expect(Set(audit.entries.map { $0.engine }) == Set(GameEngineID.allCases))
    #expect(audit.installerEngines == [.unity, .godot, .gdevelop, .cocosCreator])
    #expect(audit.entries.allSatisfy { !$0.gap.isEmpty && !$0.gapZhHans.isEmpty })
    #expect(audit.entries.allSatisfy { $0.id == $0.engine.rawValue })
}

@Test func auditClassifiesExistingHooksAndExactInstallerGaps() async throws {
    #expect(GameDeveloperInstrumentationAudit.availability(for: .unity) == .installerAvailable)
    #expect(GameDeveloperInstrumentationAudit.availability(for: .godot) == .installerAvailable)
    for engine in [GameEngineID.gdevelop, .cocosCreator] {
        #expect(GameDeveloperInstrumentationAudit.availability(for: engine) == .installerAvailable)
    }
    #expect(GameDeveloperInstrumentationAudit.availability(for: .rpgMakerMZ) == .projectInstallerMissing)
    for engine in [GameEngineID.rpgMakerMV, .love, .renpy, .microStudio, .wasm4] {
        #expect(GameDeveloperInstrumentationAudit.availability(for: engine) == .projectBridgePresent)
    }
    for engine in [GameEngineID.phaser, .kaplay, .babylon, .playcanvas, .ink, .twine] {
        #expect(GameDeveloperInstrumentationAudit.availability(for: engine) == .runtimeHookPresent)
    }
    #expect(GameDeveloperInstrumentationAudit.availability(for: .tic80) == .snapshotOnly)
    for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
        #expect(GameDeveloperInstrumentationAudit.availability(for: engine) == .guestRuntimeBridge)
    }
}

@Test func auditClaimsExactlyTheFourReviewedInstallers() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: ["README.md": Data("fixture\n".utf8)])
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let audit = try await instrumenter.audit()
    let licensedMZ = try #require(audit.entries.first { $0.engine == .rpgMakerMZ })
    #expect(!licensedMZ.hasAutomatedInstaller)
    #expect(licensedMZ.gap.contains("no automated project installer"))
    for engine in [GameEngineID.unity, .godot, .gdevelop, .cocosCreator] {
        let entry = try #require(audit.entries.first { $0.engine == engine })
        #expect(entry.hasAutomatedInstaller)
    }
    let unity = try #require(audit.entries.first { $0.engine == .unity })
    let godot = try #require(audit.entries.first { $0.engine == .godot })
    let gdevelop = try #require(audit.entries.first { $0.engine == .gdevelop })
    let cocos = try #require(audit.entries.first { $0.engine == .cocosCreator })
    #expect(unity.gap.contains("scene"))
    #expect(godot.gap.contains("autoload"))
    #expect(gdevelop.gap.contains("game.json"))
    #expect(cocos.gap.contains("3.8"))
}

@Test func unsupportedInstallerEnginesStillHaveCatalogDescriptors() throws {
    for engine in GameEngineID.allCases {
        let descriptor = try GameDeveloperEngineCatalog.descriptor(for: engine)
        #expect(descriptor.engine == engine)
        if [.unity, .godot, .gdevelop, .cocosCreator].contains(engine) {
            #expect(descriptor.support == .hostBuildHook)
            #expect(descriptor.instrumentation.requiresRebuild)
        }
    }
}
