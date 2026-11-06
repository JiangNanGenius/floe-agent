import XCTest
@testable import FloeManufacturingCore

/// R5 cell planner tests: pure model/scheduling only, no native engine, no
/// device. Times are nominal supplied values.
final class CellPlannerTests: XCTestCase {
    private func assertThrows(_ messagePart: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ManufacturingError.invalid(let message) = error else {
                return XCTFail("expected ManufacturingError.invalid, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(messagePart), "error '\(message)' does not mention '\(messagePart)'", file: file, line: line)
        }
    }

    // MARK: - Demonstration program

    func testDemonstrationPlansWithOverlappingIndependentChannels() throws {
        let cell = ManufacturingCell.opposingSpindleTwoTurret()
        let schedule = try CellPlanner().plan(cell)
        try schedule.validate(for: cell)
        let front = try XCTUnwrap(schedule.steps.first { $0.stepID == "main-front-op" })
        let drill = try XCTUnwrap(schedule.steps.first { $0.stepID == "sub-drill-op" })
        XCTAssertLessThan(front.startSeconds, drill.endSeconds)
        XCTAssertLessThan(drill.startSeconds, front.endSeconds)
        XCTAssertTrue(Set(front.resources).isDisjoint(with: drill.resources),
                      "independent channels may overlap only for distinct actual resources")
        XCTAssertGreaterThan(schedule.totalSeconds, 0)
        XCTAssertEqual(schedule.jobs.map(\.stepID), ["main-front-op", "sub-drill-op", "sub-backside-op"])
        XCTAssertEqual(schedule.ejectedWorkpieceIDs, ["wp2"])
        // Everything is owned or explicitly ejected at rest.
        XCTAssertEqual(schedule.endState.owner(of: "wp1"), "sub")
    }

    func testTransferTransactionAcquiresBeforeReleaseAndUpdatesOwnership() throws {
        let schedule = try ManufacturingCell.opposingSpindleTwoTurretSchedule()
        let transfer = try XCTUnwrap(schedule.transfers.first)
        XCTAssertEqual(transfer.workpieceID, "wp1")
        XCTAssertLessThan(transfer.acquireSeconds, transfer.releaseSeconds)
        // Rigid handover: no flip while both chucks grip; the post-release
        // retract translates the part by the carriage displacement (+42 mm).
        XCTAssertEqual(transfer.worldFromWorkpieceBefore.translationMM, [0, 0, 0])
        XCTAssertEqual(transfer.worldFromWorkpieceAfter.translationMM, [0, 0, 42])
        XCTAssertEqual(transfer.carriageDisplacementMM, [0, 0, 42])
        XCTAssertEqual(transfer.acquisitionOriginMM, [0, 0, 38])
        XCTAssertEqual(transfer.retractOriginMM, [0, 0, 80])
        let acquired = try XCTUnwrap(schedule.events.first { $0.kind == .transferAcquired })
        let released = try XCTUnwrap(schedule.events.first { $0.kind == .transferReleased })
        XCTAssertLessThan(acquired.seconds, released.seconds)
        let approach = try XCTUnwrap(schedule.events.first { $0.kind == .transferApproach })
        let retract = try XCTUnwrap(schedule.events.first { $0.kind == .transferRetract })
        XCTAssertLessThan(approach.seconds, acquired.seconds)
        XCTAssertLessThan(released.seconds, retract.seconds)
        let subState = try XCTUnwrap(schedule.endState.spindleStates["sub"])
        XCTAssertEqual(subState.clampedWorkpieceID, "wp1")
        XCTAssertEqual(subState.gripLengthMM, 12)
        XCTAssertEqual(subState.carriagePositionMM, [0, 0, 80])
        XCTAssertNil(schedule.endState.spindleStates["main"]?.clampedWorkpieceID)
    }

    func testRemoteChuckGripFailsClosed() throws {
        var cell = ManufacturingCell.opposingSpindleTwoTurret()
        cell.steps = cell.steps.map { step in
            guard case .transfer(let transfer) = step.action else { return step }
            // Position the receiver grip 20 mm away from the part end.
            var moved = transfer
            moved.acquisitionOriginMM = [0, 0, 58]
            return CellStep(id: step.id, channelID: step.channelID, order: step.order, action: .transfer(moved))
        }
        assertThrows("does not overlap") {
            _ = try CellPlanner().plan(cell)
        }
    }

    func testTurningOperationRequiresMatchingSpindleLaw() throws {
        var cell = ManufacturingCell.opposingSpindleTwoTurret()
        cell.steps = cell.steps.map { step in
            guard case .spindle(let command) = step.action, step.id == "main-rpm-1500" else { return step }
            var changed = command
            changed.rpm = 1200 // study law says capped 1500
            return CellStep(id: step.id, channelID: step.channelID, order: step.order, action: .spindle(changed))
        }
        assertThrows("capped fixed RPM") {
            _ = try CellPlanner().plan(cell)
        }
    }

    func testOpposingSpindlesRejectOppositeWorldRotationAndUnequalGripSpeeds() throws {
        var cell = ManufacturingCell.opposingSpindleTwoTurret()
        let i = try XCTUnwrap(cell.steps.firstIndex { $0.id == "sub-rpm-800" })
        guard case .spindle(var command) = cell.steps[i].action else { return XCTFail("command missing") }
        command.direction = .cw // same local sign on opposing axes gives opposing world vectors.
        cell.steps[i].action = .spindle(command)
        assertThrows("aligned world rotation") { _ = try CellPlanner().plan(cell) }
        cell = ManufacturingCell.opposingSpindleTwoTurret()
        let j = try XCTUnwrap(cell.steps.firstIndex { $0.id == "main-sync" })
        guard case .synchronize(var sync) = cell.steps[j].action else { return XCTFail("sync missing") }
        sync.speedRatio = 2
        cell.steps[j].action = .synchronize(sync)
        assertThrows("equal spindle RPM") { _ = try CellPlanner().plan(cell) }
    }

    func testPhaseAcquisitionUpdatesChuckDatumWithoutRotatingTheHeldMaterial() throws {
        let baseline = try ManufacturingCell.opposingSpindleTwoTurretSchedule()
        var cell = ManufacturingCell.opposingSpindleTwoTurret()
        let i = try XCTUnwrap(cell.steps.firstIndex { $0.id == "main-sync" })
        guard case .synchronize(var sync) = cell.steps[i].action else { return XCTFail("sync missing") }
        sync.targetPhaseOffsetDegrees = 45
        cell.steps[i].action = .synchronize(sync)
        let changed = try CellPlanner().plan(cell)
        let originalPhase = try XCTUnwrap(baseline.endState.spindleStates["sub"]?.phaseDatumDegrees)
        let acquiredPhase = try XCTUnwrap(changed.endState.spindleStates["sub"]?.phaseDatumDegrees)
        XCTAssertEqual(acquiredPhase-originalPhase,45,accuracy:1e-9)
        XCTAssertEqual(changed.transfers.first?.worldFromWorkpieceAfter.rotation,
                       baseline.transfers.first?.worldFromWorkpieceAfter.rotation)
    }

    func testPlanIsDeterministicAcrossRuns() throws {
        let cell = ManufacturingCell.opposingSpindleTwoTurret()
        let first = try CellPlanner().plan(cell)
        let second = try CellPlanner().plan(cell)
        XCTAssertEqual(first, second)
    }

    func testCodableRoundTripOfCellAndSchedule() throws {
        let cell = ManufacturingCell.opposingSpindleTwoTurret()
        let schedule = try CellPlanner().plan(cell)
        let decoder = JSONDecoder()
        let decodedCell = try decoder.decode(ManufacturingCell.self, from: try encoder.encode(cell))
        XCTAssertEqual(decodedCell, cell)
        let decodedSchedule = try decoder.decode(CellSchedule.self, from: try encoder.encode(schedule))
        XCTAssertEqual(decodedSchedule, schedule)
        try decodedSchedule.validate(for: decodedCell)
    }

    // MARK: - Failure fixtures fail closed

    func testTransferWithoutSynchronizationFailsClosed() {
        let cell = ManufacturingCell.failureTransferWithoutSync()
        assertThrows("without synchronization") {
            _ = try CellPlanner().plan(cell)
        }
    }

    func testMissingGripFailsValidation() {
        assertThrows("receiver grip length") {
            try ManufacturingCell.failureMissingGrip().validate()
        }
    }

    func testConflictingLocksCycleFailsClosed() {
        assertThrows("dependency cycle") {
            _ = try CellPlanner().plan(ManufacturingCell.failureConflictingLocksCycle())
        }
    }

    func testUnresolvedNamedWaitFailsValidation() {
        assertThrows("does not resolve") {
            try ManufacturingCell.failureUnresolvedNamedWait().validate()
        }
    }

    func testCombinedTurnSlotStudyRefused() {
        let cell = try? ManufacturingCell.failureCombinedTurnSlot()
        XCTAssertNotNil(cell)
        assertThrows("combined turning+slot") {
            try cell!.validate()
        }
    }

    // MARK: - Scheduling semantics

    func testBarrierHasCollectiveSemantics() throws {
        let cell = ManufacturingCell.barrierFixture()
        let schedule = try CellPlanner().plan(cell)
        let long = try XCTUnwrap(schedule.steps.first { $0.stepID == "a-long" })
        let barrier = try XCTUnwrap(schedule.steps.first { $0.stepID == "b-barrier" })
        let late = try XCTUnwrap(schedule.steps.first { $0.stepID == "b-late" })
        XCTAssertGreaterThanOrEqual(barrier.startSeconds, long.endSeconds - 1e-9,
                                    "no listed channel proceeds before every channel arrives")
        XCTAssertGreaterThanOrEqual(late.startSeconds, barrier.endSeconds - 1e-9)
    }

    func testNamedWaitOrdersBacksideOperationAfterTransfer() throws {
        let schedule = try ManufacturingCell.opposingSpindleTwoTurretSchedule()
        let transfer = try XCTUnwrap(schedule.steps.first { $0.stepID == "main-transfer" })
        let backside = try XCTUnwrap(schedule.steps.first { $0.stepID == "sub-backside-op" })
        XCTAssertGreaterThanOrEqual(backside.startSeconds, transfer.endSeconds - 1e-9)
        XCTAssertEqual(backside.stockDependencyIDs, ["main-front-op", "main-transfer"])
        let job = try XCTUnwrap(schedule.jobs.first { $0.stepID == "sub-backside-op" })
        XCTAssertEqual(job.stockDependencyStepIDs, ["main-front-op", "main-transfer"])
        XCTAssertEqual(job.turningToolID, "turning-insert-sub")
    }

    func testExclusionGroupSerializesSharedResources() throws {
        let serial = try CellPlanner().plan(ManufacturingCell.exclusionFixture(sharing: true))
        let a = try XCTUnwrap(serial.steps.first { $0.stepID == "a-op" })
        let b = try XCTUnwrap(serial.steps.first { $0.stepID == "b-op" })
        XCTAssertGreaterThanOrEqual(b.startSeconds, a.endSeconds - 1e-9,
                                    "shared-envelope resources must not overlap")
        let parallel = try CellPlanner().plan(ManufacturingCell.exclusionFixture(sharing: false))
        let a2 = try XCTUnwrap(parallel.steps.first { $0.stepID == "a-op" })
        let b2 = try XCTUnwrap(parallel.steps.first { $0.stepID == "b-op" })
        XCTAssertLessThan(b2.startSeconds, a2.endSeconds)
    }

    func testChuckReleaseWithoutAnotherHolderFailsClosed() {
        assertThrows("drop the last grip") {
            _ = try CellPlanner().plan(ManufacturingCell.releaseFixture())
        }
    }

    func testEjectRequiresExplicitOption() throws {
        let schedule = try CellPlanner().plan(ManufacturingCell.opposingSpindleTwoTurret())
        XCTAssertEqual(schedule.ejectedWorkpieceIDs, ["wp2"])
    }

    // MARK: - Geometry and state contract

    func testMirroredTransformRejected() throws {
        var cell = ManufacturingCell.opposingSpindleTwoTurret()
        var part = try XCTUnwrap(cell.workpieces.first { $0.id == "wp1" })
        part.worldFromWorkpiece = CellRigidTransform(rotation: [1,0,0, 0,1,0, 0,0,-1], translationMM: [0,0,0])
        cell.workpieces = cell.workpieces.map { $0.id == "wp1" ? part : $0 }
        assertThrows("right-handed") {
            try cell.validate()
        }
    }

    func testCommandedPhaseIntegrationAndTwistTransfer() throws {
        var state = CellMachineState.SpindleState(mode: .rpm, rpm: 100, direction: .cw,
                                                  phaseDatumDegrees: 0, phaseReferenceSeconds: 0,
                                                  chuckOpeningDiameterMM: 20, maxOpeningDiameterMM: 80)
        XCTAssertEqual(try XCTUnwrap(state.phase(atSeconds: 0.6)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(state.phase(atSeconds: 1.0)), 240, accuracy: 1e-9)
        state.direction = .ccw
        state.phaseReferenceSeconds = 0
        XCTAssertEqual(try XCTUnwrap(state.phase(atSeconds: 1.0)), 120, accuracy: 1e-9)
        // Parallel-axis transfer with a 90° twist rotates about the axis and
        // leaves the translation unchanged.
        let cell = ManufacturingCell.twistFixture()
        let schedule = try CellPlanner().plan(cell)
        let transfer = try XCTUnwrap(schedule.transfers.first)
        XCTAssertEqual(transfer.worldFromWorkpieceAfter.translationMM, transfer.worldFromWorkpieceBefore.translationMM)
        let expected = CellRigidTransform(rotation: [0,-1,0, 1,0,0, 0,0,1], translationMM: [0,0,0])
        XCTAssertEqual(transfer.worldFromWorkpieceAfter.rotation.count, 9)
        for (actual, wanted) in zip(transfer.worldFromWorkpieceAfter.rotation, expected.rotation) {
            XCTAssertEqual(actual, wanted, accuracy: 1e-9)
        }
    }

    func testMultiToolStudyRequiresExplicitStation() throws {
        let drill = ManufacturingCAM.Tool.researchExample(id: "drill-2", kind: "drill")
        let mill = ManufacturingCAM.Tool.researchExample(id: "mill-4")
        var study = ManufacturingStudy.shaft()
        study.turning.enabled = false
        var hole = ManufacturingCAM.Operation(id: "op-hole", name: "孔", strategy: "drill", toolID: drill.id)
        hole.holesUVMM = [[0, 0]]
        var face = ManufacturingCAM.Operation(id: "op-face", name: "面", strategy: "face", toolID: mill.id)
        face.minUVMM = [-5, -5]; face.maxUVMM = [5, 5]
        study.cam = ManufacturingCAM(tools: [drill, mill], operations: [hole, face])
        let cell = ManufacturingCell.singleSpindleFixture(study: study, stationToolID: nil, toolID: nil)
        assertThrows("explicit station/tool selection") {
            try cell.validate()
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private extension ManufacturingCell {
    /// Two channels, one long operation on A, a barrier on B and a late B
    /// step after the barrier.
    static func barrierFixture() -> ManufacturingCell {
        let frameA = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let frameB = CellFrame(originMM: [0, 0, 200], axis: [0, 0, 1], xDirection: [1, 0, 0])
        var studyA = ManufacturingStudy.shaft(); studyA.turningToolID = "t1"
        var studyB = ManufacturingStudy.shaft(); studyB.turningToolID = "t1"
        let spindleA = Spindle(id: "sa", name: "A", frame: frameA, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "wa", gripLengthMM: 10))
        let spindleB = Spindle(id: "sb", name: "B", frame: frameB, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "wb", gripLengthMM: 10))
        let wa = Workpiece(id: "wa", name: "wa", source: studyA.source, studyID: studyA.id, ownerSpindleID: "sa",
                           worldFromWorkpiece: .identity, gripLengthMM: 10, envelopeRadiusMM: 10)
        let wb = Workpiece(id: "wb", name: "wb", source: studyB.source, studyID: studyB.id, ownerSpindleID: "sb",
                           worldFromWorkpiece: frameB.transform, gripLengthMM: 10, envelopeRadiusMM: 10)
        let tool = CellTurningTool(id: "t1", name: "insert")
        return ManufacturingCell(
            name: "barrier fixture",
            turningTools: [tool],
            spindles: [spindleA, spindleB],
            turrets: [],
            channels: [.init(id: "cha", name: "A", spindleIDs: ["sa"]),
                       .init(id: "chb", name: "B", spindleIDs: ["sb"])],
            workpieces: [wa, wb],
            steps: [.init(id: "a-long", channelID: "cha", order: 0,
                          action: .operate(.init(study: studyA, workpieceID: "wa", spindleID: "sa", durationSeconds: 10))),
                    .init(id: "b-short", channelID: "chb", order: 0,
                          action: .operate(.init(study: studyB, workpieceID: "wb", spindleID: "sb", durationSeconds: 3))),
                    .init(id: "b-barrier", channelID: "chb", order: 1,
                          action: .barrier(.init(channelIDs: ["cha", "chb"]))),
                    .init(id: "b-late", channelID: "chb", order: 2,
                          action: .dwell(.init(seconds: 1)))],
            edges: [])
    }

    /// Two spindles that either share an exclusion group (serialized) or not
    /// (overlapping).
    static func exclusionFixture(sharing: Bool) -> ManufacturingCell {
        let frameA = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let frameB = CellFrame(originMM: [0, 0, 200], axis: [0, 0, 1], xDirection: [1, 0, 0])
        var studyA = ManufacturingStudy.shaft(); studyA.turningToolID = "t1"
        var studyB = ManufacturingStudy.shaft(); studyB.turningToolID = "t1"
        let groups = sharing ? [ExclusionGroup(id: "bed", resources: [.init(.spindle, "sa"), .init(.spindle, "sb")])] : []
        let spindleA = Spindle(id: "sa", name: "A", frame: frameA, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "wa", gripLengthMM: 10))
        let spindleB = Spindle(id: "sb", name: "B", frame: frameB, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "wb", gripLengthMM: 10))
        let wa = Workpiece(id: "wa", name: "wa", source: studyA.source, studyID: studyA.id, ownerSpindleID: "sa",
                           worldFromWorkpiece: .identity, gripLengthMM: 10, envelopeRadiusMM: 10)
        let wb = Workpiece(id: "wb", name: "wb", source: studyB.source, studyID: studyB.id, ownerSpindleID: "sb",
                           worldFromWorkpiece: frameB.transform, gripLengthMM: 10, envelopeRadiusMM: 10)
        return ManufacturingCell(
            name: "exclusion fixture",
            turningTools: [CellTurningTool(id: "t1", name: "insert")],
            spindles: [spindleA, spindleB],
            turrets: [],
            channels: [.init(id: "cha", name: "A", spindleIDs: ["sa"]),
                       .init(id: "chb", name: "B", spindleIDs: ["sb"])],
            workpieces: [wa, wb],
            exclusionGroups: groups,
            steps: [.init(id: "a-op", channelID: "cha", order: 0,
                          action: .operate(.init(study: studyA, workpieceID: "wa", spindleID: "sa", durationSeconds: 10))),
                    .init(id: "b-op", channelID: "chb", order: 0,
                          action: .operate(.init(study: studyB, workpieceID: "wb", spindleID: "sb", durationSeconds: 8)))],
            edges: [])
    }

    /// Single spindle whose only step releases the part with no other holder
    /// and no eject option.
    static func releaseFixture() -> ManufacturingCell {
        let frame = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        var study = ManufacturingStudy.shaft(); study.turningToolID = "t1"
        let spindle = Spindle(id: "s1", name: "S", frame: frame, maxRPM: 4000,
                              chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "w1", gripLengthMM: 10))
        let part = Workpiece(id: "w1", name: "w1", source: study.source, studyID: study.id, ownerSpindleID: "s1",
                             worldFromWorkpiece: .identity, gripLengthMM: 10, envelopeRadiusMM: 10)
        return ManufacturingCell(
            name: "release fixture",
            turningTools: [CellTurningTool(id: "t1", name: "insert")],
            spindles: [spindle],
            turrets: [],
            channels: [.init(id: "ch1", name: "1", spindleIDs: ["s1"])],
            workpieces: [part],
            steps: [.init(id: "release", channelID: "ch1", order: 0,
                          action: .chuck(.init(spindleID: "s1", operation: .release, durationSeconds: 1)))],
            edges: [])
    }

