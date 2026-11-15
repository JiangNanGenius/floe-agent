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

private func aggregate(_ bundle: GameDeveloperInstrumentationSourceBundle) -> String {
    var data = Data()
    for file in bundle.files.sorted(by: { $0.path < $1.path }) {
        data.append(contentsOf: file.path.utf8)
        data.append(0)
        data.append(contentsOf: file.sha256.utf8)
    }
    return GameDigest.sha256(data)
}

@Test func unityBundleCarriesExactSourcesLicenseNoticeAndProvenance() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let bundle = try await instrumenter.bundleSourceFiles(plan)
    let templates = try GameDeveloperInstrumentationTemplates()
    #expect(bundle.engine == .unity)
    #expect(bundle.licenseIdentifier == "MPL-2.0")
    #expect(bundle.sourceRevision == GameDeveloperInstrumentationConstants.frozenSourceRevision)
    #expect(bundle.aggregateSHA256 == aggregate(bundle))
    let license = try #require(bundle.files.first { $0.role == .license })
    let notice = try #require(bundle.files.first { $0.role == .notice })
    let provenance = try #require(bundle.files.first { $0.role == .provenance })
    #expect(license.data == templates.license.data)
    #expect(bundle.manifestSHA256 == GameDigest.sha256(provenance.data))
    let noticeText = String(decoding: notice.data, as: UTF8.self)
    #expect(noticeText.contains("SPDX-License-Identifier: MPL-2.0"))
    #expect(noticeText.contains("FloeGameDeveloperKit"))
    #expect(noticeText.contains(GameDeveloperInstrumentationConstants.frozenSourceRevision))
    #expect(noticeText.contains("window.FloeDeveloper"))
    #expect(bundle.files.contains { $0.role == .readme && !$0.data.isEmpty })
    #expect(bundle.files.contains { $0.role == .installInstructions && !$0.data.isEmpty })
    let helpers = bundle.files.filter { $0.role == .helperSource }
    #expect(helpers.count == 3)
    for file in plan.files where file.kind == .helperSource {
        let bundled = try #require(helpers.first { $0.path.hasSuffix(file.path.value) })
        #expect(bundled.data == file.outputData)
        #expect(bundled.sha256 == file.outputSHA256)
    }
    for file in bundle.files {
        #expect(file.path.hasPrefix("FloeDeveloper/"))
        #expect(!file.path.hasPrefix("/"))
        #expect(!file.path.contains(".."))
        #expect(file.bytes == file.data.count)
        #expect(GameDigest.sha256(file.data) == file.sha256)
    }
}

@Test func godotBundleKeepsProjectGodotOutButShowsTheAutoloadInstruction() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.godotProjectData())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .godot)
    let bundle = try await instrumenter.bundleSourceFiles(plan)
    let helpers = bundle.files.filter { $0.role == .helperSource }
    #expect(helpers.count == 1)
    #expect(helpers.first?.path.hasSuffix("floe_developer.gd") == true)
    #expect(!(bundle.files.contains { $0.path.hasSuffix("project.godot") }))
    let install = try #require(bundle.files.first { $0.role == .installInstructions })
    let text = String(decoding: install.data, as: UTF8.self)
    #expect(text.contains("[autoload]"))
    #expect(text.contains("FloeDeveloper=\"*res://floe_developer.gd\""))
    #expect(text.contains("project.godot"))
}

@Test func provenanceRecordsTemplatePinsAndInstalledFiles() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let bundle = try await instrumenter.bundleSourceFiles(plan)
    let provenance = try #require(bundle.files.first { $0.role == .provenance })
    let raw = try JSONSerialization.jsonObject(with: provenance.data)
    let object = try #require(raw as? [String: Any])
    #expect(object["engine"] as? String == "unity")
    #expect(object["catalogVersion"] as? String == GameDeveloperEngineCatalog.version)
    #expect(object["frozenSourceRevision"] as? String == GameDeveloperInstrumentationConstants.frozenSourceRevision)
    #expect(object["license"] as? String == "MPL-2.0")
    #expect(object["hostGate"] as? String == "FloeDeveloper")
    #expect(object["requiresRebuild"] as? Bool == true)
    let templates = try #require(object["templates"] as? [[String: Any]])
    #expect(templates.count == 4)
    #expect(Set(templates.compactMap { $0["id"] as? String })
        == Set(["unityBridge", "unityJSLibrary", "unityBehaviour", "godotAutoload"]))
    let installed = try #require(object["installedFiles"] as? [[String: Any]])
    #expect(installed.count == 3)
    for record in installed {
        #expect(record["outputSHA256"] as? String != nil)
        #expect(record["sourceBundlePath"] as? String != nil)
    }
    let patches = try #require(object["projectPatches"] as? [[String: Any]])
    #expect(patches.isEmpty)
}

@Test func buildRecordReferencesTheSourceBundleWithoutReplacingTheBuildDigest() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let receipt = try await instrumenter.apply(plan)
    let bundle = try await instrumenter.bundleSourceFiles(plan)
    let data = try await instrumenter.buildRecord(plan: plan, receipt: receipt, bundle: bundle)
    let raw = try JSONSerialization.jsonObject(with: data)
    let object = try #require(raw as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["engine"] as? String == "unity")
    #expect(object["revision"] as? String == receipt.revision)
    #expect(object["license"] as? String == "MPL-2.0")
    #expect(object["hostGate"] as? String == "FloeDeveloper")
    let owner = try #require(object["owner"] as? [String: Any])
    #expect(owner["space"] != nil)
    let helperFiles = try #require(object["helperFiles"] as? [[String: Any]])
    #expect(helperFiles.count == 3)
    for helper in helperFiles {
        #expect(helper["path"] as? String != nil)
        #expect(helper["sourceBundlePath"] as? String != nil)
        #expect(helper["sha256"] as? String != nil)
        #expect(helper["templateSHA256"] as? String != nil)
    }
    let sourceBundle = try #require(object["sourceBundle"] as? [String: Any])
    #expect(sourceBundle["manifestSHA256"] as? String == bundle.manifestSHA256)
    #expect(sourceBundle["aggregateSHA256"] as? String == bundle.aggregateSHA256)
    #expect(sourceBundle["root"] as? String == "FloeDeveloper/")
}
