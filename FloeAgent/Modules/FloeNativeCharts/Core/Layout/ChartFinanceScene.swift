// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func finance() throws {
        let kind=chart.document.type
        if case .volume(let volumes)=chart.document.data {try volumePane(volumes,rect:plot);return}
        guard case .ohlc(let rows)=chart.document.data else{throw ChartIssue(path:"layout",problem:"financial payload mismatch")}
        if kind == .volume {try volumePane(rows.map{.init(id:$0.id,time:$0.time,volume:$0.volume!)},rect:plot);return}
        let priceRect=kind == .priceVolume ? ChartRect(x:plot.x,y:plot.y,width:plot.width,height:plot.height*0.68):plot
        let t=try ChartCartesianTransform(xDomain:xDomain(rows.map{.instant($0.time)}),yDomain:valueDomain(rows.flatMap{[$0.low,$0.high]}),plot:priceRect)
        try axes(t)
        let positions=try rows.map{try t.xDomain.unitPosition(of:.instant($0.time))}.sorted()
        let gap=zip(positions,positions.dropFirst()).map{$0.1-$0.0}.min() ?? 0.5
        let width=max(1,min(32,gap*priceRect.width*0.65))
        for row in rows {
            let x=ChartCoordinate.instant(row.time),lo=try t.position(x:x,y:.number(row.low)),hi=try t.position(x:x,y:.number(row.high)),open=try t.position(x:x,y:.number(row.open)),close=try t.position(x:x,y:.number(row.close))
            let style=row.close>=row.open ? "positive":"negative",ref=source(row.id)
            let detail=valueReadout(row.time,[("open",row.open),("high",row.high),("low",row.low),("close",row.close)]+(row.volume.map{[("volume",$0)]} ?? []))
            add(.polyline([lo,hi]),style:style,sources:[ref])
            if kind == .ohlc {
                add(.polyline([.init(x:open.x-width/2,y:open.y),open]),style:style,sources:[ref])
                add(.polyline([close,.init(x:close.x+width/2,y:close.y)]),style:style,sources:[ref])
                add(.point(close),style:"hitOnly",sources:[ref],bounds:.init(x:lo.x-width/2,y:hi.y-3,width:width,height:max(6,lo.y-hi.y+6)),readout:detail)
            } else {
                bar(.init(x:open.x-width/2,y:min(open.y,close.y),width:width,height:max(1,abs(close.y-open.y))),style:style,sources:[ref],readout:detail)
            }
        }
        if kind == .priceVolume {
            for (index,ma) in (chart.document.options.movingAverages ?? []).enumerated() {
                let prices=rows.map { row -> Double in switch ma.field {case .open:row.open;case .high:row.high;case .low:row.low;case .close:row.close} }
                let means=try ChartStatMath.movingAverage(prices,method:ma.method,period:ma.period,seed:ma.seed)
                var points:[ChartPoint]=[],refs:[ChartRecordID]=[]
                for (row,value) in zip(rows,means) {
                    if let value {let point=try t.position(x:.instant(row.time),y:.number(value));points.append(point);refs.append(source(row.id));add(.point(point),style:"hitOnly",sources:[source(row.id)],bounds:.init(x:point.x-5,y:point.y-5,width:10,height:10),readout:valueReadout("\(ma.method.rawValue.uppercased()) \(ma.period)",[("value",value)]))}
                }
                if points.count>=2{add(.polyline(points),style:"series.\(index)",sources:refs)}
                legend.append(.init(id:"ma-\(index)",label:"\(ma.method.rawValue.uppercased()) \(ma.period)",styleToken:"series.\(index)"))
                if points.isEmpty {notes.append("\(ma.method.rawValue.uppercased()) \(ma.period) is warming up; missing values are not zero.")}
            }
            let rect=ChartRect(x:plot.x,y:plot.y+plot.height*0.78,width:plot.width,height:plot.height*0.22)
            try volumePane(rows.map{.init(id:$0.id,time:$0.time,volume:$0.volume!)},rect:rect,drawAxes:false)
        }
        legend += [.init(id:"rise",label:"Close ≥ open",styleToken:"positive"),.init(id:"fall",label:"Close < open",styleToken:"negative")]
    }
    mutating func volumePane(_ rows:[VolumeRecord],rect:ChartRect,drawAxes:Bool = true) throws {
        let t=try ChartCartesianTransform(xDomain:xDomain(rows.map{.instant($0.time)}),yDomain:numericDomain(rows.map(\.volume),zero:true,axis:chart.document.axes.first{$0.id==(chart.document.type == .priceVolume ? "volume":"y")}),plot:rect)
        if drawAxes {try axes(t)} else {line(.init(x:rect.x,y:rect.y+rect.height),.init(x:rect.x+rect.width,y:rect.y+rect.height));text("Volume",x:rect.x,y:rect.y-22)}
        let width=max(1,min(28,rect.width/Double(rows.count)*0.65))
        for row in rows {
            let point=try t.position(x:.instant(row.time),y:.number(row.volume)),zero=try t.position(x:.instant(row.time),y:.number(0))
            bar(.init(x:point.x-width/2,y:point.y,width:width,height:zero.y-point.y),style:"series.0.soft",sources:[source(row.id)],readout:valueReadout(row.time,[("volume",row.volume)]))
        }
    }
}
