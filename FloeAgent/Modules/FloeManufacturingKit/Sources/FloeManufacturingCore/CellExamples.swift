// SPDX-License-Identifier: MPL-2.0
import Foundation

/// R5 demonstration programs for the multi-spindle/multi-turret cell model.
/// All studies are small research fixtures; times are nominal supplied
/// values, not measured cycle times. Nothing here claims physical-safety
/// certification.
public extension ManufacturingCell {
    /// Opposing-spindle, two-turret cell: main spindle at the origin (+Z
    /// into the part), sub spindle facing it from z = 80 mm with an
    /// antiparallel axis (−Z). Channel 1 machines the front of wp1 while
    /// channel 2 independently drills wp2; a collective barrier, a
    /// matched-RPM synchronization and a coordinated chuck-to-chuck transfer
    /// hand wp1 over for back-side turning on the sub spindle. wp2 is
    /// ejected to the part catcher (the cell opts into eject explicitly).
    static func opposingSpindleTwoTurret(includeSync: Bool = true,
                                         receiverGripMM: Double = 12,
                                         waitPointName: String = "transfer-done",
                                         extraEdges: [CellEdge] = []) -> ManufacturingCell {
        let mainFrame = CellFrame(originMM: [0, 0, 0], axis: [0, 0, 1], xDirection: [1, 0, 0])
        let subFrame = CellFrame(originMM: [0, 0, 80], axis: [0, 0, -1], xDirection: [1, 0, 0])

        // Identified turning inserts (fixed 0.4 mm nose contract).
        let insertMain = CellTurningTool(id: "turning-insert-main", name: "D-style insert (main)")
        let insertSub = CellTurningTool(id: "turning-insert-sub", name: "D-style insert (sub)")
        // Identified live tools for the independent drilling job.
        let drill = ManufacturingCAM.Tool.researchExample(id: "drill-2", kind: "drill")

        var frontStudy = ManufacturingStudy.shaft()
        frontStudy.turningToolID = "turning-insert-main"
        frontStudy.turningCutting = .init(spindleMode: .fixedRPM, feedMode: .mmPerMinute,
                                          spindleRPM: 1500, surfaceSpeedMPerMinute: 100,
                                          maxSpindleRPM: 6000, feedMMPerRevolution: 0.1)
        var backStudy = ManufacturingStudy.shaft()
        backStudy.name = "阶梯轴背面"
        backStudy.turningToolID = "turning-insert-sub"
        // Only face the newly exposed lower end. Re-running a full external
        // profile through the receiver's grip would machine the clamped zone.
        var backsideSetup = TurningSetup()
        backsideSetup.roughEnabled = false;backsideSetup.profileEnabled = false
        backStudy.turningSetup = backsideSetup
        backStudy.fixtures = [.init(id:"receiver-chuck",minMM:[-15,-15,26],maxMM:[15,15,46])]
        backStudy.turningCutting = .init(spindleMode: .fixedRPM, feedMode: .mmPerMinute,
                                         spindleRPM: 800, surfaceSpeedMPerMinute: 100,
                                         maxSpindleRPM: 6000, feedMMPerRevolution: 0.1)
        // Same study identity and source: back-side features belong to the
        // same part. Real additional removal: the negative-Z approach trims
        // the original lower end, so the target profile starts at z = 2 and
        // retains the remaining shape (front work is not rerun).
        backStudy.id = frontStudy.id
        backStudy.turningApproach = .negativeZ
        backStudy.profile = [.init(10, 2), .init(10, 15), .init(7, 15), .init(7, 28), .init(5, 28), .init(5, 38)]
        backStudy.source = frontStudy.source

        var drillStudy = ManufacturingStudy.shaft()
        drillStudy.name = "轴向钻削"
        drillStudy.turning.enabled = false
        // A short second blank leaves axial space for the declared cutter,
        // rather than putting two long workpieces almost end-to-end.
        drillStudy.stock.zMaxMM = 20
        drillStudy.profile = [.init(10,0),.init(10,20)]
        drillStudy.source = .init(documentID:"fixture:drill-blank-20mm",revision:1,
            contentSHA256:ManufacturingStudy.digest(Data("radius12-z0-20-drill-blank".utf8)))
        var hole = ManufacturingCAM.Operation(id: "axial-hole", name: "轴向孔", strategy: "drill", toolID: drill.id)
        hole.frame.originMM = [0, 0, 20]
        hole.holesUVMM = [[0, 0]]
        hole.depthMM = 3
        hole.cycle = "drill"
        drillStudy.cam = ManufacturingCAM(tools: [drill], operations: [hole])

        let main = Spindle(id: "main", name: "Main spindle", frame: mainFrame, maxRPM: 6000,
                           initialMode: .stopped, initialPhaseDegrees: 0,
                           chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80,
                                        clampedWorkpieceID: "wp1", gripLengthMM: 10))
        let sub = Spindle(id: "sub", name: "Sub spindle", frame: subFrame, maxRPM: 6000,
                          initialMode: .stopped, initialPhaseDegrees: 0,
                          chuck: .init(openingDiameterMM: 24, maxOpeningDiameterMM: 80,
                                       clampedWorkpieceID: "wp2", gripLengthMM: 8))
        let turretUpper = Turret(id: "turret-upper", name: "Upper turret",
                                 stations: [.init(id: "tu-s1", name: "Turning station", turningToolID: insertMain.id),
                                            .init(id: "tu-s2", name: "Drill station", toolID: drill.id)],
                                 initialStationID: "tu-s1", indexDurationSeconds: 0.4, parkDurationSeconds: 2)
        let turretLower = Turret(id: "turret-lower", name: "Lower turret",
                                 stations: [.init(id: "tl-s1", name: "Turning station", turningToolID: insertSub.id),
                                            .init(id: "tl-s2", name: "Drill station", toolID: drill.id)],
                                 initialStationID: "tl-s1", indexDurationSeconds: 0.4, parkDurationSeconds: 2)
        let wp1 = Workpiece(id: "wp1", name: "Shaft", source: frontStudy.source, studyID: frontStudy.id,
                            ownerSpindleID: "main",
                            worldFromWorkpiece: .identity,
                            gripLengthMM: 10, lengthMM: 38, envelopeRadiusMM: 10)
        let wp2 = Workpiece(id: "wp2", name: "Drilled blank", source: drillStudy.source, studyID: drillStudy.id,
                            ownerSpindleID: "sub",
                            worldFromWorkpiece: subFrame.transform,
                            gripLengthMM: 8, lengthMM: 20, envelopeRadiusMM: 12)

