// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Charts
import UIKit
import FloeBiologyCore

struct BiologySequenceView:View {
    let records:[SequenceRecord]
    @Binding var recordIndex:Int
    @State private var circular=false
    @State private var page=0
    private var record:SequenceRecord? {records.indices.contains(recordIndex) ? records[recordIndex]:nil}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(biologyText("Record","记录"),selection:$recordIndex) {
                ForEach(Array(records.enumerated()),id:\.element.id) { i,r in Text(r.name).tag(i) }
            }.accessibilityIdentifier("biology.sequenceRecord")
            Toggle(biologyText("Circular view","环形视图"),isOn:$circular).toggleStyle(.switch)
            if let record {
                if circular {circularMap(record).frame(minHeight:220,maxHeight:320)}
                else {linearFeatures(record).frame(height:max(50,CGFloat(min(record.annotations.count,8))*24+24))}
                HStack {
                    Text("\(record.sequence.count) "+biologyText("symbols · "+record.alphabet.uppercased(),"个字符 · "+record.alphabet.uppercased())).font(.subheadline)
                    Spacer()
                    Button {page=max(0,page-1)} label:{Image(systemName:"chevron.left")}.disabled(page==0).frame(minWidth:44,minHeight:44)
                    Button {page=min(max(0,(record.sequence.count-1)/2000),page+1)} label:{Image(systemName:"chevron.right")}.disabled((page+1)*2000>=record.sequence.count).frame(minWidth:44,minHeight:44)
                }
                let start=min(page*2000,max(0,record.sequence.count-1))
                let chars=Array(record.sequence),end=min(chars.count,start+2000)
                ScrollView([.vertical,.horizontal]) {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(Array(stride(from:start,to:end,by:60)),id:\.self) { offset in
                            HStack(alignment:.top,spacing:12) {
                                Text(String(offset+1)).foregroundStyle(.secondary).frame(width:60,alignment:.trailing)
                                Text(String(chars[offset..<min(end,offset+60)])).textSelection(.enabled)
                            }.font(.system(.body,design:.monospaced))
                        }
                    }.padding(.vertical,8)
                }.accessibilityIdentifier("biology.sequenceViewport")
                if !record.annotations.isEmpty {
                    Text(biologyText("Annotations · coordinates shown as 1-based inclusive","注释 · 坐标显示为从 1 开始的闭区间")).font(.caption).foregroundStyle(.secondary)
                    ForEach(record.annotations.prefix(12)) { a in HStack {Text(a.name);Spacer();Text("\(a.start+1)…\(a.end) "+(a.strand<0 ? "←":"→")).monospacedDigit()}.font(.caption) }
                }
            }
        }.padding()
        .onChange(of:recordIndex){_,_ in page=0}
    }
    private func linearFeatures(_ r:SequenceRecord)->some View {
        Canvas { context,size in
            let count=max(1,r.sequence.count),y:CGFloat=12
            var baseline=Path();baseline.move(to:.init(x:0,y:y));baseline.addLine(to:.init(x:size.width,y:y))
            context.stroke(baseline,with:.color(.secondary),lineWidth:2)
            for (i,a) in r.annotations.prefix(8).enumerated() {
                let rect=CGRect(x:CGFloat(a.start)/CGFloat(count)*size.width,y:CGFloat(i)*24+20,width:max(3,CGFloat(a.end-a.start)/CGFloat(count)*size.width),height:12)
                context.fill(Path(roundedRect:rect,cornerRadius:3),with:.color(a.strand<0 ? .orange:.teal))
            }
        }.accessibilityLabel(biologyText("Sequence annotation overview","序列注释总览"))
    }
    private func circularMap(_ r:SequenceRecord)->some View {
        Canvas { context,size in
            let radius=min(size.width,size.height)/2-24,center=CGPoint(x:size.width/2,y:size.height/2)
            context.stroke(Path(ellipseIn:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)),with:.color(.secondary),lineWidth:2)
            for a in r.annotations.prefix(1000) {
                var path=Path();path.addArc(center:center,radius:radius,startAngle:.degrees(Double(a.start)/Double(max(r.sequence.count,1))*360-90),endAngle:.degrees(Double(a.end)/Double(max(r.sequence.count,1))*360-90),clockwise:false)
                context.stroke(path,with:.color(a.strand<0 ? .orange:.teal),style:.init(lineWidth:10,lineCap:.round))
            }
            context.draw(Text("\(r.sequence.count)\n"+biologyText("symbols","个字符")).font(.headline),at:center)
        }
    }
}
struct BiologyStructureView:View {
    let structure:ProteinStructure
    @Binding var selectedAtoms:[Int]
    @Binding var modelNumber:Int
    @Binding var chain:String
    @State private var angleX=0.25
    @State private var angleY=0.4
    @State private var dragStart:CGSize?
    @State private var zoom=1.0
    @State private var backbone=true
    private var filtered:[StructureAtom] {structure.atoms.filter{$0.model==modelNumber && (chain.isEmpty || $0.chain==chain)}}
    private struct Point:Identifiable {let atom:StructureAtom;let point:CGPoint;let depth:Double;var id:Int{atom.id}}
    private func points(_ size:CGSize)->[Point] {
        let all=filtered,atoms=Array((backbone ? all.filter{$0.name=="CA" && !$0.hetero}:all).prefix(5000))
        guard !atoms.isEmpty else{return []}
        let cx=atoms.map(\.x).reduce(0,+)/Double(atoms.count),cy=atoms.map(\.y).reduce(0,+)/Double(atoms.count),cz=atoms.map(\.z).reduce(0,+)/Double(atoms.count)
        let span=max(atoms.map{max(abs($0.x-cx),abs($0.y-cy),abs($0.z-cz))}.max() ?? 1,1)
        let scale=Double(min(size.width,size.height))*0.37/span*zoom
        return atoms.map{a in
            let xx=a.x-cx,yy=a.y-cy,zz=a.z-cz
            let x=xx*cos(angleY)+zz*sin(angleY),z = -xx*sin(angleY)+zz*cos(angleY)
            let y=yy*cos(angleX)-z*sin(angleX),depth=yy*sin(angleX)+z*cos(angleX)
            return Point(atom:a,point:.init(x:Double(size.width)/2+x*scale,y:Double(size.height)/2-y*scale),depth:depth)
        }
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Picker(biologyText("Representation","显示"),selection:$backbone) {
                    Text(biologyText("Backbone","主链")).tag(true);Text(biologyText("Atoms","原子")).tag(false)
                }.pickerStyle(.segmented).frame(maxWidth:240)
                Spacer()
                Button(biologyText("Fit","适合窗口"),systemImage:"arrow.up.left.and.arrow.down.right") {zoom=1;angleX=0.25;angleY=0.4}.frame(minHeight:44).accessibilityIdentifier("biology.structureFit")
            }.padding()
            GeometryReader { proxy in
                let projected=points(proxy.size)
                Canvas { context,size in
                    if backbone {
                        var previous:Point?
                        for p in projected {
                            if let last=previous,last.atom.chain==p.atom.chain,last.atom.model==p.atom.model,
                               abs(last.atom.residueNumber-p.atom.residueNumber)==1 {
                                let d=pow(last.atom.x-p.atom.x,2)+pow(last.atom.y-p.atom.y,2)+pow(last.atom.z-p.atom.z,2)
                                if d<30 {var line=Path();line.move(to:last.point);line.addLine(to:p.point);context.stroke(line,with:.color(.teal),style:.init(lineWidth:4,lineCap:.round))}
                            }
                            previous=p
                        }
                    }
                    for p in projected.sorted(by:{$0.depth<$1.depth}) {
                        let chosen=selectedAtoms.contains(p.atom.id),radius:CGFloat=chosen ? 7:(backbone ? 3:2.5)
                        let rect=CGRect(x:p.point.x-radius,y:p.point.y-radius,width:radius*2,height:radius*2)
                        context.fill(Path(ellipseIn:rect),with:.color(chosen ? .orange:(p.atom.element=="O" ? .red:p.atom.element=="N" ? .blue:.teal)))
                    }
                }
                .background(Color(uiColor:.secondarySystemBackground))
                .gesture(DragGesture(minimumDistance:3).onChanged{v in
                    let previous=dragStart ?? .zero
                    angleY+=Double(v.translation.width-previous.width)*0.01
                    angleX+=Double(v.translation.height-previous.height)*0.01
                    dragStart=v.translation
                }.onEnded{_ in dragStart=nil})
                .simultaneousGesture(SpatialTapGesture().onEnded{v in
                    if let nearest=projected.min(by:{hypot($0.point.x-v.location.x,$0.point.y-v.location.y)<hypot($1.point.x-v.location.x,$1.point.y-v.location.y)}),hypot(nearest.point.x-v.location.x,nearest.point.y-v.location.y)<24 {
                        if selectedAtoms.contains(nearest.id){selectedAtoms.removeAll{$0==nearest.id}}
                        else {selectedAtoms=Array((selectedAtoms+[nearest.id]).suffix(2))}
                    }
                })
                .accessibilityIdentifier("biology.structureViewport")
                .accessibilityLabel(biologyText("Native 3D structure. Drag to rotate; tap atoms to select.","原生三维结构。拖动旋转，轻点选择原子。"))
            }
            HStack {Image(systemName:"minus.magnifyingglass");Slider(value:$zoom,in:0.3...3).accessibilityLabel(biologyText("Structure zoom","结构缩放"));Image(systemName:"plus.magnifyingglass")}.padding(.horizontal)
            Text(biologyText("Actual coordinates · Cα backbone · Å","真实坐标 · Cα 主链 · 埃")).font(.caption).foregroundStyle(.secondary).padding(8)
            if filtered.count>5000 && !backbone {Text(biologyText("Showing the first 5,000 atoms. Select a chain for a closer view.","当前显示前 5,000 个原子，可选择链缩小范围。")).font(.caption).foregroundStyle(.secondary)}
        }
    }
}
struct BiologyMicroscopyView:View {
    let image:MicroscopyImage
    let result:BiologyAnalysisResult?
    @Binding var channel:Int
    @Binding var slice:Int
    @Binding var frame:Int
    @State private var overlay=true
    private var pixels:[Double] {(try? image.plane(channel:channel,slice:slice,frame:frame)) ?? []}
    private func displayImage(_ pixels:[Double])->UIImage? {
        guard pixels.count==image.width*image.height else{return nil}
        let low=pixels.min() ?? 0,high=pixels.max() ?? 1,span=max(high-low,1e-12)
        let data=Data(pixels.map{UInt8(min(255,max(0,Int(($0-low)/span*255))))})
        guard let provider=CGDataProvider(data:data as CFData),
              let cg=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:image.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{return nil}
        return UIImage(cgImage:cg)
    }
    var body:some View {
        VStack(alignment:.leading) {
            HStack {
                if image.channels>1 {Stepper("C \(channel+1)",value:$channel,in:0...image.channels-1)}
                if image.slices>1 {Stepper("Z \(slice+1)",value:$slice,in:0...image.slices-1)}
                if image.frames>1 {Stepper("T \(frame+1)",value:$frame,in:0...image.frames-1)}
                Toggle(biologyText("Labels","标记"),isOn:$overlay).frame(maxWidth:140)
            }.padding()
            GeometryReader { geometry in
                let size=geometry.size,scale=min(size.width/CGFloat(image.width),size.height/CGFloat(image.height))
                let w=CGFloat(image.width)*scale,h=CGFloat(image.height)*scale
                ZStack {
                    if let ui=displayImage(pixels) {Image(uiImage:ui).resizable().interpolation(.none).frame(width:w,height:h)}
                    if overlay,let result,result.labels.count==pixels.count,
                       result.details["channel"]==String(channel),result.details["slice"]==String(slice),result.details["frame"]==String(frame) {
                        Canvas { context,_ in
                            for i in result.labels.indices where result.labels[i]>0 {
                                let x=i%image.width,y=i/image.width,label=result.labels[i]
                                if x==0 || y==0 || x==image.width-1 || y==image.height-1 || result.labels[i-1] != label || result.labels[i+1] != label || result.labels[i-image.width] != label || result.labels[i+image.width] != label {
                                    context.fill(Path(CGRect(x:CGFloat(x)*scale,y:CGFloat(y)*scale,width:scale,height:scale)),with:.color(.orange.opacity(0.8)))
                                }
                            }
                        }.frame(width:w,height:h)
                    }
                }.frame(width:size.width,height:size.height)
            }.accessibilityIdentifier("biology.imageViewport")
            Text("\(image.width) × \(image.height) · \(image.bitDepth) bit · "+(image.pixelSizeX.map{String($0)+" "+image.calibrationUnit+"/px"} ?? biologyText("Uncalibrated pixels","未标定像素")))
                .font(.caption).foregroundStyle(.secondary).padding()
        }
    }
}
struct BiologyMatrixView:View {
    let matrix:ExpressionMatrix
    @State private var gene=0
    @State private var cell=0
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("\(matrix.geneIDs.count) "+biologyText("genes × ","个基因 × ")+"\(matrix.cellIDs.count) "+biologyText("cells","个细胞")).font(.headline)
            GeometryReader { proxy in
                let rows=min(40,matrix.geneIDs.count),columns=min(24,matrix.cellIDs.count),maximum=max(matrix.values.max() ?? 1,1)
                Canvas { context,size in
                    for i in 0..<rows {for j in 0..<columns {
                        let value=matrix.values[i*matrix.cellIDs.count+j]
                        let rect=CGRect(x:CGFloat(j)*size.width/CGFloat(columns),y:CGFloat(i)*size.height/CGFloat(rows),width:size.width/CGFloat(columns)-1,height:size.height/CGFloat(rows)-1)
                        context.fill(Path(rect),with:.color(.teal.opacity(0.08+0.92*value/maximum)))
                    }}
                }.accessibilityIdentifier("biology.matrixHeatmap")
            }.frame(minHeight:200,maxHeight:400)
            Text(biologyText("Preview: up to 40 gene rows × 24 cell columns. Original counts are retained.","预览最多 40 行基因 × 24 列细胞，完整原始计数保留。")).font(.caption).foregroundStyle(.secondary)
            Picker(biologyText("Gene","基因"),selection:$gene) {ForEach(matrix.geneIDs.indices,id:\.self){Text(matrix.geneIDs[$0]).tag($0)}}
            Picker(biologyText("Cell","细胞"),selection:$cell) {ForEach(matrix.cellIDs.indices,id:\.self){Text(matrix.cellIDs[$0]).tag($0)}}
            if matrix.geneIDs.indices.contains(gene),matrix.cellIDs.indices.contains(cell) {
                LabeledContent(biologyText("Count","计数"),value:matrix.values[gene*matrix.cellIDs.count+cell].formatted())
            }
        }.padding()
    }
}
struct BiologyNetworkView:View {
    let network:BiochemicalNetwork
    let result:BiologyAnalysisResult?
    var body:some View {
        VStack {
            GeometryReader { proxy in
                let shown=Array(network.species.prefix(16)),radius=min(proxy.size.width,proxy.size.height)*0.34
                let points=Dictionary(uniqueKeysWithValues:shown.enumerated().map{i,s in
                    (s.id,CGPoint(x:proxy.size.width/2+cos(Double(i)/Double(shown.count)*2*Double.pi)*radius,y:proxy.size.height/2+sin(Double(i)/Double(shown.count)*2*Double.pi)*radius))
                })
                Canvas {context,size in
                    for r in network.reactions {
                        for a in r.reactants.keys {for b in r.products.keys {
                            if let aa=points[a],let bb=points[b] {
                                var path=Path();path.move(to:aa);path.addLine(to:bb);context.stroke(path,with:.color(.secondary),lineWidth:2)
                                let angle=atan2(bb.y-aa.y,bb.x-aa.x),end=CGPoint(x:bb.x-cos(angle)*26,y:bb.y-sin(angle)*26)
                                var arrow=Path();arrow.move(to:.init(x:end.x-cos(angle-0.5)*10,y:end.y-sin(angle-0.5)*10));arrow.addLine(to:end);arrow.addLine(to:.init(x:end.x-cos(angle+0.5)*10,y:end.y-sin(angle+0.5)*10));context.stroke(arrow,with:.color(.secondary),lineWidth:2)
                            }
                        }}
                    }
                    for s in shown {
                        let p=points[s.id]!,rect=CGRect(x:p.x-25,y:p.y-25,width:50,height:50)
                        context.fill(Path(ellipseIn:rect),with:.color(.teal.opacity(0.15)))
                        context.stroke(Path(ellipseIn:rect),with:.color(.teal),lineWidth:1)
                        context.draw(Text(s.id).font(.headline),at:p)
                    }
                }.accessibilityIdentifier("biology.networkViewport")
            }.frame(minHeight:220,maxHeight:320)
            if network.species.count>16 {Text(biologyText("Graph shows the first 16 species; the model retains every species.","图中显示前 16 个物种，模型保留完整数据。")).font(.caption)}
            if let result,result.columns.first=="time" {
                Chart {
                    ForEach(Array(result.columns.dropFirst().enumerated()),id:\.offset){j,name in
                        ForEach(Array(result.rows.enumerated()),id:\.offset){_,row in
                            if row.count>j+1 {LineMark(x:.value("Time",row[0]),y:.value("Amount",row[j+1])).foregroundStyle(by:.value("Species",name))}
                        }
                    }
                }.chartXAxisLabel(network.timeUnit).chartYAxisLabel(network.amountUnit).frame(height:220).padding()
            }
            ForEach(network.reactions){r in
                HStack {Text(r.reactants.keys.sorted().map{"\($0) × \(r.reactants[$0]!)"}.joined(separator:" + ")+" → "+r.products.keys.sorted().map{"\($0) × \(r.products[$0]!)"}.joined(separator:" + "));Spacer();Text("k = "+r.rateConstant.formatted()).monospacedDigit()}.font(.subheadline).padding(.horizontal)
            }
        }
    }
}
#endif
