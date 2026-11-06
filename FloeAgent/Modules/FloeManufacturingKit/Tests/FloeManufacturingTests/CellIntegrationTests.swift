import XCTest
@testable import FloeManufacturingCore

final class CellIntegrationTests:XCTestCase {
    func testPartialOverlapCannotClaimTheFullRequestedGrip() throws {
        var project = ManufacturingCellProject.demonstration()
        let i = try XCTUnwrap(project.cell.steps.firstIndex { if case .transfer = $0.action { true } else { false } })
        guard case .transfer(var transfer) = project.cell.steps[i].action else { return XCTFail("transfer missing") }
        transfer.acquisitionOriginMM = [0,0,45] // only 5 mm of a requested 12 mm engages.
        project.cell.steps[i].action = .transfer(transfer)
        XCTAssertThrowsError(try CellPlanner().plan(project.cell)) { error in
            XCTAssertTrue(error.localizedDescription.contains("insufficient actual axial grip"))
        }
    }
    func testTransferContinuesActualMaterialAndReopensTheSameResult() throws {
        var project = ManufacturingCellProject.demonstration()
        project.cell.turrets[0].stations[0].toolOffsetMM = [1,-2,3]
        let value = try CellManufacturingEngine().compute(project)
        XCTAssertGreaterThanOrEqual(project.cell.spindles.count,2)
        XCTAssertGreaterThanOrEqual(project.cell.turrets.count,2)
        XCTAssertFalse(value.schedule.transfers.isEmpty)
        let backside = try XCTUnwrap(value.jobs.first { $0.stepID == "sub-backside-op" })
        XCTAssertGreaterThan(backside.artifact.result.removedMM3,0)
        XCTAssertEqual(backside.worldFromWorkpiece.translationMM,[0,0,42])
        let front = try XCTUnwrap(value.jobs.first { $0.stepID == "main-front-op" })
        let tcp = try XCTUnwrap(front.worldPaths.first?.points.first)
        XCTAssertEqual(front.worldToolReferencePaths.first?.points.first,zip(tcp,[1.0,-2,3]).map(+))
        for id in value.finalStock.keys {
            let jobs = value.jobs.filter { $0.workpieceID == id }
            for i in jobs.indices.dropFirst() {
                let before = try XCTUnwrap(jobs[i-1].artifact.result.stockState)
                XCTAssertEqual(jobs[i].artifact.startingStockSHA256,try before.fingerprint())
                XCTAssertEqual(jobs[i].artifact.result.initialMM3,before.remainingMM3,accuracy:1e-8)
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("floe-cell-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("result.floecell")
        try ManufacturingCellArchive.save(project:project,artifact:value,to:url)
        let (input,reopened) = try ManufacturingCellArchive.open(url)
        XCTAssertEqual(try ResearchArchive.digest(input),try ResearchArchive.digest(project))
        XCTAssertEqual(try ResearchArchive.digest(reopened),try ResearchArchive.digest(value))
        var changed = project;changed.cell.name += " changed"
        XCTAssertThrowsError(try ManufacturingCellArchive.save(project:changed,artifact:value,to:url))
        let control = ComputationControl();control.cancel()
        XCTAssertThrowsError(try CellManufacturingEngine().compute(project,control:control))
    }
}
