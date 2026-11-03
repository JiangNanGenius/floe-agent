// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeWorkbench
import FloeTools

struct CADBasicMachiningVerified: Sendable {
    var stlData: Data
    var manifestData: Data
    var stlSHA256: String
    var manifestSHA256: String
    var removedMM3: Double
    var remainingMM3: Double
    var supplementalFiles: [String:Data] = [:]
    var previewSummary: CADMultiAxisPreviewSummary? = nil
}
/// Independent scalar validation of the deliberately small fixed-Z scope.
/// No CAD mutations, model-authored success marker or BRep promotion.
enum CADBasicMachiningVerification {
    struct Point: Hashable { var x:Int;var y:Int;var z:Int }
    struct Edge: Hashable {var a:Point;var b:Point}
    struct Face: Hashable {var axis:Int;var plane:Int;var a:Int;var b:Int;var sign:Int}
    struct Reader {
        let data:Data;var offset=0
        mutating func u32()throws->UInt32 {guard offset+4<=data.count else{throw CADBasicMachiningVerification.fail("Truncated binary output")};defer{offset+=4};return data.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}}
        mutating func f32()throws->Float {Float(bitPattern:try u32())}
    }
    static func fail(_ text:String)->FloeError {.validationFailed(text)}
    static func verify(directory:URL,study:CADBasicMachiningStudy,coreSHA:String,wrapperSHA:String,cancellation:CancellationToken?=nil)throws->CADBasicMachiningVerified {
        func check()throws {try cancellation?.throwIfCancelled();if Task.isCancelled{throw CancellationError()}}
        try check()
        func data(_ name:String,_ cap:Int)throws->Data {
            let u=directory.appendingPathComponent(name);let a=try FileManager.default.attributesOfItem(atPath:u.path)
            guard a[.type] as? FileAttributeType == .typeRegular,((a[.size] as? NSNumber)?.intValue ?? Int.max) <= cap else{throw fail("Result exceeds its file budget")}
            guard u.resolvingSymlinksInPath().standardizedFileURL.path==u.standardizedFileURL.path else{throw fail("Result symlink refused")}
            return try Data(contentsOf:u,options:.mappedIfSafe)
        }
        let manifest=try data("manifest.json",128_000)
        guard let m=try JSONSerialization.jsonObject(with:manifest) as? [String:Any],m["schema"] as? String=="floe.cad-stock-result.v1",
              m["outcome"] as? String=="computed-not-job-accepted",m["requestSHA256"] as? String==study.inputSHA256,
              m["sourceUnchanged"] as? Bool==true,let owner=m["ownerBinding"] as? [String:Any],
              (owner["operationID"] as? String)?.lowercased()==study.id.uuidString.lowercased(),
              owner["environmentID"] as? String==study.environmentID,
              (owner["conversationID"] as? String)?.lowercased()==study.conversationID.uuidString.lowercased(),
              let source=m["source"] as? [String:Any],source["documentRevision"] as? Int==study.source.revision,
              source["modelSHA256"] as? String==study.source.modelSHA256,
              source["contentSHA256"] as? String==study.source.contentSHA256,
              owner["runID"] as? String==study.createdRunID.uuidString,owner["studyRevision"] as? Int==1,
              (source["bodyID"] as? String)?.lowercased()==study.source.bodyID.uuidString.lowercased(),
              let backend=m["backend"] as? [String:Any],backend["sourcePin"] as? String=="3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9",
              backend["coreSHA256"] as? String==coreSHA,backend["wrapperSHA256"] as? String==wrapperSHA,
              backend["architecture"] as? String=="Arm64",(backend["actualOS"] as? String)?.hasPrefix("Darwin")==true,
              let artifacts=m["artifacts"] as? [[String:Any]],artifacts.count==2,
              Set(artifacts.compactMap{$0["path"] as? String})==["stock.stl","stock.occupancy"] else{throw fail("Result identity does not match its frozen CAD operation")}
        let stl=try data("stock.stl",50_000_084),raw=try data("stock.occupancy",2_000_036)
        for a in artifacts {
            let bytes=(a["path"] as? String)=="stock.stl" ? stl : raw
            guard a["bytes"] as? Int==bytes.count,a["sha256"] as? String==FloeDigest.sha256Hex(bytes) else{throw fail("Recovered output digest mismatch")}
        }
        guard raw.count>=36,String(data:raw.prefix(8),encoding:.ascii)=="FLSTK001" else{throw fail("Invalid occupancy header")}
        var r=Reader(data:raw,offset:8);let nx=Int(try r.u32()),ny=Int(try r.u32()),nz=Int(try r.u32());let h=try r.f32(),minX=try r.f32(),minY=try r.f32(),minZ=try r.f32()
        guard nx>0,ny>0,nz>0,nx<=4000,ny<=4000,nz<=4000,nx*ny*nz<=2_000_000,
              raw.count==36+nx*ny*nz,Double(h)==study.parameters.resolutionMM,
              [minX,minY,minZ].allSatisfy({$0.isFinite && abs($0)<=10_000}) else{throw fail("Occupancy dimensions or resolution are invalid")}
        // Re-derive the stock from the frozen selected native mesh, independently of CLI metadata.
        let snapshot=study.workspaceRoot.appendingPathComponent(study.relativeDirectory+"/input/snapshot")
        for (relative,sha) in study.source.members {
            try check()
            let file=snapshot.appendingPathComponent(relative)
            guard file.standardizedFileURL.path.hasPrefix(snapshot.standardizedFileURL.path+"/"),
                  file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL,
                  try FloeDigest.sha256Hex(ofFileAt:file)==sha else{throw fail("Frozen native source changed")}
        }
        let model=try JSONSerialization.jsonObject(with:Data(contentsOf:snapshot.appendingPathComponent("document.json"))) as? [String:Any]
        guard let rows=model?["bodies"] as? [[String:Any]],let row=rows.first(where:{($0["bodyID"] as? String)?.lowercased()==study.source.bodyID.uuidString.lowercased()}),
              let meshName=row["meshBlob"] as? String,study.source.members[meshName] != nil else{throw fail("Selected source mesh identity is missing")}
        let mesh=try Data(contentsOf:snapshot.appendingPathComponent(meshName));var mr=Reader(data:mesh)
        guard try mr.u32()==0x4F533344 else{throw fail("Invalid native mesh header")}
        let version=try mr.u32(),vertices=Int(try mr.u32()),indices=Int(try mr.u32())
        guard (version==1 || version==2),vertices>0,vertices<=1_000_000,indices>0,indices<=3_000_000,
              mesh.count==16+(version==2 ? 32:24)*vertices+4*indices else{throw fail("Invalid native mesh budget")}
        var lo=[Float](repeating:.infinity,count:3),hi=[Float](repeating:-.infinity,count:3)
        for _ in 0..<vertices {for axis in 0..<3 {let v=try mr.f32();guard v.isFinite,abs(v)<=10_000 else{throw fail("Invalid source bounds")};lo[axis]=min(lo[axis],v);hi[axis]=max(hi[axis],v)}}
        let dimensions=zip(lo,hi).map{Int(ceil(($0.1-$0.0)/h))}
        guard dimensions==[nx,ny,nz],lo==[minX,minY,minZ],let stock=m["stock"] as? [String:Any],
              stock["gridDimensions"] as? [Int]==dimensions,(stock["boundsMin"] as? [Double])?.map(Float.init)==lo,(stock["boundsMax"] as? [Double])?.map(Float.init)==hi,
              stock["resolutionMM"] as? Double==Double(h),stock["mode"] as? String=="part-bounding-box-blank",stock["partIsReferenceOnly"] as? Bool==true else{throw fail("Output stock differs from the selected part's frozen bounds")}
        let p=study.parameters;let ax=Float(p.startTipMM[0]),ay=Float(p.startTipMM[1]),z0=Float(p.startTipMM[2]),bx=Float(p.endTipMM[0]),by=Float(p.endTipMM[1]),radius=Float(p.radiusMM),length=Float(p.lengthMM)
        let dx=bx-ax,dy=by-ay,den=dx*dx+dy*dy
        func material(_ x:Int,_ y:Int,_ z:Int)->Bool {guard x>=0,y>=0,z>=0,x<nx,y<ny,z<nz else{return false};return raw[36+(z*ny+y)*nx+x]==1}
        var remaining=0,expectedFaces=0
        for z in 0..<nz {try check();for y in 0..<ny {for x in 0..<nx {
            let value=raw[36+(z*ny+y)*nx+x];guard value<=1 else{throw fail("Invalid material occupancy")}
            let px=minX+(Float(x)+0.5)*h,py=minY+(Float(y)+0.5)*h,pz=minZ+(Float(z)+0.5)*h
            let t:Float=den==0 ? 0 : max(0,min(1,((px-ax)*dx+(py-ay)*dy)/den))
            let ex=px-(ax+t*dx),ey=py-(ay+t*dy)
            let expectedCut=ex*ex+ey*ey<radius*radius && pz>z0 && pz<z0+length
            guard (value==0)==expectedCut else{throw fail("The fixed-Z cut did not match the independent voxel-centre geometry")}
            if value==1 {remaining+=1;for (i,j,k) in [(x-1,y,z),(x+1,y,z),(x,y-1,z),(x,y+1,z),(x,y,z-1),(x,y,z+1)] {if !material(i,j,k){expectedFaces+=1}}}
        }}}
        guard remaining>0,expectedFaces<=500_000 else{throw fail("The resulting stock is empty or exceeds its surface budget")}
        var s=Reader(data:stl,offset:80);let triangles=Int(try s.u32())
        guard triangles==expectedFaces*2,stl.count==84+triangles*50 else{throw fail("STL surface size differs from its occupancy")}
        var faces:[Face:Int]=[:],edges:[Edge:Int]=[:]
        func less(_ a:Point,_ b:Point)->Bool {a.x != b.x ? a.x<b.x : a.y != b.y ? a.y<b.y : a.z<b.z}
        func point(_ values:[Float])throws->Point {
            let origins=[minX,minY,minZ],dims=[nx,ny,nz]
            var out:[Int]=[]
            for i in 0..<3 {guard values[i].isFinite else{throw fail("Nonfinite STL vertex")};let q=(values[i]-origins[i])/h;guard q.isFinite,q>=(-1),q<=Float(dims[i]+1) else{throw fail("STL outside stock grid")};let v=Int(q.rounded());guard v>=0,v<=dims[i] else{throw fail("STL outside stock grid")}
                let expected=origins[i]+Float(v)*h
                // Float writer roundoff only; not a geometry tolerance or a centre predicate allowance.
                guard abs(expected-values[i])<=4*Float.ulpOfOne*max(1,abs(expected)) else{throw fail("STL vertex is off the material grid")};out.append(v)
            }
            return Point(x:out[0],y:out[1],z:out[2])
        }
        for triangle in 0..<triangles {
            if triangle%1024==0{try check()}
            let storedNormal=try [s.f32(),s.f32(),s.f32()]
            let a=try point([s.f32(),s.f32(),s.f32()]),b=try point([s.f32(),s.f32(),s.f32()]),c=try point([s.f32(),s.f32(),s.f32()]);s.offset+=2
            let u=Point(x:b.x-a.x,y:b.y-a.y,z:b.z-a.z),v=Point(x:c.x-a.x,y:c.y-a.y,z:c.z-a.z)
            let normal=[u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x]
            guard normal.filter({$0 != 0}).count==1,let axis=normal.firstIndex(where:{$0 != 0}),abs(normal[axis])==1 else{throw fail("STL has a non-unit or degenerate voxel face")}
            guard storedNormal==normal.map(Float.init) else{throw fail("STL normal differs from its outward face") }
            let xs=[a.x,b.x,c.x],ys=[a.y,b.y,c.y],zs=[a.z,b.z,c.z],sign=normal[axis]>0 ? 1 : -1
            let other=axis==0 ? [ys.min()!,zs.min()!] : axis==1 ? [xs.min()!,zs.min()!] : [xs.min()!,ys.min()!]
            let plane=axis==0 ? a.x : axis==1 ? a.y : a.z
            let key=Face(axis:axis,plane:plane,a:other[0],b:other[1],sign:sign)
            let inside:Point,outside:Point
            if axis==0 {inside=Point(x:plane-(sign>0 ? 1:0),y:other[0],z:other[1]);outside=Point(x:inside.x+sign,y:inside.y,z:inside.z)}
            else if axis==1 {inside=Point(x:other[0],y:plane-(sign>0 ? 1:0),z:other[1]);outside=Point(x:inside.x,y:inside.y+sign,z:inside.z)}
            else {inside=Point(x:other[0],y:other[1],z:plane-(sign>0 ? 1:0));outside=Point(x:inside.x,y:inside.y,z:inside.z+sign)}
            guard material(inside.x,inside.y,inside.z),!material(outside.x,outside.y,outside.z) else{throw fail("STL is not the actual stock boundary")}
            faces[key,default:0]+=1
            for (p,q) in [(a,b),(b,c),(c,a)] {edges[less(p,q) ? Edge(a:p,b:q):Edge(a:q,b:p),default:0]+=1}
        }
        guard faces.count==expectedFaces,faces.values.allSatisfy({$0==2}),edges.values.allSatisfy({$0==2}) else{throw fail("STL is not a closed manifold voxel boundary")}
        let cell=Double(h)*Double(h)*Double(h)
        // CLI serializes Single values using their shortest round-trip decimal. Compare those as Singles, without a geometric tolerance.
        guard (stock["remainingMM3"] as? Double).map(Float.init)==Float(Double(remaining)*cell),(stock["removedMM3"] as? Double).map(Float.init)==Float(Double(nx*ny*nz-remaining)*cell) else{throw fail("Reported volumes differ from independently counted material")}
        return CADBasicMachiningVerified(stlData:stl,manifestData:manifest,stlSHA256:FloeDigest.sha256Hex(stl),manifestSHA256:FloeDigest.sha256Hex(manifest),removedMM3:Double(nx*ny*nz-remaining)*cell,remainingMM3:Double(remaining)*cell)
    }
}
