// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func comparison() throws {
        switch chart.document.data {
        case .parts(let parts):
            let total = parts.reduce(0) { $0+$1.value }, center = ChartPoint(x:frame.width/2,y:(frame.height+28)/2)
            let outer = min(plot.width,plot.height)/2
            let inner = chart.document.type == .donut ? outer*(chart.document.options.holeRatio ?? 0.45) : 0
            var start = -Double.pi/2
            for (index,part) in parts.enumerated() {
                let end = start + part.value/total*2*Double.pi
                let ref = source(part.id), style = "series.\(index)"
                if part.value > 0 {
                    add(.path(sector(center:center,inner:inner,outer:outer,start:start,end:end)),style:style,sources:[ref],
                        bounds:.init(x:center.x-outer,y:center.y-outer,width:outer*2,height:outer*2),
                        readout:.init(title:part.label,fields:[.init("value",number(part.value)),.init("percent",number(part.value/total*100)+"%")]))
                }
                legend.append(.init(id:part.id,label:part.label,styleToken:style)); start = end
            }
            if inner>0 { text(number(total),x:center.x-inner,y:center.y-10,width:inner*2,style:"title") }
        case .facets(let children):
            let columns = Int(ceil(sqrt(Double(children.count)))), rows = Int(ceil(Double(children.count)/Double(columns)))
            let cellWidth = plot.width/Double(columns), cellHeight = plot.height/Double(rows)
            try chartCheck(cellWidth >= 240 && cellHeight >= 180,"viewport","small multiples need at least 240x180 per facet; enlarge or export a larger figure")
            for (index,facet) in children.enumerated() {
                let child = try NativeChartSceneBuilder.build(ChartValidator.prepare(facet.document),width:cellWidth,height:cellHeight)
                let dx = plot.x+Double(index%columns)*cellWidth, dy = plot.y+Double(index/columns)*cellHeight
                let prefix = "facet-\(index)-"
                func key(_ id:ChartRecordID) -> ChartRecordID { .init(facetPath:[facet.id]+id.facetPath,collection:id.collection,id:id.id) }
                for item in child.layout.primitives {
                    primitives.append(.init(id:prefix+item.id,sourceIDs:item.sourceIDs.map(key),shape:item.shape.translated(x:dx,y:dy),styleToken:item.styleToken))
                }
                for item in child.hits {
                    hits.append(.init(primitiveID:prefix+item.primitiveID,sourceIDs:item.sourceIDs.map(key),bounds:item.bounds.translated(x:dx,y:dy),readout:item.readout))
                }
                notes += child.notes
            }
        case .cartesian(let rows): try cartesian(rows)
        default: throw ChartIssue(path:"layout",problem:"comparison payload mismatch")
        }
    }
    mutating func cartesian(_ rows:[CartesianDatum]) throws {
        let kind = chart.document.type
        let keys = orderedKeys(rows.map { $0.seriesID ?? "" })
        let xs = rows.map(\.x)
        let stack = [.stackedBar,.percentStackedBar,.stackedArea,.percentStackedArea].contains(kind)
        let percent = [.percentStackedBar,.percentStackedArea].contains(kind)
        let bars = [.column,.bar,.groupedBar,.stackedBar,.percentStackedBar].contains(kind)
        let horizontal = kind == .bar || chart.document.options.orientation == .horizontal
        var positives:[ChartCoordinate:Double] = [:],negatives:[ChartCoordinate:Double] = [:]
        let totals = Dictionary(grouping:rows,by:\.x).mapValues { $0.compactMap(\.y).reduce(0,+) }
        var bands:[String:[(CartesianDatum,Double,Double)?]] = [:], allY:[Double] = []
        for key in keys {
            var values:[(CartesianDatum,Double,Double)?] = []
            for row in rows where (row.seriesID ?? "") == key {
                guard var y = row.y else { values.append(nil); continue }
                if percent { guard let total=totals[row.x],total>0 else { values.append(nil);continue }; y = y/total*100 }
                let base:Double
                if stack {
                    base = y>=0 ? positives[row.x,default:0] : negatives[row.x,default:0]
                    if y>=0 { positives[row.x] = base+y } else { negatives[row.x] = base+y }
                } else { base = chart.document.options.baseline ?? 0 }
                let top = stack ? base+y : y
                try chartFinite(top,"layout.stack")
                allY += (bars || stack || kind == .area) ? [base,top]:[top]; values.append((row,base,top))
            }
            bands[key] = values
        }
        var xScale = try xDomain(xs)
        if (bars || kind == .combo) && chart.document.axes.first(where:{$0.id=="x"})?.lower == nil {
            switch xScale {
            case .numeric(let a,let b):
                let pad=(b/2-a/2)*0.1
                if (a-pad).isFinite && (b+pad).isFinite{xScale = .numeric(lower:a-pad,upper:b+pad)}
            case .temporal(let a,let b,let zone):let pad=b.timeIntervalSince(a)*0.05;xScale = .temporal(lower:a.addingTimeInterval(-pad),upper:b.addingTimeInterval(pad),timeZone:zone)
            case .categorical:break
            }
        }
        let extent=allY.isEmpty && percent ? [0,100]:allY
        var yScale = try kind == .combo ? numericDomain(extent):valueDomain(extent,zero:bars || stack || kind == .area)
        if kind == .combo,let key=keys.first {
            let header=chart.document.series.first{$0.id==key},axis=chart.document.axes.first{$0.id==header?.axisID}
            yScale = try numericDomain(rows.filter{($0.seriesID ?? "")==key}.compactMap(\.y),zero:header?.mark == .bar || header?.mark == .column,axis:axis)
        }
        let baseTransform = try ChartCartesianTransform(xDomain:horizontal ? yScale:xScale,yDomain:horizontal ? xScale:yScale,plot:plot)
        try axes(baseTransform)
        if percent {
            for x in orderedKeys(rows.filter{totals[$0.x]==0}.map{coordinateLabel($0.x)}) {
                let values=rows.filter{coordinateLabel($0.x)==x}
                if let first=values.first {
                    let p=try baseTransform.position(x:horizontal ? .number(0):first.x,y:horizontal ? first.x:.number(0))
                    markPoint(p,radius:3,style:"missing",sources:values.map{source($0.id)},readout:.init(title:x,fields:[.init("value","0"),.init("percent","Undefined: zero total")]))
                }
            }
        }
        let positions = try xs.map { try xScale.unitPosition(of:$0) }.sorted()
        let gaps = zip(positions,positions.dropFirst()).map { abs($0.1-$0.0) }.filter { $0>1e-12 }
        let categoryWidth = min(64,min(0.75,max(0.002,(gaps.min() ?? 0.7)*0.7))*(horizontal ? plot.height:plot.width))
        for (index,key) in keys.enumerated() {
            let header = chart.document.series.first { $0.id==key }
            let mark = kind == .combo ? header?.mark : nil
            let isBar = bars || mark == .bar || mark == .column
            var transform = baseTransform
            if kind == .combo {
                let values = rows.filter { ($0.seriesID ?? "")==key }.compactMap(\.y)
                let axis = chart.document.axes.first { $0.id==header?.axisID }
                let own:ChartAxisDomain
                own = try numericDomain(values,zero:isBar,axis:axis)
                transform = try .init(xDomain:xScale,yDomain:own,plot:plot)
                if index>0 {
                    for tick in 0...4 {
                        if let value=try own.coordinate(atUnitPosition:Double(tick)/4) { text(coordinateLabel(value),x:plot.x+plot.width+8,y:plot.y+plot.height*(1-Double(tick)/4)-9,width:52) }
                    }
                    if let unit=axis?.unit { text(unit,x:frame.width-65,y:34,width:62) }
                }
            }
            let style = "series.\(index)"
            legend.append(.init(id:key,label:header?.name ?? (key.isEmpty ? "Series":key),styleToken:style))
            var segment:[(CartesianDatum,ChartPoint,ChartPoint)] = []
            func point(_ x:ChartCoordinate,_ y:Double) throws -> ChartPoint {
                if horizontal { return try transform.position(x:.number(y),y:x) }
                return try transform.position(x:x,y:.number(y))
            }
            for item in (bands[key] ?? []) + [nil] {
                guard let (row,base,top) = item else {
                    if !segment.isEmpty {
                        if !isBar {
                            let refs = segment.map { source($0.0.id) }, points = segment.map { $0.1 }
                            if segment.count >= 2 && ([.area,.stackedArea,.percentStackedArea].contains(kind) || mark == .area) {
                                add(.polygon(points+segment.reversed().map { $0.2 }),style:style+".soft",sources:refs)
                            }
                            if points.count>=2 { add(.polyline(points),style:style,sources:refs) }
                        }
                        segment.removeAll(keepingCapacity:true)
                    }
                    continue
                }
                let topPoint=try point(row.x,top),basePoint=try point(row.x,base),ref=source(row.id)
                let readout=ChartReadout(title:row.label ?? coordinateLabel(row.x),fields:[.init("series",header?.name ?? key),.init("value",number(row.y!))]+(percent ? [.init("percent",number(top-base)+"%")]:[]))
                if isBar {
                    let grouped = kind == .groupedBar || kind == .combo
                    let width = grouped ? categoryWidth/Double(keys.count):categoryWidth
                    let offset = grouped ? -categoryWidth/2+(Double(index)+0.5)*width:0
                    let rect:ChartRect
                    if horizontal { rect = .init(x:min(topPoint.x,basePoint.x),y:topPoint.y+offset-width/2,width:abs(topPoint.x-basePoint.x),height:width*0.92) }
                    else { rect = .init(x:topPoint.x+offset-width/2,y:min(topPoint.y,basePoint.y),width:width*0.92,height:abs(topPoint.y-basePoint.y)) }
                    bar(rect,style:style,sources:[ref],readout:readout)
                } else { markPoint(topPoint,radius:3,style:style,sources:[ref],readout:readout);segment.append((row,topPoint,basePoint)) }
            }
        }
    }
    func orderedKeys(_ values:[String]) -> [String] {
        var seen:Set<String> = [];return values.filter { seen.insert($0).inserted }
    }
}

