import Foundation
import Testing
@testable import FloeNativeChartsCore

@Suite("Chart shared layout contracts")
struct ChartGeometryTests {
    @Test("Numeric spacing and screen-space inverse preserve real values")
    func numericProjection() throws {
        let transform = try ChartCartesianTransform(xDomain:.numeric(lower:0,upper:100),yDomain:.numeric(lower:0,upper:10),plot:.init(x:10,y:20,width:100,height:200))
        let a = try transform.position(x:.number(1),y:.number(5))
        let b = try transform.position(x:.number(2),y:.number(5))
        let c = try transform.position(x:.number(100),y:.number(5))
        #expect(abs((b.x-a.x)-1) < 1e-10)
        #expect(abs((c.x-b.x)-98) < 1e-10)
        #expect(a.y == 120)
        let value = try transform.coordinates(at:b)
        #expect(value.x == .number(2) && value.y == .number(5))
        #expect(throws:ChartIssue.self) { try transform.position(x:.category("2"),y:.number(5)) }
    }
    @Test("Local dates cross DST with continuous time distances")
    func daylightSavingProjection() throws {
        let start = try ChartDates.instant("2026-03-08T00:00:00-05:00")
        let end = try ChartDates.instant("2026-03-10T00:00:00-04:00")
        let domain = ChartAxisDomain.temporal(lower:start,upper:end,timeZone:"America/New_York")
        let position = try domain.unitPosition(of:.localDate("2026-03-09"))
        #expect(abs(position-23.0/47.0) < 1e-12)
        #expect(abs(position-0.5) > 0.005)
        #expect(throws:ChartIssue.self) { try ChartAxisDomain.temporal(lower:start,upper:end,timeZone:"not/a/zone").validate() }
    }
    @Test("Explicit categorical domains and finite extreme numeric bounds remain distinct")
    func domainBoundaries() throws {
        #expect(try ChartAxisDomain.categorical(["A","B"]).unitPosition(of:.category("A")) == 0.25)
        #expect(try ChartAxisDomain.categorical(["A","B"]).coordinate(atUnitPosition:-0.1) == nil)
        #expect(throws:ChartIssue.self) { try ChartAxisDomain.categorical(["A","A"]).validate() }
        let extremes = ChartAxisDomain.numeric(lower:-Double.greatestFiniteMagnitude,upper:Double.greatestFiniteMagnitude)
        #expect(try extremes.unitPosition(of:.number(0)) == 0.5)
        #expect(throws:ChartIssue.self) { try ChartAxisDomain.numeric(lower:1,upper:1).validate() }
    }
    @Test("Layout geometry is finite, bounded and references only prepared records")
    func layoutOwnershipAndBudget() throws {
        let chart = try ChartValidator.prepare(ChartCoreTests.fixture(.line))
        let id = ChartRecordID(id:"a")
        let point = ChartPrimitive(id:"point-a",sourceIDs:[id],shape:.point(.init(x:1,y:2)))
        let hit = ChartHitRegion(sourceIDs:[id],bounds:.init(x:0,y:0,width:3,height:4))
        let layout = try ChartLayout(primitives:[point],hits:[hit],for:chart)
        #expect(layout.primitives.count == 1)
        let foreign = ChartPrimitive(id:"foreign",sourceIDs:[.init(facetPath:["other"],id:"a")],shape:.point(.init(x:1,y:2)))
        #expect(throws:ChartIssue.self) { try ChartLayout(primitives:[foreign],hits:[],for:chart) }
        let infinite = ChartPrimitive(id:"bad",sourceIDs:[],shape:.point(.init(x:.infinity,y:0)))
        #expect(throws:ChartIssue.self) { try ChartLayout(primitives:[infinite],hits:[],for:chart) }
        let huge = ChartPrimitive(id:"huge",sourceIDs:[],shape:.polyline(Array(repeating:.init(x:0,y:0),count:20_001)))
        #expect(throws:ChartIssue.self) { try ChartLayout(primitives:[huge],hits:[],for:chart) }
    }
}
