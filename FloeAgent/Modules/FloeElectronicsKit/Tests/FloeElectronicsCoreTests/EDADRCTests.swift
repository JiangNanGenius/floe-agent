// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDADRCTests {
    private struct Fixture {
        var project = EDAProject(title: "Measured board")
        var a = ""
        var b = ""
        init() throws {
            project.sheets[0].labels = [.init(name: "A", position: .init(0, 0), scope: .global),
                                        .init(name: "B", position: .init(10, 0), scope: .global)]
            let list = try EDAConnectivity.derive(project)
            a = list.nets.first { $0.name == "A" }!.id; b = list.nets.first { $0.name == "B" }!.id
            project.boards[0].drcConstraints = .init(minimumTrackWidth: 0.1, minimumViaDiameter: 0.4,
                                                    minimumViaDrill: 0.2, minimumViaAnnularWidth: 0.1)
        }
        mutating func pad(_ p: EDAPoint, net: String? = nil, size: EDAPoint = .init(1, 1), shape: EDAPadShape = .circle,
                          angle: Double = 0, local: EDAPoint = .zero, layers: [String] = ["F.Cu"], drill: Double? = nil,
                          side: String = "F.Cu", footprintAngle: Double = 0) -> EDADRCObject {
            let pad = EDAPad(number: "1", position: local, size: size, angle: angle, shape: shape, drill: drill, layers: layers)
            let def = EDAFootprintDefinition(name: "Pad", pads: [pad]); project.footprints.append(def)
            let fp = EDAFootprint(definitionID: def.id, position: p, angle: footprintAngle, side: side,
                                  padNets: net.map { ["1": $0] } ?? [:])
            project.boards[0].footprints.append(fp)
            return .init(kind: .pad, objectID: pad.id, footprintID: fp.id, padNumber: "1")
        }
        mutating func track(_ points: [EDAPoint], net: String? = nil, width: Double = 0.2, layer: String = "F.Cu") -> UUID {
            let item = EDATrack(netID: net ?? a, layer: layer, width: width, points: points)
            project.boards[0].tracks.append(item); return item.id
        }
        mutating func via(_ p: EDAPoint, net: String? = nil, diameter: Double = 0.6, drill: Double = 0.3,
                          start: String = "F.Cu", end: String = "B.Cu") -> UUID {
            let item = EDAVia(netID: net ?? a, position: p, diameter: diameter, drill: drill, startLayer: start, endLayer: end)
            project.boards[0].vias.append(item); return item.id
        }
        func report() throws -> EDADRCReport { try EDADRC.check(project, boardID: project.boards[0].id) }
    }
    private func issues(_ report: EDADRCReport, _ rule: EDADRCRule) -> [EDADRCIssue] {
        report.issues.filter { $0.rule == rule && $0.severity == .error }
    }
    private func square(_ x: Double, _ y: Double, _ size: Double) -> [EDAPoint] {
        [.init(x, y), .init(x + size, y), .init(x + size, y + size), .init(x, y + size)]
    }

    @Test func parallelTrackClearanceUsesSurfaceDistanceAndLocatedWitnesses() throws {
        var f = try Fixture()
        let a = f.track([.init(10, 10), .init(20, 10)])
        let b = f.track([.init(10, 10.35), .init(20, 10.35)], net: f.b)
        let issue = try #require(issues(f.report(), .copperClearance).first)
        #expect(abs(try #require(issue.measured) - 0.15) < 0.000_001)
        #expect(issue.required == 0.2 && issue.layer == "F.Cu" && issue.severity == .error)
        #expect(Set(issue.objects.map(\.objectID)) == [a, b])
        #expect(abs(issue.position.distance(to: try #require(issue.relatedPosition)) - 0.15) < 0.000_001)
        #expect(!issue.ruleSourceIDs.isEmpty)
    }

    @Test func exactThresholdAndOverlappingDiagonalBoundsDoNotCreateFalseViolations() throws {
        var f = try Fixture()
        _ = f.track([.init(10, 10), .init(20, 10)])
        _ = f.track([.init(10, 10.4), .init(20, 10.4)], net: f.b)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
        f.project.boards[0].tracks = []
        _ = f.track([.init(10, 10), .init(20, 20)])
        _ = f.track([.init(10, 11), .init(20, 21)], net: f.b)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
    }

    @Test func crossNetCrossingIsAContactButSameNetCrossingActuallyJoins() throws {
        var f = try Fixture()
        _ = f.track([.init(10, 15), .init(20, 15)])
        _ = f.track([.init(15, 10), .init(15, 20)], net: f.b)
        let crossed = try f.report()
        #expect(issues(crossed, .copperClearance).contains { $0.code == "copper_contact" && $0.measured == 0 })
        f.project.boards[0].tracks[1].netID = f.a
        let joined = try f.report()
        #expect(issues(joined, .copperClearance).isEmpty)
        #expect(joined.routing[0].copperComponents.count == 1 && joined.routing[0].remainingConnections.isEmpty)
    }

    @Test func zeroClearanceStillReportsDifferentNetPhysicalContact() throws {
        var f = try Fixture(); f.project.boards[0].netClasses = []
        f.project.boards[0].drcConstraints?.minimumCopperClearance = 0
        _ = f.track([.init(10, 15), .init(20, 15)])
        _ = f.track([.init(15, 10), .init(15, 20)], net: f.b)
        #expect(try issues(f.report(), .copperClearance).contains { $0.code == "copper_contact" })
    }

    @Test func circularPadsDoNotUseTheirBoundingRectangle() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a, size: .init(2, 2))
        _ = f.track([.init(10.9, 10.9), .init(12, 12)], net: f.b, width: 0.1)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
    }

    @Test func rotatedRectanglePadHasAnExactRotatedContour() throws {
        var f = try Fixture(); _ = f.pad(.init(15, 15), net: f.a, size: .init(4, 1), shape: .rectangle, angle: 45)
        let unit = sqrt(0.5), along = EDAPoint(unit, unit), normal = EDAPoint(-unit, unit)
        _ = f.track([.init(15, 15) + normal * 0.7 - along, .init(15, 15) + normal * 0.7 + along], net: f.b)
        let report = try f.report(), issue = try #require(issues(report, .copperClearance).first)
        #expect(abs(try #require(issue.measured) - 0.1) < 0.000_001)
        f.project.boards[0].tracks[0].points = [.init(15, 15) + normal - along, .init(15, 15) + normal + along]
        #expect(try issues(f.report(), .copperClearance).isEmpty)
    }

    @Test func ovalPadUsesRoundedEndsInsteadOfABox() throws {
        var f = try Fixture(); _ = f.pad(.init(15, 15), net: f.a, size: .init(4, 2), shape: .oval)
        _ = f.track([.init(16.9, 15.9), .init(18, 17)], net: f.b, width: 0.1)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
        f.project.boards[0].tracks[0].points = [.init(17.1, 15), .init(18, 15)]
        let issue = try #require(issues(f.report(), .copperClearance).first)
        #expect(abs(try #require(issue.measured) - 0.05) < 0.000_001)
    }

    @Test func bottomPlacementMirrorsPadPositionAndSwapsCopperFace() throws {
        var f = try Fixture()
        let pad = f.pad(.init(20, 20), net: f.a, angle: 20, local: .init(3, 0), side: "B.Cu", footprintAngle: 90)
        _ = f.track([.init(19, 17), .init(21, 17)], net: f.b, layer: "B.Cu")
        _ = f.track([.init(19, 17), .init(21, 17)], net: f.b, layer: "F.Cu")
        let report = try f.report()
        let hits = issues(report, .copperClearance).filter { $0.objects.contains(pad) }
        #expect(hits.count == 1 && hits[0].layer == "B.Cu")
    }

    @Test func padInstancesHaveIndependentDiagnosticIdentities() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a)
        var copy = f.project.boards[0].footprints[0]; copy.id = UUID(); copy.position = .init(10.2, 10); copy.padNets["1"] = f.b
        f.project.boards[0].footprints.append(copy)
        let issue = try #require(issues(f.report(), .copperClearance).first)
        #expect(issue.objects.count == 2 && Set(issue.objects.map(\.objectID)).count == 1)
        #expect(Set(issue.objects.compactMap(\.footprintID)).count == 2)
    }

    @Test func unassignedOverlappingPadsAreNotAssumedToShareANet() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10)); _ = f.pad(.init(10, 10))
        #expect(try issues(f.report(), .copperClearance).contains { $0.code == "copper_contact" && $0.netIDs.isEmpty })
    }

    @Test func explicitMinimaCheckWidthDiameterDrillAndAnnulusIndependently() throws {
        var f = try Fixture()
        f.project.boards[0].drcConstraints = .init(minimumTrackWidth: 0.3, minimumViaDiameter: 0.6,
                                                  minimumViaDrill: 0.3, minimumViaAnnularWidth: 0.15)
        let track = f.track([.init(10, 10), .init(20, 10)], width: 0.25)
        let via = f.via(.init(30, 30), diameter: 0.5, drill: 0.25)
        let report = try f.report()
        #expect(issues(report, .trackWidth).first?.objects.first?.objectID == track)
        #expect(issues(report, .viaDiameter).first?.measured == 0.5)
        #expect(issues(report, .viaDrill).first?.measured == 0.25)
        #expect(issues(report, .viaAnnularWidth).first?.measured == 0.125)
        #expect(issues(report, .viaAnnularWidth).first?.objects.first?.objectID == via)
    }

    @Test func netClassPreferredSizesAreNeverInventedAsMinima() throws {
        var f = try Fixture(); f.project.boards[0].drcConstraints = nil
        f.project.boards[0].netClasses[0].trackWidth = 5
        f.project.boards[0].netClasses[0].viaDiameter = 10; f.project.boards[0].netClasses[0].viaDrill = 5
        _ = f.track([.init(10, 10), .init(20, 10)], width: 0.1); _ = f.via(.init(30, 30))
        let report = try f.report()
        #expect(!report.isCompleteForSupportedChecks)
        #expect([EDADRCRule.trackWidth, .viaDiameter, .viaDrill, .viaAnnularWidth].allSatisfy { rule in
            issues(report, rule).isEmpty && report.coverage.first { $0.rule == rule }?.isComplete == false
        })
    }

    @Test func missingClearancePoliciesStayUnverifiedEvenWithOnlyOneConductor() throws {
        var f = try Fixture()
        f.project.boards[0].netClasses = [.init(name: "B only", netNames: ["B"])]
        _ = f.track([.init(10, 10), .init(20, 10)])
        let report = try f.report()
        #expect(report.issues.contains { $0.code == "copper_clearance_unset" })
        #expect(report.coverage.first { $0.rule == .copperClearance }?.isComplete == false)
    }

    @Test func exactNamedAndIdentityClassClearancesUseStricterMatchingRule() throws {
        var f = try Fixture()
        f.project.boards[0].netClasses += [.init(name: "Named", netNames: ["A"], clearance: 0.4),
                                          .init(name: "ID", netNames: [f.a], clearance: 0.5)]
        _ = f.track([.init(10, 10), .init(20, 10)])
        _ = f.track([.init(10, 10.65), .init(20, 10.65)], net: f.b)
        let issue = try #require(issues(f.report(), .copperClearance).first)
        let measured = try #require(issue.measured)
        #expect(issue.required == 0.5 && abs(measured - 0.45) < 0.000_001)
        f.project.boards[0].drcConstraints?.minimumCopperClearance = 0.6
        #expect(try issues(f.report(), .copperClearance).first?.required == 0.6)
    }

    @Test func drilledViaApertureIsNotFilledWithImaginaryCopper() throws {
        var f = try Fixture(); f.project.boards[0].netClasses[0].clearance = 0.4
        _ = f.via(.init(20, 20), diameter: 2, drill: 1)
        _ = f.track([.init(20, 20), .init(20, 20)], net: f.b, width: 0.1)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
        f.project.boards[0].netClasses[0].clearance = 0.5
        let issue = try #require(issues(f.report(), .copperClearance).first)
        let measured = try #require(issue.measured)
        #expect(issue.code == "copper_clearance" && abs(measured - 0.45) < 0.000_001)
    }

    @Test func touchingAnotherLayerNeedsAViaAndTheViaReallyBridgesLayers() throws {
        var f = try Fixture()
        _ = f.track([.init(10, 15), .init(15, 15)])
        _ = f.track([.init(15, 15), .init(20, 15)], layer: "B.Cu")
        let before = try #require(f.report().routing.first { $0.netID == f.a })
        #expect(before.copperComponents.count == 2 && before.remainingConnections.count == 1)
        #expect(before.remainingConnections[0].requiresLayerTransition && before.remainingConnections[0].gap == 0)
        _ = f.via(.init(15, 15))
        let after = try #require(f.report().routing.first { $0.netID == f.a })
        #expect(after.copperComponents.count == 1 && after.remainingConnections.isEmpty)
    }

    @Test func viaSpanUsesStackupCopperOrderAndDoesNotBridgeUnspannedLayers() throws {
        var f = try Fixture()
        f.project.boards[0].layers.insert(contentsOf: [.init("In1.Cu", kind: .copper), .init("In2.Cu", kind: .copper)], at: 1)
        _ = f.track([.init(10, 15), .init(15, 15)], layer: "In1.Cu")
        _ = f.track([.init(15, 15), .init(20, 15)], layer: "In2.Cu")
        _ = f.via(.init(15, 15), start: "F.Cu", end: "In1.Cu")
        #expect(try f.report().routing.first { $0.netID == f.a }?.copperComponents.count == 2)
        f.project.boards[0].vias[0].endLayer = "B.Cu"
        #expect(try f.report().routing.first { $0.netID == f.a }?.remainingConnections.isEmpty == true)
    }

    @Test func separateSameNetIslandsProduceComponentMinusOneConnectionsNotNetCount() throws {
        var f = try Fixture()
        _ = f.pad(.init(10, 10), net: f.a); _ = f.pad(.init(20, 10), net: f.a); _ = f.pad(.init(30, 10), net: f.a)
        _ = f.pad(.init(40, 10), net: f.b)
        let report = try f.report(), status = try #require(report.routing.first { $0.netID == f.a })
        #expect(report.routing.count == 2 && status.copperComponents.count == 3)
        #expect(status.remainingConnections.count == 2 && issues(report, .unconnectedNet).count == 2)
        #expect(status.remainingConnections.allSatisfy { abs($0.gap - 9) < 0.000_001 })
        _ = f.track([.init(10, 10), .init(30, 10)])
        #expect(try f.report().routing.first { $0.netID == f.a }?.remainingConnections.isEmpty == true)
    }

    @Test func missingOrStaleZoneFillCannotPretendToConnectPads() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a); _ = f.pad(.init(20, 10), net: f.a)
        let outline: [EDAPoint] = [.init(9, 9), .init(21, 9), .init(21, 11), .init(9, 11)]
        var zone = EDAZone(netID: f.a, outline: outline); f.project.boards[0].zones = [zone]
        var report = try f.report()
        #expect(report.issues.contains { $0.code == "zone_fill_missing" })
        #expect(report.routing[0].remainingConnections.count == 1 && !report.isCompleteForSupportedChecks)
        zone.filledPolygons = [outline]; zone.fillRevision = f.project.revision
        f.project.boards[0].zones = [zone]; report = try f.report()
        #expect(report.routing[0].remainingConnections.isEmpty && report.isCompleteForSupportedChecks)
        f.project.revision += 1; report = try f.report()
        #expect(report.issues.contains { $0.code == "zone_fill_stale" } && report.routing[0].remainingConnections.count == 1)
    }

    @Test func disjointFilledPolygonsDoNotJoinJustBecauseTheyShareAZoneID() throws {
        var f = try Fixture(); var zone = EDAZone(netID: f.a, outline: square(5, 5, 30))
        zone.fillRevision = 0; zone.filledPolygons = [square(10, 10, 2), square(20, 10, 2)]
        f.project.boards[0].zones = [zone]
        let status = try #require(f.report().routing.first)
        #expect(status.copperComponents.count == 2 && status.remainingConnections.count == 1)
        #expect(abs(status.remainingConnections[0].gap - 8) < 0.000_001)
    }

    @Test func zoneUsesFilledCopperRatherThanItsLargerOutline() throws {
        var f = try Fixture(); var zone = EDAZone(netID: f.a, outline: square(5, 5, 30))
        zone.fillRevision = 0; zone.filledPolygons = [square(10, 10, 2)]; f.project.boards[0].zones = [zone]
        _ = f.track([.init(20, 20), .init(25, 20)], net: f.b)
        #expect(try issues(f.report(), .copperClearance).isEmpty)
        f.project.boards[0].tracks[0].points = [.init(10, 11), .init(15, 11)]
        #expect(try issues(f.report(), .copperClearance).contains { $0.code == "copper_contact" })
    }

    @Test func concaveBoardNotchCatchesTracksWhoseEndpointsAndBoundsAppearInside() throws {
        var f = try Fixture()
        f.project.boards[0].outline = [.init(0, 0), .init(30, 0), .init(30, 30), .init(20, 30),
                                      .init(20, 10), .init(10, 10), .init(10, 30), .init(0, 30)]
        _ = f.track([.init(5, 20), .init(25, 20)])
        #expect(try issues(f.report(), .boardEdge).contains { $0.measured == 0 })
    }

    @Test func copperEdgeGapIncludesTrackRadiusAndCutoutInterior() throws {
        var f = try Fixture(); _ = f.track([.init(10, 0.3), .init(20, 0.3)], width: 0.2)
        let issue = try #require(issues(f.report(), .boardEdge).first)
        #expect(abs(try #require(issue.measured) - 0.2) < 0.000_001 && issue.required == 0.25)
        f.project.boards[0].tracks[0].points = [.init(10, 10), .init(20, 20)]
        f.project.boards[0].cutouts = [square(14, 14, 2)]
        #expect(try issues(f.report(), .boardEdge).contains { $0.code == "copper_in_cutout" })
        f.project.boards[0].tracks[0].points = [.init(110, 10), .init(120, 20)]
        #expect(try issues(f.report(), .boardEdge).contains { $0.code == "copper_outside_board" })
    }

    @Test func cutoutInsideDrillApertureMeasuresRealAnnularCopperGap() throws {
        var f = try Fixture(); _ = f.via(.init(20, 20), diameter: 4, drill: 2)
        f.project.boards[0].cutouts = [square(19.9, 19.9, 0.2)]
        #expect(try issues(f.report(), .boardEdge).isEmpty)
    }

    @Test func keepoutGeometryUsesActualTrackWidthLayerAndIndependentFlags() throws {
        var f = try Fixture()
        _ = f.track([.init(5, 9.95), .init(20, 9.95)])
        f.project.boards[0].keepouts = [.init(outline: square(10, 10, 2), layers: ["F.Cu"], tracks: true, vias: false, copper: false)]
        #expect(try issues(f.report(), .keepout).count == 1)
        f.project.boards[0].keepouts[0].tracks = false; f.project.boards[0].keepouts[0].copper = true
        #expect(try issues(f.report(), .keepout).isEmpty)
        f.project.boards[0].keepouts[0].tracks = true; f.project.boards[0].keepouts[0].layers = ["B.Cu"]
        #expect(try issues(f.report(), .keepout).isEmpty)
    }

    @Test func copperKeepoutBlocksFilledZonesWithoutInventingPadRestrictions() throws {
        var f = try Fixture(); _ = f.pad(.init(11, 11), net: f.a)
        _ = f.track([.init(10, 11), .init(12, 11)])
        _ = f.via(.init(11, 11))
        var zone = EDAZone(netID: f.a, outline: square(10, 10, 2)); zone.fillRevision = 0; zone.filledPolygons = [zone.outline]
        f.project.boards[0].zones = [zone]
        f.project.boards[0].keepouts = [.init(outline: square(10, 10, 2), tracks: false, vias: false, copper: true)]
        let hits = try issues(f.report(), .keepout)
        #expect(hits.count == 1 && hits[0].objects.contains { $0.kind == .zone })
        #expect(hits[0].objects.allSatisfy { $0.kind != .pad && $0.kind != .track && $0.kind != .via })
    }

    @Test func viaKeepoutExcludesTheWholeViaIncludingItsAperture() throws {
        var f = try Fixture(); _ = f.via(.init(20, 20), diameter: 2, drill: 1)
        f.project.boards[0].keepouts = [.init(outline: square(19.9, 19.9, 0.2), tracks: false, vias: true, copper: false)]
        #expect(try issues(f.report(), .keepout).count == 2)
    }

    @Test func ambiguousPadGeometryReportsIncompleteCoverageAndNeverUsesABox() throws {
        var f = try Fixture(); let pad = f.pad(.init(10, 10), net: f.a, size: .init(4, 4), shape: .roundRectangle)
        _ = f.track([.init(8, 10), .init(12, 10)], net: f.b)
        var report = try f.report()
        #expect(report.issues.contains { $0.code == "pad_shape_unsupported" && $0.objects == [pad] })
        #expect(!report.isCompleteForSupportedChecks && issues(report, .copperClearance).isEmpty)
        f.project.footprints[0].pads[0].shape = .circle; f.project.footprints[0].pads[0].size = .init(4, 2)
        report = try f.report(); #expect(report.issues.contains { $0.code == "pad_shape_unsupported" })
    }

    @Test func missingLibrariesAndInvalidPadDrillCannotProduceACompleteReport() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a, drill: 2)
        var report = try f.report()
        #expect(report.hasErrors && !report.isCompleteForSupportedChecks)
        #expect(report.issues.contains { $0.code == "pad_drill_exceeds_copper" })
        f.project.footprints = []; report = try f.report()
        #expect(report.issues.contains { $0.code == "missing_footprint_definition" })
    }

    @Test func multiLayerPadsWithoutPlatingDoNotSilentlyBridgeCopperLayers() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a, size: .init(2, 2), layers: ["F.Cu", "B.Cu"], drill: 0.5)
        let report = try f.report()
        #expect(report.issues.contains { $0.code == "pad_plating_unspecified" })
        #expect(report.routing[0].copperComponents.count == 2 && report.routing[0].remainingConnections.count == 1)
        #expect(report.coverage.first { $0.rule == .unconnectedNet }?.isComplete == false)
    }

    @Test func unmatchedSchematicTerminalsAndUnknownBoardNetsAreExplicitlyUnverified() throws {
        var f = try Fixture()
        let sym = EDASymbolDefinition(name: "Pin", pins: [.init(number: "1", position: .zero)])
        let c = EDAComponent(symbolID: sym.id, reference: "U1"); f.project.symbols = [sym]; f.project.components = [c]
        f.project.sheets[0].symbols = [.init(componentID: c.id, position: .init(20, 0))]
        _ = f.track([.init(10, 10), .init(20, 10)], net: "not-a-schematic-net")
        let report = try f.report()
        #expect(report.issues.contains { $0.code == "schematic_terminal_unmapped" && $0.details["componentID"] == c.id.uuidString })
        #expect(report.issues.contains { $0.code == "unresolved_board_net" })
        #expect(!report.isCompleteForSupportedChecks)
    }

    @Test func legacySchemaOneOriginalDecodesWithoutNewConstraints() throws {
        var f = try Fixture(); f.project.boards[0].drcConstraints = nil
        let data = try JSONEncoder().encode(f.project)
        let decoded = try JSONDecoder().decode(EDAProject.self, from: data)
        #expect(decoded.boards[0].drcConstraints == nil)
        try EDAValidation.validate(decoded)
        #expect(try !EDADRC.check(decoded, boardID: decoded.boards[0].id).isCompleteForSupportedChecks)
    }

    @Test func validationRejectsNegativeNonfiniteAndOutOfRangeMinima() throws {
        for value in [-0.1, Double.nan, Double.infinity, 100_001] {
            var f = try Fixture(); f.project.boards[0].drcConstraints?.minimumTrackWidth = value
            #expect(throws: EDAError.invalid("DRC minimum constraint")) { try EDAValidation.validate(f.project) }
            #expect(throws: EDAError.self) { try f.report() }
        }
    }

    @Test func structuredReportsRoundTripAndRemainDeterministic() throws {
        var f = try Fixture(); _ = f.pad(.init(10, 10), net: f.a); _ = f.pad(.init(20, 10), net: f.a)
        let before = f.project, report = try f.report()
        #expect(f.project == before)
        #expect(try JSONDecoder().decode(EDADRCReport.self, from: JSONEncoder().encode(report)) == report)
        f.project.boards[0].footprints.reverse()
        #expect(try f.report() == report)
        #expect(!report.excludedChecks.isEmpty)
    }

    @Test func cancellationAndGeometryBudgetFailWithoutAPartialPassReport() throws {
        let f = try Fixture()
        #expect(throws: EDAError.cancelled) { try EDADRC.check(f.project, boardID: f.project.boards[0].id, cancelled: { true }) }
        #expect(throws: EDAError.missing("DRC board")) { try EDADRC.check(f.project, boardID: UUID()) }
        let budget = EDADRCBudget(cancelled: { false }); budget.remaining = 0
        #expect(throws: EDAError.invalid("board DRC geometry budget")) {
            try EDADRCGeometry.distance(.init(outer: .capsule(.zero, .zero, 1)), .init(outer: .capsule(.init(3, 0), .init(3, 0), 1)), budget: budget)
        }
    }
}