    /// Parallel-axis donor/receiver with a 90° commanded twist transfer.
    static func twistFixture() -> ManufacturingCell {
        let frameA = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let frameB = CellFrame(originMM: [0, 0, 60], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let spindleA = Spindle(id: "sa", name: "A", frame: frameA, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "w1", gripLengthMM: 10))
        let spindleB = Spindle(id: "sb", name: "B", frame: frameB, maxRPM: 4000,
                               chuck: .init(openingDiameterMM: 30, maxOpeningDiameterMM: 80))
        let part = Workpiece(id: "w1", name: "w1", source: .init(documentID: "d", revision: 1, contentSHA256: String(repeating: "a", count: 64)),
                             studyID: UUID(), ownerSpindleID: "sa",
                             worldFromWorkpiece: .identity, gripLengthMM: 10, lengthMM: 38, envelopeRadiusMM: 10)
        return ManufacturingCell(
            name: "twist fixture",
            spindles: [spindleA, spindleB],
            turrets: [],
            channels: [.init(id: "cha", name: "A", spindleIDs: ["sa"]),
                       .init(id: "chb", name: "B", spindleIDs: ["sb"])],
            workpieces: [part],
            uncommon: .init(allowsPartEject: true),
            steps: [.init(id: "stop-a", channelID: "cha", order: 0,
                          action: .spindle(.init(spindleID: "sa", mode: .stopped, durationSeconds: 0.5))),
                    .init(id: "open-b", channelID: "chb", order: 0,
                          action: .chuck(.init(spindleID: "sb", operation: .open, openDiameterMM: 26, durationSeconds: 0.5))),
                    .init(id: "move", channelID: "cha", order: 1,
                          action: .transfer(.init(donorSpindleID: "sa", receiverSpindleID: "sb", workpieceID: "w1",
                                                  receiverGripLengthMM: 12, clearanceMM: 1, twistDegrees: 90,
                                                  acquisitionOriginMM: [0, 0, 26], durationSeconds: 2)))],
            edges: [.init(from: "open-b", to: "move")])
    }

