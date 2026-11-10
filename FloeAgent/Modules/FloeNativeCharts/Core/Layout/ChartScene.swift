// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ChartReadoutField: Sendable, Equatable {
    public var name: String; public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}
public struct ChartReadout: Sendable, Equatable {
    public var title: String
    public var fields: [ChartReadoutField]
    public init(title: String, fields: [ChartReadoutField]) { self.title = title; self.fields = fields }
}
public struct ChartSceneHit: Sendable, Equatable {
    public var primitiveID: String
    public var sourceIDs: [ChartRecordID]
    public var bounds: ChartRect
    public var readout: ChartReadout
}
public struct ChartLegendItem: Sendable, Equatable {
    public var id: String; public var label: String; public var styleToken: String
}
public struct NativeChartScene: Sendable, Equatable {
    public let frame: ChartRect
    public let layout: ChartLayout
    public let hits: [ChartSceneHit]
    public let legend: [ChartLegendItem]
    public let notes: [String]
}

public enum NativeChartSceneBuilder {
    public static func build(_ chart: PreparedChart, width: Double = 960, height: Double = 640,
                             title: String? = nil) throws -> NativeChartScene {
        try Task.checkCancellation()
        var builder = ChartSceneBuilder(chart:chart,width:width,height:height)
        try chartCheck(builder.frame.isValid && width >= 240 && height >= 180 && width <= 8192 && height <= 8192,
                       "viewport","native chart viewport must be 240...8192 by 180...8192")
        builder.text(title ?? chart.document.title ?? "Chart",x:16,y:10,width:width-32,height:28,style:"title")
        switch chart.descriptor.family {
        case .comparison: try builder.comparison()
        case .statistics: try builder.statistics()
        case .finance: try builder.finance()
        case .multivariate: try builder.multivariate()
        case .relationships: try builder.relationships()
        case .schedule: try builder.schedule()
        }
        try Task.checkCancellation()
        let layout = try ChartLayout(primitives:builder.primitives,
            hits:builder.hits.map { .init(sourceIDs:$0.sourceIDs,bounds:$0.bounds) },for:chart)
        return .init(frame:builder.frame,layout:layout,hits:builder.hits,legend:builder.legend,notes:builder.notes)
    }
}

