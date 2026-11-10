// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func statistics() throws {
        switch chart.document.type {
        case .histogram: try histogram()
        case .boxPlot: try boxes()
        case .violin,.density: try densities()
        case .errorBars,.confidenceBand: try intervals()
        default: throw ChartIssue(path:"layout",problem:"statistics type mismatch")
        }
    }
    mutating func histogram() throws {
        var groups:[(String,[HistogramBin],[ChartRecordID])] = []
        switch chart.document.data {
        case .bins(let bins):
            for key in orderedKeys(bins.map { $0.seriesID ?? "" }) { let b=bins.filter { ($0.seriesID ?? "")==key };groups.append((key,b,b.map { source($0.id) })) }
        case .samples(let samples):
            for series in samples {
                let edges:[Double]
                if let given=chart.document.options.binEdges { edges=given }
                else {
                    var a=series.values.min()!,b=series.values.max()!;if a==b{a-=0.5;b+=0.5}
                    let n=chart.document.options.binCount ?? min(200,max(1,Int(ceil(log2(Double(series.values.count))))+1))
                    edges=(0...n).map { a*(1-Double($0)/Double(n))+b*Double($0)/Double(n) }
                }
                var counts=Array(repeating:0,count:edges.count-1)
                for value in series.values {
                    guard let index=(0..<counts.count).first(where:{value>=edges[$0] && (value<edges[$0+1] || ($0==counts.count-1 && value==edges[$0+1]))}) else { throw ChartIssue(path:"options.binEdges",problem:"bin edges exclude a supplied sample") }
                    counts[index]+=1
                }
                let bins=counts.indices.map { HistogramBin(id:"\(series.id)-\($0)",lower:edges[$0],upper:edges[$0+1],count:counts[$0]) }
                groups.append((series.id,bins,[source(series.id,collection:"samples")]))
            }
        default:throw ChartIssue(path:"layout",problem:"histogram data mismatch")
        }
        let bins=groups.flatMap{$0.1}
        let measure=chart.document.options.histogramMeasure ?? .count
        func height(_ bin:HistogramBin,_ total:Double)->Double { switch measure {case .count:Double(bin.count);case .density:Double(bin.count)/total/(bin.upper-bin.lower);case .probability:Double(bin.count)/total} }
        let t=try transform(xs:bins.flatMap{[.number($0.lower),.number($0.upper)]},ys:groups.flatMap{group in let total=group.1.reduce(0.0){$0+Double($1.count)};return group.1.map{height($0,total)}},zero:true)
        try axes(t)
        for (g,group) in groups.enumerated() {
            for (i,bin) in group.1.enumerated() {
                let total=group.1.reduce(0.0){$0+Double($1.count)},value=height(bin,total)
                let a=try t.position(x:.number(bin.lower),y:.number(value)),b=try t.position(x:.number(bin.upper),y:.number(0))
                let refs=chart.document.data.kind == .bins ? [group.2[i]]:group.2
                bar(.init(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y),style:"series.\(g).soft",sources:refs,
                    readout:valueReadout(group.0,[("lower",bin.lower),("upper",bin.upper),("count",Double(bin.count)),(measure.rawValue,value)]))
            }
            legend.append(.init(id:group.0,label:group.0,styleToken:"series.\(g)"))
        }
        notes.append("Bins are [lower, upper), with the final upper edge included; y is \(measure.rawValue).")
    }
    mutating func boxes() throws {
        let boxes:[BoxSummary],refs:[ChartRecordID]
        switch chart.document.data {
        case .boxSummary(let values):boxes=values;refs=values.map{source($0.id)}
        case .samples(let groups):boxes=try groups.map{try ChartStatMath.tukeyBox($0.values,id:$0.id)};refs=groups.map{source($0.id,collection:"samples")};notes.append("Linear R7 quartiles; Tukey 1.5 IQR whiskers use actual samples.")
        default:throw ChartIssue(path:"layout",problem:"box data mismatch")
        }
        let y=try valueDomain(boxes.flatMap{[$0.lowerWhisker,$0.upperWhisker]+$0.outliers})
        let t=try ChartCartesianTransform(xDomain:.categorical(boxes.map{$0.label ?? $0.id}),yDomain:y,plot:plot);try axes(t)
        let width=plot.width/Double(boxes.count)*0.5
        for (i,b) in boxes.enumerated() {
            let x=ChartCoordinate.category(b.label ?? b.id),ref=refs[i],style="series.\(i)"
            let low=try t.position(x:x,y:.number(b.lowerWhisker)),high=try t.position(x:x,y:.number(b.upperWhisker)),q1=try t.position(x:x,y:.number(b.q1)),q3=try t.position(x:x,y:.number(b.q3)),median=try t.position(x:x,y:.number(b.median))
            line(low,high,style:style);line(.init(x:low.x-width/4,y:low.y),.init(x:low.x+width/4,y:low.y),style:style);line(.init(x:high.x-width/4,y:high.y),.init(x:high.x+width/4,y:high.y),style:style)
            bar(.init(x:q1.x-width/2,y:q3.y,width:width,height:q1.y-q3.y),style:style+".soft",sources:[ref],readout:valueReadout(b.label ?? b.id,[("lowerWhisker",b.lowerWhisker),("q1",b.q1),("median",b.median),("q3",b.q3),("upperWhisker",b.upperWhisker)]))
            line(.init(x:median.x-width/2,y:median.y),.init(x:median.x+width/2,y:median.y),style:style)
            for value in b.outliers {markPoint(try t.position(x:x,y:.number(value)),radius:3,style:style,sources:[ref],readout:valueReadout("Outlier",[("value",value)]))}
        }
    }
    mutating func densities() throws {
        var groups:[DensitySeries] = [],refs:[ChartRecordID] = []
        switch chart.document.data {
        case .density(let values):groups=values;refs=values.map{source($0.id,collection:"density")}
        case .samples(let values):
            for group in values {
                let result=try ChartStatMath.density(group.values,bandwidth:chart.document.options.bandwidth,id:group.id)
                groups.append(result.series);refs.append(source(group.id,collection:"samples"));notes.append("Gaussian KDE: \(group.id), h=\(number(result.bandwidth)); supplied samples retained.")
            }
        default:throw ChartIssue(path:"layout",problem:"density data mismatch")
        }
        if chart.document.type == .violin {
            let t=try ChartCartesianTransform(xDomain:.categorical(groups.map(\.id)),yDomain:valueDomain(groups.flatMap{$0.points.map(\.x)}),plot:plot);try axes(t)
            let width=plot.width/Double(groups.count)*0.42
            for (i,group) in groups.enumerated() {
                let center=try t.position(x:.category(group.id),y:.number(group.points[0].x)).x,maxDensity=group.points.map(\.density).max()!
                try chartCheck(maxDensity>0,"density","violin has no positive density")
                let left=try group.points.map{p in ChartPoint(x:center-width*p.density/maxDensity,y:try t.position(x:.category(group.id),y:.number(p.x)).y)}
                let right=try group.points.reversed().map{p in ChartPoint(x:center+width*p.density/maxDensity,y:try t.position(x:.category(group.id),y:.number(p.x)).y)}
                add(.polygon(left+right),style:"series.\(i).soft",sources:[refs[i]],bounds:bounding(left+right),readout:.init(title:group.id,fields:[.init("method","Mirrored density"),.init("samples",String(group.points.count))]))
                for (p,position) in zip(group.points,left) {add(.point(position),style:"hitOnly",sources:[refs[i]],bounds:.init(x:position.x-5,y:position.y-4,width:10,height:8),readout:valueReadout(group.id,[("value",p.x),("density",p.density)]))}
            }
        } else {
            let t=try transform(xs:groups.flatMap{$0.points.map{.number($0.x)}},ys:groups.flatMap{$0.points.map(\.density)},zero:true);try axes(t)
            for (i,group) in groups.enumerated() {
                let points=try group.points.map{try t.position(x:.number($0.x),y:.number($0.density))}
                add(.polyline(points),style:"series.\(i)",sources:[refs[i]])
                for (p,position) in zip(group.points,points) {add(.point(position),style:"hitOnly",sources:[refs[i]],bounds:.init(x:position.x-5,y:position.y-5,width:10,height:10),readout:valueReadout(group.id,[("x",p.x),("density",p.density)]))}
                legend.append(.init(id:group.id,label:group.id,styleToken:"series.\(i)"))
            }
        }
    }
    mutating func intervals() throws {
        guard case .intervals(let rows)=chart.document.data else{return}
        let t=try transform(xs:rows.map(\.x),ys:rows.flatMap{[$0.lower,$0.upper]});try axes(t)
        for (g,key) in orderedKeys(rows.map{$0.seriesID ?? ""}).enumerated() {
            let values=rows.filter{($0.seriesID ?? "")==key},style="series.\(g)"
            let low=try values.map{try t.position(x:$0.x,y:.number($0.lower))},high=try values.map{try t.position(x:$0.x,y:.number($0.upper))}
            if chart.document.type == .confidenceBand && values.count >= 2 {add(.polygon(low+high.reversed()),style:style+".soft",sources:values.map{source($0.id)})}
            var estimates:[ChartPoint] = []
            for (i,row) in values.enumerated() {
                let point=try t.position(x:row.x,y:.number(row.estimate));estimates.append(point)
                if chart.document.type == .errorBars || values.count == 1 {
                    line(low[i],high[i],style:style)
                    line(.init(x:low[i].x-6,y:low[i].y),.init(x:low[i].x+6,y:low[i].y),style:style)
                    line(.init(x:high[i].x-6,y:high[i].y),.init(x:high[i].x+6,y:high[i].y),style:style)
                }
                markPoint(point,style:style,sources:[source(row.id)],readout:valueReadout(coordinateLabel(row.x),[("estimate",row.estimate),("lower",row.lower),("upper",row.upper)]))
            }
            if chart.document.type == .confidenceBand && estimates.count>=2 {add(.polyline(estimates),style:style,sources:values.map{source($0.id)})}
        }
        if let level=chart.document.options.confidenceLevel{notes.append("Confidence level: \(number(level*100))%.")}
        if let method=chart.document.options.method {notes.append(method)}
    }
}