    /// Single spindle/turret cell carrying the supplied study as one
    /// operation with optional explicit station/tool selection.
    static func singleSpindleFixture(study: ManufacturingStudy, stationToolID: String?, toolID: String?) -> ManufacturingCell {
        let frame = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let spindle = Spindle(id: "s1", name: "S", frame: frame, maxRPM: 4000,
                              chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80, clampedWorkpieceID: "w1", gripLengthMM: 10))
        let part = Workpiece(id: "w1", name: "w1", source: study.source, studyID: study.id, ownerSpindleID: "s1",
                             worldFromWorkpiece: .identity, gripLengthMM: 10, envelopeRadiusMM: 10)
        var stations: [Turret.Station] = []
        var tools: [ManufacturingCAM.Tool] = study.cam?.tools ?? []
        if let stationToolID {
            stations.append(.init(id: "st1", name: "st1", toolID: stationToolID))
        }
        let turret = Turret(id: "t1", name: "T", stations: stations.isEmpty ? [.init(id: "st1", name: "empty")] : stations,
                            initialStationID: "st1", indexDurationSeconds: 0.4, parkDurationSeconds: 2)
        return ManufacturingCell(
            name: "single spindle fixture",
            tools: tools,
            spindles: [spindle],
            turrets: [turret],
            channels: [.init(id: "ch1", name: "1", spindleIDs: ["s1"], turretIDs: ["t1"])],
            workpieces: [part],
            steps: [.init(id: "op", channelID: "ch1", order: 0,
                          action: .operate(.init(study: study, workpieceID: "w1", spindleID: "s1",
                                                 turretID: "t1", stationID: stations.isEmpty ? nil : "st1",
                                                 toolID: toolID, durationSeconds: 5)))],
            edges: [])
    }
}
