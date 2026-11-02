// SPDX-License-Identifier: MPL-2.0
// E27/E28/E30 original-sized fixtures. Source only until Root's App run.
#if canImport(UIKit)
import Foundation
import XCTest
import simd
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeCAD
@testable import FloeApp

@MainActor
final class NativeCADImportParityTests: XCTestCase {
    private var workspace:URL!
    private var center:CadDocumentCenter!
    private var targets:[URL]=[]
    override func setUp() async throws {
        workspace=FileManager.default.temporaryDirectory.appendingPathComponent("ImportParity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        center=CadDocumentCenter(nativeProposalStoreFileURL:workspace.appendingPathComponent("proposals.json"))
    }
    override func tearDown() async throws {
        for url in targets {
            for record in FloeCAD3DBridge.shared.pendingProposals(for:url) { FloeCAD3DBridge.shared.discard(proposalID:record.id) }
            await FloeCAD3DBridge.shared.releaseDocument(at:url)
        }
        if let workspace { try? FileManager.default.removeItem(at:workspace) }
    }
    private func target(_ name:String) async throws -> URL {
        let url=workspace.appendingPathComponent(name)
        let doc=try await FloeCADDocument.create(at:url,name:name); doc.close(); targets.append(url);return url
    }
    private func put(_ path:String,_ bytes:Data) throws -> URL {
        let url=workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:url);return url
    }
    private func propose(target:String,source:String,units:String?=nil,resources:[String:String]=[:],token:CancellationToken=CancellationToken()) async throws -> UUID {
        let tool=CadDocumentTool(host:center)
        var extra:[String:Any]=["resources":resources]
        if let units { extra["units"]=units }
        let object:[String:Any]=["action":"import","path":target,"source_path":source,
            "payload":String(data:try JSONSerialization.data(withJSONObject:extra),encoding:.utf8)!]
        let args=try JSONDecoder().decode(CadDocumentArguments.self,from:JSONSerialization.data(withJSONObject:object))
        try tool.validate(args)
        let context=ToolContext(runID:UUID(),toolCallID:"import-parity-\(UUID().uuidString)",scope:.local,
            workspaceRootURL:workspace,cancellation:token,environmentID:"env-import-parity",conversationID:UUID())
        let reply=try await tool.execute(args,context:context)
        let text=reply.summary
        let start=try XCTUnwrap(text.firstIndex(of:"{")),end=try XCTUnwrap(text.lastIndex(of:"}"))
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text[start...end].utf8)) as? [String:Any])
        let record=try XCTUnwrap(json["proposal"] as? [String:Any])
        return try XCTUnwrap((record["id"] as? String).flatMap(UUID.init(uuidString:)))
    }
    private func apply(_ id:UUID) async throws {
        let grant=try await center.issueNativeCADGrant(proposalID:id)
        _=try await center.applyNativeCAD(proposalID:id,grantID:grant)
    }
    private func manual(_ group:CADImportSourceGroup,unit:MeshImportUnit,name:String) async throws -> FloeCADDocument {
        let url=try await target(name),doc=try await FloeCADDocument.open(at:url)
        let vm=doc.viewModel()
        let parsed=await vm.probeMeshOffMainWithOperation(data:group.primary.data,
            fileName:group.primary.fileName,siblings:group.resources)
        let prepared=try XCTUnwrap(parsed)
        XCTAssertNotNil(prepared.probe.coverage)
        await vm.importMeshProbe(prepared.probe,unit:unit,operation:prepared.operation)
        XCTAssertNil(vm.errorMessage)
        return doc
    }
    private func worldBounds(_ body:Body) -> (SIMD3<Double>,SIMD3<Double>) {
        let points=body.render.positions.map { p -> SIMD3<Double> in
            let v=body.transform.matrix*SIMD4(SIMD3<Double>(p),1);return SIMD3(v.x,v.y,v.z)/v.w
        }
        return (points.reduce(SIMD3(repeating:Double.greatestFiniteMagnitude)){simd_min($0,$1)},
                points.reduce(SIMD3(repeating:-Double.greatestFiniteMagnitude)){simd_max($0,$1)})
    }
    private func equalBodies(_ a:FloeCADDocument,_ b:FloeCADDocument) {
        let left=a.session.document.bodies.sorted{$0.name<$1.name},right=b.session.document.bodies.sorted{$0.name<$1.name}
        XCTAssertEqual(left.count,right.count)
        for (x,y) in zip(left,right) {
            XCTAssertEqual(x.name,y.name);XCTAssertEqual(x.render,y.render);XCTAssertEqual(x.transform,y.transform)
            XCTAssertEqual(x.material?.baseColor,y.material?.baseColor)
            XCTAssertEqual(x.material?.metallic,y.material?.metallic);XCTAssertEqual(x.material?.roughness,y.material?.roughness)
            XCTAssertEqual(x.material?.baseColorTexture,y.material?.baseColorTexture)
        }
    }

    func testAuthorizedFileGroupManualAndActualToolPreserveNestedPlacementMaterialsAndNativeReopen() async throws {
        let source=try put("scene/scene.gltf",NativeImportParityFixture.scene)
        var urls=[source],paths:[String:String]=[:]
        for (name,bytes) in NativeImportParityFixture.resources { urls.append(try put("scene/"+name,bytes));paths[name]="scene/"+name }
        let selected=await CADImportSourceReader.readGroup(urls:urls),group=try selected.get()
        let ui=try await manual(group,unit:.metres,name:"Manual.floecad");defer{ui.close()}
        let aiURL=try await target("Agent.floecad")
        let proposal=try await propose(target:"Agent.floecad",source:"scene/scene.gltf",resources:paths)
        let pendingSpec=await center.nativeImportSpec(proposalID:proposal)
        let spec=try XCTUnwrap(pendingSpec)
        XCTAssertEqual(spec.resourceSHA256,try CADImportResources.hashes(group.resources))
        let frozen=try XCTUnwrap(FloeCAD3DBridge.shared.pendingProposals(for:aiURL).first(where:{$0.id==proposal}))
        let durable=try XCTUnwrap(FloeCAD3DBridge.importSpec(from:frozen))
        XCTAssertEqual(durable.resourcePaths,spec.resourcePaths);XCTAssertEqual(durable.resourceSHA256,spec.resourceSHA256)
        let operation=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(frozen.operationJSON.utf8)) as? [String:Any])
        XCTAssertEqual(operation["op"] as? String,"document.importMeshGroup")
        XCTAssertEqual((operation["args"] as? [String:Any])?["groupVersion"] as? Int,1)
        try await apply(proposal)
        let ai=try await FloeCAD3DBridge.shared.openDocument(at:aiURL)
        equalBodies(ui,ai);XCTAssertEqual(ai.summary().bodyCount,2)
        for body in ai.session.document.bodies {
            let (lo,hi)=worldBounds(body)
            let expectedLo:SIMD3<Double>=body.name == "A" ? SIMD3(9,20,30):SIMD3(6,20,30)
            let expectedHi:SIMD3<Double>=body.name == "A" ? SIMD3(11,22,32):SIMD3(10,22,31)
            for axis in 0..<3 { XCTAssertEqual(lo[axis],expectedLo[axis],accuracy:1e-4);XCTAssertEqual(hi[axis],expectedHi[axis],accuracy:1e-4) }
            XCTAssertEqual(body.material?.baseColorTexture,body.name == "A" ? NativeImportParityFixture.red:NativeImportParityFixture.blue)
            let material=try XCTUnwrap(body.material)
            let color:SIMD4<Double>=body.name == "A" ? SIMD4(1,0.1,0.1,1):SIMD4(0.1,0.1,1,1)
            for channel in 0..<4 { XCTAssertEqual(material.baseColor[channel],color[channel],accuracy:1e-6) }
            XCTAssertEqual(material.metallic,0,accuracy:1e-6);XCTAssertEqual(material.roughness,0.7,accuracy:1e-6)
        }
        let glb=GLBExporter.glb(bodies:ai.session.document.bodies)
        let wire=try independentGLBRows(glb)
        XCTAssertEqual(wire.count,2)
        for row in wire {
            let lo=row.minimumMM,hi=row.maximumMM
            XCTAssertEqual(lo.x,row.name == "A" ? 9:6,accuracy:1e-4)
            XCTAssertEqual(hi.x,row.name == "A" ? 11:10,accuracy:1e-4)
            XCTAssertEqual(lo.y,20,accuracy:1e-4);XCTAssertEqual(lo.z,30,accuracy:1e-4)
            XCTAssertEqual(hi.y,22,accuracy:1e-4);XCTAssertEqual(hi.z,row.name == "A" ? 32:31,accuracy:1e-4)
            let color=row.name == "A" ? [1.0,0.1,0.1,1.0]:[0.1,0.1,1.0,1.0]
            XCTAssertEqual(row.baseColor.count,4)
            for channel in 0..<min(4,row.baseColor.count) { XCTAssertEqual(row.baseColor[channel],color[channel],accuracy:1e-6) }
            XCTAssertEqual(row.metallic,0,accuracy:1e-6);XCTAssertEqual(row.roughness,0.7,accuracy:1e-6)
            XCTAssertEqual(row.imageSHA256,CADImportResources.sha256(row.name == "A" ? NativeImportParityFixture.red:NativeImportParityFixture.blue))
        }
        keep(glb,name:"E27 nested scene independent export.glb")
        ui.session.undo();XCTAssertEqual(ui.summary().bodyCount,0);ui.session.redo();XCTAssertEqual(ui.summary().bodyCount,2)
        let saved=await ui.save();XCTAssertTrue(saved.succeeded)
        let uiURL=ui.url;ui.close();let reopened=try await FloeCADDocument.open(at:uiURL);defer{reopened.close()}
        equalBodies(reopened,ai)
        XCTAssertEqual(try Data(contentsOf:source),NativeImportParityFixture.scene)
        for (name,bytes) in NativeImportParityFixture.resources { XCTAssertEqual(try Data(contentsOf:workspace.appendingPathComponent("scene/"+name)),bytes) }
    }

    func testExplicitTwoMillimetresAndTwoMetresAgreeAcrossManualAgentAndIndependentExport() async throws {
        for (label,unit,size,data) in [("mm",MeshImportUnit.millimetres,2.0,NativeImportParityFixture.tiny),
                                       ("m",MeshImportUnit.metres,2000.0,NativeImportParityFixture.scan)] {
            let source=try put("\(label).obj",data),selected=await CADImportSourceReader.readGroup(urls:[source])
            let ui=try await manual(selected.get(),unit:unit,name:"Manual-\(label).floecad");defer{ui.close()}
            let aiURL=try await target("Agent-\(label).floecad")
            let proposal=try await propose(target:"Agent-\(label).floecad",source:"\(label).obj",units:label)
            try await apply(proposal)
            let ai=try await FloeCAD3DBridge.shared.openDocument(at:aiURL)
            equalBodies(ui,ai)
            let body=try XCTUnwrap(ai.session.document.bodies.first),(lo,hi)=worldBounds(body)
            for axis in 0..<3 { XCTAssertEqual(hi[axis]-lo[axis],size,accuracy:1e-4) }
            let glb=GLBExporter.glb(bodies:[body]),row=try XCTUnwrap(try independentGLBRows(glb).first)
            for axis in 0..<3 { XCTAssertEqual(row.maximumMM[axis]-row.minimumMM[axis],size,accuracy:1e-4) }
            keep(glb,name:label == "mm" ? "E30 original 2mm part.glb":"E30 original 2m scan.glb")
            let saved=await ui.save();XCTAssertTrue(saved.succeeded)
            let manualURL=ui.url;ui.close()
            let reopened=try await FloeCADDocument.open(at:manualURL);defer{reopened.close()}
            equalBodies(reopened,ai)
            XCTAssertEqual(try Data(contentsOf:source),data)
        }
    }

    func testMissingResourceAndChangedResourceRefuseWithoutFewerPartsOrSourceRewrites() async throws {
        _=try put("scene.gltf",NativeImportParityFixture.scene)
        _=try put("geometry.bin",NativeImportParityFixture.geometry)
        _=try put("textures/red.png",NativeImportParityFixture.red)
        let targetURL=try await target("Missing.floecad")
        do {
            _=try await propose(target:"Missing.floecad",source:"scene.gltf",resources:["geometry.bin":"geometry.bin","textures/red.png":"textures/red.png"])
            XCTFail("A missing blue texture must not become a successful lower-fidelity import")
        } catch { XCTAssertTrue(error.localizedDescription.contains("blue.png"),"\(error)") }
        let empty=try await FloeCAD3DBridge.shared.openDocument(at:targetURL);XCTAssertEqual(empty.summary().bodyCount,0)
        _=try put("textures/blue.png",NativeImportParityFixture.blue)
        let paths=["geometry.bin":"geometry.bin","textures/red.png":"textures/red.png","textures/blue.png":"textures/blue.png"]
        let proposal=try await propose(target:"Missing.floecad",source:"scene.gltf",resources:paths)
        let count=empty.liveChangeCount
        _=try put("textures/blue.png",NativeImportParityFixture.red)
        do { try await apply(proposal);XCTFail("A preview cannot apply changed accompanying bytes") } catch {}
        XCTAssertEqual(empty.summary().bodyCount,0);XCTAssertEqual(empty.liveChangeCount,count)
        XCTAssertEqual(try Data(contentsOf:workspace.appendingPathComponent("scene.gltf")),NativeImportParityFixture.scene)
        XCTAssertEqual(try Data(contentsOf:workspace.appendingPathComponent("textures/blue.png")),NativeImportParityFixture.red)
    }

    func testExplicitResourcePathCannotGrantOutsideWorkspaceAccessAndCancellationPreservesSources() async throws {
        let source=try put("tiny.obj",NativeImportParityFixture.tiny)
        let targetURL=try await target("Guard.floecad")
        do { _=try await propose(target:"Guard.floecad",source:"tiny.obj",units:"mm",resources:["untrusted.bin":"../outside-workspace.bin"]);XCTFail("A resource string is not an access grant") } catch {}
        let token=CancellationToken();token.cancel()
        do { _=try await propose(target:"Guard.floecad",source:"tiny.obj",units:"mm",token:token);XCTFail("A cancelled read/import must not create a proposal") } catch {}
        let doc=try await FloeCAD3DBridge.shared.openDocument(at:targetURL)
        XCTAssertEqual(doc.summary().bodyCount,0)
        XCTAssertEqual(try Data(contentsOf:source),NativeImportParityFixture.tiny)
    }

    func testStrictScaleAndAmbiguousOrUnsupportedInputsCannotSilentlyDowngrade() async throws {
        for raw:Any in [0,-1,Double.infinity,Double.nan,"1000",true] {
            XCTAssertThrowsError(try CADImportUnits.resolve(units:"mm",scale:raw))
            switch AgentExec.parse(["op":"document.import","args":["path":"/synthetic/part.obj","units":"mm","unitScale":raw]]) {
            case .success:XCTFail("Invalid explicit scale must not fall back to units")
            case .failure:break
            }
        }
        XCTAssertThrowsError(try CADImportUnits.resolve(units:"mm",scale:1000))
        XCTAssertEqual(try CADImportUnits.resolve(units:"m",scale:1000),1000)
        XCTAssertThrowsError(try CADMeshImportService.parse(data:NativeImportParityFixture.tiny,fileName:"part.obj",requireExplicitUnits:true))
        let zip=try CADMeshImportService.parse(data:NativeImportParityFixture.singleZip,fileName:"part.zip",unitScale:1,requireExplicitUnits:true)
        XCTAssertEqual(zip.partCount,1)
        XCTAssertThrowsError(try CADMeshImportService.parse(data:NativeImportParityFixture.ambiguousZip,fileName:"ambiguous.zip",unitScale:1,requireExplicitUnits:true))
        XCTAssertThrowsError(try CADImportResources.hashes(["Texture.png":NativeImportParityFixture.red,"texture.png":NativeImportParityFixture.blue]))
        var source=try XCTUnwrap(JSONSerialization.jsonObject(with:NativeImportParityFixture.scene) as? [String:Any])
        source["extensionsRequired"]=["UNKNOWN_required_extension"]
        XCTAssertThrowsError(try CADMeshImportService.parse(data:JSONSerialization.data(withJSONObject:source),fileName:"unsupported.gltf",siblings:NativeImportParityFixture.resources))
    }

    private func keep(_ data:Data,name:String) {
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.data")
        attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private struct WireRow {
        let name:String
        let minimumMM:SIMD3<Double>,maximumMM:SIMD3<Double>
        let imageSHA256:String?
        let baseColor:[Double]
        let metallic:Double,roughness:Double
    }
    /// Independent GLB wire reader: does not call GLTFImporter, unit helpers
    /// or the production export coverage/model adapters.
    private func independentGLBRows(_ data:Data) throws -> [WireRow] {
        func u32(_ at:Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self)) } }
        XCTAssertEqual(u32(0),0x46546c67)
        let length=Int(u32(12)),binary=20+length+8
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:20..<20+length)) as? [String:Any])
        let nodes=try XCTUnwrap(json["nodes"] as? [[String:Any]]),meshes=try XCTUnwrap(json["meshes"] as? [[String:Any]])
        let accessors=try XCTUnwrap(json["accessors"] as? [[String:Any]]),views=try XCTUnwrap(json["bufferViews"] as? [[String:Any]])
        let materials=json["materials"] as? [[String:Any]] ?? [],textures=json["textures"] as? [[String:Any]] ?? [],images=json["images"] as? [[String:Any]] ?? []
        func matrix(_ node:[String:Any]) -> simd_double4x4 {
            if let m=node["matrix"] as? [Double],m.count==16 { return simd_double4x4(SIMD4(m[0],m[1],m[2],m[3]),SIMD4(m[4],m[5],m[6],m[7]),SIMD4(m[8],m[9],m[10],m[11]),SIMD4(m[12],m[13],m[14],m[15])) }
            let s=node["scale"] as? [Double] ?? [1,1,1],t=node["translation"] as? [Double] ?? [0,0,0]
            var m=simd_double4x4(diagonal:SIMD4(s[0],s[1],s[2],1));m.columns.3=SIMD4(t[0],t[1],t[2],1);return m
        }
        var rows:[WireRow]=[]
        func visit(_ index:Int,_ parent:simd_double4x4) throws {
            let node=nodes[index],world=parent*matrix(node)
            if let mesh=node["mesh"] as? Int {
                for primitive in meshes[mesh]["primitives"] as? [[String:Any]] ?? [] {
                    let attributes=try XCTUnwrap(primitive["attributes"] as? [String:Any])
                    let accessor=accessors[try XCTUnwrap(attributes["POSITION"] as? Int)]
                    XCTAssertEqual(accessor["componentType"] as? Int,5126)
                    let view=views[try XCTUnwrap(accessor["bufferView"] as? Int)],count=try XCTUnwrap(accessor["count"] as? Int)
                    let start=binary+(view["byteOffset"] as? Int ?? 0)+(accessor["byteOffset"] as? Int ?? 0),stride=view["byteStride"] as? Int ?? 12
                    var lo=SIMD3<Double>(repeating:.greatestFiniteMagnitude),hi = -lo
                    for i in 0..<count {
                        let p=(0..<3).map { Double(Float(bitPattern:u32(start+i*stride+$0*4))) }
                        let v=world*SIMD4(p[0],p[1],p[2],1),mm=SIMD3(v.x,v.y,v.z)/v.w*1000
                        lo=simd_min(lo,mm);hi=simd_max(hi,mm)
                    }
                    var imageSHA:String?
                    if let material=primitive["material"] as? Int,let pbr=materials[material]["pbrMetallicRoughness"] as? [String:Any],
                       let texture=pbr["baseColorTexture"] as? [String:Any],let index=texture["index"] as? Int,
                       let source=textures[index]["source"] as? Int,let imageView=images[source]["bufferView"] as? Int {
                        let view=views[imageView],offset=binary+(view["byteOffset"] as? Int ?? 0),size=try XCTUnwrap(view["byteLength"] as? Int)
                        imageSHA=CADImportResources.sha256(data.subdata(in:offset..<offset+size))
                    }
                    let material=(primitive["material"] as? Int).map { materials[$0] }
                    let pbr=material?["pbrMetallicRoughness"] as? [String:Any] ?? [:]
                    rows.append(WireRow(name:node["name"] as? String ?? "",minimumMM:lo,maximumMM:hi,imageSHA256:imageSHA,
                        baseColor:pbr["baseColorFactor"] as? [Double] ?? [1,1,1,1],
                        metallic:pbr["metallicFactor"] as? Double ?? 1,roughness:pbr["roughnessFactor"] as? Double ?? 1))
                }
            }
            for child in node["children"] as? [Int] ?? [] { try visit(child,world) }
        }
        let scenes=try XCTUnwrap(json["scenes"] as? [[String:Any]])
        for node in scenes[json["scene"] as? Int ?? 0]["nodes"] as? [Int] ?? [] { try visit(node,matrix_identity_double4x4) }
        return rows
    }
}
private enum NativeImportParityFixture {
    static let tiny = Data("o two_unit_cube\nv 0 0 0\nv 2 0 0\nv 2 2 0\nv 0 2 0\nv 0 0 2\nv 2 0 2\nv 2 2 2\nv 0 2 2\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 4 8 7 3\nf 1 5 8 4\nf 2 3 7 6\n".utf8)
    static let scan = Data("o two_metre_scan\nv 0 0 0\nv 2 0 0\nv 2 2 0\nv 0 2 0\nv 0 0 2\nv 2 0 2\nv 2 2 2\nv 0 2 2\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 4 8 7 3\nf 1 5 8 4\nf 2 3 7 6\n".utf8)
    static let scene = Data(base64Encoded: "eyJhc3NldCI6eyJ2ZXJzaW9uIjoiMi4wIiwiZ2VuZXJhdG9yIjoiRTI3IGluZGVwZW5kZW50IGF1dGhvcmVkIGZpeHR1cmUifSwiYnVmZmVycyI6W3sidXJpIjoiZ2VvbWV0cnkuYmluIiwiYnl0ZUxlbmd0aCI6MzA0fV0sImJ1ZmZlclZpZXdzIjpbeyJidWZmZXIiOjAsImJ5dGVPZmZzZXQiOjAsImJ5dGVMZW5ndGgiOjk2fSx7ImJ1ZmZlciI6MCwiYnl0ZU9mZnNldCI6OTYsImJ5dGVMZW5ndGgiOjE0NH0seyJidWZmZXIiOjAsImJ5dGVPZmZzZXQiOjI0MCwiYnl0ZUxlbmd0aCI6NjR9XSwiYWNjZXNzb3JzIjpbeyJidWZmZXJWaWV3IjowLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6OCwidHlwZSI6IlZFQzMifSx7ImJ1ZmZlclZpZXciOjEsImNvbXBvbmVudFR5cGUiOjUxMjUsImNvdW50IjozNiwidHlwZSI6IlNDQUxBUiJ9LHsiYnVmZmVyVmlldyI6MiwiY29tcG9uZW50VHlwZSI6NTEyNiwiY291bnQiOjgsInR5cGUiOiJWRUMyIn1dLCJpbWFnZXMiOlt7InVyaSI6InRleHR1cmVzL3JlZC5wbmcifSx7InVyaSI6InRleHR1cmVzL2JsdWUucG5nIn1dLCJ0ZXh0dXJlcyI6W3sic291cmNlIjowfSx7InNvdXJjZSI6MX1dLCJtYXRlcmlhbHMiOlt7Im5hbWUiOiJSZWQiLCJwYnJNZXRhbGxpY1JvdWdobmVzcyI6eyJiYXNlQ29sb3JGYWN0b3IiOlsxLDAuMSwwLjEsMV0sIm1ldGFsbGljRmFjdG9yIjowLCJyb3VnaG5lc3NGYWN0b3IiOjAuNywiYmFzZUNvbG9yVGV4dHVyZSI6eyJpbmRleCI6MH19fSx7Im5hbWUiOiJCbHVlIiwicGJyTWV0YWxsaWNSb3VnaG5lc3MiOnsiYmFzZUNvbG9yRmFjdG9yIjpbMC4xLDAuMSwxLDFdLCJtZXRhbGxpY0ZhY3RvciI6MCwicm91Z2huZXNzRmFjdG9yIjowLjcsImJhc2VDb2xvclRleHR1cmUiOnsiaW5kZXgiOjF9fX1dLCJtZXNoZXMiOlt7InByaW1pdGl2ZXMiOlt7ImF0dHJpYnV0ZXMiOnsiUE9TSVRJT04iOjAsIlRFWENPT1JEXzAiOjJ9LCJpbmRpY2VzIjoxLCJtYXRlcmlhbCI6MH1dfSx7InByaW1pdGl2ZXMiOlt7ImF0dHJpYnV0ZXMiOnsiUE9TSVRJT04iOjAsIlRFWENPT1JEXzAiOjJ9LCJpbmRpY2VzIjoxLCJtYXRlcmlhbCI6MX1dfV0sIm5vZGVzIjpbeyJuYW1lIjoiUGFyZW50IiwidHJhbnNsYXRpb24iOlswLjAxLDAuMDIsMC4wM10sImNoaWxkcmVuIjpbMSwyXX0seyJuYW1lIjoiQSIsIm1lc2giOjAsInRyYW5zbGF0aW9uIjpbMC4wMDEsMCwwXSwicm90YXRpb24iOlswLDAsMC43MDcxMDY3ODExODY1NDc2LDAuNzA3MTA2NzgxMTg2NTQ3Nl19LHsibmFtZSI6IkIiLCJtZXNoIjoxLCJ0cmFuc2xhdGlvbiI6Wy0wLjAwNCwwLDBdLCJzY2FsZSI6WzIsMSwwLjVdfV0sInNjZW5lcyI6W3sibm9kZXMiOlswXX1dLCJzY2VuZSI6MH0=")!
    static let geometry = Data(base64Encoded: "AAAAAAAAAAAAAAAAbxIDOwAAAAAAAAAAbxIDO28SAzsAAAAAAAAAAG8SAzsAAAAAAAAAAAAAAABvEgM7bxIDOwAAAABvEgM7bxIDO28SAztvEgM7AAAAAG8SAztvEgM7AAAAAAMAAAACAAAAAAAAAAIAAAABAAAABAAAAAUAAAAGAAAABAAAAAYAAAAHAAAAAAAAAAEAAAAFAAAAAAAAAAUAAAAEAAAAAwAAAAcAAAAGAAAAAwAAAAYAAAACAAAAAAAAAAQAAAAHAAAAAAAAAAcAAAADAAAAAQAAAAIAAAAGAAAAAQAAAAYAAAAFAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AACAPwAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAIA/AACAPw==")!
    static let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4ICHxH4QZYAwATBQIfcFVEEEAAAAASUVORK5CYII=")!
    static let blue = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOQkPjwH4QZYAwARVQIfdTLW5EAAAAASUVORK5CYII=")!
    static let singleZip = Data(base64Encoded: "UEsDBBQAAAAAAPWIYl2vuChbjAAAAIwAAAAMAAAAdGlueS0ybW0ub2JqbyB0d29fdW5pdF9jdWJlCnYgMCAwIDAKdiAyIDAgMAp2IDIgMiAwCnYgMCAyIDAKdiAwIDAgMgp2IDIgMCAyCnYgMiAyIDIKdiAwIDIgMgpmIDEgNCAzIDIKZiA1IDYgNyA4CmYgMSAyIDYgNQpmIDQgOCA3IDMKZiAxIDUgOCA0CmYgMiAzIDcgNgpQSwECFAMUAAAAAAD1iGJdr7goW4wAAACMAAAADAAAAAAAAAAAAAAAgAEAAAAAdGlueS0ybW0ub2JqUEsFBgAAAAABAAEAOgAAALYAAAAAAA==")!
    static let ambiguousZip = Data(base64Encoded: "UEsDBBQAAAAAAPWIYl2vuChbjAAAAIwAAAAHAAAAb25lLm9iam8gdHdvX3VuaXRfY3ViZQp2IDAgMCAwCnYgMiAwIDAKdiAyIDIgMAp2IDAgMiAwCnYgMCAwIDIKdiAyIDAgMgp2IDIgMiAyCnYgMCAyIDIKZiAxIDQgMyAyCmYgNSA2IDcgOApmIDEgMiA2IDUKZiA0IDggNyAzCmYgMSA1IDggNApmIDIgMyA3IDYKUEsDBBQAAAAAAPWIYl2vuChbjAAAAIwAAAAHAAAAdHdvLm9iam8gdHdvX3VuaXRfY3ViZQp2IDAgMCAwCnYgMiAwIDAKdiAyIDIgMAp2IDAgMiAwCnYgMCAwIDIKdiAyIDAgMgp2IDIgMiAyCnYgMCAyIDIKZiAxIDQgMyAyCmYgNSA2IDcgOApmIDEgMiA2IDUKZiA0IDggNyAzCmYgMSA1IDggNApmIDIgMyA3IDYKUEsBAhQDFAAAAAAA9YhiXa+4KFuMAAAAjAAAAAcAAAAAAAAAAAAAAIABAAAAAG9uZS5vYmpQSwECFAMUAAAAAAD1iGJdr7goW4wAAACMAAAABwAAAAAAAAAAAAAAgAGxAAAAdHdvLm9ialBLBQYAAAAAAgACAGoAAABiAQAAAAA=")!
    static var resources: [String:Data] { ["geometry.bin": geometry, "textures/red.png": red, "textures/blue.png": blue] }
}

#endif
