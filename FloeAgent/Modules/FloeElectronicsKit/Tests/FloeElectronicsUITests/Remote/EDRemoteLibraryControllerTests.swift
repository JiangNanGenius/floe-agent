// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeElectronicsUI
import FloeElectronicsCore

private actor FakeRemoteLibraryService: EDRemoteLibraryServing {
    var installCount = 0
    var downloaded: [String] = []
    var installedParts: [(String, String)] = []
    let libraryID = "kicad-footprints"

    func status() async throws -> ElectronicsRemoteStatus {
        try JSONDecoder().decode(ElectronicsRemoteStatus.self, from: Data(#"""
        {"installed":true,"tag":"data-v1-394500c9831cbd7575b8","dataVersion":"v1-394500c9831cbd7575b8","datasetSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceCount":1,"modelCount":1,"installedAt":null,"cache":{"assets":1,"models":1,"indexes":1,"bytes":12}}
        """#.utf8))
    }
    func refresh(progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteRefreshReceipt {
        try JSONDecoder().decode(ElectronicsRemoteRefreshReceipt.self, from: Data(#"""
        {"tag":"data-v1-394500c9831cbd7575b8","dataVersion":"v1-394500c9831cbd7575b8","datasetSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","producerRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceCount":1,"modelCount":1,"catalogBytes":10,"modelIndexBytes":10,"changed":false}
        """#.utf8))
    }
    func searchLibraries(text: String, offset: Int, limit: Int) async throws -> ElectronicsRemoteLibraryPage {
        try JSONDecoder().decode(ElectronicsRemoteLibraryPage.self, from: Data(#"""
        {"total":1,"nextOffset":null,"libraries":[{"id":"kicad-footprints","repository":"https://github.com/KiCad/kicad-footprints","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","licenseID":"CC-BY-SA-4.0","attribution":"KiCad","recordCount":1,"sourceStatus":"normalized","statuses":{"converted":1},"kinds":{"footprint":1},"downloadAssetName":"kicad-footprints-2d.zip","packageBytes":10,"packageSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
        """#.utf8))
    }
    func searchParts(libraryID: String, text: String, kind: String?, status: String?,
                     offset: Int, limit: Int, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemotePartPage {
        try JSONDecoder().decode(ElectronicsRemotePartPage.self, from: Data(#"""
        {"total":2,"nextOffset":null,"parts":[{"id":"floe:electronics:kicad-footprints:footprint:Resistor_SMD:R_0603_1608Metric~bd9f073c6826","kind":"footprint","name":"R_0603_1608Metric","library":"Resistor_SMD","status":"converted","path":"records/kicad-footprints/00054.jsonl.gz","line":65,"sha256":"1f21771f65f443ad042efcc929f47e9f80c2dd00a72594e69118ef6210009a19","sourcePath":"Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod"},{"id":"floe:electronics:kicad-footprints:footprint:Review:Unsupported~000000000000","kind":"footprint","name":"Review","library":"Review","status":"reviewRequired","path":"records/kicad-footprints/00054.jsonl.gz","line":66,"sha256":"2222222222222222222222222222222222222222222222222222222222222222","sourcePath":"Review.pretty/Review.kicad_mod"}]}
        """#.utf8))
    }
    func searchModels(text: String, format: String?, offset: Int, limit: Int) async throws -> ElectronicsRemoteModelPage {
        try JSONDecoder().decode(ElectronicsRemoteModelPage.self, from: Data(#"""
        {"total":0,"nextOffset":null,"models":[]}
        """#.utf8))
    }
    func install(libraryID: String, partID: String, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteInstallResult {
        installCount += 1; installedParts.append((libraryID, partID))
        return try JSONDecoder().decode(ElectronicsRemoteInstallResult.self, from: Data(#"""
        {"reference":{"packageID":"floe.remote.kicad-footprints.footprint.1f21771f65f443ad","version":"1.0.0","packageSHA256":"3333333333333333333333333333333333333333333333333333333333333333","partID":"footprint:Resistor_SMD:R_0603_1608Metric"},"snapshotSHA256":"4444444444444444444444444444444444444444444444444444444444444444","libraryID":"kicad-footprints","sourceRecordID":"floe:electronics:kicad-footprints:footprint:Resistor_SMD:R_0603_1608Metric~bd9f073c6826","sourceRecordSHA256":"1f21771f65f443ad042efcc929f47e9f80c2dd00a72594e69118ef6210009a19","sourcePath":"Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod","partName":"R_0603_1608Metric","partKind":"footprint","catalogRevision":2,"models":[{"modelID":"model:kicad-packages3d:Resistor_SMD.3dshapes/R_0603_1608Metric.step","fileName":"R_0603_1608Metric.step","format":"step","gitBlobSHA1":"a885593ca3dd3dd354835d6f586626a712c61c2a","sourcePath":"Resistor_SMD.3dshapes/R_0603_1608Metric.step","licenseSourceID":"kicad-footprints"}],"originalBytes":3995,"normalizedRecordBytes":500,"noticeCount":2,"semantics":"read back"}
        """#.utf8))
    }
    func downloadModel(id: String, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteModelReceipt {
        downloaded.append(id)
        return try JSONDecoder().decode(ElectronicsRemoteModelReceipt.self, from: Data(#"""
        {"id":"model:kicad-packages3d:Resistor_SMD.3dshapes/R_0603_1608Metric.step","sourceID":"kicad-packages3d","repository":"https://gitlab.com/kicad/libraries/kicad-packages3D","revision":"8975715167d1a76f9b44be155ac02326f704cdbb","path":"Resistor_SMD.3dshapes/R_0603_1608Metric.step","gitBlobSHA1":"a885593ca3dd3dd354835d6f586626a712c61c2a","format":"step","licenseSourceID":"kicad-footprints","byteCount":40618,"sha256":"1875571c326d0d9e96f36b4efeb8094068ef7619f0a449c781caf0b49c2e5861","cached":false,"displayName":"R_0603_1608Metric.step","cachePath":"/tmp/model.step"}
        """#.utf8))
    }
    func isModelCached(reference: EDAFootprintModelReference) async -> Bool { false }
}

@MainActor
final class EDRemoteLibraryControllerTests: XCTestCase {
    private func waitIdle(_ controller: EDRemoteLibraryController) async {
        for _ in 0..<300 {
            if !controller.busy { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("controller did not settle")
    }

    func testSearchInstallAndInstalledCallbackUseTheInjectedService() async {
        let service = FakeRemoteLibraryService()
        let controller = EDRemoteLibraryController(service: service)
        var installed: ElectronicsRemoteInstallResult?
        controller.onInstalled = { installed = $0 }
        controller.start()
        await waitIdle(controller)
        XCTAssertEqual(controller.status?.installed, true)
        XCTAssertEqual(controller.libraries.first?.id, "kicad-footprints")
        XCTAssertEqual(controller.selectedLibraryID, "kicad-footprints")
        controller.searchParts()
        await waitIdle(controller)
        XCTAssertEqual(controller.parts.count, 2)
        XCTAssertEqual(controller.partTotal, 2)
        let converted = controller.parts[0]
        controller.install(converted)
        await waitIdle(controller)
        let count = await service.installCount
        let parts = await service.installedParts
        XCTAssertEqual(count, 1)
        XCTAssertEqual(parts.first?.0, "kicad-footprints")
        XCTAssertEqual(parts.first?.1, converted.id)
        XCTAssertNotNil(installed)
        XCTAssertEqual(installed?.reference.partID, "footprint:Resistor_SMD:R_0603_1608Metric")
        XCTAssertEqual(controller.lastInstall?.models.first?.format, "step")
        controller.downloadModel("model:kicad-packages3d:Resistor_SMD.3dshapes/R_0603_1608Metric.step")
        await waitIdle(controller)
        let downloads = await service.downloaded
        XCTAssertEqual(downloads.count, 1)
    }

    func testReviewRequiredPartIsNeverSentToTheInstallService() async {
        let service = FakeRemoteLibraryService()
        let controller = EDRemoteLibraryController(service: service)
        controller.start(); await waitIdle(controller)
        controller.searchParts(); await waitIdle(controller)
        let review = controller.parts.first { $0.status == "reviewRequired" }!
        controller.install(review)
        await waitIdle(controller)
        let count = await service.installCount
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(controller.message)
    }
}
