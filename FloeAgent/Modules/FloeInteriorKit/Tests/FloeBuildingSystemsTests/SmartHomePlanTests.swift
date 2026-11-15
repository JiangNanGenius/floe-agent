// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingSystems

final class SmartHomePlanTests:XCTestCase {
    private func powerPlan()->SmartHomePlan {
        let a=SmartHomePort(label:"+",medium:.dcPower,terminal:.positive,direction:.source,
            nominalVoltageV:24,maximumCurrentA:0.5,evidenceID:"synthetic-source-rating")
        let b=SmartHomePort(label:"+",medium:.dcPower,terminal:.positive,direction:.sink,
            minimumVoltageV:20,maximumVoltageV:28,demandCurrentA:0.3,evidenceID:"synthetic-load-rating")
        return .init(projectID:UUID(),equipment:[.init(name:"电源",productReference:"Demo-Supply",ports:[a]),
            .init(name:"负载",productReference:"Demo-Load",ports:[b])],
            connections:[.init(firstPortID:a.id,secondPortID:b.id)])
    }
    private func codes(_ plan:SmartHomePlan)->Set<String>{Set(SmartHomePlanValidator.validate(plan).issues.map(\.code))}
    func testDeclaredPowerConnectionAndOverload() {
        var plan=powerPlan()
        XCTAssertEqual(SmartHomePlanValidator.validate(plan).invalidCount,0)
        XCTAssertEqual(SmartHomePlanValidator.validate(plan).needsInputCount,0)
        plan.equipment[1].ports[0].demandCurrentA=0.8
        XCTAssertTrue(codes(plan).contains("supply-current-exceeded"))
    }
    func testUnknownRatingsDoNotPassAsVerified() {
        var plan=powerPlan();plan.equipment[1].ports[0].minimumVoltageV=nil
        XCTAssertTrue(codes(plan).contains("power-conditions-unverified"))
        plan=powerPlan();plan.equipment[0].ports[0].evidenceID=nil
        XCTAssertTrue(codes(plan).contains("rating-evidence-missing"))
        plan=powerPlan();plan.equipment[0].ports[0].maximumCurrentA=nil
        XCTAssertTrue(codes(plan).contains("current-budget-unverified"))
    }
    func testInvalidRangeNonfiniteAndWrongPolarityAreSafe() {
        var plan=powerPlan();plan.equipment[1].ports[0].minimumVoltageV=30
        XCTAssertTrue(codes(plan).contains("invalid-voltage-range"))
        plan=powerPlan();plan.equipment[0].ports[0].nominalVoltageV = .nan
        XCTAssertTrue(codes(plan).contains("invalid-port-rating"))
        plan=powerPlan();plan.equipment[1].ports[0].terminal = .negative
        XCTAssertTrue(codes(plan).contains("terminal-mismatch"))
        plan=powerPlan();plan.equipment[0].ports[0].nominalVoltageV=48
        XCTAssertTrue(codes(plan).contains("voltage-mismatch"))
    }
    func testBusTypeDoesNotInventUpperProtocolAndTermination() {
        let a=SmartHomePort(label:"A",medium:.rs485,terminal:.signalA)
        let b=SmartHomePort(label:"A",medium:.rs485,terminal:.signalA)
        let segment=SmartHomeSegment(name:"Bus",medium:.rs485)
        var plan=SmartHomePlan(projectID:UUID(),equipment:[.init(name:"A",productReference:"Demo-A",ports:[a]),
            .init(name:"B",productReference:"Demo-B",ports:[b])],
            connections:[.init(firstPortID:a.id,secondPortID:b.id,segmentID:segment.id)],segments:[segment])
        XCTAssertTrue(codes(plan).contains("protocol-unverified"))
        XCTAssertTrue(codes(plan).contains("terminal-mapping-unverified"))
        XCTAssertTrue(codes(plan).contains("termination-conditions-unverified"))
        for index in plan.equipment.indices {
            plan.equipment[index].ports[0].protocolName="synthetic-modbus"
            plan.equipment[index].ports[0].compatibilityProfile="synthetic-terminal-map"
        }
        plan.segments[0].terminationEvidenceID="synthetic-topology-review"
        XCTAssertEqual(SmartHomePlanValidator.validate(plan).needsInputCount,0)
        plan.equipment[1].ports[0].protocolName="different-protocol"
        XCTAssertTrue(codes(plan).contains("protocol-mismatch"))
    }
    func testPortCapacityDuplicateConnectionAndMissingIDs() {
        var plan=powerPlan();plan.equipment[0].ports[0].maximumConnections=1
        let second=plan.equipment[1].ports[0]
        plan.connections.append(.init(firstPortID:plan.equipment[0].ports[0].id,secondPortID:second.id))
        XCTAssertTrue(codes(plan).contains("duplicate-connection"))
        XCTAssertTrue(codes(plan).contains("port-capacity-exceeded"))
        plan=powerPlan();plan.connections[0].secondPortID=UUID()
        XCTAssertTrue(codes(plan).contains("unknown-or-self-endpoint"))
        plan=powerPlan();plan.equipment[1].ports[0].id=plan.equipment[0].ports[0].id
        XCTAssertTrue(codes(plan).contains("duplicate-or-excessive-identity"))
    }
    func testNeutralGatewayAndRoomRequirements() {
        var plan=powerPlan();plan.equipment[1].requiresNeutral=true
        plan.equipment[1].gatewayRequirement="synthetic-gateway-profile"
        plan.equipment[1].roomID=UUID()
        XCTAssertTrue(codes(plan).contains("neutral-port-required"))
        XCTAssertTrue(codes(plan).contains("gateway-missing"))
        XCTAssertTrue(codes(plan).contains("unknown-room"))
    }
    func testPhysicalDevicesAndChannelsStaySeparateByRoomAndRole() {
        let roomA=UUID(),roomB=UUID()
        var a=SmartHomeEquipment(name:"A",productReference:"Relay4",roomID:roomA,ports:[],channelCount:4)
        var b=a;b.id=UUID();b.roomID=roomB
        var spare=a;spare.id=UUID();spare.isSpare=true
        let plan=SmartHomePlan(projectID:UUID(),roomIDs:[roomA,roomB],equipment:[a,b,spare])
        let rows=SmartHomeSchedules.bom(plan)
        XCTAssertEqual(rows.count,3)
        XCTAssertEqual(rows.reduce(0){$0+$1.physicalDeviceCount},3)
        XCTAssertEqual(rows.reduce(0){$0+$1.knownChannelCount},12)
        a.name="Changed display name"
        XCTAssertTrue(SmartHomeSchedules.bomCSV(plan).contains("physical_devices"))
    }
    func testPlanRoundTripRenameCASAndCableUnits() throws {
        let original=powerPlan(),id=original.equipment[0].id
        let next=try original.renamedEquipment(id,to:"改名后的电源",expectedRevision:0)
        XCTAssertEqual(next.revision,1)
        XCTAssertEqual(next.connections,original.connections)
        XCTAssertNotEqual(next.equipment[0].name,original.equipment[0].name)
        XCTAssertThrowsError(try next.renamedEquipment(id,to:"stale",expectedRevision:0))
        XCTAssertEqual(try SmartHomePlan.reopen(next.encoded()),next)
        let wire=SmartHomeConnection(firstPortID:UUID(),secondPortID:UUID(),routeMM:[.init(0,0,0),.init(3000,4000,0)])
        XCTAssertEqual(wire.routedLengthM,5)
    }
    func testLegendPresetDefinitionsDoNotFabricateRatings() throws {
        let presets=SystemLegendCatalog.presets
        XCTAssertEqual(Set(presets.map(\.id)).count,presets.count)
        let plug=try XCTUnwrap(presets.first{$0.id=="ac-plug-lnp"})
        let socket=try XCTUnwrap(presets.first{$0.id=="ac-socket-lnp"})
        let neutral=try XCTUnwrap(presets.first{$0.id=="neutral-switch"})
        XCTAssertNotEqual(plug.id,socket.id)
        XCTAssertEqual(plug.roles,[.line,.neutral,.protectiveEarth])
        let draft=SystemLegendCatalog.draft(from:neutral,name:"零线开关")
        XCTAssertEqual(draft.requiresNeutral,true)
        XCTAssertTrue(draft.productReference.isEmpty)
        XCTAssertTrue(draft.assetVersion.isEmpty)
        XCTAssertTrue(codes(.init(projectID:UUID(),equipment:[draft])).contains("missing-device-definition"))
        XCTAssertTrue(draft.ports.allSatisfy{$0.nominalVoltageV==nil && $0.evidenceID==nil})
        XCTAssertTrue(draft.ports.contains{$0.terminal == .neutral})
    }
    func testIncompleteScenePlanRemainsNeedsInput() {
        let scene=SmartHomeScenePlan(name:" ",triggerDescription:"",actionDescription:"",equipmentIDs:[])
        let result=SmartHomePlanValidator.validate(.init(projectID:UUID(),scenes:[scene]))
        XCTAssertTrue(result.issues.contains{$0.code=="scene-description-missing" && $0.severity == .needsInput})
        XCTAssertTrue(result.issues.contains{$0.code=="scene-device-empty" && $0.severity == .needsInput})
        XCTAssertEqual(result.state,"needs-input")
    }

}
