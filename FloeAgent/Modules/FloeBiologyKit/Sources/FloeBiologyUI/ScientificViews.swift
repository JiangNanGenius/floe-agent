// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import SceneKit
import simd
import FloeBiologyCore
import FloeBiologyEngine

func biologyViewCompute<T:Sendable>(_ body:@escaping @Sendable ()throws->T) async throws -> T {
    let task=Task.detached(priority:.userInitiated){try body()}
    return try await withTaskCancellationHandler{try await task.value}onCancel:{task.cancel()}
}

@MainActor struct BiologyRibbonView:View {
    let asset:BiologyAsset
    let structure:ProteinStructure
    @Binding var selectedAtoms:[Int]
    @Binding var modelNumber:Int
    @Binding var chain:String
    @State private var representation="backbone"
    @State private var scene:SCNScene?
    @State private var resetToken=0
    @State private var error:String?
    private var atoms:[StructureAtom]{structure.atoms.filter{$0.model==modelNumber && (chain.isEmpty || $0.chain==chain)}}
    private var alphaCount:Int{atoms.filter{$0.name=="CA" && !$0.hetero}.count}
    private var displayedCount:Int{representation=="ribbon" ? alphaCount:min(5000,representation=="atoms" ? atoms.count:alphaCount)}
    private var countUnit:String{representation=="ribbon" ? biologyText("residues","个残基"):representation=="backbone" ? biologyText("Cα atoms","个 Cα 原子"):biologyText("atoms","个原子")}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:16) {
                Picker(biologyText("Structure view","结构视图"),selection:$representation) {
                    Text(biologyText("Backbone","主链")).tag("backbone")
                    Text(biologyText("Atoms","原子")).tag("atoms")
                    Text(biologyText("Ribbon","带状模型")).tag("ribbon")
                }.pickerStyle(.segmented).accessibilityIdentifier("biology.structureRepresentation")
                Button{resetToken+=1}label:{Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:44,height:44)}
                    .buttonStyle(BiologyControlButtonStyle(compact:true)).accessibilityLabel(biologyText("Fit","适合窗口")).accessibilityIdentifier("biology.structureFit")
            }
            ZStack {
                if let scene {
                    BiologyMeshScene(scene:scene,atoms:atoms,selectedAtoms:Set(selectedAtoms),resetToken:resetToken,onSelect:{id in
                        if selectedAtoms.contains(id){selectedAtoms.removeAll{$0==id}}else{selectedAtoms=Array((selectedAtoms+[id]).suffix(2))}
                    }).accessibilityIdentifier(representation=="ribbon" ? "biology.ribbonViewport":"biology.structureViewport")
                }else if let error{ContentUnavailableView(biologyText("Unable to draw structure","无法显示结构"),systemImage:"exclamationmark.triangle",description:Text(error))}
                else{ProgressView()}
            }.frame(minHeight:280,maxHeight:.infinity).biologyCanvas()
            HStack(alignment:.firstTextBaseline) {
                Text("\(displayedCount) "+countUnit).font(.subheadline).monospacedDigit()
                Spacer()
                if selectedAtoms.count==2,let a=atoms.first(where:{$0.id==selectedAtoms[0]}),let b=atoms.first(where:{$0.id==selectedAtoms[1]}) {
                    Text(sqrt(pow(a.x-b.x,2)+pow(a.y-b.y,2)+pow(a.z-b.z,2)).formatted(.number.precision(.fractionLength(2)))+" Å").font(.subheadline.weight(.semibold)).monospacedDigit()
                }else if let id=selectedAtoms.first,let a=atoms.first(where:{$0.id==id}){Text(a.chain+":"+String(a.residueNumber)+" · "+a.name).font(.subheadline).foregroundStyle(.secondary)}else{Text(biologyText("Drag to rotate · pinch to zoom","拖动旋转 · 捏合缩放")).font(.caption).foregroundStyle(.secondary)}
            }
            if representation=="ribbon" {
                HStack(spacing:18){legend(biologyText("Helix","螺旋"),.orange);legend(biologyText("Sheet","折叠"),.blue);legend(biologyText("Unassigned","未标注"),.teal)}
            }
            if representation != "ribbon",(representation=="atoms" ? atoms.count:alphaCount)>5000{BiologyViewFootnote(text:biologyText("Showing the first 5,000 atoms. Select a chain to narrow the view.","显示前 5,000 个原子，可选择链缩小范围。"))}
        }.padding(BiologyStyle.spacing).background(BiologyStyle.background)
        .task(id:"\(asset.id):\(asset.revision):\(modelNumber):\(chain):\(representation)") {
            scene=nil;error=nil
            do {
                if representation=="ribbon" {
                    let structure=structure,model=modelNumber,chain=chain,data=asset.originalData,format=asset.originalFormat
                    let mesh=try await biologyViewCompute{
                        let deposited=try ["cif","mmcif"].contains(format) ? BiologyImporter.cifSecondaryClasses(String(decoding:data,as:UTF8.self)):BiologyProteinRibbon.depositedClasses(pdb:data)
                        return try BiologyProteinRibbon.build(structure,model:model,chain:chain.isEmpty ? nil:chain,deposited:deposited)
                    };try Task.checkCancellation()
                    guard !mesh.vertices.isEmpty else{throw BiologyError.unavailable(biologyText("No ribbon in this model. Choose Atoms.","这个模型没有可显示的带状结构，请选择原子视图。"))}
                    scene=BiologyMeshScene.makeScene(mesh)
                }else{
                    if representation=="backbone",!atoms.contains(where:{$0.name=="CA" && !$0.hetero}){throw BiologyError.unavailable(biologyText("No Cα atoms in this model. Choose Atoms.","这个模型没有 Cα 原子，请选择原子视图。"))}
                    scene=BiologySceneFactory.molecule(atoms,backbone:representation=="backbone")
                }
            }catch is CancellationError{}catch{self.error=error.localizedDescription}
        }
    }
    private func legend(_ text:String,_ color:Color)->some View {Label{Text(text)}icon:{Circle().fill(color).frame(width:7,height:7)}.font(.caption).foregroundStyle(.secondary)}
}

