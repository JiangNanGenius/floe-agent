import XCTest
import FloeManufacturingCore

final class CAMPreviewSettingsTests:XCTestCase {
    func testLegacySettingsKeepPositionAndMigrateToMachiningFocus() throws {
        let old = Data(#"{"position":42.25,"speed":2,"selectedChapterID":"study:turning-face","selectedOnly":true,"paths":"all","showHead":false,"showSpindles":true,"smooth":true,"camera":"front"}"#.utf8)
        let state = try JSONDecoder().decode(CAMPreviewSettings.self,from:old)
        XCTAssertEqual(state.position,42.25);XCTAssertEqual(state.speed,2);XCTAssertTrue(state.selectedOnly)
        XCTAssertEqual(state.camera,.front);XCTAssertEqual(state.paths,.all)
        XCTAssertEqual(state.displayScope,.machining);XCTAssertEqual(state.structureDisplay,.hidden)
        XCTAssertEqual(state.spindleDisplay,.hidden);XCTAssertEqual(state.holderDisplay,.hidden)
        XCTAssertEqual(state.workholdingDisplay,.translucent)
        XCTAssertEqual(try JSONDecoder().decode(CAMPreviewSettings.self,from:JSONEncoder().encode(state)),state)
        XCTAssertThrowsError(try JSONDecoder().decode(CAMPreviewSettings.self,from:Data(#"{"transparency":1.2}"#.utf8)))
    }
    func testIndependentObjectTransparencySurvivesPortableArchiveWithoutChangingSource() throws {
        let study = ManufacturingStudy.shaft(),artifact = try NativeManufacturingEngine().compute(study,control:.init()),source = CAMPreviewSource.study(study,artifact)
        let identity = try CAMPreviewProgram(source:source).sourceKey
        var state = CAMPreviewSettings();state.position = 12;state.applyScope(.machine)
        state.transparency = 0.8;state.spindleDisplay = .translucent;state.holderDisplay = .hidden
        XCTAssertEqual(state.opacity(.translucent),0.2,accuracy:1e-12)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("display.floepreview")
        try CAMPreviewArchive.save(source:source,viewState:JSONEncoder().encode(state),to:url)
        let reopened = try CAMPreviewArchive.open(url),data = try XCTUnwrap(reopened.viewState)
        XCTAssertEqual(try JSONDecoder().decode(CAMPreviewSettings.self,from:data),state)
        XCTAssertEqual(try CAMPreviewProgram(source:reopened.source).sourceKey,identity)
        XCTAssertEqual(study.stock.resolutionMM,1)
    }
}
