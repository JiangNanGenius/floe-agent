// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeManufacturingParameters

final class ManufacturingParameterCatalogTests: XCTestCase {

    private let catalog = ManufacturingParameterCatalog.standard

    /// The exact runtime bindings Root wires. Anything else must be
    /// configuration-only / fixed / notAvailable.
    private let expectedBindings: Set<String> = [
        "stock.radiusMM", "stock.zMinMM", "stock.zMaxMM", "stock.resolutionMM",
        "fixtures",
        "turning.enabled", "turning.stepOverMM", "turning.allowanceMM",
        "turning.finishPasses", "turning.feedMMPerMinute",
        "milling.enabled", "milling.angleDegrees", "milling.widthMM", "milling.depthMM",
        "milling.startZMM", "milling.endZMM", "milling.toolRadiusMM",
        "milling.toolLengthMM", "milling.feedMMPerMinute",
        "acMotion.toolLengthMM", "acMotion.steps", "acMotion.start", "acMotion.end",
        "budget.maxCells", "budget.maxPoses", "budget.maxTriangles",
        "millingAssembly.shankDiameterMM", "millingAssembly.holderProfile",
        "millingAssembly.clearanceMM", "budget.maxCollisionQueries",
        "turningCutting.spindleMode", "turningCutting.feedMode", "turningCutting.spindleRPM",
        "turningCutting.surfaceSpeedMPerMinute", "turningCutting.maxSpindleRPM", "turningCutting.feedMMPerRevolution",
    ]

    private let r4Bindings:Set<String> = [
        "stock.shape",
        "stock.minMM",
        "stock.maxMM",
        "budget.maxFrames",
        "budget.maxRetainedMeshBytes",
        "turningSetup.faceEnabled",
        "turningSetup.roughEnabled",
        "turningSetup.profileEnabled",
        "turningSetup.allowGrooving",
        "turningSetup.clearanceMM",
        "turningSetup.horizontalFeedMMPerMinute",
        "turningSetup.verticalFeedMMPerMinute",
        "turningSetup.leadinAngleDegrees",
        "turningSetup.leadoutAngleDegrees",
        "turningSetup.insertEdgeLengthMM",
        "turningSetup.insertRotationDegrees",
        "turningSetup.insertShape",
        "camTool.name",
        "camTool.kind",
        "camTool.diameterMM",
        "camTool.cuttingLengthMM",
        "camTool.tipAngleDegrees",
        "camTool.gaugeLengthMM",
        "camTool.flutes",
        "camTool.assembly.shankDiameterMM",
        "camTool.assembly.holderProfile",
        "camTool.assembly.clearanceMM",
        "camOperation.name",
        "camOperation.enabled",
        "camOperation.strategy",
        "camOperation.toolID",
        "camOperation.climb",
        "camOperation.springPasses",
        "camOperation.cycle",
        "camOperation.frame.originMM",
        "camOperation.frame.axis",
        "camOperation.frame.xDirection",
        "camOperation.minUVMM",
        "camOperation.maxUVMM",
        "camOperation.centerUVMM",
        "camOperation.contourUVMM",
        "camOperation.holesUVMM",
        "camOperation.acSeed",
        "camOperation.radiusMM",
        "camOperation.depthMM",
        "camOperation.stepDownMM",
        "camOperation.stepOverMM",
        "camOperation.wallStockMM",
        "camOperation.floorStockMM",
        "camOperation.breakThroughMM",
        "camOperation.clearanceMM",
        "camOperation.feedMMPerMinute",
        "camOperation.plungeFeedMMPerMinute",
        "camOperation.rapidMMPerMinute",
        "camOperation.dwellSeconds",
        "camOperation.peckDepthMM",
        "camOperation.chipBreakRetractMM",
        "camOperation.cutting.toolSpindleRPM",
        "camOperation.cutting.feedPerToothMM",
        "camOperation.cutting.feedPerRevolutionMM",
        "camOperation.cutting.mode",
    ]

    func testCatalogSelfConsistency() {
        XCTAssertEqual(catalog.validate(), [], "catalog has structural problems")
    }

