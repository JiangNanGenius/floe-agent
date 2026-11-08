// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDACopperFillTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [EDAPoint] {
        [.init(x,y), .init(x+w,y), .init(x+w,y+h), .init(x,y+h)]
    }
    private struct Fixture {
        var p = EDAProject(title: "Copper refill counterexamples")
        let a: String
        let b: String
        init() throws {
            p.sheets[0].labels = [.init(name:"A",position:.zero,scope:.global),
                                  .init(name:"B",position:.init(10,0),scope:.global)]
            let nets = try EDAConnectivity.derive(p).nets
            a = nets.first { $0.name == "A" }!.id; b = nets.first { $0.name == "B" }!.id
            p.boards[0].outline = [.init(0,0),.init(30,0),.init(30,30),.init(0,30)]
            p.boards[0].edgePlated = false
        }
        mutating func zone(net: String? = nil, layer: String = "F.Cu", priority: Int = 0,
                           outline: [EDAPoint]? = nil, thermal: EDAThermalRelief? = nil) -> UUID {
            let z = EDAZone(netID:net ?? a,layer:layer,outline:outline ?? p.boards[0].outline,
                            priority:priority,thermal:thermal != nil,thermalRelief:thermal)
            p.boards[0].zones.append(z); return z.id
        }
        mutating func pad(_ pos: EDAPoint, net: String? = nil, shape: EDAPadShape = .circle,
                          size: EDAPoint = .init(2,2), angle: Double = 0, side: String = "F.Cu",
                          local: EDAPoint = .zero, footprintAngle: Double = 0) -> UUID {
            let pad = EDAPad(number:"1",position:local,size:size,angle:angle,shape:shape,layers:["F.Cu"])
            let def = EDAFootprintDefinition(name:"Known copper only",pads:[pad]); p.footprints.append(def)
            p.boards[0].footprints.append(.init(definitionID:def.id,position:pos,angle:footprintAngle,side:side,padNets:["1":net ?? b]))
            return pad.id
        }
        func filled() throws -> (EDAEditingSession, EDACopperFillReport) {
            var s = try EDAEditingSession(project:p)
            let r = try s.refillCopper(boardID:p.boards[0].id,expectedRevision:p.revision)
            return (s,r)
        }
    }
    private func polygons(_ s: EDAEditingSession, _ id: UUID) -> [[EDAPoint]] {
        s.project.boards[0].zones.first { $0.id == id }!.filledPolygons
    }
    private func contains(_ paths: [[EDAPoint]], _ p: EDAPoint) -> Bool {
        paths.contains { EDAGeometry.contains(p,polygon:$0) }
    }
    private func code(_ code: String, _ operation: () throws -> Void) throws {
        do { try operation(); Issue.record("Expected \(code)") }
        catch let error as EDACopperFillFailure { #expect(error.issues.contains { $0.code == code }) }
    }
    private func evidence(_ name: String, project: EDAProject, report: EDACopperFillReport) throws {
        guard let root = ProcessInfo.processInfo.environment["FLOE_COPPER_EVIDENCE_ROOT"] else { return }
        let directory = URL(fileURLWithPath:root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(report).write(to:directory.appendingPathComponent("refill-report.json"))
        try encoder.encode(project).write(to:directory.appendingPathComponent("actual-project.json"))
        for file in try EDAExchange.export(project,format:.gerber).files {
            try file.data.write(to:directory.appendingPathComponent(file.name))
        }
    }

    @Test func nativeRingIsPartitionedWithoutFillingItsHole() throws {
        let c = EDACopperClipper(cancelled:{false})
        let ring = try c.difference([rect(0,0,20,20)],[rect(5,5,10,10)])
        let solids = try c.simpleSolids(ring)
        #expect(abs(solids.reduce(0){$0+EDAGeometry.signedArea($1)} - 300) < 0.000001)
        #expect(solids.allSatisfy { EDAGeometry.simplePolygon($0) && EDAGeometry.signedArea($0)>0 })
        #expect(!contains(solids,.init(10,10)))
        #expect(contains(solids,.init(2,10)) && contains(solids,.init(18,10)))
    }

    @Test func nestedIslandAndMultipleHolesKeepTheirActualTopology() throws {
        let c = EDACopperClipper(cancelled:{false})
        let body = try c.difference([rect(0,0,30,20)],[rect(3,3,8,8),rect(18,5,7,10)])
        let island = rect(5,5,2,2)
        let paths = try c.union(body+[island]), solids = try c.simpleSolids(paths)
        #expect(abs(solids.reduce(0){$0+EDAGeometry.signedArea($1)} - 470) < 0.000001)
        #expect(contains(solids,.init(6,6)) && !contains(solids,.init(4,4)))
        #expect(!contains(solids,.init(20,10)) && contains(solids,.init(14,10)))
    }

    @Test func concaveBoardCutoutAndTrueCapsuleSlotProduceRealVoids() throws {
        var f = try Fixture()
        f.p.boards[0].outline = [.init(0,0),.init(30,0),.init(30,12),.init(12,12),.init(12,30),.init(0,30)]
        f.p.boards[0].cutouts = [rect(4,4,3,3)]
        f.p.boards[0].holes = [.init(position:.init(5,20),diameter:1.2,plated:false,endPosition:.init(9,20))]
        let z = f.zone(outline:rect(0,0,30,30)); let (s,r) = try f.filled(), p = polygons(s,z)
        #expect(!contains(p,.init(20,20)) && contains(p,.init(10,20)))
        #expect(!contains(p,.init(5.5,5.5)) && contains(p,.init(8,5)))
        #expect(!contains(p,.init(7,20)) && !contains(p,.init(9.4,20)))
        #expect(contains(p,.init(4.45,20.55))) // in capsule bbox, outside its real round cap
        #expect(!contains(p,.init(0.2,10)) && contains(p,.init(0.26,10)))
        #expect(r.resultRevision == s.project.revision && s.project.boards[0].zones[0].fillState == .filled)
        try evidence("concave-slot",project:s.project,report:r)
    }

    @Test func circleAndRotatedPadClearanceDoNotRemoveTheirBoundingBoxes() throws {
        var f = try Fixture(); _ = f.pad(.init(10,10)); _ = f.pad(.init(20,20),shape:.rectangle,size:.init(4,1),angle:45)
        let z = f.zone(); let (s,r) = try f.filled(), p = polygons(s,z)
        #expect(contains(p,.init(11.05,11.05)) && !contains(p,.init(11.1,10)))
        #expect(contains(p,.init(21.8,20)) && !contains(p,.init(21,21)))
        let checked = try EDADRC.check(s.project,boardID:s.project.boards[0].id)
        #expect(!checked.issues.contains { $0.severity == .error && $0.rule == .copperClearance })
        try evidence("round-rotated-pads",project:s.project,report:r)
    }

    @Test func bottomTransformAndBlindViaUseOnlyTheirActualCopperLayers() throws {
        var f = try Fixture()
        f.p.boards[0].layers = [.init("F.Cu",kind:.copper),.init("In1.Cu",kind:.copper),
                               .init("In2.Cu",kind:.copper),.init("B.Cu",kind:.copper)]
        _ = f.pad(.init(20,20),shape:.oval,size:.init(4,2),angle:45,side:"B.Cu",local:.init(2,1),footprintAngle:90)
        f.p.boards[0].vias = [.init(netID:f.b,position:.init(8,8),diameter:0.8,drill:0.3,startLayer:"F.Cu",endLayer:"In1.Cu")]
        var ids:[String:UUID] = [:]
        for layer in ["F.Cu","In1.Cu","In2.Cu","B.Cu"] { ids[layer] = f.zone(layer:layer) }
        let (s,_) = try f.filled()
        #expect(!contains(polygons(s,ids["B.Cu"]!),.init(19,18)))
        #expect(contains(polygons(s,ids["F.Cu"]!),.init(19,18)))
        #expect(!contains(polygons(s,ids["F.Cu"]!),.init(8.5,8)))
        #expect(!contains(polygons(s,ids["In1.Cu"]!),.init(8.5,8)))
        #expect(contains(polygons(s,ids["In2.Cu"]!),.init(8,8)))
    }

    @Test func sameNetTrackIsSolidWhileForeignTrackKeepsSurfaceClearance() throws {
        var f = try Fixture()
        f.p.boards[0].tracks = [.init(netID:f.a,width:0.4,points:[.init(3,8),.init(25,8)]),
                                .init(netID:f.b,width:0.4,points:[.init(10,12),.init(20,22)])]
        let z = f.zone(); let (s,_) = try f.filled(), p = polygons(s,z)
        #expect(contains(p,.init(10,8)) && !contains(p,.init(15,17)))
        #expect(contains(p,.init(14.5,17.5))) // diagonal bbox overlap is still copper
        for polygon in p {
            let witness = try EDADRCGeometry.distance(.init(outer:.polygon(polygon)),
                .init(outer:.capsule(.init(10,12),.init(20,22),0.2)),budget:EDADRCBudget(cancelled:{false}))
            #expect(witness.distance + 0.000001 >= 0.2)
        }
    }

    @Test func onlyTheCopperKeepoutFlagAndMatchingLayerExcludeZoneFill() throws {
        var f = try Fixture()
        f.p.boards[0].keepouts = [.init(outline:rect(3,3,4,4),tracks:true,vias:true,copper:false),
                                  .init(outline:rect(10,3,4,4),layers:["B.Cu"],copper:true),
                                  .init(outline:rect(17,3,4,4),layers:["F.Cu"],tracks:false,vias:false,copper:true)]
        let z = f.zone(); let (s,_) = try f.filled(), p = polygons(s,z)
        #expect(contains(p,.init(5,5)) && contains(p,.init(12,5)) && !contains(p,.init(19,5)))
    }

    @Test func priorityUsesTheHigherActualFillAndEqualPriorityConflictRefuses() throws {
        var f = try Fixture(); _ = f.pad(.init(15,15),net:f.a)
        let high = f.zone(net:f.b,priority:2,outline:rect(5,5,20,20)), low = f.zone(priority:1)
        let (s,_) = try f.filled()
        #expect(!contains(polygons(s,high),.init(15,15)) && contains(polygons(s,low),.init(15,15)))
        #expect(!contains(polygons(s,low),.init(8,8)) && contains(polygons(s,low),.init(2,2)))
        f.p.boards[0].zones[1].priority = 2
        var edit = try EDAEditingSession(project:f.p); let original = edit.project
        try code("ambiguous_zone_priority") { try edit.refillCopper(boardID:original.boards[0].id,expectedRevision:0) }
        #expect(edit.project == original && !edit.canUndo)
    }

    @Test func isolatedRegionsRemainSeparateRealConnectivityComponents() throws {
        var f = try Fixture(); f.p.boards[0].keepouts = [.init(outline:rect(14,-1,2,32),layers:["F.Cu"],copper:true)]
        let z = f.zone(); let (s,r) = try f.filled(), p = polygons(s,z)
        #expect(contains(p,.init(5,15)) && contains(p,.init(25,15)) && !contains(p,.init(15,15)))
        #expect(r.zones[0].regionCount == 2)
        let checked = try EDADRC.check(s.project,boardID:s.project.boards[0].id)
        let net = try #require(checked.routing.first { $0.netID == f.a })
        #expect(net.copperComponents.count == 2 && net.remainingConnections.count == 1)
        try evidence("isolated-regions",project:s.project,report:r)
    }

    @Test func fourThermalSpokesAndTheirGapAreActualCopperGeometry() throws {
        var f = try Fixture(); _ = f.pad(.init(15,15),net:f.a)
        let z = f.zone(thermal:.init(gap:0.25,spokeWidth:0.3,spokeAngleDegrees:0,spokeCount:4))
        let (s,r) = try f.filled(), p = polygons(s,z)
        #expect(contains(p,.init(16.15,15)) && !contains(p,.init(15.82,15.82)))
        #expect(contains(p,.init(15,15)) && contains(p,.init(17,17)))
        #expect(r.zones[0].thermals.count == 1 && r.zones[0].thermals[0].connectedSpokes == 4)
        try evidence("four-thermal-spokes",project:s.project,report:r)
        f.p.boards[0].zones[0].thermalRelief?.spokeAngleDegrees = 45
        let (rotated,_) = try f.filled()
        #expect(contains(polygons(rotated,z),.init(15.82,15.82)) && !contains(polygons(rotated,z),.init(16.15,15)))
    }

    @Test func obstructedThermalSpokeRefusesTheWholeAtomicRefill() throws {
        var f = try Fixture(); _ = f.pad(.init(15,15),net:f.a)
        _ = f.pad(.init(16.45,15),net:f.b,shape:.rectangle,size:.init(0.2,2))
        _ = f.zone(thermal:.init(gap:0.25,spokeWidth:0.3,spokeAngleDegrees:0,spokeCount:4))
        var s = try EDAEditingSession(project:f.p); let old = s.project
        try code("thermal_connection_incomplete") { try s.refillCopper(boardID:old.boards[0].id,expectedRevision:0) }
        #expect(s.project == old && !s.canUndo)
    }

    @Test func thermalLegacyCompatibilityExplicitDefaultsAndConfiguredFloors() throws {
        var f = try Fixture(); _ = f.zone(); f.p.boards[0].zones[0].thermal = true
        try code("thermal_parameters_unspecified") { _ = try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id) }
        let created = EDACopperFill.newZone(netID:f.a,layer:"F.Cu",outline:f.p.boards[0].outline)
        #expect(created.thermalRelief == .init(gap:0.25,spokeWidth:0.3,spokeAngleDegrees:45,spokeCount:4))
        f.p.boards[0].zones[0].thermalRelief = .creationDefault
        f.p.boards[0].drcConstraints = .init(minimumCopperClearance:0.4)
        try code("thermal_gap_below_clearance_floor") { _ = try f.filled() }
        f.p.boards[0].zones[0].thermalRelief?.gap = 0.5
        f.p.boards[0].drcConstraints?.minimumTrackWidth = 0.5
        try code("thermal_spoke_below_explicit_minimum_track_width") { _ = try f.filled() }
        f.p.boards[0].zones[0].thermalRelief?.spokeWidth = 0.6
        _ = try f.filled()
        f.p.boards[0].drcConstraints = nil; f.p.boards[0].netClasses[0].trackWidth = 2
        f.p.boards[0].zones[0].thermalRelief = .creationDefault
        _ = try f.filled() // preferred routing size is not a DRC minimum
        for value in [-1.0, Double.nan, .infinity] {
            var bad = f.p; bad.boards[0].zones[0].thermalRelief?.gap = value
            #expect(throws: EDAError.self) { try EDAValidation.validate(bad) }
        }
        var bad = f.p; bad.boards[0].zones[0].thermalRelief?.spokeCount = 2
        #expect(throws: EDAError.unsupported("thermal spoke count")) { try EDAValidation.validate(bad) }
    }

    @Test func computedEmptyIsExplicitAndOldMissingEmptyStillFails() throws {
        var f = try Fixture(); f.p.boards[0].keepouts = [.init(outline:rect(-1,-1,32,32),layers:["F.Cu"],copper:true)]
        _ = f.zone(); let (s,r) = try f.filled()
        #expect(s.project.boards[0].zones[0].fillState == .empty && r.zones[0].polygonCount == 0)
        let drc = try EDADRC.check(s.project,boardID:s.project.boards[0].id)
        #expect(drc.issues.contains { $0.code == "zone_fill_empty" && $0.severity == .information })
        #expect(!drc.issues.contains { $0.code == "zone_fill_missing" || $0.code == "zone_fill_stale" })
        let bundle = try EDAExchange.export(s.project,format:.gerber)
        #expect(!bundle.files.contains { $0.name.hasPrefix("Copper-") })
        let manifest = try #require(bundle.files.first { $0.name == "Gerber-manifest.json" })
        let json = try #require(JSONSerialization.jsonObject(with:manifest.data) as? [String:Any])
        #expect((json["computedEmptyZoneIDs"] as? [String])?.count == 1)
        #expect((json["emptyCopperLayers"] as? [Int]) == [1,2])
        var old = s.project; old.boards[0].zones[0].fillState = nil
        #expect(throws: EDAManufacturingFailure.self) { try EDAExchange.export(old,format:.gerber) }
        try evidence("computed-empty",project:s.project,report:r)
        var priority = try Fixture(); _ = priority.zone(net:priority.b,priority:2); _ = priority.zone(priority:1)
        let (covered,_) = try priority.filled()
        #expect(covered.project.boards[0].zones[1].fillState == .empty)
    }

    @Test func typedEditsStripDerivedAuthorityAndUndoRestoresOnlyRealComputedFills() throws {
        var f = try Fixture(); _ = f.zone(); var (s,_) = try f.filled()
        let first = s.project; var forged = first.boards[0].zones[0]
        forged.filledPolygons = []; forged.fillState = .empty
        try s.apply([.putZone(board:first.boards[0].id,forged)],expectedRevision:first.revision)
        #expect(s.project.boards[0].zones[0].fillState == nil && s.project.boards[0].zones[0].fillRevision == nil)
        try s.undo(expectedRevision:s.project.revision)
        #expect(s.project.boards[0].zones[0].filledPolygons == first.boards[0].zones[0].filledPolygons)
        #expect(s.project.boards[0].zones[0].fillRevision == s.project.revision && s.project.boards[0].zones[0].fillState == .filled)
        try s.redo(expectedRevision:s.project.revision)
        #expect(s.project.boards[0].zones[0].fillState == nil)
        _ = try s.refillCopper(boardID:s.project.boards[0].id,expectedRevision:s.project.revision)
        #expect(s.project.boards[0].zones[0].fillState == .filled)
        var changed = s.project.boards[0].zones[0]; changed.thermalRelief = .creationDefault
        try s.apply([.putZone(board:s.project.boards[0].id,changed)],expectedRevision:s.project.revision)
        #expect(s.project.boards[0].zones[0].fillRevision == nil)
        var inconsistent = first; inconsistent.boards[0].zones[0].fillState = .empty
        #expect(throws: EDAError.invalid("zone fill state")) { try EDAValidation.validate(inconsistent) }
    }

    @Test func staleSameRevisionChangedSourceReadOnlyAndCancellationCannotCommit() throws {
        var f = try Fixture(); _ = f.zone()
        let plan = try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id)
        var s = try EDAEditingSession(project:f.p)
        try s.apply([.rename("Changed")],expectedRevision:0); let changed = s.project
        #expect(throws: EDAError.invalid("copper fill source changed")) { try s.applyCopperFill(plan,expectedRevision:1) }
        #expect(s.project == changed)
        var different = f.p; different.boards[0].boardEdgeClearance = 0.5
        var external = try EDAEditingSession(project:different)
        #expect(throws: EDAError.invalid("copper fill source changed")) { try external.applyCopperFill(plan,expectedRevision:0) }
        var readOnly = try EDAEditingSession(project:f.p,readOnly:true)
        #expect(throws: EDAError.readOnly) { try readOnly.applyCopperFill(plan,expectedRevision:0) }
        var cancelled = try EDAEditingSession(project:f.p)
        #expect(throws: EDAError.cancelled) { try cancelled.applyCopperFill(plan,expectedRevision:0,cancelled:{true}) }
        #expect(cancelled.project == f.p && !cancelled.canUndo)
        #expect(throws: EDAError.cancelled) { try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id,cancelled:{true}) }
    }

    @Test func legacyJSONOmitsNewKeysAndFilledOriginalRoundTrips() throws {
        var f = try Fixture(); _ = f.zone()
        var raw = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(f.p)) as? [String:Any])
        var boards = try #require(raw["boards"] as? [[String:Any]])
        var zones = try #require(boards[0]["zones"] as? [[String:Any]])
        for i in zones.indices { zones[i].removeValue(forKey:"thermalRelief"); zones[i].removeValue(forKey:"fillState") }
        boards[0]["zones"] = zones; raw["boards"] = boards
        let legacy = try JSONDecoder().decode(EDAProject.self,from:JSONSerialization.data(withJSONObject:raw))
        #expect(legacy.boards[0].zones[0].thermalRelief == nil && legacy.boards[0].zones[0].fillState == nil)
        let (s,_) = try f.filled(), bundle = try EDAExchange.export(s.project,format:.project)
        let bytes = try #require(bundle.files.first).data
        #expect(try EDAExchange.decodeProject(bytes) == s.project)
        var edit = try EDAEditingSession(project:s.project)
        let revision = edit.project.revision
        _ = try edit.refillCopper(boardID:edit.project.boards[0].id,expectedRevision:revision)
        #expect(edit.project.revision == revision && !edit.canUndo) // idempotent real recompute
    }

    @Test func unsupportedGeometryAndBudgetsFailWithoutPartialSuccess() throws {
        var f = try Fixture(); _ = f.zone(); _ = f.pad(.init(10,10),shape:.roundRectangle)
        try code("pad_shape_unsupported") { _ = try f.filled() }
        f.p.footprints[0].pads[0].shape = .circle
        f.p.boards[0].graphics = [.line(.zero,.init(1,1),width:0.1)]
        try code("graphic_layer_unspecified") { _ = try f.filled() }
        f.p.boards[0].graphics = []; f.p.boards[0].zones[0].outline = Array(repeating:.zero,count:20_001)
        #expect(throws: EDAError.invalid("copper fill input polygon budget")) { _ = try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id) }
    }

    @Test func outputIsDeterministicWhenCopperInputOrderChanges() throws {
        var f = try Fixture(); _ = f.zone()
        f.p.boards[0].tracks = [.init(netID:f.b,width:0.5,points:[.init(5,8),.init(12,8)]),
                                .init(netID:f.b,width:0.3,points:[.init(21,17),.init(24,22)])]
        let first = try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id)
        f.p.boards[0].tracks.reverse()
        let second = try EDACopperFill.plan(f.p,boardID:f.p.boards[0].id)
        #expect(first.polygons == second.polygons)
    }

    @Test func allThermalFieldsAndDerivedStateAreValidated() throws {
        var f = try Fixture(); _ = f.zone(thermal:.creationDefault)
        for invalid in [-1.0,Double.nan,.infinity] {
            var p = f.p; p.boards[0].zones[0].thermalRelief?.spokeWidth = invalid
            #expect(throws: EDAError.self) { try EDAValidation.validate(p) }
        }
        for invalid in [Double.nan,Double.infinity,1_000_001] {
            var p = f.p; p.boards[0].zones[0].thermalRelief?.spokeAngleDegrees = invalid
            #expect(throws: EDAError.self) { try EDAValidation.validate(p) }
        }
        for count in [0,2,5] {
            var p = f.p; p.boards[0].zones[0].thermalRelief?.spokeCount = count
            #expect(throws: EDAError.self) { try EDAValidation.validate(p) }
        }
        var p = f.p; p.boards[0].zones[0].fillState = .empty
        #expect(throws: EDAError.invalid("zone fill state")) { try EDAValidation.validate(p) }
        let missingField = Data("{\"gap\":0.25,\"spokeWidth\":0.3,\"spokeCount\":4}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EDAThermalRelief.self,from:missingField) }
    }

    @Test func fillSaveUsesTheExistingRealOriginalCASAcrossWriters() async throws {
        var f = try Fixture(); _ = f.zone()
        let base = try #require(ProcessInfo.processInfo.environment["FLOE_COPPER_TEST_TEMP"])
        let root = URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try await EDAProjectStore.create(root:root,project:f.p)
        let saved = try await store.load()
        var s = try EDAEditingSession(project:saved.project,savedDigest:saved.digest)
        _ = try s.refillCopper(boardID:f.p.boards[0].id,expectedRevision:0)
        let candidate = s.project, directory = store.root
        let successes = await withTaskGroup(of:Bool.self,returning:Int.self) { group in
            for _ in 0..<2 { group.addTask {
                do {
                    let writer = try EDAProjectStore(root:directory,projectID:candidate.id)
                    _ = try await writer.save(candidate,expectedRevision:0,expectedDigest:saved.digest)
                    return true
                } catch { return false }
            }}
            var count = 0; for await ok in group { if ok { count += 1 } }; return count
        }
        #expect(successes == 1)
        let actual = try await store.load()
        #expect(actual.project == candidate && actual.project.boards[0].zones[0].fillState == .filled)
        #expect(try await store.history().count == 1)
    }
}