struct ChartSceneBuilder {
    let chart: PreparedChart
    let frame: ChartRect
    var primitives: [ChartPrimitive] = []
    var hits: [ChartSceneHit] = []
    var legend: [ChartLegendItem] = []
    var notes: [String] = []
    init(chart: PreparedChart,width:Double,height:Double) {
        self.chart = chart; frame = .init(x:0,y:0,width:width,height:height)
    }
    var plot: ChartRect { .init(x:64,y:52,width:max(1,frame.width-124),height:max(1,frame.height-140)) }
    func source(_ id: String,collection:String = "rows") -> ChartRecordID { .init(collection:collection,id:id) }
    func number(_ value: Double) -> String { String(format:"%.5g",locale:Locale(identifier:"en_US_POSIX"),value) }
    func coordinateLabel(_ value: ChartCoordinate) -> String {
        switch value { case .number(let v): number(v); case .category(let v),.instant(let v),.localDate(let v): v }
    }
    @discardableResult mutating func add(_ shape: ChartShape,style: String = "series.0",sources: [ChartRecordID] = [],
                                         bounds: ChartRect? = nil,readout: ChartReadout? = nil) -> String {
        let id = "primitive-\(primitives.count)"
        primitives.append(.init(id:id,sourceIDs:sources,shape:shape,styleToken:style))
        if let bounds, let readout, !sources.isEmpty {
            hits.append(.init(primitiveID:id,sourceIDs:sources,bounds:bounds,readout:readout))
        }
        return id
    }
    mutating func text(_ value:String,x:Double,y:Double,width:Double = 110,height:Double = 20,style:String = "text") {
        add(.text(String(value.prefix(320)),frame:.init(x:x,y:y,width:max(1,width),height:max(1,height))),style:style)
    }
    mutating func line(_ a:ChartPoint,_ b:ChartPoint,style:String = "axis") { add(.polyline([a,b]),style:style) }
    func numericDomain(_ values:[Double],zero:Bool = false) throws -> ChartAxisDomain {
        let finite = values.filter(\.isFinite)
        guard var low = finite.min(), var high = finite.max() else { throw ChartIssue(path:"layout",problem:"no finite numerical extent") }
        if zero { low = min(0,low); high = max(0,high) }
        if low == high {
            let pad = max(1,abs(low)*0.05)
            let a = low-pad, b = high+pad
            low = a.isFinite ? a : -Double.greatestFiniteMagnitude
            high = b.isFinite ? b : Double.greatestFiniteMagnitude
        }
        return .numeric(lower:low,upper:high)
    }
    func xDomain(_ coordinates:[ChartCoordinate]) throws -> ChartAxisDomain {
        guard let first = coordinates.first else { throw ChartIssue(path:"layout",problem:"empty coordinate extent") }
        switch first {
        case .category:
            var seen:Set<String> = []; var labels:[String] = []
            for value in coordinates { if case .category(let text) = value, seen.insert(text).inserted { labels.append(text) } }
            return try resolvedXDomain(.categorical(labels),coordinates:coordinates)
        case .number: return try resolvedXDomain(numericDomain(coordinates.compactMap { if case .number(let n) = $0 { return n }; return nil }),coordinates:coordinates)
        case .instant,.localDate:
            let dates = try coordinates.map { coordinate -> Date in
                switch coordinate { case .instant(let s): try ChartDates.instant(s); case .localDate(let s): try ChartDates.localDate(s,timeZone:chart.document.options.timeZone ?? "UTC"); default: throw ChartIssue(path:"layout",problem:"mixed coordinate types") }
            }
            var low = dates.min()!, high = dates.max()!
            if low == high { low = low.addingTimeInterval(-43200); high = high.addingTimeInterval(43200) }
            return try resolvedXDomain(.temporal(lower:low,upper:high,timeZone:chart.document.options.timeZone ?? "UTC"),coordinates:coordinates)
        }
    }
    func transform(xs:[ChartCoordinate],ys:[Double],zero:Bool = false) throws -> ChartCartesianTransform {
        try .init(xDomain:xDomain(xs),yDomain:valueDomain(ys,zero:zero),plot:plot)
    }
    mutating func axes(_ transform: ChartCartesianTransform) throws {
        let p = transform.plot
        line(.init(x:p.x,y:p.y),.init(x:p.x,y:p.y+p.height))
        line(.init(x:p.x,y:p.y+p.height),.init(x:p.x+p.width,y:p.y+p.height))
        func ticks(_ domain:ChartAxisDomain) throws -> [(Double,ChartCoordinate)] {
            if case .categorical(let labels)=domain {
                let stride=max(1,Int(ceil(Double(labels.count)/12)))
                return try labels.enumerated().filter{$0.offset%stride==0}.map{(_,label) in (try domain.unitPosition(of:.category(label)),.category(label))}
            }
            return try (0...4).compactMap{i in let f=Double(i)/4;return try domain.coordinate(atUnitPosition:f).map{(f,$0)}}
        }
        for (f,value) in try ticks(transform.yDomain) {
            let y=p.y+(1-f)*p.height
            if f>0{line(.init(x:p.x,y:y),.init(x:p.x+p.width,y:y),style:"grid")}
            text(coordinateLabel(value),x:2,y:y-9,width:p.x-6)
        }
        for (f,value) in try ticks(transform.xDomain){
            let label:String
            if case .instant(let raw)=value,let date=try? ChartDates.instant(raw) {
                let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(identifier:chart.document.options.timeZone ?? "UTC");format.dateFormat="MM-dd HH:mm";label=format.string(from:date)
            }else{label=String(coordinateLabel(value).prefix(16))}
            text(label,x:p.x+f*p.width-28,y:p.y+p.height+8,width:88)
        }
        if let axis=chart.document.axes.first(where:{$0.id=="x"}),let title=axis.title ?? axis.unit{text(title,x:p.x+p.width/2-80,y:frame.height-62,width:200)}
        if let axis=valueAxis(),let title=axis.title ?? axis.unit{text(title,x:p.x,y:p.y-19,width:250)}

    }
    func bounding(_ points:[ChartPoint],padding:Double = 5) -> ChartRect {
        let xs = points.map(\.x),ys = points.map(\.y)
        return .init(x:(xs.min() ?? 0)-padding,y:(ys.min() ?? 0)-padding,
                     width:max(1,(xs.max() ?? 0)-(xs.min() ?? 0)+2*padding),height:max(1,(ys.max() ?? 0)-(ys.min() ?? 0)+2*padding))
    }
    func valueReadout(_ title:String,_ values:[(String,Double)]) -> ChartReadout {
        .init(title:title,fields:values.map { .init($0.0,number($0.1)) })
    }
    mutating func markPoint(_ point:ChartPoint,radius:Double = 4,style:String,sources:[ChartRecordID],readout:ChartReadout) {
        add(.circle(center:point,radius:radius),style:style,sources:sources,
            bounds:.init(x:point.x-max(6,radius),y:point.y-max(6,radius),width:2*max(6,radius),height:2*max(6,radius)),readout:readout)
    }
    mutating func bar(_ rect:ChartRect,style:String,sources:[ChartRecordID],readout:ChartReadout) {
        let safe = ChartRect(x:rect.x,y:rect.y,width:max(0.5,rect.width),height:max(0.5,rect.height))
        add(.rectangle(safe),style:style,sources:sources,bounds:safe,readout:readout)
    }
    func arc(center:ChartPoint,radius:Double,start:Double,end:Double) -> [ChartPathSegment] {
        let n = max(1,Int(ceil(abs(end-start)/(.pi/2))))
        return (0..<n).map { i in
            let a = start+(end-start)*Double(i)/Double(n), b = start+(end-start)*Double(i+1)/Double(n)
            let k = 4.0/3.0*tan((b-a)/4)
            let p1 = ChartPoint(x:center.x+radius*cos(a),y:center.y+radius*sin(a))
            let p2 = ChartPoint(x:center.x+radius*cos(b),y:center.y+radius*sin(b))
            return .cubic(control1:.init(x:p1.x-k*radius*sin(a),y:p1.y+k*radius*cos(a)),
                          control2:.init(x:p2.x+k*radius*sin(b),y:p2.y-k*radius*cos(b)),end:p2)
        }
    }
    func sector(center:ChartPoint,inner:Double,outer:Double,start:Double,end:Double) -> [ChartPathSegment] {
        var path:[ChartPathSegment] = [.move(.init(x:center.x+outer*cos(start),y:center.y+outer*sin(start)))]
        path += arc(center:center,radius:outer,start:start,end:end)
        if inner > 0 {
            path.append(.line(.init(x:center.x+inner*cos(end),y:center.y+inner*sin(end))))
            path += arc(center:center,radius:inner,start:end,end:start)
        } else { path.append(.line(center)) }
        path.append(.close); return path
    }
}
