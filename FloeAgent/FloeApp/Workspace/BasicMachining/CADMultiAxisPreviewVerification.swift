// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkbench

struct CADMultiAxisPreviewSummary:Codable,Sendable {
    struct Fixture:Codable,Sendable {var id:String;var state:String}
    var continuousRemainingLowerMM3:Double
    var continuousRemainingUpperMM3:Double
    var fixtures:[Fixture]
}

/// Independent scalar geometry/whole-cell and mesh checks; no backend execution or CAD mutation.
enum CADMultiAxisPreviewVerification {
    typealias Reader=CADBasicMachiningVerification.Reader
    typealias Point=CADBasicMachiningVerification.Point
    typealias Edge=CADBasicMachiningVerification.Edge
    typealias Face=CADBasicMachiningVerification.Face
    static func fail(_ s:String)->FloeError {.validationFailed(s)}
    struct V {var x:Double;var y:Double;var z:Double
        init(_ a:[Double]){x=a[0];y=a[1];z=a[2]}
        init(_ x:Double,_ y:Double,_ z:Double){self.x=x;self.y=y;self.z=z}
        static func +(a:V,b:V)->V {V(a.x+b.x,a.y+b.y,a.z+b.z)}
        static func -(a:V,b:V)->V {V(a.x-b.x,a.y-b.y,a.z-b.z)}
        static func *(a:V,b:Double)->V {V(a.x*b,a.y*b,a.z*b)}
        static func dot(_ a:V,_ b:V)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
        var norm:Double {sqrt(Self.dot(self,self))}
        var unit:V {self*(1/norm)}
        var values:[Double] {[x,y,z]}
    }
    struct Q {var x:Double;var y:Double;var z:Double;var w:Double
        static func dot(_ a:Q,_ b:Q)->Double {a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w}
        var unit:Q {let n=sqrt(Self.dot(self,self));return Q(x:x/n,y:y/n,z:z/n,w:w/n)}
        static func from(_ input:V)->Q {let a=input.unit;return a.z < -1+1e-14 ? Q(x:1,y:0,z:0,w:0):Q(x:-a.y,y:a.x,z:0,w:1+a.z).unit}
        static func mix(_ a:Q,_ original:Q,_ t:Double)->Q {
            var b=original;var d=dot(a,b);if d<0 {b=Q(x:-b.x,y:-b.y,z:-b.z,w:-b.w);d = -d}
            if d>0.9999999999 {return Q(x:a.x*(1-t)+b.x*t,y:a.y*(1-t)+b.y*t,z:a.z*(1-t)+b.z*t,w:a.w*(1-t)+b.w*t).unit}
            let angle=acos(max(-1,min(1,d))),u=sin((1-t)*angle)/sin(angle),v=sin(t*angle)/sin(angle)
            return Q(x:a.x*u+b.x*v,y:a.y*u+b.y*v,z:a.z*u+b.z*v,w:a.w*u+b.w*v)
        }
        var axis:V {V(2*(x*z+w*y),2*(y*z-w*x),1-2*(x*x+y*y)).unit}
    }
    struct Pose {var tip:V;var axis:V}
    struct Grid {
        var raw:Data;var nx:Int;var ny:Int;var nz:Int;var h:Double;var lo:V
        var cells:Int {nx*ny*nz}
        func material(_ x:Int,_ y:Int,_ z:Int)->Bool {x>=0&&y>=0&&z>=0&&x<nx&&y<ny&&z<nz && raw[36+(z*ny+y)*nx+x]==1}
        func value(_ index:Int)->UInt8 {raw[36+index]}
        var count:Int {raw.dropFirst(36).reduce(0){$0+Int($1)}}
        var volume:Double {Double(count)*h*h*h}
    }
    static func grid(_ raw:Data)throws->Grid {
        guard raw.count>=36,String(data:raw.prefix(8),encoding:.ascii)=="FLSTK001" else{throw fail("Invalid preview occupancy")}
        var r=Reader(data:raw,offset:8);let nx=Int(try r.u32()),ny=Int(try r.u32()),nz=Int(try r.u32()),h=Double(try r.f32());let lo=V(Double(try r.f32()),Double(try r.f32()),Double(try r.f32()))
        guard nx>0,ny>0,nz>0,nx<=1024,ny<=1024,nz<=1024,nx*ny*nz<=131072,raw.count==36+nx*ny*nz,[0.125,0.25,0.5,1].contains(h),lo.values.allSatisfy({$0.isFinite&&abs($0)<=100}),raw.dropFirst(36).allSatisfy({$0<=1}) else{throw fail("Preview occupancy budget/layout")}
        return Grid(raw:raw,nx:nx,ny:ny,nz:nz,h:h,lo:lo)
    }
    static func sdf(_ point:V,_ pose:Pose,_ radius:Double,_ length:Double,_ offset:Double=0)->Double {
        let v=point-pose.tip,h=V.dot(v,pose.axis),u=sqrt(max(0,V.dot(v,v)-h*h))-radius,a=abs(h-offset-length/2)-length/2
        return min(max(u,a),0)+hypot(max(u,0),max(a,0))
    }
    static func mesh(_ data:Data,_ g:Grid,check:()throws->Void)throws {
        guard data.count>=84 else{throw fail("Truncated preview STL")};var r=Reader(data:data,offset:80);let triangles=Int(try r.u32())
        guard triangles>0,triangles<=400000,data.count==84+50*triangles else{throw fail("Preview STL budget")}
        func less(_ a:Point,_ b:Point)->Bool {a.x != b.x ? a.x<b.x : a.y != b.y ? a.y<b.y:a.z<b.z}
        var edges:[Edge:Int]=[:],faces:[Face:Int]=[:],links:[Point:[(Point,Point)]]=[:];var volume=0.0,expectedFaces=0
        for z in 0..<g.nz {try check();for y in 0..<g.ny {for x in 0..<g.nx where g.material(x,y,z) {for p in [(x-1,y,z),(x+1,y,z),(x,y-1,z),(x,y+1,z),(x,y,z-1),(x,y,z+1)] where !g.material(p.0,p.1,p.2){expectedFaces += 1}}}}
        for triangle in 0..<triangles {
            if triangle%1024==0 {try check()};let normal=[Double(try r.f32()),Double(try r.f32()),Double(try r.f32())];var points:[Point]=[],world:[V]=[]
            for _ in 0..<3 {let v=V(Double(try r.f32()),Double(try r.f32()),Double(try r.f32()));let q=(v-g.lo)*(1/g.h);guard q.values.allSatisfy({$0.isFinite&&abs($0)<=2048}) else{throw fail("Nonfinite preview STL")};let k=q.values.map{Int($0.rounded())};guard zip(q.values,k).allSatisfy({$0.0.isFinite&&abs($0.0-Double($0.1))<1e-6}),k[0]>=0,k[0]<=g.nx,k[1]>=0,k[1]<=g.ny,k[2]>=0,k[2]<=g.nz else{throw fail("Off-grid preview STL")};points.append(Point(x:k[0],y:k[1],z:k[2]));world.append(v)}
            _=try r.u32Half();let a=points[0],b=points[1],c=points[2],u=world[1]-world[0],v=world[2]-world[0],cross=V(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
            guard zip(normal,cross.values).allSatisfy({$0.0==$0.1/(g.h*g.h)}),normal.filter({$0 != 0}).count==1 else{throw fail("Preview STL normals/winding")}
            let axis=normal.firstIndex(where:{$0 != 0})!,sign=normal[axis]>0 ? 1:-1,xyz=[[a.x,a.y,a.z],[b.x,b.y,b.z],[c.x,c.y,c.z]],other=[0,1,2].filter{$0 != axis},plane=xyz[0][axis]
            guard xyz.allSatisfy({$0[axis]==plane}),other.allSatisfy({i in xyz.map{$0[i]}.max()! - xyz.map{$0[i]}.min()! == 1}) else{throw fail("Preview STL non-cell face")}
            let s0=xyz.map{$0[other[0]]}.min()!,s1=xyz.map{$0[other[1]]}.min()!,key=Face(axis:axis,plane:plane,a:s0,b:s1,sign:sign)
            var inside=[0,0,0];inside[axis]=plane-(sign>0 ? 1:0);inside[other[0]]=s0;inside[other[1]]=s1;var outside=inside;outside[axis]+=sign
            guard g.material(inside[0],inside[1],inside[2]),!g.material(outside[0],outside[1],outside[2]) else{throw fail("Preview STL differs from recovered material")}
            faces[key,default:0]+=1;links[a,default:[]].append((b,c));links[b,default:[]].append((c,a));links[c,default:[]].append((a,b));for(p,q) in [(a,b),(b,c),(c,a)]{edges[less(p,q) ? Edge(a:p,b:q):Edge(a:q,b:p),default:0]+=1}
            volume += V.dot(world[0],V(world[1].y*world[2].z-world[1].z*world[2].y,world[1].z*world[2].x-world[1].x*world[2].z,world[1].x*world[2].y-world[1].y*world[2].x))/6
        }
        for list in links.values {
            try check();var adjacent:[Point:Set<Point>]=[:]
            for (a,b) in list {adjacent[a,default:[]].insert(b);adjacent[b,default:[]].insert(a)}
            var seen=Set<Point>(),stack=[adjacent.keys.first!]
            while let point=stack.popLast() {if seen.insert(point).inserted {stack.append(contentsOf:adjacent[point] ?? [])}}
            guard seen.count==adjacent.count,adjacent.values.allSatisfy({$0.count==2}) else{throw fail("Preview STL has a nonmanifold vertex link")}
        }
        guard faces.count==expectedFaces,faces.values.allSatisfy({$0==2}),edges.values.allSatisfy({$0==2}),abs(volume-g.volume)<=1e-6*max(1,g.volume) else{throw fail("Preview STL is not a closed manifold with the recovered stock volume")}
    }
    static func verify(directory:URL,study:CADBasicMachiningStudy,cancellation:CancellationToken)throws->CADBasicMachiningVerified {
        guard study.formatVersion==2,let preview=study.parameters.preview else{throw fail("Preview parameters absent")};try study.parameters.validate()
        func check()throws {try cancellation.throwIfCancelled();if Task.isCancelled {throw CancellationError()}}
        func normalized(_ v:Any)throws->Data {try JSONSerialization.data(withJSONObject:v,options:.sortedKeys)}
        func data(_ name:String,_ cap:Int=20_000_084)throws->Data {
            try check();guard !name.hasPrefix("/"),!name.split(separator:"/").contains("..") else{throw fail("Invalid preview member")};let u=directory.appendingPathComponent(name)
            let a=try FileManager.default.attributesOfItem(atPath:u.path);guard a[.type] as? FileAttributeType == .typeRegular,((a[.size] as? NSNumber)?.intValue ?? Int.max)<=cap,u.standardizedFileURL==u.resolvingSymlinksInPath().standardizedFileURL else{throw fail("Preview member symlink/budget")};return try Data(contentsOf:u,options:.mappedIfSafe)
        }
        func object(_ d:Data)throws->[String:Any] {guard let o=try JSONSerialization.jsonObject(with:d) as? [String:Any] else{throw fail("Preview JSON object required")};return o}
        let md=try data("manifest.json",128000),m=try object(md)
        let expectedOwner:[String:Any]=["operationID":study.id.uuidString,"environmentID":study.environmentID,"conversationID":study.conversationID.uuidString,"runID":study.createdRunID.uuidString,"jobID":NSNull(),"studyRevision":1]
        let snapshotRoot=study.relativeDirectory+"/input/snapshot"
        let expectedSource:[String:Any]=["snapshotRoot":snapshotRoot,"bodyID":study.source.bodyID.uuidString,"documentRevision":study.source.revision,"modelSHA256":study.source.modelSHA256,"contentSHA256":study.source.contentSHA256,"files":study.source.members.sorted{$0.key<$1.key}.map{["path":snapshotRoot+"/"+$0.key,"sha256":$0.value]}]
        guard m["schema"] as? String=="floe.cad-multi-axis-preview-result.v1",m["outcome"] as? String=="computed-not-job-accepted",m["fullE38Accepted"] as? Bool==false,m["requestSHA256"] as? String==study.inputSHA256,m["sourceUnchanged"] as? Bool==true,
              let owner=m["ownerBinding"],try normalized(owner)==normalized(expectedOwner),let source=m["source"],try normalized(source)==normalized(expectedSource),let backend=m["backend"] as? [String:Any],
              backend["sourcePin"] as? String=="3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9",backend["coreSHA256"] as? String==CADBasicMachiningResources.coreSHA256,backend["wrapperSHA256"] as? String==CADMultiAxisPreviewResources.wrapperSHA256,backend["motionHostSHA256"] as? String==CADMultiAxisPreviewResources.motionSHA256,backend["fixtureHostSHA256"] as? String==CADMultiAxisPreviewResources.fixtureSHA256,backend["architecture"] as? String=="Arm64",(backend["actualOS"] as? String)?.hasPrefix("Darwin")==true else{throw fail("Preview owner/source/backend identity mismatch")}
        var allowed:Set<String>=["stock.stl","stock.occupancy","motion-input.json","motion/manifest.json","motion/evaluated-poses.tsv"]
        for stem in ["nominal","remaining-lower","remaining-upper"] {for ext in ["stl","occupancy"]{allowed.insert("motion/\(stem).\(ext)")}}
        if !preview.fixtures.isEmpty {allowed.formUnion(["fixtures-input.json","fixtures/manifest.json"]);for f in preview.fixtures{allowed.insert("fixtures/fixture-\(f.id).stl")}}
        guard let rows=m["artifacts"] as? [[String:Any]],rows.count==allowed.count,Set(rows.compactMap{$0["path"] as? String})==allowed else{throw fail("Preview artifact set mismatch")}
        var files:[String:Data]=[:];for row in rows {guard let name=row["path"] as? String else{throw fail("Preview artifact name")};let d=try data(name);guard row["bytes"] as? Int==d.count,row["sha256"] as? String==FloeDigest.sha256Hex(d) else{throw fail("Preview artifact changed")};files[name]=d}
        let snapshot=study.workspaceRoot.appendingPathComponent(snapshotRoot)
        for(name,sha) in study.source.members {try check();let u=snapshot.appendingPathComponent(name);guard u.standardizedFileURL.path.hasPrefix(snapshot.standardizedFileURL.path+"/"),u.standardizedFileURL==u.resolvingSymlinksInPath().standardizedFileURL,try FloeDigest.sha256Hex(ofFileAt:u)==sha else{throw fail("Frozen native snapshot changed")}}
        let model=try object(Data(contentsOf:snapshot.appendingPathComponent("document.json")))
        guard let bodies=model["bodies"] as? [[String:Any]],let body=bodies.first(where:{($0["bodyID"] as? String)?.lowercased()==study.source.bodyID.uuidString.lowercased()}),let blob=body["meshBlob"] as? String,study.source.members[blob] != nil else{throw fail("Preview native mesh identity")}
        let meshData=try Data(contentsOf:snapshot.appendingPathComponent(blob));var mr=Reader(data:meshData);guard try mr.u32()==0x4F533344 else{throw fail("Native mesh magic")};let version=try mr.u32(),vertices=Int(try mr.u32()),indices=Int(try mr.u32());guard (version==1||version==2),vertices>0,vertices<=1000000,indices>0,indices<=3000000,meshData.count==16+(version==2 ? 32:24)*vertices+4*indices else{throw fail("Native mesh budget")}
        var lo=[Double](repeating:.infinity,count:3),hi=[Double](repeating:-.infinity,count:3)
        for _ in 0..<vertices {for axis in 0..<3 {let v=Double(try mr.f32());guard v.isFinite,abs(v)<=100 else{throw fail("Native mesh bounds budget")};lo[axis]=min(lo[axis],v);hi[axis]=max(hi[axis],v)}}
        let h=study.parameters.resolutionMM;lo=lo.map{floor($0/h)*h};hi=hi.map{ceil($0/h)*h}
        let componentInput=try object(files["motion-input.json"]!),component=try object(files["motion/manifest.json"]!)
        let expectedParameters=try preview.taskParameters(radius:study.parameters.radiusMM,length:study.parameters.lengthMM,resolution:h)
        guard let stock=componentInput["stock"],try normalized(stock)==normalized(["minMM":lo,"maxMM":hi,"resolutionMM":h]),
              let posed=componentInput["poses"],try normalized(posed)==normalized(expectedParameters["poses"]!),let sampling=componentInput["sampling"],try normalized(sampling)==normalized(expectedParameters["sampling"]!),
              let componentTool=componentInput["tool"],try normalized(componentTool)==normalized(["kind":"flat-end-mill","radiusMM":study.parameters.radiusMM,"lengthMM":study.parameters.lengthMM]),
              component["inputSHA256"] as? String==FloeDigest.sha256Hex(files["motion-input.json"]!),let spans=component["spans"] as? [[String:Any]],spans.count==preview.poses.count-1 else{throw fail("Preview motion parameters changed")}
        var poses:[Pose]=[];var delta=0.0,holderDelta=0.0
        let trace=String(decoding:files["motion/evaluated-poses.tsv"]!,as:UTF8.self).split(separator:"\n").dropFirst();var line=trace.makeIterator()
        for k in 0..<spans.count {
            guard let n=spans[k]["steps"] as? Int,n>=1,n<=1024 else{throw fail("Preview sample budget")}
            let a=preview.poses[k],b=preview.poses[k+1],qa=Q.from(V(a.axisTowardSpindle)),qb=Q.from(V(b.axisTowardSpindle)),distance=(V(b.tipMM)-V(a.tipMM)).norm,angle=2*acos(max(0,min(1,abs(Q.dot(qa,qb)))))
            guard angle<=150*Double.pi/180 else{throw fail("Preview orientation segment exceeds 150 degrees")}
            delta=max(delta,distance/(2*Double(n))+2*hypot(study.parameters.radiusMM,study.parameters.lengthMM)*sin(angle/(4*Double(n))))
            if let holder=preview.holder{holderDelta=max(holderDelta,distance/(2*Double(n))+2*hypot(holder.radiusMM,holder.offsetFromTipMM+holder.lengthMM)*sin(angle/(4*Double(n))))}
            for j in 0...n {let t=Double(j)/Double(n),p=Pose(tip:V(a.tipMM)*(1-t)+V(b.tipMM)*t,axis:Q.mix(qa,qb,t).axis);poses.append(p)
                guard let row=line.next() else{throw fail("Truncated preview trace")};let fields=row.split(separator:"\t"),values=fields.dropFirst(3).compactMap{Double($0)}
                guard fields.count==9,Int(fields[0])==k,Int(fields[1])==j,Int(fields[2])==n,values.count==6,values.allSatisfy({$0.isFinite}),(V(Array(values.prefix(3)))-p.tip).norm<=1e-5,(V(Array(values.suffix(3))).unit-p.axis).norm<=2e-6 else{throw fail("Preview trace differs from canonical XYZ/IJK trajectory")}
            }
        }
        guard line.next()==nil else{throw fail("Extra preview poses")}
        let lower=try grid(files["motion/remaining-lower.occupancy"]!),nominal=try grid(files["motion/nominal.occupancy"]!),upper=try grid(files["motion/remaining-upper.occupancy"]!)
        for g in [lower,nominal,upper] {guard g.h==h,g.lo.values==lo,[g.nx,g.ny,g.nz]==zip(lo,hi).map({Int(($0.1-$0.0)/h)}),g.cells*poses.count<=120000000 else{throw fail("Preview stock changed or certificate budget exceeded")}}
        guard files["stock.occupancy"]==files["motion/nominal.occupancy"],files["stock.stl"]==files["motion/nominal.stl"] else{throw fail("Nominal preview alias changed")}
        let rho=sqrt(3)*h/2
        for z in 0..<nominal.nz {try check();for y in 0..<nominal.ny {for x in 0..<nominal.nx {
            let i=(z*nominal.ny+y)*nominal.nx+x,a=lower.value(i),b=nominal.value(i),c=upper.value(i)
            guard a<=b,b<=c else{throw fail("Preview material envelope nesting")};if c==1&&a==0 {continue}
            let point=V(lo)+V(Double(x)+0.5,Double(y)+0.5,Double(z)+0.5)*h
            var best=Double.infinity;for pose in poses{best=min(best,sdf(point,pose,study.parameters.radiusMM,study.parameters.lengthMM))}
            guard !(c==0&&best > -rho-1e-9),!(a==1&&best<delta+rho+1e-9) else{throw fail("Preview continuous complete-cell certificate failed")}
        }}}
        for(stem,g) in [("remaining-lower",lower),("nominal",nominal),("remaining-upper",upper)]{try mesh(files["motion/\(stem).stl"]!,g,check:check)}
        guard let totals=m["stock"] as? [String:Any],totals["mode"] as? String=="outward-rounded-part-bounds-blank",totals["boundsMin"] as? [Double]==lo,totals["boundsMax"] as? [Double]==hi,totals["resolutionMM"] as? Double==h,totals["remainingMM3"] as? Double==nominal.volume,totals["removedMM3"] as? Double==Double(nominal.cells)*h*h*h-nominal.volume,totals["continuousRemainingLowerMM3"] as? Double==lower.volume,totals["continuousRemainingUpperMM3"] as? Double==upper.volume else{throw fail("Preview volumes differ from independent occupancy counts")}
        var fixtureStates:[CADMultiAxisPreviewSummary.Fixture]=[]
        if !preview.fixtures.isEmpty {
            guard let holder=preview.holder else{throw fail("Fixture holder missing")};let fi=try object(files["fixtures-input.json"]!),fm=try object(files["fixtures/manifest.json"]!)
            guard let hf=fi["holder"],try normalized(hf)==normalized(expectedParameters["holder"]!),let ff=fi["fixtures"],try normalized(ff)==normalized(expectedParameters["fixtures"]!),fm["motionInputSHA256"] as? String==FloeDigest.sha256Hex(files["motion-input.json"]!),fm["motionManifestSHA256"] as? String==FloeDigest.sha256Hex(files["motion/manifest.json"]!),fm["fixturesInputSHA256"] as? String==FloeDigest.sha256Hex(files["fixtures-input.json"]!),let checks=fm["checks"] as? [[String:Any]],checks.count==preview.fixtures.count else{throw fail("Fixture lineage/parameters changed")}
            for f in preview.fixtures {
                guard let row=checks.first(where:{$0["id"] as? String==f.id}),let state=row["state"] as? String,["intersecting","clear","uncertain-refine"].contains(state) else{throw fail("Fixture result missing")}
                let dims=zip(f.minMM,f.maxMM).map{Int(($0.1-$0.0)/f.resolutionMM)};guard dims.reduce(1,*)*poses.count<=16000000 else{throw fail("Fixture certificate budget")};var best=Double.infinity
                for pose in poses {try check();for z in 0..<dims[2] {for y in 0..<dims[1] {for x in 0..<dims[0] {let point=V(f.minMM)+V(Double(x)+0.5,Double(y)+0.5,Double(z)+0.5)*f.resolutionMM;best=min(best,sdf(point,pose,holder.radiusMM,holder.lengthMM,holder.offsetFromTipMM))}}}}
                if state=="intersecting" {guard best < -1e-6 else{throw fail("Fixture collision has no independent interior witness")}}
                if state=="clear" {guard best>holderDelta+sqrt(3)*f.resolutionMM/2+1e-6 else{throw fail("Fixture clearance has no continuous complete-box certificate")}}
                var raw=Data("FLSTK001".utf8);for n in dims{var v=UInt32(n).littleEndian;withUnsafeBytes(of:&v){raw.append(contentsOf:$0)}};for n in [f.resolutionMM]+f.minMM {var v=Float(n).bitPattern.littleEndian;withUnsafeBytes(of:&v){raw.append(contentsOf:$0)}};raw.append(Data(repeating:1,count:dims.reduce(1,*)));try mesh(files["fixtures/fixture-\(f.id).stl"]!,try grid(raw),check:check)
                fixtureStates.append(.init(id:f.id,state:state))
            }
        }
        let stl=files.removeValue(forKey:"stock.stl")!;_ = files.removeValue(forKey:"stock.occupancy")
        return CADBasicMachiningVerified(stlData:stl,manifestData:md,stlSHA256:FloeDigest.sha256Hex(stl),manifestSHA256:FloeDigest.sha256Hex(md),removedMM3:Double(nominal.cells)*h*h*h-nominal.volume,remainingMM3:nominal.volume,supplementalFiles:files,previewSummary:.init(continuousRemainingLowerMM3:lower.volume,continuousRemainingUpperMM3:upper.volume,fixtures:fixtureStates))
    }
}

private extension CADBasicMachiningVerification.Reader {
    mutating func u32Half()throws->UInt16 {guard offset+2<=data.count else{throw CADMultiAxisPreviewVerification.fail("Truncated STL attribute")};defer{offset+=2};return data.withUnsafeBytes{UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt16.self))}}
}