@MainActor struct BiologyTreeView:View {
    let data:Data
    var selection:JSONValue?
    @State private var tree:BiologyTree?
    @State private var lengths=true
    @State private var selected:Int?
    @State private var page=0
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle(biologyText("Use branch lengths","使用分支长度"),isOn:$lengths).font(.subheadline).frame(minHeight:44)
            if let tree {
                let positions=tree.layout(useLengths:lengths),span=max(positions.map(\.x).max() ?? 1,1e-12),height=max(260,Double(min(100,tree.leaves.count-page*100))*32),pageOffset=Double(page*100),selectedNode=selected
                if tree.leaves.count>100 {HStack{Button(biologyText("Previous","上一页")){page-=1}.buttonStyle(BiologyControlButtonStyle()).disabled(page==0);Spacer();Text("\(page+1) / \((tree.leaves.count+99)/100)");Spacer();Button(biologyText("Next","下一页")){page+=1}.buttonStyle(BiologyControlButtonStyle()).disabled((page+1)*100>=tree.leaves.count)}.padding(.horizontal)}
                GeometryReader { geometry in
                let plotWidth=max(80,geometry.size.width-172),labelBackground=BiologyStyle.canvas
                ScrollView(.vertical) {
                    Canvas {context,size in
                        func point(_ id:Int)->CGPoint {.init(x:20+positions[id].x/span*plotWidth,y:20+(positions[id].y-pageOffset)*32)}
                        for node in tree.nodes {
                            let p=point(node.id)
                            for child in node.children {let q=point(child);if max(p.y,q.y)>=0 && min(p.y,q.y)<=size.height {var line=Path();line.move(to:p);line.addLine(to:.init(x:p.x,y:q.y));line.addLine(to:q);context.stroke(line,with:.color(.secondary),style:.init(lineWidth:1.5,lineCap:.round,lineJoin:.round))}}
                            guard p.y>=0,p.y<=size.height else {continue}
                            if selectedNode==node.id {context.fill(Path(ellipseIn:.init(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.orange))}
                            if node.children.isEmpty || !node.label.isEmpty {
                                let label=Text(node.label.isEmpty ? "#\(node.id)":String(node.label.prefix(24))).font(node.children.isEmpty ? .callout:.caption).foregroundStyle(.primary),position=CGPoint(x:p.x+10,y:p.y+(node.children.isEmpty ? 0:-14))
                                let resolved=context.resolve(label),measured=resolved.measure(in:.init(width:150,height:32))
                                if !node.children.isEmpty{context.fill(Path(roundedRect:.init(x:position.x-3,y:position.y-measured.height/2-1,width:measured.width+6,height:measured.height+2),cornerRadius:2),with:.color(labelBackground))}
                                context.draw(resolved,at:position,anchor:.leading)
                            }
                        }
                    }.frame(width:geometry.size.width,height:height+40)
                    .gesture(SpatialTapGesture().onEnded{value in selected=positions.indices.min{a,b in hypot(20+positions[a].x/span*plotWidth-value.location.x,20+(positions[a].y-Double(page*100))*32-value.location.y)<hypot(20+positions[b].x/span*plotWidth-value.location.x,20+(positions[b].y-Double(page*100))*32-value.location.y)}})
                }.biologyCanvas().accessibilityIdentifier("biology.treeViewport")
                }.frame(minHeight:260,maxHeight:440)
                if let selected,tree.nodes.indices.contains(selected) {let node=tree.nodes[selected];Text(node.label+" · "+(node.length.map{String($0)} ?? biologyText("No branch length","无分支长度"))).textSelection(.enabled).padding(.horizontal)}
                BiologyViewFootnote(text:"\(tree.leaves.count) "+biologyText("leaves · saved Newick topology","个叶节点 · Newick 拓扑"),symbol:"point.3.connected.trianglepath.dotted")
                Spacer(minLength:0)
            } else if let error {Text(error).padding()}else{ProgressView()}
        }.padding(BiologyStyle.spacing).background(BiologyStyle.background).task {do {tree=try await biologyViewCompute{try BiologyTree.parse(data)};applySelection()}catch{self.error=error.localizedDescription}}
        .onChange(of:selection){_,_ in applySelection()}
    }
    private func applySelection(){selected=selection?["nodeID"]?.string.flatMap(Int.init);if let tree,let selected,tree.nodes.indices.contains(selected){page=Int(tree.layout()[selected].y)/100}}
}