    func testPreviewUsedBindingsMatchRootContractExactly() {
        let bound = Set(catalog.parameters.compactMap(\.binding))
        let expected = expectedBindings.union(r4Bindings)
        XCTAssertEqual(bound, expected,
                       "binding drift: missing \(expected.subtracting(bound)), extra \(bound.subtracting(expected))")
        for descriptor in catalog.parameters where descriptor.support == .previewUsed {
            XCTAssertNotNil(descriptor.binding)
        }
        // Low-frequency controls can be executable; rarity is a UI filter, not a capability flag.
        XCTAssertEqual(Set(catalog.parameters.filter { $0.support == .previewUsed && $0.rare }.map(\.id)),
                       ["feeds.spindle.cssMPerMin", "feeds.cutting.mmPerRevolution", "machine.spindle.maxRPM",
                        "turning.setup.allowGrooving","turning.setup.leadinAngleDegrees","turning.setup.leadoutAngleDegrees","turning.setup.insertRotationDegrees",
                        "cam.tool.gaugeLengthMM","cam.tool.assembly.shankDiameterMM","cam.tool.assembly.holderProfile","cam.tool.assembly.clearanceMM",
                        "cam.operation.frame.originMM","cam.operation.frame.axis","cam.operation.frame.xDirection","cam.operation.acSeed",
                        "cam.operation.wallStockMM","cam.operation.floorStockMM","cam.operation.breakThroughMM","cam.operation.dwellSeconds","cam.operation.chipBreakRetractMM",
                        "verification.runtime.maxFrames","verification.runtime.maxRetainedMeshBytes"])
    }

    func testFixedParametersAreHonest() {
        // Two distinct fixed nose-radius records, both pinned at 0.4 mm:
        //  - tool.turning.noseRadiusMM — the tool-definition side (ISO DCMT insert record)
        //  - turning.toolNoseRadiusMM  — the Study/operation-side fixed prototype field
        // plus the frozen table_table kinematic chain. Stock form is executable in R4.
        let fixed = catalog.parameters.filter { $0.support == .fixed }
        XCTAssertEqual(Set(fixed.map(\.id)),
                       ["tool.turning.noseRadiusMM", "turning.toolNoseRadiusMM", "machine.kinematic.type"])
        XCTAssertEqual(catalog.lookup("tool.turning.noseRadiusMM")?.defaultValue, .number(0.4))
        XCTAssertEqual(catalog.lookup("turning.toolNoseRadiusMM")?.defaultValue, .number(0.4))
        XCTAssertEqual(catalog.lookup("turning.toolNoseRadiusMM")?.kind, .number)
        for descriptor in fixed {
            XCTAssertNil(descriptor.binding, "fixed parameters must not claim runtime bindings: \(descriptor.id)")
        }
    }

    func testCellFlagsDoNotPretendToActivateResourcesInASingleStudy() {
        let ids = Set(catalog.parameters.filter { $0.support == .notAvailable }.map(\.id))
        XCTAssertEqual(ids, [])
        for id in ["machine.spindle.dualEnabled", "machine.turret.enabled", "machine.channels.count"] {
            XCTAssertEqual(catalog.lookup(id)?.support,.configurationOnly)
            XCTAssertNil(catalog.lookup(id)?.binding)
        }
    }

    func testAllParametersHaveBilingualMetadataAndSources() {
        for descriptor in catalog.parameters {
            XCTAssertFalse(descriptor.nameZH.isEmpty, descriptor.id)
            XCTAssertFalse(descriptor.nameEN.isEmpty, descriptor.id)
            XCTAssertFalse(descriptor.helpZH.isEmpty, descriptor.id)
            XCTAssertFalse(descriptor.helpEN.isEmpty, descriptor.id)
            XCTAssertFalse(descriptor.sourceRefs.isEmpty, "missing sourceRefs: \(descriptor.id)")
        }
    }

    func testEveryParameterBelongsToAGroup() {
        let groupIDs = Set(catalog.groups.map(\.id))
        for descriptor in catalog.parameters {
            XCTAssertTrue(groupIDs.contains(descriptor.groupID), descriptor.id)
        }
    }

