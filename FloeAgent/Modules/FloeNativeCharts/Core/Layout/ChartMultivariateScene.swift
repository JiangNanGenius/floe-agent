// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func multivariate() throws {
        switch chart.document.data {
        case .cartesian(let rows):
            let t=try transform(xs:rows.map(\.x),ys:rows.compactMap(\.y));try axes(t)
            let maximum=rows.compactMap(\.size).max() ?? 1
            for row in rows {
                let p=try t.position(x:row.x,y:.number(row.y!))
                let radius=chart.document.type == .bubble ? (maximum>0 ? sqrt((row.size ?? 0)/maximum)*22:0):4
                markPoint(p,radius:radius,style:"series.0",sources:[source(row.id)],readout:.init(title:row.label ?? row.id,fields:[.init("x",coordinateLabel(row.x)),.init("y",number(row.y!))]+(row.size.map{[.init("size",number($0))]} ?? [])))
            }
            if chart.document.type == .bubble {notes.append("Bubble area, not radius, is proportional to size.")}
        case .matrix(let cells):
            let columns=try xDomain(cells.map(\.column)),rows=try xDomain(cells.map(\.row))
            let t=try ChartCartesianTransform(xDomain:columns,yDomain:rows,plot:plot);try axes(t)
            let columnCount=Set(cells.map(\.column)).count,rowCount=Set(cells.map(\.row)).count
            let width=plot.width/Double(columnCount)*0.92,height=plot.height/Double(rowCount)*0.92
            let values=cells.compactMap(\.value),low=values.min() ?? 0,high=values.max() ?? 1
            for cell in cells {
                let p=try t.position(x:cell.column,y:cell.row)
                let fraction=cell.value.map{high==low ? 0.5:($0-low)/(high-low)}
                let style=fraction.map{"heat.\(min(9,max(0,Int($0*9))))"} ?? "missing"
                bar(.init(x:p.x-width/2,y:p.y-height/2,width:width,height:height),style:style,sources:[source(cell.id)],readout:.init(title:cell.id,fields:[.init("row",coordinateLabel(cell.row)),.init("column",coordinateLabel(cell.column)),.init("value",cell.value.map(number) ?? "Missing")]))
            }
            notes.append("Missing cells are distinct from numeric zero; color scale \(number(low))…\(number(high)).")
        case .dimensions(let data):
            if chart.document.type == .radar {try radar(data)} else {try parallel(data)}
        case .polar(let points):try polar(points)
        default:throw ChartIssue(path:"layout",problem:"multivariate payload mismatch")
        }
    }
    mutating func radar(_ data:DimensionData) throws {
        let center=ChartPoint(x:frame.width/2,y:frame.height/2+14),radius=min(plot.width,plot.height)/2*0.9,n=data.dimensions.count
        for ring in 1...4 {add(.circle(center:center,radius:radius*Double(ring)/4),style:"grid.outline")}
        for (i,dim) in data.dimensions.enumerated() {
            let angle = -Double.pi/2+Double(i)/Double(n)*2*Double.pi
            let end=ChartPoint(x:center.x+radius*cos(angle),y:center.y+radius*sin(angle))
            line(center,end,style:"grid");text(dim.label+(dim.unit.map{" (\($0))"} ?? ""),x:end.x-45,y:end.y-10,width:120)
        }
        for (i,row) in data.records.enumerated() {
            var points:[ChartPoint] = []
            for (j,pair) in zip(row.values,data.dimensions).enumerated() {
                let fraction=try ChartAxisDomain.numeric(lower:pair.1.lower,upper:pair.1.upper).unitPosition(of:.number(pair.0))
                let angle = -Double.pi/2+Double(j)/Double(n)*2*Double.pi
                let p=ChartPoint(x:center.x+radius*fraction*cos(angle),y:center.y+radius*fraction*sin(angle));points.append(p)
                markPoint(p,radius:3,style:"series.\(i)",sources:[source(row.id)],readout:.init(title:row.label ?? row.id,fields:[.init(pair.1.label,number(pair.0)),.init("range","\(number(pair.1.lower))…\(number(pair.1.upper))")]))
            }
            add(.polygon(points),style:"series.\(i).soft",sources:[source(row.id)])
            if data.records.count<=16{legend.append(.init(id:row.id,label:row.label ?? row.id,styleToken:"series.\(i)"))}
        }
    }
    mutating func parallel(_ data:DimensionData) throws {
        let n=data.dimensions.count
        for (i,dim) in data.dimensions.enumerated() {
            let x=plot.x+Double(i)/Double(n-1)*plot.width
            line(.init(x:x,y:plot.y),.init(x:x,y:plot.y+plot.height))
            text(dim.label,x:x-35,y:plot.y-22,width:100)
            text(number(dim.lower),x:x-25,y:plot.y+plot.height+6,width:80)
            text(number(dim.upper),x:x-25,y:plot.y-5,width:80)
        }
        for (i,row) in data.records.enumerated() {
            var points:[ChartPoint] = []
            for (j,pair) in zip(row.values,data.dimensions).enumerated() {
                let fraction=try ChartAxisDomain.numeric(lower:pair.1.lower,upper:pair.1.upper).unitPosition(of:.number(pair.0))
                let p=ChartPoint(x:plot.x+Double(j)/Double(n-1)*plot.width,y:plot.y+(1-fraction)*plot.height);points.append(p)
                markPoint(p,radius:2,style:"series.\(i)",sources:[source(row.id)],readout:.init(title:row.label ?? row.id,fields:[.init(pair.1.label,number(pair.0))]))
            }
            add(.polyline(points),style:"series.\(i)",sources:[source(row.id)])
        }
    }
    mutating func polar(_ points:[PolarDatum]) throws {
        let center=ChartPoint(x:frame.width/2,y:frame.height/2+10),radius=min(plot.width,plot.height)/2*0.9,maximum=max(points.map(\.radius).max() ?? 0,1e-12)
        let degrees=chart.document.options.angleUnit == .degrees,clockwise=chart.document.options.clockwise ?? false
        for ring in 1...4 {add(.circle(center:center,radius:radius*Double(ring)/4),style:"grid.outline")}
        for tick in 0..<8 {
            let angle=Double(tick)*Double.pi/4,end=ChartPoint(x:center.x+radius*cos(angle),y:center.y+(clockwise ? 1:-1)*radius*sin(angle))
            line(center,end,style:"grid");text(number(degrees ? angle*180/Double.pi:angle),x:end.x-16,y:end.y-8,width:70)
        }
        for point in points {
            let raw=point.angle+(chart.document.options.zeroAngle ?? 0),angle=degrees ? raw*Double.pi/180:raw
            let distance=point.radius/maximum*radius,p=ChartPoint(x:center.x+distance*cos(angle),y:center.y+(clockwise ? 1:-1)*distance*sin(angle))
            markPoint(p,style:"series.0",sources:[source(point.id)],readout:valueReadout(point.id,[("angle",point.angle),("radius",point.radius)]))
        }
    }
}