        var steps: [CellStep] = []
        var edges: [CellEdge] = [
            .init(from: "sub-open", to: "main-transfer"),
            // Collective barrier participation on the sub channel: handover
            // prep begins only after both channels arrive.
            .init(from: "main-barrier", to: "sub-release"),
            .init(from: "main-barrier", to: "sub-open"),
        ]
        var waitPoints: [CellNamedWaitPoint] = []

        // Channel 1: front-side turning on wp1.
        steps.append(.init(id: "main-rpm-1500", channelID: "ch-main", order: 0,
                           action: .spindle(.init(spindleID: "main", mode: .rpm, rpm: 1500,
                                                 direction: .cw, durationSeconds: 2))))
        steps.append(.init(id: "main-approach", channelID: "ch-main", order: 1,
                           action: .approach(.init(turretID: "turret-upper", spindleID: "main",
                                                   workpieceID: "wp1", durationSeconds: 1, clearanceMM: 3))))
        steps.append(.init(id: "main-front-op", channelID: "ch-main", order: 2,
                           action: .operate(.init(study: frontStudy, workpieceID: "wp1", spindleID: "main",
                                                  turretID: "turret-upper", stationID: "tu-s1",
                                                  turningToolID: insertMain.id, durationSeconds: 30))))
        steps.append(.init(id: "main-retract", channelID: "ch-main", order: 3,
                           action: .retract(.init(turretID: "turret-upper", spindleID: "main", durationSeconds: 1))))
        var mainOrder = 4
        if includeSync {
            steps.append(.init(id: "main-stop", channelID: "ch-main", order: mainOrder,
                               action: .spindle(.init(spindleID: "main", mode: .stopped, durationSeconds: 1.5))))
            mainOrder += 1
        }
        steps.append(.init(id: "main-barrier", channelID: "ch-main", order: mainOrder,
                           action: .barrier(.init(channelIDs: ["ch-main", "ch-sub"]))))
        mainOrder += 1
        if includeSync {
            steps.append(.init(id: "main-rpm-800", channelID: "ch-main", order: mainOrder,
                               action: .spindle(.init(spindleID: "main", mode: .rpm, rpm: 800,
                                                     direction: .cw, durationSeconds: 2))))
            mainOrder += 1
            steps.append(.init(id: "main-sync", channelID: "ch-main", order: mainOrder,
                               action: .synchronize(.init(spindleIDs: ["main", "sub"], mode: .matchedRPM,
                                                          speedRatio: 1, phaseToleranceDegrees: 5,
                                                          targetPhaseOffsetDegrees: 0, durationSeconds: 2))))
            mainOrder += 1
        }
        steps.append(.init(id: "main-transfer", channelID: "ch-main", order: mainOrder,
                           action: .transfer(.init(donorSpindleID: "main", receiverSpindleID: "sub",
                                                   workpieceID: "wp1", receiverGripLengthMM: receiverGripMM,
                                                   clearanceMM: 1, twistDegrees: 0,
                                                   acquisitionOriginMM: [0, 0, 38],
                                                   retractOriginMM: [0, 0, 80],
                                                   durationSeconds: 6))))
        mainOrder += 1
        steps.append(.init(id: "main-park", channelID: "ch-main", order: mainOrder,
                           action: .parkTurret(.init(turretID: "turret-upper"))))
        mainOrder += 1
        steps.append(.init(id: "main-final-stop", channelID: "ch-main", order: mainOrder,
                           action: .spindle(.init(spindleID: "main", mode: .stopped, durationSeconds: 1.5))))

