// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeWorkbench

struct MediaV2ColorInspector:View {
    @Bindable var session:MediaV2Session
    @State private var curve:[ImageFreehandStroke.Point]=[.init(x:0,y:0),.init(x:0.25,y:0.25),.init(x:0.5,y:0.5),.init(x:0.75,y:0.75),.init(x:1,y:1)]
    @State private var balance=ImageColorBalance()
    @State private var tone="midtones"
    @State private var preset="CIPhotoEffectChrome"
    @State private var lut:ImageColorLUT?
    @State private var lutName:String?
    @State private var showImport=false
    @State private var noise=0.5
    @State private var sharpen=20.0
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            if session.tool == "image.curves" {
                MediaV2ToneCurveEditor(points:$curve).frame(height:180)
                Text(WorkbenchText.t("拖动控制点调整明暗曲线。", "Drag control points to adjust the tone curve.")).font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("重置曲线", "Reset curve")){curve=[.init(x:0,y:0),.init(x:0.25,y:0.25),.init(x:0.5,y:0.5),.init(x:0.75,y:0.75),.init(x:1,y:1)]}
            }else if session.tool == "image.balance" {
                Picker(WorkbenchText.t("色调范围", "Tonal range"),selection:$tone){Text(WorkbenchText.t("阴影", "Shadows")).tag("shadows");Text(WorkbenchText.t("中间调", "Midtones")).tag("midtones");Text(WorkbenchText.t("高光", "Highlights")).tag("highlights")}.pickerStyle(.segmented)
                channel(WorkbenchText.t("青－红", "Cyan–red"),\.red)
                channel(WorkbenchText.t("洋红－绿", "Magenta–green"),\.green)
                channel(WorkbenchText.t("黄－蓝", "Yellow–blue"),\.blue)
                Toggle(WorkbenchText.t("保持亮度", "Preserve luminance"),isOn:$balance.preserveLuminance)
            }else if session.tool == "image.lut" {
                Picker(WorkbenchText.t("滤镜", "Filter"),selection:$preset){Text(WorkbenchText.t("鲜艳", "Chrome")).tag("CIPhotoEffectChrome");Text(WorkbenchText.t("黑白", "Mono")).tag("CIPhotoEffectMono");Text(WorkbenchText.t("黑色电影", "Noir")).tag("CIPhotoEffectNoir");Text(WorkbenchText.t("褪色", "Fade")).tag("CIPhotoEffectFade");Text(WorkbenchText.t("即时成像", "Instant")).tag("CIPhotoEffectInstant");Text(WorkbenchText.t("棕褐色", "Sepia")).tag("CISepiaTone")}
                Button(WorkbenchText.t("导入 .cube LUT", "Import .cube LUT")){showImport=true}.frame(minHeight:44)
                if let lutName{Label(lutName,systemImage:"checkmark.circle");Button(WorkbenchText.t("改用内置滤镜", "Use built-in filter")){lut=nil;self.lutName=nil}}
            }else{
                MusicValueSlider(title:WorkbenchText.t("降噪", "Noise reduction"),value:noise,range:0...1){noise=$0}
                MusicValueSlider(title:WorkbenchText.t("锐化", "Sharpen"),value:sharpen,range:0...100){sharpen=$0}
            }
            Button(WorkbenchText.t("应用到当前图层", "Apply to current layer")){apply()}.frame(minHeight:44).disabled(session.selectedLayer==nil || session.processingTool)
            if session.selection != nil{Text(WorkbenchText.t("仅处理当前选区。", "Only the selected area is processed.")).font(.caption).foregroundStyle(.secondary)}
            if session.processingTool{ProgressView();Button(WorkbenchText.t("取消处理", "Cancel processing")){session.cancelToolProcessing()}}
        }
        .fileImporter(isPresented:$showImport,allowedContentTypes:[.plainText,.data]){result in
            do{
                let url=try result.get();guard url.pathExtension.lowercased()=="cube" else{throw MediaV2CommandError.invalidInput}
                let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
                let bytes=try Data(contentsOf:url,options:.mappedIfSafe);guard bytes.count<=2_097_152,let text=String(data:bytes,encoding:.utf8) else{throw MediaV2CommandError.invalidInput}
                let name=url.lastPathComponent
                Task{do{let worker=Task.detached{try ImageColorLUT.parseCube(text)};lut=try await worker.value;lutName=name}catch{session.diagnostic=error.localizedDescription}}
            }catch{session.diagnostic=error.localizedDescription}
        }
    }
    private var selectedBalance:ImageRGBBalance{tone=="shadows" ? balance.shadows:tone=="highlights" ? balance.highlights:balance.midtones}
    private func channel(_ title:String,_ path:WritableKeyPath<ImageRGBBalance,Double>)->some View{
        MusicValueSlider(title:title,value:selectedBalance[keyPath:path],range:-1...1){value in var rgb=selectedBalance;rgb[keyPath:path]=value;if tone=="shadows"{balance.shadows=rgb}else if tone=="highlights"{balance.highlights=rgb}else{balance.midtones=rgb}}
    }
    private func apply(){
        var input=MediaV2ToolInput();input.expectedRevision=session.document.revision;input.objectID=session.selectedLayerID
        var adjustment=ImageLayerAdjustment()
        switch session.tool{case "image.curves":adjustment.toneCurve=curve;case "image.balance":adjustment.colorBalance=balance;case "image.lut":if let lut{adjustment.colorLUT=lut}else{input.text=preset};default:adjustment.noiseReduction=noise;adjustment.sharpenRadius=sharpen}
        input.adjustment=adjustment;let tool=session.tool
        Task{do{_=try await session.performTool(tool,input:input)}catch{session.diagnostic=error.localizedDescription}}
    }
}
struct MediaV2ToneCurveEditor:View{
    @Binding var points:[ImageFreehandStroke.Point]
    @State private var selected:Int?
    var body:some View{GeometryReader{geometry in
        Canvas{context,size in
            let rect=CGRect(origin:.zero,size:size);context.fill(Path(rect),with:.color(.secondary.opacity(0.06)))
            for index in 1...3{let f=CGFloat(index)/4;var grid=Path();grid.move(to:.init(x:size.width*f,y:0));grid.addLine(to:.init(x:size.width*f,y:size.height));grid.move(to:.init(x:0,y:size.height*f));grid.addLine(to:.init(x:size.width,y:size.height*f));context.stroke(grid,with:.color(.secondary.opacity(0.25)),lineWidth:1)}
            var curve=Path();for (index,p) in points.enumerated(){let point=CGPoint(x:p.x*size.width,y:(1-p.y)*size.height);if index==0{curve.move(to:point)}else{curve.addLine(to:point)};context.fill(Path(ellipseIn:.init(x:point.x-5,y:point.y-5,width:10,height:10)),with:.color(.accentColor))};context.stroke(curve,with:.color(.accentColor),lineWidth:2)
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{value in
            if selected==nil{selected=points.indices.min{a,b in hypot(points[a].x*geometry.size.width-value.startLocation.x,(1-points[a].y)*geometry.size.height-value.startLocation.y)<hypot(points[b].x*geometry.size.width-value.startLocation.x,(1-points[b].y)*geometry.size.height-value.startLocation.y)}}
            guard let index=selected else{return};points[index].y=min(1,max(0,1-Double(value.location.y/max(1,geometry.size.height))))
            if index>0 && index<points.count-1{points[index].x=min(points[index+1].x-0.01,max(points[index-1].x+0.01,Double(value.location.x/max(1,geometry.size.width))))}
        }.onEnded{_ in selected=nil})
    }.accessibilityLabel(WorkbenchText.t("明暗曲线", "Tone curve"))}
}
#endif
