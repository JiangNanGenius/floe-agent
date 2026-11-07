// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

public struct BiologyTriangleMesh:Sendable {
    /// Three consecutive vertices form each triangle, in physical coordinates.
    public var vertices:[SIMD3<Float>]=[]
    /// 0=coil/unassigned, 1=deposited helix, 2=deposited sheet, 3=density.
    public var classes:[UInt8]=[]
    public init() {}
    mutating func triangle(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ c:SIMD3<Double>,kind:UInt8) {
        vertices += [SIMD3<Float>(a),SIMD3<Float>(b),SIMD3<Float>(c)];classes += [kind,kind,kind]
    }
}
public extension BiologyDensityVolume {
    func isosurface(value:Double,stride step:Int=1,maximumTriangles:Int=30000) throws -> BiologyTriangleMesh {
        guard value.isFinite,(1...32).contains(step),(1...30000).contains(maximumTriangles) else {throw BiologyError.invalid("Invalid density isovalue or surface budget.")}
        var mesh=BiologyTriangleMesh()
        guard dimensions.x>step,dimensions.y>step,dimensions.z>step else {return mesh}
        let offsets=[SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(1,1,0),SIMD3(0,1,0),SIMD3(0,0,1),SIMD3(1,0,1),SIMD3(1,1,1),SIMD3(0,1,1)]
        let tetrahedra=[[0,5,1,6],[0,1,2,6],[0,2,3,6],[0,3,7,6],[0,7,4,6],[0,4,5,6]]
        for z in Swift.stride(from:0,to:dimensions.z-step,by:step) {try Task.checkCancellation()
            for y in Swift.stride(from:0,to:dimensions.y-step,by:step) {for x in Swift.stride(from:0,to:dimensions.x-step,by:step) {
                let corners=offsets.map{SIMD3(x,y,z) &+ ($0 &* step)},samples=corners.map{values[index($0.x,$0.y,$0.z)]}
                if samples.allSatisfy({$0<value}) || samples.allSatisfy({$0>=value}) {continue}
                let positions=corners.map{position(SIMD3<Double>($0))}
                func crossing(_ i:Int,_ j:Int)->SIMD3<Double> {let t=(value-samples[i])/(samples[j]-samples[i]);return positions[i]+(positions[j]-positions[i])*t}
                for t in tetrahedra {
                    let inside=t.filter{samples[$0]>=value},outside=t.filter{samples[$0]<value}
                    if inside.isEmpty || outside.isEmpty {continue}
                    let outward=outside.reduce(SIMD3<Double>.zero){$0+positions[$1]}/Double(outside.count)-inside.reduce(SIMD3<Double>.zero){$0+positions[$1]}/Double(inside.count)
                    func emit(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ c:SIMD3<Double>) throws {
                        guard mesh.vertices.count/3<maximumTriangles else {throw BiologyError.invalid("Surface exceeds 30,000 triangles. Choose a larger stride or a different isovalue.")}
                        if simd_dot(simd_cross(b-a,c-a),outward)>=0 {mesh.triangle(a,b,c,kind:3)}else{mesh.triangle(a,c,b,kind:3)}
                    }
                    if inside.count==1 || outside.count==1 {
                        let one=inside.count==1 ? inside:outside,many=inside.count==1 ? outside:inside
                        try emit(crossing(one[0],many[0]),crossing(one[0],many[1]),crossing(one[0],many[2]))
                    } else {
                        let a=crossing(inside[0],outside[0]),b=crossing(inside[0],outside[1]),c=crossing(inside[1],outside[1]),d=crossing(inside[1],outside[0])
                        try emit(a,b,c);try emit(a,c,d)
                    }
                }
            }}
        };return mesh
    }
}