        // Channel 2: independent drilling on wp2, eject, then back-side turning on wp1.
        steps.append(.init(id: "sub-rpm-2000", channelID: "ch-sub", order: 0,
                           action: .spindle(.init(spindleID: "sub", mode: .rpm, rpm: 2000,
                                                 direction: .ccw, durationSeconds: 2))))
        steps.append(.init(id: "sub-index-drill", channelID: "ch-sub", order: 1,
                           action: .indexTurret(.init(turretID: "turret-lower", stationID: "tl-s2"))))
        steps.append(.init(id: "sub-approach", channelID: "ch-sub", order: 2,
                           action: .approach(.init(turretID: "turret-lower", spindleID: "sub",
                                                   workpieceID: "wp2", durationSeconds: 1, clearanceMM: 3))))
        steps.append(.init(id: "sub-drill-op", channelID: "ch-sub", order: 3,
                           action: .operate(.init(study: drillStudy, workpieceID: "wp2", spindleID: "sub",
                                                  turretID: "turret-lower", stationID: "tl-s2",
                                                  toolID: drill.id, durationSeconds: 18))))
        steps.append(.init(id: "sub-retract", channelID: "ch-sub", order: 4,
                           action: .retract(.init(turretID: "turret-lower", spindleID: "sub", durationSeconds: 1))))
        var subOrder = 5
        if includeSync {
            steps.append(.init(id: "sub-stop", channelID: "ch-sub", order: subOrder,
                               action: .spindle(.init(spindleID: "sub", mode: .stopped, durationSeconds: 1.5))))
            subOrder += 1
        }
        steps.append(.init(id: "sub-release", channelID: "ch-sub", order: subOrder,
                           action: .chuck(.init(spindleID: "sub", operation: .release, durationSeconds: 1))))
        subOrder += 1
        steps.append(.init(id: "sub-open", channelID: "ch-sub", order: subOrder,
                           action: .chuck(.init(spindleID: "sub", operation: .open,
                                                openDiameterMM: 26, durationSeconds: 1))))
        subOrder += 1
        if includeSync {
            steps.append(.init(id: "sub-rpm-800", channelID: "ch-sub", order: subOrder,
                               action: .spindle(.init(spindleID: "sub", mode: .rpm, rpm: 800,
                                                     direction: .ccw, durationSeconds: 2))))
            edges.append(.init(from: "sub-rpm-800", to: "main-sync"))
            edges.append(.init(from: "main-barrier", to: "sub-rpm-800"))
            subOrder += 1
        }
        steps.append(.init(id: "sub-index-turn", channelID: "ch-sub", order: subOrder,
                           action: .indexTurret(.init(turretID: "turret-lower", stationID: "tl-s1"))))
        subOrder += 1
        steps.append(.init(id: "sub-wait-transfer", channelID: "ch-sub", order: subOrder,
                           action: .wait(.init(pointName: waitPointName))))
        waitPoints.append(.init(name: "transfer-done", stepIDs: ["main-transfer"]))
        subOrder += 1
        steps.append(.init(id: "sub-backside-op", channelID: "ch-sub", order: subOrder,
                           action: .operate(.init(study: backStudy, workpieceID: "wp1", spindleID: "sub",
                                                  turretID: "turret-lower", stationID: "tl-s1",
                                                  turningToolID: insertSub.id, durationSeconds: 25,
                                                  stockDependencyIDs: ["main-front-op", "main-transfer"]))))
        subOrder += 1
        steps.append(.init(id: "sub-retract-2", channelID: "ch-sub", order: subOrder,
                           action: .retract(.init(turretID: "turret-lower", spindleID: "sub", durationSeconds: 1))))
        subOrder += 1
        steps.append(.init(id: "sub-dwell", channelID: "ch-sub", order: subOrder,
                           action: .dwell(.init(seconds: 1, workpieceID: "wp1"))))
        edges.append(contentsOf: extraEdges)

