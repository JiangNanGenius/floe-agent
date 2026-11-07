// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

public struct BiologyTreeNode:Sendable,Equatable,Identifiable {
    public let id:Int
    public var label:String
    public var length:Double?
    public var children:[Int]
    public var comments:[String]
}
public struct BiologyTree:Sendable,Equatable {
    public var nodes:[BiologyTreeNode]
    public var root:Int
    public var leaves:[BiologyTreeNode] {nodes.filter{$0.children.isEmpty}}
    public static func parse(_ data:Data) throws -> BiologyTree {
        guard data.count<=262144,let text=String(data:data,encoding:.utf8) else {throw BiologyError.invalid("Newick input exceeds 256 KiB or is not UTF-8.")}
        var parser=NewickParser(chars:Array(text));return try parser.parse()
    }
    /// Branch lengths are used only when every branch is finite/nonnegative.
    /// Otherwise a cladogram preserves topology without inventing distances.
    public func layout(useLengths:Bool=true)->[SIMD2<Double>] {
        let lengths=useLengths && nodes.filter{$0.id != root}.allSatisfy{$0.length.map{$0>=0} ?? false}
        var points=[SIMD2<Double>](repeating:.zero,count:nodes.count),leaf=0
        func walk(_ id:Int,_ x:Double) {
            let n=nodes[id]
            if n.children.isEmpty {points[id]=SIMD2(x,Double(leaf));leaf+=1;return}
            for child in n.children {walk(child,x+(lengths ? nodes[child].length ?? 0:1))}
            points[id]=SIMD2(x,n.children.reduce(0){$0+points[$1].y}/Double(n.children.count))
        }
        walk(root,0);return points
    }
}
private struct NewickParser {
    let chars:[Character]
    var index=0
    var nodes:[BiologyTreeNode]=[]
    mutating func whitespace(){while index<chars.count,chars[index].isWhitespace{index+=1}}
    mutating func comments() throws -> [String] {
        var out:[String]=[];whitespace()
        while index<chars.count,chars[index]=="[" {
            index+=1;var text="",depth=1
            while index<chars.count,depth>0 {
                let c=chars[index];index+=1
                if c=="[" {depth+=1}else if c=="]" {depth-=1}
                guard depth<=16 else {throw BiologyError.invalid("Newick comment nesting exceeds its budget.")}
                if depth>0{text.append(c)}
            }
            guard depth==0 else {throw BiologyError.invalid("Unterminated Newick comment.")};out.append(text);whitespace()
        };return out
    }
    mutating func label() throws -> String {
        whitespace();guard index<chars.count else {return ""}
        if chars[index]=="'" {
            index+=1;var text=""
            while index<chars.count {
                let c=chars[index];index+=1
                if c=="'" {if index<chars.count,chars[index]=="'" {text.append("'");index+=1}else{return text}}else{text.append(c)}
            };throw BiologyError.invalid("Unterminated quoted Newick label.")
        }
        let start=index
        while index<chars.count,!",():;[]".contains(chars[index]){index+=1}
        return String(chars[start..<index]).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    mutating func node(_ depth:Int) throws -> Int {
        guard depth<=128,nodes.count<5000 else {throw BiologyError.invalid("Newick depth/node budget exceeded.")}
        var notes=try comments(),children:[Int]=[]
        if index<chars.count,chars[index]=="(" {
            index+=1
            while true {
                children.append(try node(depth+1));whitespace()
                guard index<chars.count else {throw BiologyError.invalid("Unclosed Newick group.")}
                if chars[index]==")" {index+=1;break}
                guard chars[index]=="," else {throw BiologyError.invalid("Expected a Newick child separator.")};index+=1
            }
        }
        let name=try label();notes+=try comments()
        var length:Double?
        if index<chars.count,chars[index]==":" {
            index+=1;whitespace();let start=index
            while index<chars.count,!",);[".contains(chars[index]),!chars[index].isWhitespace{index+=1}
            guard let number=Double(String(chars[start..<index])),number.isFinite else {throw BiologyError.invalid("Invalid Newick branch length.")};length=number;notes+=try comments()
        }
        let id=nodes.count;nodes.append(.init(id:id,label:name,length:length,children:children,comments:notes));return id
    }
    mutating func parse() throws -> BiologyTree {
        let root=try node(0);whitespace()
        guard index<chars.count,chars[index]==";" else {throw BiologyError.invalid("Newick must end with a semicolon.")};index+=1;whitespace()
        guard index==chars.count,!nodes[root].label.isEmpty || !nodes[root].children.isEmpty else {throw BiologyError.invalid("Expected one nonempty Newick tree.")}
        return .init(nodes:nodes,root:root)
    }
}

public struct BiologyDensityVolume:Sendable {
    /// Canonical crystallographic X,Y,Z axes; source MAPC/MAPR/MAPS is applied.
    public var dimensions:SIMD3<Int>
    public var values:[Double]
    public var origin:SIMD3<Double>
    public var starts:SIMD3<Int>
    public var basis:[SIMD3<Double>]
    public func index(_ x:Int,_ y:Int,_ z:Int)->Int {x+dimensions.x*(y+dimensions.y*z)}
    public func position(_ point:SIMD3<Double>)->SIMD3<Double> {origin+basis[0]*(point.x+Double(starts.x))+basis[1]*(point.y+Double(starts.y))+basis[2]*(point.z+Double(starts.z))}
    public static func parse(_ data:Data) throws -> BiologyDensityVolume {
        guard data.count>=1024,data.count<=BiologyImporter.maximumInputBytes else {throw BiologyError.invalid("MRC header is missing or inline volume exceeds 16 MiB.")}
        let bytes=[UInt8](data)
        func word(_ offset:Int,_ little:Bool)->UInt32 {
            let b=bytes[offset..<offset+4];return little ? b.enumerated().reduce(0){$0|UInt32($1.element)<<UInt32(8*$1.offset)}:b.reduce(0){($0<<8)|UInt32($1)}
        }
        let little:Bool
        if bytes[212]==0x44 {little=true}
        else if bytes[212]==0x11 {little=false}
        else {
            let a=word(0,true),b=word(0,false)
            guard (a>0 && a<=512) != (b>0 && b<=512) else {throw BiologyError.invalid("MRC byte order is ambiguous.")};little=a>0 && a<=512
        }
        func integer(_ o:Int)->Int {Int(Int32(bitPattern:word(o,little)))}
        func real(_ o:Int)->Double {Double(Float(bitPattern:word(o,little)))}
        let raw=[integer(0),integer(4),integer(8)],mode=integer(12),axes=[integer(64)-1,integer(68)-1,integer(72)-1]
        guard raw.allSatisfy({(1...512).contains($0)}),raw.reduce(1,*)<=2_097_152,Set(axes)==Set([0,1,2]),[0,1,2,6,12].contains(mode) else {throw BiologyError.invalid("Unsupported MRC dimensions, axis order or sample mode.")}
        let unit=[real(40),real(44),real(48)],angles=[real(52),real(56),real(60)].map{$0*Double.pi/180},grid=[integer(28),integer(32),integer(36)]
        guard unit.allSatisfy({$0.isFinite && $0>0}),angles.allSatisfy({$0.isFinite && $0>0 && $0<Double.pi}),grid.allSatisfy({$0>0}) else {throw BiologyError.invalid("Invalid MRC cell calibration.")}
        let ca=cos(angles[0]),cb=cos(angles[1]),cg=cos(angles[2]),sg=sin(angles[2]),cz2=1-cb*cb-pow((ca-cb*cg)/sg,2)
        guard abs(sg)>1e-10,cz2>0 else {throw BiologyError.invalid("Degenerate crystallographic cell.")}
        let basis=[SIMD3(unit[0]/Double(grid[0]),0,0),SIMD3(unit[1]*cg/Double(grid[1]),unit[1]*sg/Double(grid[1]),0),SIMD3(unit[2]*cb/Double(grid[2]),unit[2]*(ca-cb*cg)/sg/Double(grid[2]),unit[2]*sqrt(cz2)/Double(grid[2]))]
        var dims=SIMD3<Int>(repeating:0),starts=SIMD3<Int>(repeating:0)
        for i in 0..<3 {dims[axes[i]]=raw[i];starts[axes[i]]=integer(16+4*i)}
        let extended=integer(92),stride=mode==0 ? 1:mode==2 ? 4:2
        guard extended>=0,extended<=data.count-1024,raw.reduce(1,*)*stride<=data.count-1024-extended else {throw BiologyError.invalid("MRC voxel data is truncated.")}
        var values=[Double](repeating:0,count:raw.reduce(1,*)),offset=1024+extended
        for z in 0..<raw[2] {try Task.checkCancellation();for y in 0..<raw[1] {for x in 0..<raw[0] {
            let value:Double
            if mode==0 {value=Double(Int8(bitPattern:bytes[offset]))}
            else if mode==2 {value=Double(Float(bitPattern:word(offset,little)))}
            else {let bits=little ? UInt16(bytes[offset])|UInt16(bytes[offset+1])<<8:UInt16(bytes[offset])<<8|UInt16(bytes[offset+1]);value=mode==1 ? Double(Int16(bitPattern:bits)):mode==12 ? Double(Float16(bitPattern:bits)):Double(bits)}
            guard value.isFinite else {throw BiologyError.invalid("MRC contains non-finite voxels.")}
            var coordinate=SIMD3<Int>(repeating:0);for (i,v) in [x,y,z].enumerated(){coordinate[axes[i]]=v}
            values[coordinate.x+dims.x*(coordinate.y+dims.y*coordinate.z)]=value;offset+=stride
        }}}
        let origin=SIMD3(real(196),real(200),real(204));guard [origin.x,origin.y,origin.z].allSatisfy(\.isFinite) else {throw BiologyError.invalid("Invalid MRC origin.")}
        let volume=BiologyDensityVolume(dimensions:dims,values:values,origin:origin,starts:starts,basis:basis)
        for z in [0,dims.z-1] {for y in [0,dims.y-1] {for x in [0,dims.x-1] {
            let p=volume.position(SIMD3(Double(x),Double(y),Double(z)))
            guard [p.x,p.y,p.z].allSatisfy({$0.isFinite && abs($0)<=1e9}) else {throw BiologyError.invalid("Density coordinates exceed the native geometry range.")}
        }}}
        return volume
    }
    public func slice(axis:Int,index selected:Int) throws -> (width:Int,height:Int,values:[Double]) {
        guard (0...2).contains(axis),(0..<dimensions[axis]).contains(selected) else {throw BiologyError.invalid("Density slice is outside the volume.")}
        let other=(0...2).filter{$0 != axis},width=dimensions[other[0]],height=dimensions[other[1]]
        var out:[Double]=[];out.reserveCapacity(width*height)
        for y in 0..<height {for x in 0..<width {var c=SIMD3<Int>(repeating:0);c[axis]=selected;c[other[0]]=x;c[other[1]]=y;out.append(values[index(c.x,c.y,c.z)])}}
        return (width,height,out)
    }
}