public enum BiologyProteinRibbon {
    public static func depositedClasses(pdb:Data)->[String:UInt8] {
        guard let text=String(data:pdb,encoding:.utf8) else {return [:]}
        var kinds:[String:UInt8]=[:]
        for line in text.split(whereSeparator:\.isNewline) where line.hasPrefix("HELIX ") || line.hasPrefix("SHEET ") {
            let chars=Array(line)
            func field(_ a:Int,_ b:Int)->String {guard chars.count>=b else{return ""};return String(chars[a..<b]).trimmingCharacters(in:.whitespaces)}
            let helix=line.hasPrefix("HELIX "),chain=field(helix ? 19:21,helix ? 20:22),endChain=field(helix ? 31:32,helix ? 32:33)
            guard chain==endChain,let lo=Int(field(helix ? 21:22,helix ? 25:26)),let hi=Int(field(33,37)),lo<=hi,hi-lo<100000 else {continue}
            for residue in lo...hi {kinds[chain+":"+String(residue)]=helix ? 1:2}
        };return kinds
    }
    /// A smooth ribbon follows actual Cα coordinates. Width/color uses only
    /// deposited secondary-structure records; missing assignments remain coil.
    public static func build(_ structure:ProteinStructure,model:Int,chain:String?=nil,deposited:[String:UInt8]=[:]) throws -> BiologyTriangleMesh {
        let atoms=structure.atoms.filter{$0.model==model && !$0.hetero && (chain==nil || $0.chain==chain)}
        guard atoms.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy{$0.isFinite && abs($0)<=1e9}}) else {throw BiologyError.invalid("Protein coordinates exceed the native geometry range.")}
        let alpha=atoms.filter{$0.name=="CA"}
        guard alpha.count<=10000 else {throw BiologyError.invalid("Ribbon exceeds 10,000 residues. Select a smaller chain.")}
        let carbonyl=Dictionary(atoms.filter{$0.name=="O"}.map{($0.residueID,$0)},uniquingKeysWith:{$1})
        var mesh=BiologyTriangleMesh()
        func point(_ a:StructureAtom)->SIMD3<Double> {SIMD3(a.x,a.y,a.z)}
        var previousNormal=SIMD3<Double>(0,0,1)
        for i in 0..<max(0,alpha.count-1) {
            if i%128==0 {try Task.checkCancellation()}
            let a=alpha[i],b=alpha[i+1],p1=point(a),p2=point(b)
            guard a.chain==b.chain,simd_length(p2-p1)<5,simd_length(p2-p1)>1e-9 else {continue}
            let p0=i>0 && alpha[i-1].chain==a.chain && simd_length(point(alpha[i-1])-p1)<5 ? point(alpha[i-1]):p1
            let p3=i+2<alpha.count && alpha[i+2].chain==a.chain && simd_length(point(alpha[i+2])-p2)<5 ? point(alpha[i+2]):p2
            let tangent=simd_normalize(p2-p1)
            var normal:SIMD3<Double>
            if let oxygen=carbonyl[a.residueID] {normal=simd_cross(tangent,point(oxygen)-p1)}else{normal=previousNormal-tangent*simd_dot(previousNormal,tangent)}
            if simd_length(normal)<1e-8 {normal=simd_cross(tangent,abs(tangent.z)<0.9 ? SIMD3(0,0,1):SIMD3(0,1,0))}
            normal=simd_normalize(normal);if simd_dot(normal,previousNormal)<0{normal = -normal};previousNormal=normal
            let side=simd_normalize(simd_cross(normal,tangent)),kind=deposited[a.chain+":"+String(a.residueNumber)] ?? 0
            let width:Double=kind==1 ? 1.1:kind==2 ? 1.5:0.22
            func sample(_ t:Double)->SIMD3<Double> {0.5*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)}
            for j in 0..<6 {
                let t0=Double(j)/6,t1=Double(j+1)/6
                let sheetEnd=kind==2 && (deposited[b.chain+":"+String(b.residueNumber)] ?? 0) != 2
                let w0=sheetEnd ? width*(1-t0)*1.5:width,w1=sheetEnd ? width*(1-t1)*1.5:width
                let c=sample(t0),d=sample(t1)
                mesh.triangle(c-side*w0,c+side*w0,d+side*w1,kind:kind);mesh.triangle(c-side*w0,d+side*w1,d-side*w1,kind:kind)
            }
        };return mesh
    }
}
