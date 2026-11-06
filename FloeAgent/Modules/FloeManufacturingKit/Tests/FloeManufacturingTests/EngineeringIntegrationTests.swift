import XCTest
@testable import FloeManufacturingCore

final class EngineeringIntegrationTests:XCTestCase {
    func testBoundedNativeAnalysisArchivesBothKindsAndRejectsChangedInputs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("floe-engineering-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        for thermal in [false,true] {
            let input = EngineeringAnalysisProject.demonstration(thermal:thermal)
            let result = try EngineeringAnalysisEngine().compute(input)
            let url = folder.appendingPathComponent(thermal ? "heat.floeanalysis" : "static.floeanalysis")
            try EngineeringAnalysisArchive.save(project:input,artifact:result,to:url)
            let (saved,reopened) = try EngineeringAnalysisArchive.open(url)
            XCTAssertEqual(try ResearchArchive.digest(saved),try ResearchArchive.digest(input))
            XCTAssertEqual(try ResearchArchive.digest(reopened),try ResearchArchive.digest(result))
            var changed = input;changed.source.revision += 1
            XCTAssertThrowsError(try EngineeringAnalysisArchive.save(project:changed,artifact:result,to:url))
        }
        let control = ComputationControl();control.cancel()
        XCTAssertThrowsError(try EngineeringAnalysisEngine().compute(.demonstration(),control:control))
    }
}
