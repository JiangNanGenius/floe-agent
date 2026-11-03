// SPDX-License-Identifier: MPL-2.0
import Foundation
import ImageIO
import CoreGraphics
import simd

nonisolated enum CADMaterialGraphError:String,Error,LocalizedError {
    case invalid="invalid_material_graph",cancelled="material_graph_cancelled",stale="material_graph_stale",budget="material_graph_budget",busy="material_graph_busy"
    var errorDescription:String? {
        switch self {
        case .invalid:FloeCADStrings.text("cad.nodes.invalid","Check the graph connections, image references and values.")
        case .cancelled:FloeCADStrings.text("cad.nodes.cancelled","Baking was cancelled. Your material is unchanged.")
        case .stale:FloeCADStrings.text("cad.nodes.stale","The source changed. Bake the graph again.")
        case .budget:FloeCADStrings.text("cad.nodes.budget","Reduce the graph or image size and try again.")
        case .busy:FloeCADStrings.text("cad.nodes.busy","A material bake is finishing. Wait before starting another.")
        }
    }
}
nonisolated struct CADMaterialNode:Codable,Equatable,Sendable {
    nonisolated enum Operation:String,Codable,Sendable { case value,color,image,mix,multiply,checker }
    var id:UUID=UUID();var operation:Operation;var inputs:[UUID]=[]
    var color:SIMD4<Double>?;var value:Double?;var imageID:UUID?;var imageSHA256:String?;var factor:Double?;var frequency:Int?
    private enum CodingKeys:String,CodingKey { case id,operation,inputs,color,value,imageID,imageSHA256,factor,frequency }
    init(id:UUID=UUID(),operation:Operation,inputs:[UUID]=[],color:SIMD4<Double>?=nil,value:Double?=nil,imageID:UUID?=nil,imageSHA256:String?=nil,factor:Double?=nil,frequency:Int?=nil) {
        self.id=id;self.operation=operation;self.inputs=inputs;self.color=color;self.value=value;self.imageID=imageID;self.imageSHA256=imageSHA256;self.factor=factor;self.frequency=frequency
    }
    init(from decoder:Decoder) throws {
        try CADMaterialStrict.keys(decoder,["id","operation","inputs","color","value","imageID","imageSHA256","factor","frequency"])
        let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(UUID.self,forKey:.id);operation=try c.decode(Operation.self,forKey:.operation)
        inputs=try c.decodeIfPresent([UUID].self,forKey:.inputs) ?? [];color=try c.decodeIfPresent(SIMD4<Double>.self,forKey:.color);value=try c.decodeIfPresent(Double.self,forKey:.value)
        imageID=try c.decodeIfPresent(UUID.self,forKey:.imageID);imageSHA256=try c.decodeIfPresent(String.self,forKey:.imageSHA256);factor=try c.decodeIfPresent(Double.self,forKey:.factor);frequency=try c.decodeIfPresent(Int.self,forKey:.frequency)
    }
}
/// Nodes and image assets have independent stable IDs; edges and outputs are
/// references. Images are immutable CADMaterialTexture snapshots, not paths.
nonisolated struct CADMaterialNodeGraph:Codable,Equatable,Sendable {
    var version=1;var id=UUID();var nodes:[CADMaterialNode];var outputs:[String:UUID];var images:[CADMaterialTexture]=[];var resolution=128
    var recipeSHA256:String?;var bakedSHA256:[String:String]?
    private enum CodingKeys:String,CodingKey { case version,id,nodes,outputs,images,resolution,recipeSHA256,bakedSHA256 }
    init(nodes:[CADMaterialNode],outputs:[String:UUID],images:[CADMaterialTexture]=[],resolution:Int=128) { self.nodes=nodes;self.outputs=outputs;self.images=images;self.resolution=resolution }
    init(from decoder:Decoder) throws {
        try CADMaterialStrict.keys(decoder,["version","id","nodes","outputs","images","resolution","recipeSHA256","bakedSHA256"])
        let c=try decoder.container(keyedBy:CodingKeys.self);version=try c.decode(Int.self,forKey:.version);id=try c.decode(UUID.self,forKey:.id)
        nodes=try c.decode([CADMaterialNode].self,forKey:.nodes);outputs=try c.decode([String:UUID].self,forKey:.outputs);images=try c.decodeIfPresent([CADMaterialTexture].self,forKey:.images) ?? []
        if c.contains(.images) {
            var assets=try c.nestedUnkeyedContainer(forKey:.images)
            while !assets.isAtEnd { try CADMaterialStrict.keys(assets.superDecoder(),["id","slot","name","mimeType","colorSpace","orientation","bytes","sha256"]) }
        }
        resolution=try c.decode(Int.self,forKey:.resolution);recipeSHA256=try c.decodeIfPresent(String.self,forKey:.recipeSHA256);bakedSHA256=try c.decodeIfPresent([String:String].self,forKey:.bakedSHA256)
        try validate()
    }
    var digest:String { var copy=self;copy.recipeSHA256=nil;copy.bakedSHA256=nil;let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return (try? encoder.encode(copy)).map(CADMaterialTexture.digest) ?? "" }
    func order() throws -> [CADMaterialNode] {
        guard Set(nodes.map(\.id)).count==nodes.count else { throw CADMaterialGraphError.invalid }
        let map=Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,$0) });var visiting=Set<UUID>(),done=Set<UUID>(),result:[CADMaterialNode]=[]
        func visit(_ id:UUID) throws {
            if done.contains(id) { return };guard visiting.insert(id).inserted,let node=map[id] else { throw CADMaterialGraphError.invalid }
            for input in node.inputs { try visit(input) };visiting.remove(id);done.insert(id);result.append(node)
        }
        for node in nodes { try visit(node.id) };return result
    }
    func validate(requireBake:Bool=false) throws {
        guard version==1,(1...32).contains(nodes.count),[64,128,256].contains(resolution),images.count<=4,
              images.reduce(0,{$0+$1.bytes.count})<=4*1024*1024,Set(images.map(\.id)).count==images.count,
              !outputs.isEmpty,Set(outputs.keys).isSubset(of:["baseColor","roughness","metallic"]) else { throw CADMaterialGraphError.invalid }
        let ordered=try order(),ids=Set(ordered.map(\.id));guard outputs.values.allSatisfy({ids.contains($0)}) else { throw CADMaterialGraphError.invalid }
        for image in images { guard image.bytes.count<=1024*1024,image.sha256==CADMaterialTexture.digest(image.bytes),MaterialImageSniffer.mimeType(of:image.bytes) != nil else { throw CADMaterialGraphError.invalid } }
        for node in nodes {
            func count(_ n:Int) throws { guard node.inputs.count==n else { throw CADMaterialGraphError.invalid } }
            switch node.operation {
            case .value:try count(0);guard let v=node.value,v.isFinite,(0...1).contains(v) else { throw CADMaterialGraphError.invalid }
            case .color:try count(0);guard let c=node.color,c.w==1,[c.x,c.y,c.z,c.w].allSatisfy({$0.isFinite && (0...1).contains($0)}) else { throw CADMaterialGraphError.invalid }
            case .image:try count(0);guard let id=node.imageID,let image=images.first(where:{$0.id.raw==id}),node.imageSHA256==image.sha256 else { throw CADMaterialGraphError.invalid }
            case .multiply:try count(2)
            case .mix:try count(2);guard let f=node.factor,f.isFinite,(0...1).contains(f) else { throw CADMaterialGraphError.invalid }
            case .checker:try count(2);guard let f=node.frequency,(1...64).contains(f) else { throw CADMaterialGraphError.invalid }
            }
        }
        if requireBake { guard recipeSHA256==digest,let bakedSHA256,Set(bakedSHA256.keys)==Set(outputs.keys),bakedSHA256.values.allSatisfy({$0.count==64 && $0.allSatisfy(\.isHexDigit)}) else { throw CADMaterialGraphError.invalid } }
    }
    static func checker() -> Self {
        let a=CADMaterialNode(operation:.color,color:SIMD4(0.04,0.12,0.8,1)),b=CADMaterialNode(operation:.color,color:SIMD4(0.8,0.08,0.02,1))
        var c=CADMaterialNode(operation:.checker,frequency:8);c.inputs=[a.id,b.id];return Self(nodes:[a,b,c],outputs:["baseColor":c.id])
    }
}
nonisolated struct CADMaterialGraphComputed:Sendable {
    var graph:CADMaterialNodeGraph;var textures:[CADMaterialTexture]
    func applying(to original:CADMaterialDefinition) -> CADMaterialDefinition {
        var result=original
        for texture in textures {
            result.textures.removeAll { $0.slot==texture.slot };result.textures.append(texture)
            switch texture.slot { case .baseColor:result.baseColor.x=1;result.baseColor.y=1;result.baseColor.z=1;case .roughness:result.roughness=1;case .metallic:result.metallic=1;default:break }
        }
        result.nodeGraph=graph;return result
    }
}
nonisolated enum CADMaterialGraphKernel {
    static func compute(_ input:CADMaterialNodeGraph,cancellation:CADMeshCancellation,external:(any MeshImportCancellationChecking)?=nil) throws -> CADMaterialGraphComputed {
        try input.validate();let started=ProcessInfo.processInfo.systemUptime
        func check() throws { if cancellation.isCancelled || external?.isCancelled==true || Task.isCancelled { throw CADMaterialGraphError.cancelled };if ProcessInfo.processInfo.systemUptime-started>10 { throw CADMaterialGraphError.budget } }
        try check();let ordered=try input.order(),resolution=input.resolution
        var images:[UUID:(pixels:CADExportImage.Pixels,linear:Bool)]=[:]
        for image in input.images {
            try check()
            // Header bounds precede image allocation; the shared decoder's
            // broader general-image limit is not this graph's resource bound.
            guard let source=CGImageSourceCreateWithData(image.bytes as CFData,nil),let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width=(p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,let height=(p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,width>0,height>0,width<=1024,height<=1024 else { throw CADMaterialGraphError.budget }
            guard case let .success(decoded)=CADExportImage.decode(image.bytes),let pixels=CADExportImage.pixels(decoded,orientation:image.orientation) else { throw CADMaterialGraphError.invalid }
            guard stride(from:3,to:pixels.rgba.count,by:4).allSatisfy({pixels.rgba[$0]==255}) else { throw CADMaterialGraphError.invalid }
            images[image.id.raw]=(pixels,image.colorSpace == .linear)
        }
        let index=Dictionary(uniqueKeysWithValues:ordered.enumerated().map { ($0.element.id,$0.offset) })
        var buffers=Dictionary(uniqueKeysWithValues:input.outputs.keys.map { ($0,[UInt8](repeating:0,count:resolution*resolution*4)) })
        var values=[SIMD4<Double>](repeating:.zero,count:ordered.count)
        for y in 0..<resolution { try check();for x in 0..<resolution {
            let u=(Double(x)+0.5)/Double(resolution),v=(Double(y)+0.5)/Double(resolution)
            for (i,node) in ordered.enumerated() {
                func value(_ n:Int) -> SIMD4<Double> { values[index[node.inputs[n]]!] }
                switch node.operation {
                case .value:let n=node.value!;values[i]=SIMD4(n,n,n,1)
                case .color:values[i]=node.color!
                case .multiply:values[i]=value(0)*value(1)
                case .mix:values[i]=value(0)*(1-node.factor!)+value(1)*node.factor!
                case .checker:let f=Double(node.frequency!);values[i]=value((Int(floor(u*f))+Int(floor(v*f)))%2)
                case .image:
                    let image=images[node.imageID!]!,px=min(image.pixels.width-1,Int(u*Double(image.pixels.width))),py=min(image.pixels.height-1,Int(v*Double(image.pixels.height))),offset=(py*image.pixels.width+px)*4
                    var c=SIMD4<Double>(repeating:1)
                    for channel in 0..<4 { let s=Double(image.pixels.rgba[offset+channel])/255;c[channel]=(channel<3 && !image.linear) ? CADExportImage.srgbToLinear(s):s };values[i]=c
                }
            }
            for (slot,id) in input.outputs {
                let value=values[index[id]!],offset=(y*resolution+x)*4
                for channel in 0..<4 {
                    let v:Double
                    if slot=="baseColor" { v=channel<3 ? CADExportImage.linearToSRGB(value[channel]):value.w }
                    else { v=channel<3 ? value.x:1 }
                    buffers[slot]![offset+channel]=UInt8((min(max(v,0),1)*255).rounded())
                }
            }
        } }
        try check();var textures:[CADMaterialTexture]=[],hashes:[String:String]=[:]
        for slot in input.outputs.keys.sorted() {
            guard let typed=MaterialTextureSlot(rawValue:slot),let bytes=CADExportImage.encodePNG(.init(width:resolution,height:resolution,rgba:buffers[slot]!)) else { throw CADMaterialGraphError.invalid }
            let texture=CADMaterialTexture(slot:typed,name:"Baked graph",mimeType:"image/png",colorSpace:slot=="baseColor" ? .srgb:.linear,orientation:.topLeft,bytes:bytes)
            textures.append(texture);hashes[slot]=texture.sha256
        }
        var graph=input;graph.recipeSHA256=input.digest;graph.bakedSHA256=hashes;try graph.validate(requireBake:true);try check()
        return CADMaterialGraphComputed(graph:graph,textures:textures)
    }
}
