// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

@Test func normalPlansReportAHostGatedHelper() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    #expect(plan.dormancy.gated)
    #expect(plan.dormancy.hostObjectName == "FloeDeveloper")
    #expect(plan.dormancy.evidence.contains { $0.contains("window.FloeDeveloper") })
    #expect(!plan.dormancy.productionBehavior.isEmpty)
    #expect(!plan.dormancy.productionBehaviorZhHans.isEmpty)
}

@Test func godotTemplateWithoutTheHostGateFailsClosed() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.godotProjectData())
    defer { clean(imported) }
    let base = try GameDeveloperInstrumentationTemplates()
    let original = try #require(String(data: base.godotAutoload.data, encoding: .utf8))
    let modified = original.replacingOccurrences(
        of: "window.FloeDeveloper", with: "window.NotFloe")
    let templates = try InstrumentationFixture.templates(godot: Data(modified.utf8))
    let instrumenter = try InstrumentationFixture.instrumenter(imported, templates: templates)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .godot)
    guard let error else { Issue.record("expected dormancyUnverified"); return }
    guard case .dormancyUnverified(let detail) = error else {
        Issue.record("expected dormancyUnverified, got \(error)")
        return
    }
    #expect(detail.contains("window.FloeDeveloper"))
}

@Test func unityTemplateWithoutAWebGLConditionFailsClosed() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let base = try GameDeveloperInstrumentationTemplates()
    let original = try #require(String(data: base.unityBehaviour.data, encoding: .utf8))
    let modified = original.replacingOccurrences(
        of: "#if UNITY_WEBGL && !UNITY_EDITOR", with: "#if true")
    let templates = try InstrumentationFixture.templates(
        unityBehaviour: Data(modified.utf8))
    let instrumenter = try InstrumentationFixture.instrumenter(imported, templates: templates)
    let error = await InstrumentationFixture.planError(
        instrumenter, context: imported.context, engine: .unity)
    guard let error else { Issue.record("expected dormancyUnverified"); return }
    guard case .dormancyUnverified(_) = error else {
        Issue.record("expected dormancyUnverified, got \(error)")
        return
    }
}

@Test func installedUnityHelpersHaveNoPlayerReachableControlPath() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    for file in plan.files {
        let text = String(decoding: file.outputData, as: UTF8.self)
        #expect(!text.contains("OnGUI"))
        #expect(!text.contains("SendMessage("))
        #expect(!text.contains("System.Reflection"))
        #expect(!text.contains("UnityEditor."))
    }
    let js = try #require(plan.files.first { $0.path.value.hasSuffix(".jslib") })
    let jsText = String(decoding: js.outputData, as: UTF8.self)
    #expect(jsText.components(separatedBy: "window.FloeDeveloper").count - 1 >= 4)
}

@Test func installedGodotHelperHasNoProcessOrEvaluatorPath() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.godotProjectData())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .godot)
    let helper = try #require(plan.files.first { $0.kind == .helperSource })
    let text = String(decoding: helper.outputData, as: UTF8.self)
    #expect(!text.contains("OS.execute"))
    #expect(!text.contains("OS.create_process"))
    #expect(text.contains("if not OS.has_feature(\"web\"):"))
    #expect(text.contains("window.FloeDeveloper"))
}