        return ManufacturingCell(
            name: "Opposing spindle two-turret demo",
            tools: [drill],
            turningTools: [insertMain, insertSub],
            spindles: [main, sub],
            turrets: [turretUpper, turretLower],
            channels: [.init(id: "ch-main", name: "Channel 1", spindleIDs: ["main"], turretIDs: ["turret-upper"]),
                       .init(id: "ch-sub", name: "Channel 2", spindleIDs: ["sub"], turretIDs: ["turret-lower"])],
            workpieces: [wp1, wp2],
            uncommon: .init(allowsPartEject: true),
            steps: steps,
            waitPoints: waitPoints,
            edges: edges)
    }

    /// Convenience: plan the demonstration program.
    static func opposingSpindleTwoTurretSchedule() throws -> CellSchedule {
        try CellPlanner().plan(opposingSpindleTwoTurret())
    }

    // MARK: - Failure fixtures (each fails closed at validation or planning)

    /// Transfer with both spindles still turning and no synchronization.
    static func failureTransferWithoutSync() -> ManufacturingCell {
        opposingSpindleTwoTurret(includeSync: false)
    }
    /// Handover requesting a zero-length receiver grip.
    static func failureMissingGrip() -> ManufacturingCell {
        opposingSpindleTwoTurret(receiverGripMM: 0)
    }
    /// Cross-channel dependency cycle (conflicting locks).
    static func failureConflictingLocksCycle() -> ManufacturingCell {
        opposingSpindleTwoTurret(extraEdges: [.init(from: "main-transfer", to: "sub-drill-op"),
                                              .init(from: "sub-drill-op", to: "main-front-op")])
    }
    /// A named wait that does not resolve to any registered wait point.
    static func failureUnresolvedNamedWait() -> ManufacturingCell {
        opposingSpindleTwoTurret(waitPointName: "no-such-point")
    }
    /// One operation carrying a combined turning+slot study.
    static func failureCombinedTurnSlot() throws -> ManufacturingCell {
        var combined = ManufacturingStudy.shaft(milled: true)
        combined.turningToolID = "turning-insert-main"
        combined.millingToolID = "mill-4"
        let mill = ManufacturingCAM.Tool.researchExample(id: "mill-4")
        var cell = opposingSpindleTwoTurret()
        cell.steps.append(.init(id: "main-combined-op", channelID: "ch-main", order: 11,
                                action: .operate(.init(study: combined, workpieceID: "wp1", spindleID: "main",
                                                       turretID: "turret-upper", stationID: "tu-s1",
                                                       turningToolID: "turning-insert-main", durationSeconds: 10))))
        cell.tools.append(mill)
        return cell
    }
}