extension ChartRect {
    func translated(x dx:Double,y dy:Double) -> Self { .init(x:x+dx,y:y+dy,width:width,height:height) }
}
extension ChartPoint {
    func translated(x dx:Double,y dy:Double) -> Self { .init(x:x+dx,y:y+dy) }
}
extension ChartShape {
    func translated(x dx:Double,y dy:Double) -> Self {
        switch self {
        case .point(let p): .point(p.translated(x:dx,y:dy))
        case .polyline(let p): .polyline(p.map { $0.translated(x:dx,y:dy) })
        case .polygon(let p): .polygon(p.map { $0.translated(x:dx,y:dy) })
        case .rectangle(let r): .rectangle(r.translated(x:dx,y:dy))
        case .circle(let p,let r): .circle(center:p.translated(x:dx,y:dy),radius:r)
        case .text(let text,let r): .text(text,frame:r.translated(x:dx,y:dy))
        case .path(let segments): .path(segments.map { item in
            switch item {
            case .move(let p): .move(p.translated(x:dx,y:dy))
            case .line(let p): .line(p.translated(x:dx,y:dy))
            case .cubic(let a,let b,let c): .cubic(control1:a.translated(x:dx,y:dy),control2:b.translated(x:dx,y:dy),end:c.translated(x:dx,y:dy))
            case .close: .close
            }
        })
        }
    }
}
