import Foundation
import Testing
@testable import FloeNativeChartsCore

@Suite("Native chart core contracts")
struct ChartCoreTests {
    static let day1 = "2026-11-08T00:00:00Z"
    static let day2 = "2026-11-09T00:00:00Z"
    static func fixture(_ kind: ChartKind) -> ChartDocument {
        var options = ChartOptions()
        let data: ChartData
        switch kind {
        case .line,.column,.bar,.groupedBar,.stackedBar,.percentStackedBar,.area,.stackedArea,.percentStackedArea,.scatter:
            data = .cartesian([.init(id:"a",x:.number(1),y:2),.init(id:"b",x:.number(100),y:4)])
        case .bubble:
            data = .cartesian([.init(id:"a",x:.number(1),y:2,size:1),.init(id:"b",x:.number(100),y:4,size:4)])
        case .combo:
            return .init(type:kind,data:.cartesian([
                .init(id:"a",x:.number(1),y:2,seriesID:"line"),.init(id:"b",x:.number(1),y:4,seriesID:"bar")]),
                axes:[.init(id:"price",kind:.numeric,unit:"USD"),.init(id:"volume",kind:.numeric,unit:"shares")],
                series:[.init(id:"line",name:"Price",mark:.line,axisID:"price"),.init(id:"bar",name:"Volume",mark:.column,axisID:"volume")])
        case .smallMultiples:
            data = .facets([.init(id:"first",document:fixture(.line)),.init(id:"second",document:fixture(.scatter))])
        case .pie,.donut: data = .parts([.init(id:"a",label:"A",value:1),.init(id:"b",label:"B",value:3)])
        case .histogram,.boxPlot,.violin,.density: data = .samples([.init(id:"s",values:[0,1,2,3,4,100])])
        case .errorBars,.confidenceBand:
            data = .intervals([.init(id:"a",x:.number(1),estimate:2,lower:1,upper:4),.init(id:"b",x:.number(100),estimate:3,lower:2,upper:5)])
            options.intervalMeaning = kind == .confidenceBand ? .confidence : .custom
            if kind == .confidenceBand { options.confidenceLevel = 0.95; options.method = "Supplied intervals" }
        case .candlestick,.ohlc,.priceVolume:
            data = .ohlc([.init(id:"a",time:day1,open:10,high:13,low:9,close:12,volume:100),
                          .init(id:"b",time:day2,open:12,high:14,low:11,close:13,volume:150)])
            if kind == .priceVolume { options.movingAverages = [.init(method:.sma,period:2)] }
        case .volume: data = .volume([.init(id:"a",time:day1,volume:0),.init(id:"b",time:day2,volume:100)])
        case .heatmap: data = .matrix([.init(id:"a",row:.category("r"),column:.number(1),value:nil),.init(id:"b",row:.category("r"),column:.number(2),value:0)])
        case .radar,.parallelCoordinates:
            data = .dimensions(.init(dimensions:[.init(id:"a",label:"A",lower:0,upper:10),.init(id:"b",label:"B",lower:0,upper:100),.init(id:"c",label:"C",lower:-1,upper:1)],records:[.init(id:"row",values:[5,50,0])]))
        case .polar: data = .polar([.init(id:"a",angle:90,radius:2)]); options.angleUnit = .degrees
        case .treemap,.sunburst,.tree:
            data = .hierarchy([.init(id:"root",label:"Root",value:4),.init(id:"a",label:"A",parentID:"root",value:1),.init(id:"b",label:"B",parentID:"root",value:3)])
        case .network:
            data = .graph(.init(nodes:[.init(id:"a",label:"A"),.init(id:"b",label:"B"),.init(id:"c",label:"Isolated")],edges:[.init(id:"ab",source:"a",target:"b",weight:-0.5),.init(id:"ba",source:"b",target:"a",weight:1)]))
        case .waterfall:
            data = .waterfall([.init(id:"a",label:"Up",kind:.delta,value:5),.init(id:"b",label:"Down",kind:.delta,value:-2),.init(id:"c",label:"Up",kind:.delta,value:3),.init(id:"total",label:"Total",kind:.total,value:6)])
        case .funnel: data = .stages([.init(id:"a",label:"First",value:10),.init(id:"b",label:"Second",value:20)])
        case .sankey:
            data = .flow(.init(nodes:[.init(id:"a",label:"A"),.init(id:"b",label:"B"),.init(id:"c",label:"C")],links:[.init(id:"ab",source:"a",target:"b",value:4),.init(id:"bc",source:"b",target:"c",value:3)]))
        case .chord: data = .flowMatrix(.init(nodes:[.init(id:"a",label:"A"),.init(id:"b",label:"B")],values:[[0,2],[2,0]]))
        case .timeline: data = .events([.init(id:"a",label:"A",time:day1),.init(id:"b",label:"B",time:day2)])
        case .gantt:
            data = .tasks([.init(id:"a",label:"Task",start:day1,end:day2,progress:0.5),.init(id:"b",label:"Milestone",start:day2,end:day2,milestone:true,dependsOn:["a"])])
        case .calendarHeatmap:
            data = .calendar([.init(id:"leap",day:.localDate("2024-02-29"),value:0),.init(id:"next",day:.localDate("2024-03-01"),value:2)]); options.timeZone = "America/New_York"
        }
        return .init(type:kind,data:data,title:kind.rawValue,options:options)
    }
    @Test("Every CH identity round-trips its real typed payload")
    func allForty() throws {
        #expect(ChartCatalog.descriptors.count == 40)
        #expect(Set(ChartCatalog.descriptors.map(\.requirementID)) == Set((1...40).map { String(format:"CH%02d",$0) }))
        #expect(Set(ChartCatalog.descriptors.map(\.kind)) == Set(ChartKind.allCases))
        for kind in ChartKind.allCases {
            let document = Self.fixture(kind)
            let bytes = try ChartDocumentCodec.encode(document)
            guard case .v2(let chart) = try ChartDocumentCodec.decode(bytes) else { Issue.record("Expected v2 \(kind)"); continue }
            #expect(chart.document == document)
            #expect(chart.descriptor.kind == kind)
            #expect(!chart.recordIDs.isEmpty)
            #expect(chart.inputRecordCount > 0 && chart.inputRecordCount <= 2000)
        }
    }
    @Test("Legacy five kinds retain categorical labels and negative source values")
    func legacyFive() throws {
        for kind in LegacyChartDocument.Kind.allCases {
            let source = LegacyChartDocument(type:kind,series:[.init(name:"Old",points:[.init(label:"one",value:-2),.init(label:"100",value:3)])])
            let bytes = try ChartDocumentCodec.encode(source)
            guard case .legacy(let reopened) = try ChartDocumentCodec.decode(bytes) else { Issue.record("Expected legacy"); continue }
            #expect(reopened == source)
            #expect(reopened.series[0].points[0].value == -2)
        }
    }
    @Test("Unknown fields and unsupported future versions fail at the data boundary")
    func strictJSON() throws {
        let bytes = try ChartDocumentCodec.encode(Self.fixture(.line))
        var object = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        object["silentlyIgnored"] = true
        #expect(throws:ChartIssue.self) { try ChartDocumentCodec.decode(JSONSerialization.data(withJSONObject:object)) }
        object.removeValue(forKey:"silentlyIgnored"); object["schemaVersion"] = 3
        #expect(throws:ChartIssue.self) { try ChartDocumentCodec.decode(JSONSerialization.data(withJSONObject:object)) }
        object["schemaVersion"] = 2
        var data = try #require(object["data"] as? [String:Any])
        var records = try #require(data["records"] as? [[String:Any]])
        records[0]["pretendOHLC"] = 100; data["records"] = records; object["data"] = data
        #expect(throws:ChartIssue.self) { try ChartDocumentCodec.decode(JSONSerialization.data(withJSONObject:object)) }
    }
    @Test("Historical read allowance does not inflate new v2 write limits")
    func historicalReadLimit() throws {
        let old = LegacyChartDocument(type:.line,series:[.init(name:"old",points:[.init(label:"A",value:1)])])
        var oldBytes = try ChartDocumentCodec.encode(old)
        oldBytes.append(Data(repeating:32,count:ChartLimits.documentBytes-oldBytes.count+1))
        guard case .legacy = try ChartDocumentCodec.decode(oldBytes) else { Issue.record("Legacy read limit lost"); return }
        var modern = try ChartDocumentCodec.encode(Self.fixture(.line))
        modern.append(Data(repeating:32,count:ChartLimits.documentBytes-modern.count+1))
        #expect(throws:ChartIssue.self) { try ChartDocumentCodec.decode(modern) }
    }
    @Test("Scatter preserves unsorted and repeated numeric x; category x is not accepted")
    func scatterCoordinates() throws {
        let document = ChartDocument(type:.scatter,data:.cartesian([
            .init(id:"one",x:.number(100),y:1),.init(id:"two",x:.number(2),y:2),.init(id:"three",x:.number(2),y:3)]))
        #expect(try ChartValidator.prepare(document).document == document)
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.scatter,data:.cartesian([.init(id:"a",x:.category("100"),y:1)]))) }
    }
    @Test("Proportions, aligned stacks and bubble sizes are checked without clipping")
    func proportionsAndStacks() throws {
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.pie,data:.parts([.init(id:"x",label:"X",value:-1)]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.donut,data:.parts([.init(id:"x",label:"X",value:0)]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.percentStackedBar,data:.cartesian([.init(id:"x",x:.category("A"),y:-1)]))) }
        let zero = ChartDocument(type:.percentStackedArea,data:.cartesian([.init(id:"x",x:.number(1),y:0)]))
        let prepared = try ChartValidator.prepare(zero)
        #expect(prepared.document == zero && !prepared.warnings.isEmpty)
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.bubble,data:.cartesian([.init(id:"x",x:.number(1),y:2)]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.stackedArea,data:.cartesian([.init(id:"a",x:.number(1),y:1,seriesID:"a"),.init(id:"b",x:.number(2),y:1,seriesID:"b")]))) }
    }
    @Test("Statistics distinguish raw samples, supplied summaries and confidence")
    func statisticalContracts() throws {
        let summary = BoxSummary(id:"box",lowerWhisker:0,q1:1.25,median:2.5,q3:3.75,upperWhisker:4,outliers:[100])
        _ = try ChartValidator.prepare(.init(type:.boxPlot,data:.boxSummary([summary])))
        var wrong = summary; wrong.median = 10
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.boxPlot,data:.boxSummary([wrong]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.histogram,data:.bins([.init(id:"a",lower:0,upper:2,count:1),.init(id:"b",lower:1,upper:3,count:2)]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.violin,data:.samples([.init(id:"a",values:[1,1,1])])) ) }
        _ = try ChartValidator.prepare(.init(type:.violin,data:.samples([.init(id:"a",values:[1,1])]),options:.init(bandwidth:0.5)))
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.confidenceBand,data:.intervals([.init(id:"x",x:.number(1),estimate:2,lower:1,upper:3)]))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.density,data:.density([.init(id:"a",points:[.init(x:0,density:0),.init(x:1,density:0)])]))) }
    }
    @Test("Financial values require actual OHLC, explicit volume and ordered instants")
    func financialContracts() throws {
        var source = Self.fixture(.candlestick)
        guard case .ohlc(var rows) = source.data else { return }
        rows[0].high = 1; source.data = .ohlc(rows)
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(source) }
        rows[0].high = 13; rows[1].time = rows[0].time; source.data = .ohlc(rows)
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(source) }
        source = Self.fixture(.priceVolume)
        source.options.movingAverages = [.init(method:.ema,period:20)]
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(source) }
    }
    @Test("Dimensions, polar units and hierarchy topology are real contracts")
    func multivariateAndHierarchy() throws {
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.polar,data:.polar([.init(id:"x",angle:90,radius:1)]))) }
        let cycle = ChartData.hierarchy([.init(id:"a",label:"A",parentID:"b",value:1),.init(id:"b",label:"B",parentID:"a",value:1)])
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.tree,data:cycle)) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.treemap,data:.hierarchy([.init(id:"a",label:"A",value:20),.init(id:"b",label:"B",parentID:"a",value:2)]))) }
        var document = Self.fixture(.radar)
        guard case .dimensions(var dimensions) = document.data else { return }
        dimensions.records[0].values[0] = 100; document.data = .dimensions(dimensions)
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(document) }
    }
    @Test("Networks allow cycles but flow cycles, asymmetry and false totals are rejected")
    func flowContracts() throws {
        let network = Self.fixture(.network)
        #expect(try ChartValidator.prepare(network).document == network)
        let flow = Self.fixture(.sankey)
        #expect(try ChartValidator.prepare(flow).warnings.count == 1)
        guard case .flow(var data) = flow.data else { return }
        data.links.append(.init(id:"ca",source:"c",target:"a",value:1))
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.sankey,data:.flow(data))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.chord,data:.flowMatrix(.init(nodes:[.init(id:"a",label:"A"),.init(id:"b",label:"B")],values:[[0,1],[2,0]])))) }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.waterfall,data:.waterfall([.init(id:"a",label:"A",kind:.delta,value:5),.init(id:"b",label:"Total",kind:.total,value:6)]))) }
        #expect(try ChartValidator.prepare(Self.fixture(.funnel)).document == Self.fixture(.funnel))
    }
    @Test("Calendar dates, zones, local aggregation and milestones are explicit")
    func calendarContracts() throws {
        _ = try ChartDates.localDate("2024-02-29")
        #expect(throws:ChartIssue.self) { try ChartDates.localDate("2023-02-29") }
        #expect(throws:ChartIssue.self) { try ChartDates.instant("2026-11-09T10:00:00") }
        #expect(throws:ChartIssue.self) { try ChartDates.instant("2026-02-30T10:00:00Z") }
        let values: [CalendarValue] = [.init(id:"a",day:.instant("2026-11-01T05:30:00Z"),value:1),.init(id:"b",day:.instant("2026-11-01T06:30:00Z"),value:2)]
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.calendarHeatmap,data:.calendar(values),options:.init(timeZone:"America/New_York"))) }
        _ = try ChartValidator.prepare(.init(type:.calendarHeatmap,data:.calendar(values),options:.init(timeZone:"America/New_York",aggregation:.sum)))
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.gantt,data:.tasks([.init(id:"a",label:"A",start:Self.day1,end:Self.day1)]))) }
    }
    @Test("Global budgets, v2 payload mismatch and nested facets fail")
    func boundaries() throws {
        #expect(throws:ChartIssue.self) { try ChartDocumentCodec.decode(Data(repeating:32,count:ChartLimits.documentBytes+1)) }
        for kind in ChartKind.allCases {
            let wrong: ChartData = [.pie,.donut].contains(kind) ? .cartesian([.init(id:"a",x:.number(1),y:2)]) : .parts([.init(id:"a",label:"A",value:1)])
            #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:kind,data:wrong)) }
        }
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.smallMultiples,data:.facets([.init(id:"nested",document:Self.fixture(.smallMultiples))]))) }
        let samples = ChartDocument(type:.histogram,data:.samples([.init(id:"s",values:Array(repeating:1,count:1001))]))
        #expect(throws:ChartIssue.self) { try ChartValidator.prepare(.init(type:.smallMultiples,data:.facets([.init(id:"a",document:samples),.init(id:"b",document:samples)]))) }
    }
    @Test("Preparation honors cancellation before producing a usable chart")
    func cancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ChartValidator.prepare(Self.fixture(.line))
        }
        do { _ = try await task.value; Issue.record("Cancelled preparation succeeded") }
        catch { #expect(error is CancellationError) }
    }
}
