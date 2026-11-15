// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameDeveloperCore
@testable import FloeGameInstrumentation

private var frozenSDK: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FloeGameInstrumentationTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FloeGameInstrumentation
        .deletingLastPathComponent() // Modules (the matching sealed SDK graph)
        .appendingPathComponent("FloeGameDeveloperKit", isDirectory: true)
}

@Test func bundledTemplatesAreByteIdenticalToTheFrozenSDK() throws {
    let templates = try GameDeveloperInstrumentationTemplates()
    for template in templates.all {
        let url = frozenSDK.appendingPathComponent(template.sdkPath)
        let data = try Data(contentsOf: url)
        #expect(data == template.data, "template \(template.id)")
        #expect(GameDigest.sha256(data) == template.sha256)
        #expect(data.count == template.bytes)
    }
    let license = try Data(contentsOf: frozenSDK.appendingPathComponent("LICENSE"))
    #expect(license == templates.license.data)
}

@Test func templatePinsTrackTheCatalogAndFrozenRevision() throws {
    let templates = try GameDeveloperInstrumentationTemplates()
    #expect(templates.catalogVersion == GameDeveloperEngineCatalog.version)
    #expect(templates.frozenSourceRevision == GameDeveloperInstrumentationConstants.frozenSourceRevision)
    #expect(templates.all.count == 4)
    #expect(Set(templates.all.map { $0.id })
        == Set(["unityBridge", "unityJSLibrary", "unityBehaviour", "godotAutoload"]))
    #expect(templates.pinsSHA256.count == 64)
}

@Test func noticeCarriesTheMPLAndDevelopmentOnlyBoundary() throws {
    let templates = try GameDeveloperInstrumentationTemplates()
    let text = try #require(String(data: templates.notice, encoding: .utf8))
    #expect(text.contains("SPDX-License-Identifier: MPL-2.0"))
    #expect(text.contains("FloeGameDeveloperKit"))
    #expect(text.contains(GameDeveloperInstrumentationConstants.frozenSourceRevision))
    #expect(text.contains("window.FloeDeveloper"))
    #expect(text.contains("No imported game"))
}
