// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Charts
import UIKit
import FloeBiologyCore

struct BiologySequenceView:View {
    let records:[SequenceRecord]
    @Binding var recordIndex:Int
    var selectedRange:Range<Int>?=nil
    @State private var circular=false
    @State private var page=0
    private var record:SequenceRecord? {records.indices.contains(recordIndex) ? records[recordIndex]:nil}
    var body:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:16) {
            BiologyChoiceField(title:biologyText("Record","记录"),selection:$recordIndex,value:record?.name ?? biologyText("Choose record","选择记录"),identifier:"biology.sequenceRecord") {
                ForEach(Array(records.enumerated()),id:\.element.id) { i,r in Text(r.name).tag(i) }
            }
            Toggle(biologyText("Circular view","环形视图"),isOn:$circular).toggleStyle(.switch).font(.subheadline)
            if let record {
                if circular {circularMap(record).frame(height:260).biologyCanvas()}
                else {linearFeatures(record).frame(height:max(78,CGFloat(min(record.annotations.count,8))*24+52)).biologyCanvas()}
                HStack {
                    Text(biologyText("Sequence","序列")).font(.headline)
                    Text("\(record.sequence.count) · "+record.alphabet.uppercased()).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button {page=max(0,page-1)} label:{Image(systemName:"chevron.left").frame(width:44,height:44)}.buttonStyle(BiologyControlButtonStyle(compact:true)).disabled(page==0)
                    Button {page=min(max(0,(record.sequence.count-1)/2000),page+1)} label:{Image(systemName:"chevron.right").frame(width:44,height:44)}.buttonStyle(BiologyControlButtonStyle(compact:true)).disabled((page+1)*2000>=record.sequence.count)
                }
                let start=min(page*2000,max(0,record.sequence.count-1))
                let chars=Array(record.sequence),end=min(chars.count,start+2000)
                ScrollView([.vertical,.horizontal]) {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(Array(stride(from:start,to:end,by:60)),id:\.self) { offset in
                            HStack(alignment:.top,spacing:12) {
                                Text(String(offset+1)).foregroundStyle(.secondary).frame(width:48,alignment:.trailing)
                                Text(highlight(String(chars[offset..<min(end,offset+60)]),offset:offset)).textSelection(.enabled)
                            }.font(.system(.body,design:.monospaced))
                        }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(height:CGFloat(min(360,max(110,((end-start+59)/60)*32+32)))).biologyCanvas().accessibilityIdentifier("biology.sequenceViewport")
                if !record.annotations.isEmpty {
                    Text(biologyText("Annotations · coordinates shown as 1-based inclusive","注释 · 坐标显示为从 1 开始的闭区间")).font(.caption).foregroundStyle(.secondary)
                    ForEach(record.annotations.prefix(12)) { a in HStack {Text(a.name);Spacer();Text("\(a.start+1)…\(a.end) "+(a.strand<0 ? "←":"→")).monospacedDigit()}.font(.caption) }
                }
            }
        }.padding(BiologyStyle.spacing).frame(maxWidth:BiologyStyle.contentWidth,alignment:.topLeading).frame(maxWidth:.infinity)
        }.background(BiologyStyle.background)
        .onChange(of:recordIndex){_,_ in page=0}
        .onChange(of:selectedRange,initial:true){_,range in if let range{page=range.lowerBound/2000}}
    }
    private func highlight(_ text:String,offset:Int)->AttributedString {
        var value=AttributedString(text)
        if let range=selectedRange {
            let lo=max(0,range.lowerBound-offset),hi=min(text.count,range.upperBound-offset)
            if lo<hi {let a=value.index(value.startIndex,offsetByCharacters:lo),b=value.index(value.startIndex,offsetByCharacters:hi);value[a..<b].backgroundColor = .orange.opacity(0.25)}
        };return value
    }
    private func linearFeatures(_ r:SequenceRecord)->some View {
        Canvas { context,size in
            let count=max(1,r.sequence.count),y:CGFloat=12
            var baseline=Path();baseline.move(to:.init(x:16,y:y));baseline.addLine(to:.init(x:size.width-16,y:y))
            context.stroke(baseline,with:.color(.secondary.opacity(0.6)),lineWidth:1)
            for tick in 0...4 {let x=16+CGFloat(tick)/4*(size.width-32);var line=Path();line.move(to:.init(x:x,y:y));line.addLine(to:.init(x:x,y:y+5));context.stroke(line,with:.color(.secondary),lineWidth:1);context.draw(Text(String(max(1,Int(Double(tick)/4*Double(r.sequence.count))))).font(.caption2).foregroundStyle(.primary),at:.init(x:x,y:y+17))}
            if r.annotations.isEmpty {context.draw(Text(biologyText("No annotated features","暂无注释区域")).font(.caption).foregroundStyle(.secondary),at:.init(x:16,y:55),anchor:.leading)}
            for (i,a) in r.annotations.prefix(8).enumerated() {
                let rect=CGRect(x:16+CGFloat(a.start)/CGFloat(count)*(size.width-32),y:CGFloat(i)*24+40,width:max(3,CGFloat(a.end-a.start)/CGFloat(count)*(size.width-32)),height:12)
                context.fill(Path(roundedRect:rect,cornerRadius:3),with:.color(a.strand<0 ? .orange:.teal))
            }
        }.padding(.horizontal,12).accessibilityLabel(biologyText("Sequence annotation overview","序列注释总览"))
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
struct BiologyMicroscopyView:View {
    let image:MicroscopyImage
    let result:BiologyAnalysisResult?
    @Binding var channel:Int
    @Binding var slice:Int
    @Binding var frame:Int
    var selectedRegion:[Int]?=nil
    var showsControls=true
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
            if showsControls {HStack {
                if image.channels>1 {Stepper("C \(channel+1)",value:$channel,in:0...image.channels-1)}
                if image.slices>1 {Stepper("Z \(slice+1)",value:$slice,in:0...image.slices-1)}
                if image.frames>1 {Stepper("T \(frame+1)",value:$frame,in:0...image.frames-1)}
                if image.channels==1 && image.slices==1 && image.frames==1 {Text(biologyText("Image plane","图像平面")).font(.subheadline).foregroundStyle(.secondary)}
                Spacer(minLength:12)
                if result?.labels.count==pixels.count {Toggle(biologyText("Labels","标记"),isOn:$overlay).frame(maxWidth:140)}
            }.frame(minHeight:44)}
            GeometryReader { geometry in
                let size=geometry.size,scale=min(size.width/CGFloat(image.width),size.height/CGFloat(image.height))
                let w=CGFloat(image.width)*scale,h=CGFloat(image.height)*scale
                ZStack {
                    if let ui=displayImage(pixels) {Image(uiImage:ui).resizable().interpolation(.none).frame(width:w,height:h)}
                    if let r=selectedRegion,r.count==4 {
                        Canvas{context,_ in context.stroke(Path(CGRect(x:CGFloat(r[0])*scale,y:CGFloat(r[1])*scale,width:CGFloat(r[2])*scale,height:CGFloat(r[3])*scale)),with:.color(.orange),lineWidth:2)}.frame(width:w,height:h)
                    }
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
            }.background(Color.black).clipShape(RoundedRectangle(cornerRadius:14)).accessibilityIdentifier("biology.imageViewport")
            if showsControls {Text("\(image.width) × \(image.height) · \(image.bitDepth) bit · "+(image.pixelSizeX.map{String($0)+" "+image.calibrationUnit+"/px"} ?? biologyText("Uncalibrated pixels","未标定像素")))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().padding(.top,12)}
        }.padding(showsControls ? BiologyStyle.spacing:0).background(BiologyStyle.background)
    }
}
struct BiologyMatrixView:View {
    let matrix:ExpressionMatrix
    var selection:JSONValue?=nil
    @State private var gene=0
    @State private var cell=0
    var body:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:20) {
            BiologySectionHeading(title:biologyText("Expression matrix","表达矩阵"),detail:"\(matrix.geneIDs.count) × \(matrix.cellIDs.count)")
            let rows=min(40,matrix.geneIDs.count),columns=min(24,matrix.cellIDs.count),maximum=max(matrix.values.max() ?? 1,1),selectedGene=gene,selectedCell=cell
            Canvas { context,size in
                let left:CGFloat=76,top:CGFloat=16,width=max(1,size.width-left-16),height=max(1,size.height-58)
                for i in 0..<rows {
                    let cy=top+(CGFloat(i)+0.5)*height/CGFloat(rows),labelStep=max(1,Int(ceil(18/(height/CGFloat(rows)))))
                    if i%labelStep==0 || i==selectedGene {context.draw(Text(String(matrix.geneIDs[i].prefix(12))).font(.caption).foregroundStyle(.primary),at:.init(x:left-10,y:cy),anchor:.trailing)}
                    for j in 0..<columns {
                        let value=matrix.values[i*matrix.cellIDs.count+j],rect=CGRect(x:left+CGFloat(j)*width/CGFloat(columns),y:top+CGFloat(i)*height/CGFloat(rows),width:width/CGFloat(columns)-2,height:height/CGFloat(rows)-2)
                        context.fill(Path(roundedRect:rect,cornerRadius:2),with:.color(.teal.opacity(0.08+0.92*max(0,min(1,value/maximum)))))
                        if (i==selectedGene && j==selectedCell) || selection?["genes"]?.array?.contains(.string(matrix.geneIDs[i]))==true || selection?["cells"]?.array?.contains(.string(matrix.cellIDs[j]))==true {context.stroke(Path(roundedRect:rect,cornerRadius:2),with:.color(.orange),lineWidth:2)}
                    }
                }
                for j in Swift.stride(from:0,to:columns,by:max(1,Int(ceil(56/(width/CGFloat(columns)))))) {context.draw(Text(String(matrix.cellIDs[j].prefix(8))).font(.caption2).foregroundStyle(.primary),at:.init(x:left+(CGFloat(j)+0.5)*width/CGFloat(columns),y:top+height+12),anchor:.top)}
            }.frame(height:min(440,max(220,CGFloat(rows)*32+58))).biologyCanvas().accessibilityLabel(biologyText("Expression heatmap","表达热图")).accessibilityIdentifier("biology.matrixHeatmap")
            HStack {Text("0");Rectangle().fill(LinearGradient(colors:[.teal.opacity(0.08),.teal],startPoint:.leading,endPoint:.trailing)).frame(width:100,height:7);Text(maximum.formatted(.number.precision(.significantDigits(1...4))));Spacer();Text(biologyText("Genes × cells","基因 × 细胞"))}.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ViewThatFits(in:.horizontal){
                HStack(alignment:.top,spacing:16){geneField.frame(minWidth:220);cellField.frame(minWidth:220)}
                VStack(alignment:.leading,spacing:16){geneField;cellField}
            }
            if matrix.geneIDs.indices.contains(gene),matrix.cellIDs.indices.contains(cell){LabeledContent{Text(matrix.values[gene*matrix.cellIDs.count+cell].formatted()).foregroundStyle(.primary).fontWeight(.medium)}label:{Text(biologyText("Selected value","选中值"))}.font(.subheadline).monospacedDigit().accessibilityElement(children:.combine).accessibilityLabel(biologyText("Selected value","选中值")).accessibilityValue(matrix.values[gene*matrix.cellIDs.count+cell].formatted()).accessibilityIdentifier("biology.matrixSelectedValue")}
            if matrix.geneIDs.count>40 || matrix.cellIDs.count>24 {BiologyViewFootnote(text:biologyText("Preview: 40 gene rows × 24 cell columns. Export includes the full matrix.","预览 40 行基因 × 24 列细胞，导出包含完整矩阵。"))}
        }.padding(BiologyStyle.spacing).frame(maxWidth:BiologyStyle.contentWidth).frame(maxWidth:.infinity)
        }.background(BiologyStyle.background)
        .onChange(of:selection,initial:true){_,s in
            if let id=s?["genes"]?.array?.first?.string,let i=matrix.geneIDs.firstIndex(of:id){gene=i}
            if let id=s?["cells"]?.array?.first?.string,let i=matrix.cellIDs.firstIndex(of:id){cell=i}
        }
    }
    private var geneField:some View {
        BiologyChoiceField(title:biologyText("Gene","基因"),selection:$gene,value:matrix.geneIDs.indices.contains(gene) ? matrix.geneIDs[gene]:"",identifier:"biology.geneField"){ForEach(matrix.geneIDs.indices,id:\.self){Text(matrix.geneIDs[$0]).tag($0)}}.frame(maxWidth:.infinity)
    }
    private var cellField:some View {
        BiologyChoiceField(title:biologyText("Cell","细胞"),selection:$cell,value:matrix.cellIDs.indices.contains(cell) ? matrix.cellIDs[cell]:"",identifier:"biology.cellField"){ForEach(matrix.cellIDs.indices,id:\.self){Text(matrix.cellIDs[$0]).tag($0)}}.frame(maxWidth:.infinity)
    }
}
struct BiologyNetworkView:View {
    let network:BiochemicalNetwork
    let result:BiologyAnalysisResult?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            BiologySectionHeading(title:biologyText("Reaction network","反应网络"),detail:"\(network.species.count) "+biologyText("species","个物种"))
            GeometryReader { proxy in
                let shown=Array(network.species.prefix(16)),radius=min(proxy.size.width,proxy.size.height)*0.34
                let points=Dictionary(uniqueKeysWithValues:shown.enumerated().map{i,s in
                    (s.id,CGPoint(x:proxy.size.width/2+cos(Double.pi+Double(i)/Double(shown.count)*2*Double.pi)*radius,y:proxy.size.height/2+sin(Double.pi+Double(i)/Double(shown.count)*2*Double.pi)*radius))
                })
                Canvas {context,size in
                    for r in network.reactions {
                        for a in r.reactants.keys {for b in r.products.keys {
                            if let aa=points[a],let bb=points[b] {
                                let angle=atan2(bb.y-aa.y,bb.x-aa.x),start=CGPoint(x:aa.x+cos(angle)*34,y:aa.y+sin(angle)*34),end=CGPoint(x:bb.x-cos(angle)*34,y:bb.y-sin(angle)*34)
                                var path=Path();path.move(to:start);path.addLine(to:end);context.stroke(path,with:.color(.secondary),lineWidth:1.5)
                                var arrow=Path();arrow.move(to:.init(x:end.x-cos(angle-0.5)*10,y:end.y-sin(angle-0.5)*10));arrow.addLine(to:end);arrow.addLine(to:.init(x:end.x-cos(angle+0.5)*10,y:end.y-sin(angle+0.5)*10));context.stroke(arrow,with:.color(.secondary),lineWidth:2)
                            }
                        }}
                    }
                    for s in shown {
                        let p=points[s.id]!,rect=CGRect(x:p.x-32,y:p.y-32,width:64,height:64)
                        context.fill(Path(ellipseIn:rect),with:.color(.teal.opacity(0.1)))
                        context.stroke(Path(ellipseIn:rect),with:.color(.teal),lineWidth:1)
                        context.draw(Text(String(s.id.prefix(8))).font(.subheadline.weight(.semibold)),at:p)
                    }
                }.accessibilityIdentifier("biology.networkViewport")
            }.frame(height:network.species.count>8 ? 520:network.species.count>4 ? 360:260).biologyCanvas()
            if network.species.count>16 {Text(biologyText("Graph shows the first 16 species; the model retains every species.","图中显示前 16 个物种，模型保留完整数据。")).font(.caption)}
            if let result,result.columns.first=="time" {
                BiologyTimeCoursePlot(result:result,timeUnit:network.timeUnit,amountUnit:network.amountUnit)
            }
            ForEach(network.reactions){r in
                HStack {Text(r.reactants.keys.sorted().map{"\($0) × \(r.reactants[$0]!)"}.joined(separator:" + ")+" → "+r.products.keys.sorted().map{"\($0) × \(r.products[$0]!)"}.joined(separator:" + "));Spacer();Text("k = "+r.rateConstant.formatted()).monospacedDigit()}.font(.subheadline).padding(.vertical,10)
            }
        }.padding(BiologyStyle.spacing).frame(maxWidth:BiologyStyle.contentWidth).frame(maxWidth:.infinity).background(BiologyStyle.background)
    }
}
#endif
