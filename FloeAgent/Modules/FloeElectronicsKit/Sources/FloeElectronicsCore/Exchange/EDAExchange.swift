// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum EDAExportFormat:String,Codable,CaseIterable,Sendable {
    case project,netlist,bom,positions,boardSVG,schematicSVG,gerber,excellon
}
public struct EDAExchangeFile:Sendable,Equatable {
    public let name:String
    public let mimeType:String
    public let data:Data
    public var sha256:String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    public init(name:String,mimeType:String,data:Data){self.name=name;self.mimeType=mimeType;self.data=data}
}
public struct EDAExchangeBundle:Sendable {
    public let projectID:UUID
    public let revision:UInt64
    public let files:[EDAExchangeFile]
    public let limitations:[String]
}
public enum EDAExchange {
    private struct Envelope:Codable {
        let format:String
        let version:Int
        let project:EDAProject
    }
    public static func decodeProject(_ data:Data) throws -> EDAProject {
        guard data.count<=64*1024*1024 else{throw EDAError.invalid("project byte limit")}
        let value=try JSONDecoder().decode(Envelope.self,from:data)
        guard value.format=="org.floe.electronics.project",value.version==1 else{throw EDAError.unsupported("project format")}
        try EDAValidation.validate(value.project)
        // Native v1 exports omit nil optionals. Refuse unfamiliar records
        // rather than successfully importing a reduced, silently lossy copy.
        let raw=try JSONSerialization.jsonObject(with:data)
        let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
        try knownFields(raw,canonical:canonical,path:"$")
        return value.project
    }
    private static func knownFields(_ input:Any,canonical:Any,path:String) throws {
        if let input=input as? [String:Any],let encoded=canonical as? [String:Any] {
            for key in input.keys.sorted() {
                guard let value=encoded[key] else{throw EDAError.unsupported("native project field "+path+"."+key)}
                try knownFields(input[key]!,canonical:value,path:path+"."+key)
            }
        } else if let input=input as? [Any],let encoded=canonical as? [Any] {
            guard input.count==encoded.count else{throw EDAError.unsupported("native project array "+path)}
            for index in input.indices{try knownFields(input[index],canonical:encoded[index],path:path+"[\(index)]")}
        }
    }
    public static func export(_ project:EDAProject,format:EDAExportFormat,boardID:UUID?=nil,
                              variant:String="Default",cancelled:@Sendable ()->Bool={false}) throws -> EDAExchangeBundle {
        if format == .gerber || format == .excellon {
            return try EDAManufacturing.export(project, format: format, boardID: boardID, cancelled: cancelled)
        }
        try EDAValidation.validate(project)
        guard !cancelled() else{throw EDAError.cancelled}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var files:[EDAExchangeFile]=[],limitations:[String]=[]
        let board=boardID.flatMap{id in project.boards.first{$0.id==id}} ?? project.boards.first
        if let boardID,board?.id != boardID{throw EDAError.missing("board")}
        switch format {
        case .gerber, .excellon: throw EDAError.invalid("manufacturing dispatch")
        case .project:
            files=[.init(name:"Project.floeeda",mimeType:"application/json",data:try encoder.encode(Envelope(format:"org.floe.electronics.project",version:1,project:project)))]
        case .netlist:
            files=[.init(name:"Netlist.json",mimeType:"application/json",data:try encoder.encode(EDAConnectivity.derive(project,cancelled:cancelled)))]
        case .bom:
            guard project.variants.contains(variant) else{throw EDAError.missing("assembly variant")}
            var rows=[["Reference","Value","Footprint","Manufacturer","PartNumber","Variant"]]
            for item in project.components.sorted(by:{$0.reference.localizedStandardCompare($1.reference) == .orderedAscending}) where !item.excludedVariants.contains(variant){
                guard !cancelled() else{throw EDAError.cancelled}
                rows.append([item.reference,item.value,project.footprints.first{$0.id==item.footprintID}?.name ?? "",item.fields["Manufacturer"] ?? "",item.fields["PartNumber"] ?? "",variant])
            }
            files=[.init(name:"BOM.csv",mimeType:"text/csv",data:Data(csv(rows).utf8))]
            limitations=["Spreadsheet formula-like text cells are escaped; original values remain in the native project."]
        case .positions:
            guard let board else{throw EDAError.missing("board")}
            guard project.variants.contains(variant) else{throw EDAError.missing("assembly variant")}
            var rows=[["Reference","Value","Footprint","X_mm","Y_mm","Rotation_deg","Side"]]
            for item in board.footprints.sorted(by:{$0.reference<$1.reference}){
                guard !cancelled() else{throw EDAError.cancelled}
                if let id=item.componentID,project.components.first(where:{$0.id==id})?.excludedVariants.contains(variant)==true{continue}
                rows.append([item.reference,item.value,project.footprints.first{$0.id==item.definitionID}?.name ?? "",number(item.position.x),number(item.position.y),number(item.angle),item.side=="B.Cu" ? "bottom":"top"])
            }
            files=[.init(name:"Positions.csv",mimeType:"text/csv",data:Data(csv(rows,numericColumns:[3,4,5]).utf8))]
        case .boardSVG:
            guard let board else{throw EDAError.missing("board")}
            files=[.init(name:"Board.svg",mimeType:"image/svg+xml",data:Data(try svg(project,board:board,cancelled:cancelled).utf8))]
            if board.zones.contains(where:{$0.fillRevision != project.revision}){limitations.append("Unfilled or stale copper zones are shown as boundaries only.")}
            if board.footprints.contains(where:{instance in project.footprints.first{$0.id==instance.definitionID}?.pads.contains{$0.shape == .roundRectangle} == true}){limitations.append("Round-rectangle pads lack a radius in this model; only their measured outer extent is drawn.")}
        case .schematicSVG:
            for sheet in project.sheets {
                files.append(.init(name:"Sheet-"+sheet.id.uuidString+".svg",mimeType:"image/svg+xml",data:Data(try svg(project,sheet:sheet,cancelled:cancelled).utf8)))
            }
        }
        guard files.count<=500,files.reduce(0,{$0+$1.data.count})<=128*1024*1024 else{throw EDAError.invalid("export byte budget")}
        return .init(projectID:project.id,revision:project.revision,files:files,limitations:limitations)
    }
    private static func number(_ value:Double)->String{String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),value)}
    private static func xml(_ value:String)->String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
    private static func csv(_ rows:[[String]],numericColumns:Set<Int>=[])->String {
        rows.enumerated().map{rowIndex,row in row.enumerated().map { column,raw in
            let isNumber=rowIndex>0 && numericColumns.contains(column) && Double(raw)?.isFinite == true
            let safe=(!isNumber && raw.first.map{"=+-@\t\r".contains($0)} == true) ? "'"+raw:raw
            return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
        }.joined(separator:",")}.joined(separator:"\r\n")+"\r\n"
    }
    private static func svg(_ project:EDAProject,board:EDABoard?=nil,sheet:EDASheet?=nil,cancelled:@Sendable ()->Bool) throws ->String {
        var body:[String]=[],points:[EDAPoint]=[];var count=0
        func check() throws {count+=1;if cancelled(){throw EDAError.cancelled};if count>100_000{throw EDAError.invalid("drawing object budget")}}
        func line(_ p:[EDAPoint],color:String="black",width:Double=0.2,closed:Bool=false,fill:String="none") throws {
            try check();guard p.count<=100_000 else{throw EDAError.invalid("drawing point budget")};points+=p
            let values=p.map{number($0.x)+","+number(-$0.y)}.joined(separator:" ")
            body.append("<\(closed ? "polygon":"polyline") points=\"\(values)\" fill=\"\(fill)\" stroke=\"\(color)\" stroke-width=\"\(number(width))\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>")
        }
        func circle(_ p:EDAPoint,radius:Double,color:String,fill:String="none") throws {try check();points += [p + .init(-radius,-radius),p + .init(radius,radius)];body.append("<circle cx=\"\(number(p.x))\" cy=\"\(number(-p.y))\" r=\"\(number(radius))\" stroke=\"\(color)\" stroke-width=\"0.15\" fill=\"\(fill)\"/>")}
        func text(_ value:String,_ p:EDAPoint,height:Double=1.8,angle:Double=0,mirrored:Bool=false) throws {
            try check()
            let extent=min(100_000,Double(value.count)*height*0.7)
            points += [EDAPoint.zero,.init(extent,0),.init(extent,height),.init(0,height)].map{$0.transformed(origin:p,angle:angle,mirrored:mirrored)}
            let transform="translate(\(number(p.x)) \(number(-p.y))) rotate(\(number(-angle)))"+(mirrored ? " scale(1 -1)":"")
            body.append("<text transform=\"\(transform)\" font-family=\"sans-serif\" font-size=\"\(number(height))\">\(xml(value))</text>")
        }
        func graphics(_ g:[EDAGraphic],transform:(EDAPoint)->EDAPoint={ $0 }) throws {
            for item in g {switch item {
            case .line(let a,let b,let width):try line([transform(a),transform(b)],width:width)
            case .rectangle(let a,let b,let width):try line([a,.init(b.x,a.y),b,.init(a.x,b.y)].map(transform),width:width,closed:true)
            case .circle(let c,let r,let width):try line((0...64).map{let a=Double($0)*2*Double.pi/64;return transform(c + .init(cos(a)*r,sin(a)*r))},width:width,closed:true)
            case .arc(let c,let r,let start,let sweep,let width):
                let n=max(2,min(256,Int(abs(sweep)/2)+1));try line((0...n).map{let a=(start+sweep*Double($0)/Double(n))*Double.pi/180;return transform(c + .init(cos(a)*r,sin(a)*r))},width:width)
            case .text(let s,let p,let h,let angle):
                let origin=transform(.zero),x=transform(.init(cos(angle * .pi/180),sin(angle * .pi/180)))-origin
                let a=transform(.init(1,0))-origin,b=transform(.init(0,1))-origin
                try text(s,transform(p),height:h,angle:atan2(x.y,x.x)*180 / .pi,mirrored:EDAGeometry.cross(a,b)<0)
            case .dimension(let a,let b,let offset):let delta=b-a,n=EDAPoint(-delta.y/max(delta.length,0.001),delta.x/max(delta.length,0.001))*offset;try line([transform(a),transform(a+n),transform(b+n),transform(b)]);try text(number(delta.length)+" mm",transform((a+b)*0.5+n))
            }}
        }
        if let board {
            try line(board.outline,color:"green",closed:true)
            for p in board.cutouts{try line(p,color:"green",closed:true)}
            for zone in board.zones {if zone.fillRevision==project.revision{for p in zone.filledPolygons{try line(p,color:"green",closed:true,fill:"#c5e4cc")}}else{try line(zone.outline,color:"green",width:0.1,closed:true)}}
            for track in board.tracks{try line(track.points,color:track.layer=="B.Cu" ? "blue":"red",width:track.width)}
            for via in board.vias{try circle(via.position,radius:via.diameter/2,color:"orange",fill:"orange");try circle(via.position,radius:via.drill/2,color:"black",fill:"white")}
            for hole in board.holes {
                if let end=hole.endPosition {
                    try check()
                    let vector=end-hole.position,normal=EDAPoint(-vector.y,vector.x)*(hole.diameter/2/vector.length)
                    let corners=[hole.position+normal,end+normal,end-normal,hole.position-normal]
                    let extent=EDAPoint(hole.diameter/2,hole.diameter/2)
                    for center in [hole.position,end] {points.append(center-extent);points.append(center+extent)}
                    func point(_ p:EDAPoint)->String {number(p.x)+" "+number(-p.y)}
                    let r=number(hole.diameter/2)
                    let d="M "+point(corners[0])+" L "+point(corners[1])+" A "+r+" "+r+" 0 0 1 "+point(corners[2])+" L "+point(corners[3])+" A "+r+" "+r+" 0 0 1 "+point(corners[0])+" Z"
                    body.append("<path d=\"\(d)\" fill=\"white\" stroke=\"black\" stroke-width=\"0.15\"/>")
                } else {try circle(hole.position,radius:hole.diameter/2,color:"black",fill:"white")}
            }
            for fp in board.footprints {
                guard let definition=project.footprints.first(where:{$0.id==fp.definitionID}) else{throw EDAError.missing("footprint definition")}
                try graphics(definition.graphics,transform:fp.point)
                for pad in definition.pads{
                    let w=pad.size.x/2,h=pad.size.y/2
                    func t(_ q:EDAPoint)->EDAPoint{fp.point(q.transformed(origin:pad.position,angle:pad.angle))}
                    let polygon:[EDAPoint]
                    switch pad.shape {
                    case .rectangle,.roundRectangle:polygon=[.init(-w,-h),.init(w,-h),.init(w,h),.init(-w,h)]
                    case .circle:polygon=(0...48).map{let a=Double($0)*2*Double.pi/48;return .init(cos(a)*w,sin(a)*h)}
                    case .oval:let r=min(w,h),a=EDAPoint(w>h ? w-r:0,w>h ? 0:h-r);polygon=(0...48).map{let angle=Double($0)*2*Double.pi/48,c=cos(angle),s=sin(angle);return .init(c*r+(c>=0 ? a.x:-a.x),s*r+(s>=0 ? a.y:-a.y))}
                    }
                    try line(polygon.map(t),color:"#aa7700",closed:true,fill:"#f7cc55")
                    if let d=pad.drill{try circle(fp.point(pad.position),radius:d/2,color:"black",fill:"white")}
                }
                try text(fp.reference,fp.position + .init(0,3))
            }
            try graphics(board.graphics)
        }
        if let sheet {
            for wire in sheet.wires{try line(wire.points,color:"green")}
            for junction in sheet.junctions{try circle(junction.position,radius:0.3,color:"green",fill:"green")}
            for placement in sheet.symbols {
                guard let component=project.components.first(where:{$0.id==placement.componentID}),let definition=project.symbols.first(where:{$0.id==component.symbolID}) else{throw EDAError.missing("symbol definition")}
                func t(_ p:EDAPoint)->EDAPoint{p.transformed(origin:placement.position,angle:placement.angle,mirrored:placement.mirrored)}
                try graphics(definition.graphics,transform:t)
                for pin in definition.pins where pin.unit==0 || pin.unit==placement.unit{try circle(t(pin.position),radius:0.15,color:"black");try text(pin.number,t(pin.position),height:0.9)}
                try text(component.reference+" "+component.value,placement.position + .init(0,4))
            }
            for label in sheet.labels{try text(label.name,label.position)}
            for bus in sheet.buses{try line(bus.points,color:"blue",width:0.5);if let p=bus.points.first{try text(bus.name,p)}}
            for mark in sheet.noConnects{try line([mark.position + .init(-0.6,-0.6),mark.position + .init(0.6,0.6)],color:"blue");try line([mark.position + .init(-0.6,0.6),mark.position + .init(0.6,-0.6)],color:"blue")}
            try graphics(sheet.graphics)
        }
        let minX=(points.map(\.x).min() ?? 0)-5,maxX=(points.map(\.x).max() ?? 100)+5,minY=(points.map(\.y).min() ?? 0)-5,maxY=(points.map(\.y).max() ?? 80)+5
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(maxX-minX))mm\" height=\"\(number(maxY-minY))mm\" viewBox=\"\(number(minX)) \(number(-maxY)) \(number(maxX-minX)) \(number(maxY-minY))\"><title>\(xml(project.title))</title>"+body.joined()+"</svg>"
    }
}