@MainActor struct BiologyDensityView:View {
    let data:Data
    var selection:JSONValue?
    @State private var volume:BiologyDensityVolume?
    @State private var axis=2
    @State private var index=0
    @State private var surface=false
    @State private var isovalue=0.0
    @State private var stride=1
    @State private var image:MicroscopyImage?
    @State private var scene:SCNScene?
    @State private var resetToken=0
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Picker(biologyText("Density view","密度视图"),selection:$surface) {Text(biologyText("Slice","切片")).tag(false);Text(biologyText("Surface","等值面")).tag(true)}.pickerStyle(.segmented).frame(minHeight:44)
            if let volume {
                if surface {
                    ViewThatFits(in:.horizontal) {
                        HStack(alignment:.bottom,spacing:16){isovalueField;samplingControl;fitButton}
                        VStack(spacing:12){isovalueField;HStack{samplingControl;fitButton}}
                    }.font(.subheadline)
                    if let scene {BiologyMeshScene(scene:scene,resetToken:resetToken).biologyCanvas().accessibilityIdentifier("biology.densitySurface")}
                    else if let error{ContentUnavailableView(biologyText("No surface to display","没有可显示的等值面"),systemImage:"cube.transparent",description:Text(error))}
                    else {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
                } else {
                    HStack {Picker(biologyText("Axis","轴"),selection:$axis){Text("X").tag(0);Text("Y").tag(1);Text("Z").tag(2)}.pickerStyle(.segmented);Stepper("\(index+1) / \(volume.dimensions[axis])",value:$index,in:0...volume.dimensions[axis]-1)}.font(.subheadline).frame(minHeight:44)
                    if let image {BiologyMicroscopyView(image:image,result:nil,channel:.constant(0),slice:.constant(0),frame:.constant(0),showsControls:false)}
                }
                Text("\(volume.dimensions.x) × \(volume.dimensions.y) × \(volume.dimensions.z) · "+biologyText("coordinates in Å","坐标单位为埃")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }else{ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
            if let error {Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding()}
        }.padding(BiologyStyle.spacing).background(BiologyStyle.background).task(id:data) {
            do {let parsed=try await biologyViewCompute{try BiologyDensityVolume.parse(data)};volume=parsed;axis=Int(selection?["axis"]?.number ?? 2);axis=min(2,max(0,axis));index=min(parsed.dimensions[axis]-1,max(0,Int(selection?["index"]?.number ?? Double(parsed.dimensions[axis]/2))));isovalue=parsed.values.reduce(0,+)/Double(parsed.values.count);await redraw()}
            catch {self.error=error.localizedDescription}
        }.task(id:"\(surface):\(axis):\(index):\(isovalue):\(stride)"){await redraw()}
        .onChange(of:axis){_,_ in if let volume{index=min(index,volume.dimensions[axis]-1)}}
        .onChange(of:selection){_,s in if let volume{axis=min(2,max(0,Int(s?["axis"]?.number ?? 2)));index=min(volume.dimensions[axis]-1,max(0,Int(s?["index"]?.number ?? 0)))}}
    }
    private var isovalueField:some View {
        TextField("",value:$isovalue,format:.number.precision(.significantDigits(1...4))).keyboardType(.decimalPad).biologyNamedInput(biologyText("Isovalue","等值")).frame(maxWidth:240)
    }
    private var samplingControl:some View {
        VStack(alignment:.leading,spacing:8){
            Text(biologyText("Sampling","采样")).font(.subheadline)
            Stepper(String(stride),value:$stride,in:1...4).frame(minHeight:44)
        }
    }
    private var fitButton:some View{Button{resetToken+=1}label:{Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:44,height:44)}.buttonStyle(BiologyControlButtonStyle(compact:true)).accessibilityLabel(biologyText("Fit","适合窗口"))}
    private func redraw() async {
        guard let volume else {return};error=nil
        do {
            if surface {
                scene=nil;let value=isovalue,step=stride
                let mesh=try await biologyViewCompute{try volume.isosurface(value:value,stride:step)}
                guard !mesh.vertices.isEmpty else{throw BiologyError.unavailable(biologyText("Choose a different isovalue.","请调整等值。"))}
                try Task.checkCancellation();scene=BiologyMeshScene.makeScene(mesh)
            } else {let slice=try volume.slice(axis:axis,index:index);image=MicroscopyImage(width:slice.width,height:slice.height,samples:slice.values)}
        }catch is CancellationError {}catch{self.error=error.localizedDescription}
    }
}
#endif
