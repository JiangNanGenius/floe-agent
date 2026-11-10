// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(CoreGraphics)
import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import FloeNativeChartsCore

@MainActor public struct NativeChartViewer:View {
    public let chart:PreparedChart
    public let language:NativeChartLanguage
    public let expanded:Bool
    @State private var scene:NativeChartScene?
    @State private var selection:Set<ChartFilterKey>?
    @State private var zoom:CGFloat=1
    @State private var baseZoom:CGFloat=1
    @State private var viewportWidth:CGFloat=0
    @State private var viewportHeight:CGFloat=0
    @State private var hasCustomZoom=false
    @State private var readout:ChartReadout?
    @State private var showFilters=false
    @State private var showData=false
    @State private var showDetails=false
    @State private var showExpanded=false
    @State private var failure:String?
    @State private var exportFailure:String?
    @State private var exporting=false
    @State private var exportDocument:ChartExportDocument?
    @State private var exportType:UTType = .png
    @State private var showExporter=false
    @State private var exportTask:Task<Void,Never>?
    @State private var exportRequestID:UUID?
    public init(chart:PreparedChart,language:NativeChartLanguage = .current,expanded:Bool = false,initialSelection:Set<ChartFilterKey>? = nil){self.chart=chart;self.language=language;self.expanded=expanded;_selection=State(initialValue:initialSelection)}
    private var title:String{chart.document.title ?? language.title(for:chart.document.type)}
    private var request:ViewerRequest{.init(chart:chart,selection:selection)}
    public var body:some View {
        VStack(alignment:.leading,spacing:10){
            controls
            if let scene {
                ScrollView([.horizontal,.vertical]){
                    Canvas{context,_ in context.withCGContext{cg in cg.scaleBy(x:zoom,y:zoom);NativeChartCGRenderer.draw(scene,in:cg)}}
                        .frame(width:scene.frame.width*zoom,height:scene.frame.height*zoom)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded{value in readout=NativeChartHitTester(scene:scene).readout(at:.init(x:value.location.x/zoom,y:value.location.y/zoom))})
                        .simultaneousGesture(MagnificationGesture().onChanged{value in hasCustomZoom=true;zoom=min(8,max(0.1,baseZoom*value))}.onEnded{_ in baseZoom=zoom})
                        .accessibilityLabel(title)
                        .accessibilityHint(language.text("Open Values to read the chart data.","可打开“数值”读取图表数据。"))
                        .accessibilityIdentifier("chart.canvas")
                }.frame(minHeight:expanded ? 420:260,maxHeight:expanded ? .infinity:400)
                .clipped()
                .background{GeometryReader{proxy in Color.clear.onAppear{updateViewport(proxy.size,scene:scene)}.onChange(of:proxy.size){size in updateViewport(size,scene:scene)}}}
                if let readout {readoutView(readout)}
            } else if failure != nil {
                Label(language.text("The chart could not be displayed.","图表暂时无法显示。"),systemImage:"exclamationmark.triangle")
                Button(language.text("Details","详情")){showDetails=true}
            } else if selection != nil {
                Text(language.text("No visible data. Reset the filter to continue.","没有可见数据，可重置筛选。"))
                Button(language.text("Reset filter","重置筛选")){selection=nil}
            } else {ProgressView()}
            if exporting {ProgressView(language.text("Exporting…","正在导出…"))}
        }
        .task(id:request){
            let current=request,renderTitle=title;scene=nil;failure=nil;readout=nil
            let worker=Task.detached(priority:.userInitiated){() throws -> NativeChartScene? in
                guard let view=ChartDisplayFilter.apply(current.selection,to:current.chart) else{return nil}
                let optionCount=ChartDisplayFilter.options(for:current.chart).count
                let width:Double=current.chart.document.type == .smallMultiples ? 1280:960
                let height:Double=current.chart.document.type == .smallMultiples ? 960:(current.chart.document.type == .calendarHeatmap ? max(640,min(2400,Double(optionCount)*0.5)):640)
                return try view.scene(width:width,height:height,title:renderTitle)
            }
            do {
                let result=try await withTaskCancellationHandler{try await worker.value}onCancel:{worker.cancel()}
                try Task.checkCancellation();guard request==current else{return};scene=result;if let result{fitIfNeeded(result)}
            }catch is CancellationError{}catch{guard request==current && !Task.isCancelled else{return};failure=String(describing:error)}
        }
        .sheet(isPresented:$showFilters){ChartFilterSheet(chart:chart,selection:$selection,language:language)}
        .sheet(isPresented:$showData){NavigationStack{List{ForEach(Array((scene?.hits ?? []).enumerated()),id:\.offset){_,hit in readoutView(hit.readout)}}.navigationTitle(language.text("Values","数值")).toolbar{Button(language.text("Done","完成")){showData=false}}}}
        .sheet(isPresented:$showDetails){NavigationStack{ScrollView{VStack(alignment:.leading,spacing:12){if let failure{Text(failure)};ForEach(Array((scene?.notes ?? []).enumerated()),id:\.offset){_,note in Text(note)};ForEach(Array(chart.warnings.enumerated()),id:\.offset){_,warning in Text(warning.description)}}.padding()}.navigationTitle(language.text("Chart details","图表详情")).toolbar{Button(language.text("Done","完成")){showDetails=false}}}}
        .nativeChartExpansion(isPresented:$showExpanded,chart:chart,language:language,title:title,selection:selection)
        .fileExporter(isPresented:$showExporter,document:exportDocument,contentType:exportType,defaultFilename:String(title.prefix(80))){result in if case .failure(let error)=result{exportFailure=error.localizedDescription};exportDocument=nil}
        .alert(language.text("Export failed","未能导出"),isPresented:Binding(get:{exportFailure != nil},set:{if !$0{exportFailure=nil}})){Button(language.text("OK","好")){exportFailure=nil}}message:{Text(exportFailure ?? "")}
        .onDisappear{exportTask?.cancel();exportRequestID=nil;exporting=false}
    }
    private var controls:some View {
        ViewThatFits(in:.horizontal){
            HStack{filterButton;valuesButton;zoomButtons;Spacer();exportMenu;expandButton}
            VStack{HStack{filterButton;valuesButton;Spacer();exportMenu;expandButton};HStack{zoomButtons;Spacer()}}
        }.buttonStyle(.borderless)
    }
    private var filterButton:some View{Button{showFilters=true}label:{Label(language.text("Filter","筛选"),systemImage:"line.3.horizontal.decrease.circle")}.frame(minWidth:44,minHeight:44).accessibilityIdentifier("chart.filter")}
    private var valuesButton:some View{Button{showData=true}label:{Label(language.text("Values","数值"),systemImage:"tablecells")}.frame(minWidth:44,minHeight:44).accessibilityIdentifier("chart.values")}
    private var zoomButtons:some View{HStack{
        Button{hasCustomZoom=true;zoom=max(0.1,zoom/1.3);baseZoom=zoom}label:{Image(systemName:"minus.magnifyingglass")}.frame(minWidth:44,minHeight:44).accessibilityLabel(language.text("Zoom out","缩小")).accessibilityIdentifier("chart.zoomOut")
        Button{hasCustomZoom=false;if let scene{fitIfNeeded(scene)}}label:{Text("\(Int(zoom*100))%")}.frame(minWidth:44,minHeight:44).accessibilityLabel(language.text("Fit chart","适应视图")).accessibilityIdentifier("chart.fit").accessibilityValue("\(Int(zoom*100))%")
        Button{hasCustomZoom=true;zoom=min(8,zoom*1.3);baseZoom=zoom}label:{Image(systemName:"plus.magnifyingglass")}.frame(minWidth:44,minHeight:44).accessibilityLabel(language.text("Zoom in","放大")).accessibilityIdentifier("chart.zoomIn")
    }}
    private func updateViewport(_ size:CGSize,scene:NativeChartScene){viewportWidth=size.width;viewportHeight=size.height;fitIfNeeded(scene)}
    private func fitIfNeeded(_ scene:NativeChartScene){
        guard !hasCustomZoom,viewportWidth>0,viewportHeight>0 else{return}
        zoom=max(0.1,min(1,min(viewportWidth/scene.frame.width,viewportHeight/scene.frame.height)));baseZoom=zoom
    }
    @ViewBuilder private var expandButton:some View{if !expanded{Button{showExpanded=true}label:{Image(systemName:"arrow.up.left.and.arrow.down.right")}.frame(minWidth:44,minHeight:44).accessibilityLabel(language.text("Full screen","全屏")).accessibilityIdentifier("chart.fullScreen")}}
    private var exportMenu:some View{Menu{Button(language.text("Image (current view)","图片（当前视图）")){export(.png)};Button(language.text("PDF (current view)","PDF（当前视图）")){export(.pdf)};Button(language.text("JSON (original data)","JSON（原始数据）")){export(.json)};Divider();Button(language.text("Details","详情")){showDetails=true}}label:{Image(systemName:"square.and.arrow.up")}.frame(minWidth:44,minHeight:44).disabled(exporting).accessibilityLabel(language.text("Export chart","导出图表")).accessibilityIdentifier("chart.export")}
    private func readoutView(_ readout:ChartReadout)->some View{VStack(alignment:.leading,spacing:4){Text(readout.title).font(.headline);ForEach(Array(readout.fields.enumerated()),id:\.offset){_,field in HStack{Text(language.field(field.name)).foregroundStyle(.secondary);Spacer();Text(field.value).textSelection(.enabled)}}}.font(.callout).padding(8).accessibilityElement(children:.combine)}
    private func export(_ type:UTType){
        guard type == .json || scene != nil else{return}
        exportTask?.cancel();let id=UUID();exportRequestID=id;exporting=true
        let snapshot=scene,source=chart
        exportTask=Task{
            let worker=Task.detached(priority:.userInitiated){() throws -> Data in
                if type == .json{return try NativeChartExporter.json(source)}
                guard let snapshot else{throw ChartIssue(path:"export",problem:"chart is not ready")}
                return try type == .pdf ? NativeChartExporter.pdf([snapshot]):NativeChartExporter.png(snapshot)
            }
            do{let bytes=try await withTaskCancellationHandler{try await worker.value}onCancel:{worker.cancel()};try Task.checkCancellation();guard exportRequestID==id else{return};exportType=type;exportDocument = .init(data:bytes);showExporter=true}
            catch is CancellationError{}catch{if exportRequestID==id{exportFailure=error.localizedDescription}}
            if exportRequestID==id{exporting=false}
        }
    }
}
@MainActor private extension View {
    @ViewBuilder func nativeChartExpansion(isPresented:Binding<Bool>,chart:PreparedChart,language:NativeChartLanguage,title:String,selection:Set<ChartFilterKey>?)->some View {
        #if os(iOS) || os(visionOS)
        fullScreenCover(isPresented:isPresented){NavigationStack{NativeChartViewer(chart:chart,language:language,expanded:true,initialSelection:selection).padding().navigationTitle(title).toolbar{Button(language.text("Done","完成")){isPresented.wrappedValue=false}}}}
        #else
        sheet(isPresented:isPresented){NavigationStack{NativeChartViewer(chart:chart,language:language,expanded:true,initialSelection:selection).padding().frame(minWidth:800,minHeight:600).navigationTitle(title).toolbar{Button(language.text("Done","完成")){isPresented.wrappedValue=false}}}}
        #endif
    }
}
private struct ViewerRequest:Equatable,Sendable{let chart:PreparedChart;let selection:Set<ChartFilterKey>?}
private struct ChartExportDocument:FileDocument{
    static let readableContentTypes:[UTType]=[.png,.pdf,.json]
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{guard let bytes=configuration.file.regularFileContents,bytes.count<=16*1_048_576 else{throw ChartIssue(path:"export",problem:"invalid file")};data=bytes}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{.init(regularFileWithContents:data)}
}
private struct ChartFilterSheet:View{
    let chart:PreparedChart
    @Binding var selection:Set<ChartFilterKey>?
    let language:NativeChartLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var query=""
    private var options:[ChartFilterOption]{ChartDisplayFilter.options(for:chart)}
    var body:some View{NavigationStack{List{Section{Button(language.text("Show all","全部显示")){selection=nil};Button(language.text("Clear","清空选择")){selection=[]}};ForEach(options.filter{query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)}){option in Toggle(option.label,isOn:Binding(get:{selection?.contains(option.id) ?? true},set:{enabled in var selected=selection ?? Set(options.map(\.id));if enabled{selected.insert(option.id)}else{selected.remove(option.id)};selection=selected}))}}.searchable(text:$query,prompt:language.text("Find records or series","查找记录或系列")).navigationTitle(language.text("Filter chart","筛选图表")).toolbar{Button(language.text("Done","完成")){dismiss()}}}}
}
#endif