    func testFamiliesAreCovered() {
        // Spot-check the named task families exist in the catalog.
        let ids = Set(catalog.parameters.map(\.id))
        let expectedIDs: Set<String> = [
            // tool assemblies
            "tool.assembly.kind", "tool.assembly.flutes", "tool.assembly.helixAngleDegrees",
            "tool.assembly.overallLengthMM", "tool.assembly.shankDiameterMM",
            "tool.assembly.gaugeLengthMM", "tool.assembly.overhangMM",
            "tool.assembly.holderName", "tool.assembly.holderType", "tool.assembly.holderProfile",
            "tool.assembly.wearLengthOffsetMM", "tool.assembly.wearRadiusOffsetMM",
            "tool.mill.diameterMM", "tool.mill.cornerRadiusMM", "tool.mill.pointAngleDegrees",
            "tool.drill.diameterMM", "tool.reamer.diameterMM", "tool.tap.pitchMM",
            "tool.turning.isoString", "tool.turning.insertShape", "tool.turning.noseRadiusMM",
            "tool.turning.insertICMM", "tool.turning.chipbreaker", "tool.turning.edgePreparation",
            "tool.grooving.insertWidthMM", "tool.boring.barDiameterMM",
            // stock / material / workholding
            "stock.material.name", "stock.material.surfaceSpeedMPerMin",
            "workholding.fixtures", "workholding.datum.origin", "workholding.tailstock.enabled",
            // feeds
            "feeds.spindle.rpm", "feeds.spindle.cssMPerMin", "feeds.cutting.mmPerTooth",
            "feeds.cutting.mmPerRevolution", "feeds.plunge.mmPerMin", "feeds.coolant.mode",
            // milling engagements / entry-exit
            "milling.stepDownMM", "milling.stepOverRatio", "milling.maxEngagementDegrees",
            "milling.stockToLeaveMM", "milling.breakThroughMM", "milling.direction",
            "milling.entryMode", "milling.entryRampAngleDegrees", "milling.entryHelixRadiusMM",
            "motion.clearanceHeightMM", "motion.safeHeightMM",
            "motion.leadIn.lengthMM", "motion.leadIn.angleDegrees", "motion.leadOut.lengthMM",
            // operations
            "ops.pocket.mode", "ops.contour.side", "ops.pencil.thresholdDegrees",
            "ops.restMachining.enabled",
            // drilling / threading
            "holes.cycle", "holes.peck.depthMM", "holes.peck.retractMM",
            "holes.dwell.seconds", "holes.breakThroughMM", "holes.boring.dwellSeconds",
            "threads.tapping.pitchMM", "threads.tapping.mode",
            "threads.milling.diameterMM", "threads.milling.pitchMM", "threads.milling.segmentsPerRevolution",
            "threads.turning.pitchMM", "threads.turning.infeedAngleDegrees",
            // turning
            "turning.allowGrooving", "turning.horizontalFeedMMPerMin", "turning.verticalFeedMMPerMin",
            "turning.clearanceMM", "turning.leadIn.angleDegrees", "turning.leadOut.angleDegrees",
            "turning.operation", "turning.parting.feedMMPerMin",
            // 5-axis
            "fiveAxis.strategy", "fiveAxis.orientation.aDegrees", "fiveAxis.orientation.cDegrees",
            "fiveAxis.leadAngleDegrees", "fiveAxis.tiltAngleDegrees",
            "fiveAxis.swarf.zTopMM", "fiveAxis.swarf.numPasses", "fiveAxis.swarf.overhangCompensation",
            "fiveAxis.rough.aSteps", "fiveAxis.rough.cSteps",
            "acMotion.start", "acMotion.end",
            // machine
            "machine.axis.a.minDegrees", "machine.axis.a.maxDegrees",
            "machine.axis.c.minDegrees", "machine.travel.xMM",
            "machine.spindle.maxRPM", "machine.feed.maxMMPerMin",
            "machine.accel.maxMMPerSec2", "machine.jerk.maxMMPerSec3",
            "machine.channels.count", "machine.spindle.dualEnabled", "machine.turret.enabled",
            // verification / export
            "verification.collision.holderCheck", "verification.gouge.checkEnabled",
            "verification.singularity.sinThreshold", "budget.maxCells",
            "export.post.name", "export.post.programNumber", "export.post.units",
        ]
        XCTAssertTrue(expectedIDs.isSubset(of: ids),
                      "missing families: \(expectedIDs.subtracting(ids).sorted())")
    }

    func testSearchFiltersRare() {
        let rareResults = catalog.search(query: "holder", includeRare: true)
        let commonResults = catalog.search(query: "holder", includeRare: false)
        XCTAssertFalse(rareResults.isEmpty)
        XCTAssertLessThan(commonResults.count, rareResults.count)
        XCTAssertFalse(commonResults.contains { $0.rare })
        // Case-insensitive id match.
        XCTAssertTrue(catalog.search(query: "ACMotion", includeRare: true)
            .contains { $0.id == "acMotion.steps" })
        // Empty query returns everything (respecting includeRare).
        XCTAssertEqual(catalog.search(query: "", includeRare: false).count,
                       catalog.parameters.filter { !$0.rare }.count)
    }

    func testCatalogCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ManufacturingParameterCatalog.self, from: data)
        XCTAssertEqual(decoded, catalog)
    }
}
