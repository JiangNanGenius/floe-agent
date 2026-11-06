import XCTest
@testable import FloeManufacturingCore

final class CAMOperationInspectionTests:XCTestCase {
    func testSourceOwnersAndAppliedTurningInsertArePreserved() throws {
        let study = ManufacturingStudy.turnMillCAM(),artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let fingerprint = try study.fingerprint(),program = try CAMPreviewProgram(source:.study(study,artifact))
        for chapter in program.chapters {
            let context = try XCTUnwrap(program.inspection(forChapterID:chapter.id))
            XCTAssertEqual(context.study,study);XCTAssertEqual(context.chapter.id,chapter.id)
            if context.turning { XCTAssertEqual(context.turningSetup,artifact.result.turningSetupReceipt?.applied ?? study.configuredTurningSetup);XCTAssertNil(context.tool) }
            else if context.legacyMilling {
                XCTAssertEqual(chapter.kind,"milling-slot");XCTAssertNil(context.operation);XCTAssertNil(context.tool)
                XCTAssertEqual(context.study.milling,study.milling)
            } else {
                let operation = try XCTUnwrap(context.operation),tool = try XCTUnwrap(context.tool)
                XCTAssertEqual(operation.toolID,tool.id);XCTAssertEqual(tool,study.cam?.tools.first { $0.id == operation.toolID })
            }
        }
        XCTAssertEqual(try study.fingerprint(),fingerprint)
        XCTAssertNil(program.inspection(forChapterID:"missing"))
    }
    func testCellInspectionUsesJobOwnerAndDoesNotAttachMachiningDataToMachineSteps() throws {
        let project = VirtualMachineProject.demonstration(),artifact = try CellManufacturingEngine().compute(project.cell)
        let program = try CAMPreviewProgram(source:.cell(project,artifact))
        var jobs = Set<String>(),machine = 0
        for chapter in program.chapters {
            if let expected = artifact.jobs.first(where:{ $0.stepID == chapter.jobID }) {
                let context = try XCTUnwrap(program.inspection(forChapterID:chapter.id))
                let step = try XCTUnwrap(artifact.executedCell.steps.first { $0.id == chapter.jobID })
                guard case .operate(let op) = step.action else { return XCTFail("a result job must refer to an operate step") }
                XCTAssertEqual(context.study,op.study);XCTAssertEqual(context.study.id,expected.artifact.studyID);jobs.insert(chapter.jobID)
            } else { XCTAssertNil(program.inspection(forChapterID:chapter.id));machine += 1 }
        }
        XCTAssertGreaterThan(jobs.count,1);XCTAssertGreaterThan(machine,0)
    }
}
