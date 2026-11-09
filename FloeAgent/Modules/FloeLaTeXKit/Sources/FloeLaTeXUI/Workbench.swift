// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXEngine

public struct LaTeXPreviewContext {
    public var url:URL
    public var location:LaTeXPDFLocation?
    public var onSource:@MainActor (Int,Double,Double)->Void
}
public typealias LaTeXPDFRenderer = @MainActor (LaTeXPreviewContext)->AnyView

/// Service-owned work may outlive an editor. A newly opened editor observes
/// the same operation without sharing its selection, draft or undo state.
public struct LaTeXWorkbenchOperation {
    public var status:String
    public var stopLabel:String
    public var stop:@MainActor ()->Void
    public init(status:String,stopLabel:String,stop:@escaping @MainActor ()->Void) {
        self.status=status;self.stopLabel=stopLabel;self.stop=stop
    }
}

/// Reusable inside Space, a task artifact, a note attachment or a document scene.
/// The host resolves ownership and supplies its existing protected PDF surface.
public struct LaTeXWorkbench:View {
    @Bindable private var session:LaTeXEditorSession
    private let pdfRenderer:LaTeXPDFRenderer
    private let onAssistant:(@MainActor ()->Void)?
    private let operation:LaTeXWorkbenchOperation?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var panel:Panel? = .files
    @State private var showingPreview=false
    @State private var availableWidth:CGFloat=0
    @State private var insertion:LaTeXInsertion?
    @State private var importingAsset=false
    @State private var share:ShareItem?
    public init(session:LaTeXEditorSession,pdfRenderer:@escaping LaTeXPDFRenderer,onAssistant:(@MainActor ()->Void)? = nil,operation:LaTeXWorkbenchOperation? = nil) {
        self.session=session;self.pdfRenderer=pdfRenderer;self.onAssistant=onAssistant;self.operation=operation
    }
    enum Panel:String,CaseIterable,Identifiable {case files,outline,references,search,history,builds,settings;var id:String{rawValue}}
    private struct ShareItem:Identifiable {let id=UUID();var url:URL}
    public var body:some View {
        VStack(spacing:0) {
            editorToolbar
            Divider()
            HStack(spacing:0) {
                if sizeClass == .regular,let panel {
                    LaTeXSidePanel(session:session,panel:panel).frame(width:250)
                    Divider()
                }
                VStack(spacing:0) {
                    if session.mode == .source {LaTeXSourceEditor(session:session)}else {LaTeXVisualEditor(session:session)}
                    statusBar
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if sizeClass == .regular,showingPreview {
                    Divider();preview.frame(minWidth:280,maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
        .onGeometryChange(for:CGFloat.self) { $0.size.width } action: { width in
            availableWidth=width
            if sizeClass == .regular,width<1_050,showingPreview {panel=nil}
        }
        .onChange(of:panel) { _,value in
            if value != nil,sizeClass == .regular,availableWidth<1_050,showingPreview {showingPreview=false}
        }
        .task {
            if session.manifest == nil {await session.load()}
            while !Task.isCancelled {try? await Task.sleep(for:.seconds(0.75));guard !Task.isCancelled else{return};await session.refresh()}
        }
        .onDisappear {Task {try? await session.save()}}
        .sheet(item:$insertion) {value in LaTeXInsertSheet(session:session,kind:value)}
        .sheet(item:Binding(get:{sizeClass != .regular ? panel:nil},set:{panel=$0})) {panel in
            NavigationStack {LaTeXSidePanel(session:session,panel:panel).toolbar {ToolbarItem(placement:.confirmationAction) {Button(session.t("完成","Done")) {self.panel=nil}}}}
        }
        .sheet(isPresented:Binding(get:{sizeClass != .regular && showingPreview},set:{showingPreview=$0})) {NavigationStack {preview.toolbar {ToolbarItem(placement:.confirmationAction) {Button(session.t("完成","Done")) {showingPreview=false}}}}}
        .fileImporter(isPresented:$importingAsset,allowedContentTypes:[.item],allowsMultipleSelection:true) {result in
            do {let urls=try result.get();Task {for url in urls {await session.importFile(url)}}}catch {session.report(error)}
        }
        .sheet(item:$share) {item in LaTeXShareSheet(url:item.url)}
        .alert(session.t("无法完成操作","Unable to complete action"),isPresented:Binding(get:{session.error != nil},set:{if !$0 {session.error=nil}})) {Button(session.t("好","OK")) {session.error=nil}}message:{Text(session.error ?? "")}
        .confirmationDialog(session.t("正文已在其他位置更新","This document changed elsewhere"),isPresented:Binding(get:{session.conflict != nil},set:{_ in}),titleVisibility:.visible) {
            Button(session.t("保存我的草稿为新修订","Save my draft as a new revision")) {Task {await session.resolveConflict(keepDraft:true)}}
            Button(session.t("使用最新修订","Use the latest revision")) {Task {await session.resolveConflict(keepDraft:false)}}
            Button(session.t("稍后处理","Decide later"),role:.cancel) {}
        }message:{Text(session.t("你的草稿已单独保留。","Your draft has been preserved separately."))}
    }
    private var editorToolbar:some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:14) {
                Menu {
                    ForEach(Panel.allCases) {value in Button {panel=panel==value ? nil:value}label:{Label(title(value),systemImage:symbol(value))}}
                }label:{Image(systemName:"sidebar.left")}.accessibilityLabel(session.t("项目面板","Project panels"))
                Picker(session.t("写作模式","Writing mode"),selection:Binding(get:{session.mode},set:{value in
                    guard value != session.mode else{return}
                    endEditing();session.mode=value
                })) {
                    Text(session.t("可视化","Visual")).tag(LaTeXEditorSession.Mode.visual)
                    Text(session.t("源码","Source")).tag(LaTeXEditorSession.Mode.source)
                }.pickerStyle(.segmented).frame(width:190).disabled(LaTeXFileKind.infer(session.path) != .source).accessibilityIdentifier("latex.mode")
                Button {session.undo()}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!session.undoAvailable).accessibilityLabel(session.t("撤销","Undo"))
                Button {session.redo()}label:{Image(systemName:"arrow.uturn.forward")}.disabled(!session.redoAvailable).accessibilityLabel(session.t("重做","Redo"))
                if session.mode == .source {
                    Menu {
                        Button(session.t("折叠／展开当前区域","Toggle current fold")) {session.foldSource(.toggleCurrent)}
                        Button(session.t("全部折叠","Fold all")) {session.foldSource(.collapseAll)}
                        Button(session.t("全部展开","Expand all")) {session.foldSource(.expandAll)}
                    }label:{Image(systemName:"chevron.down.square")}
                        .accessibilityLabel(session.t("源码折叠","Source folding")).accessibilityIdentifier("latex.folding")
                    Menu {ForEach(session.sourceCompletions) {value in Button(value.title) {session.complete(value)}}}label:{Text(session.t("补全","Complete"))}
                        .disabled(session.sourceCompletions.isEmpty)
                }
                Menu {
                    ForEach(LaTeXInsertion.allCases) {kind in Button(kind.title(session)) {insertion=kind}}
                    Button(session.t("导入图片或文件","Import image or file")) {importingAsset=true}
                }label:{Image(systemName:"plus")}.accessibilityLabel(session.t("插入","Insert"))
                Button {endEditing();Task {await session.compile();setPreview(true)}}label:{Label(session.t("排版","Typeset"),systemImage:"play.fill")}.disabled(session.isBuilding || operation != nil).accessibilityIdentifier("latex.compile")
                if session.isBuilding || operation != nil {Button {if let operation {operation.stop()}else {session.stop()}}label:{Image(systemName:"stop.fill")}.accessibilityLabel(operation?.stopLabel ?? session.t("停止排版","Stop typesetting"))}
                Button {setPreview(!showingPreview)}label:{Image(systemName:"doc.richtext")}.accessibilityLabel(session.t("PDF 预览","PDF preview"))
                Button {endEditing();session.revealPDF();setPreview(true)}label:{Image(systemName:"scope")}.accessibilityLabel(session.t("定位到 PDF","Locate in PDF"))
                Menu {
                    if let url=session.pdfURL {Button(session.t("导出 PDF","Export PDF")) {if session.pdfIsCurrent {share = .init(url:url)}else {session.error=session.t("先排版最新内容，再导出 PDF。","Typeset the latest content before exporting PDF.")}}}
                    Button(session.t("导出工程 ZIP","Export project ZIP")) {endEditing();Task {do {share = .init(url:try await session.exportZIP())}catch {session.report(error)}}}
                }label:{Image(systemName:"square.and.arrow.up")}.accessibilityLabel(session.t("导出","Export"))
                if let onAssistant {Button(action:onAssistant) {Image(systemName:"sparkles")}.accessibilityLabel(session.t("论文助手","Writing assistant"))}
            }.buttonStyle(.borderless).padding(.horizontal,14).frame(minHeight:52)
        }
    }
    private var statusBar:some View {
        HStack(spacing:10) {
            if session.isBuilding || operation != nil {ProgressView().controlSize(.mini)}
            Button {panel = .builds}label:{Text(buildStatus).lineLimit(1)}.buttonStyle(.plain).accessibilityIdentifier("latex.buildStatus")
            Spacer(minLength:8)
            Text(session.dirty ? session.t("正在保存…","Saving…"):session.t("已保存","Saved")).foregroundStyle(.secondary)
            Text(session.path).lineLimit(1).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal,12).frame(height:30).background(.bar)
    }
    private var buildStatus:String {
        if let operation {return operation.status}
        if session.preparingTypeset {return session.t("正在准备排版…","Preparing typesetting…")}
        guard let build=session.build else {return session.t("尚未排版","Ready to typeset")}
        return switch build.state {case .queued,.preparing:session.t("正在准备…","Preparing…");case .compiling:session.t("正在排版…","Typesetting…");case .succeeded:session.pdfIsCurrent ? session.t("PDF 已更新","PDF is up to date"):session.t("PDF 等待更新","PDF needs updating");case .failed:session.t("排版遇到问题，查看详情","Typesetting failed · View details");case .cancelled:session.t("排版已停止","Typesetting stopped");case .interrupted:session.t("排版已中断","Typesetting interrupted")}
    }
    private var preview:some View {
        VStack(spacing:0) {
            if let url=session.pdfURL {
                if !session.pdfIsCurrent {Text(session.t("显示上次成功排版的版本","Showing the last successful PDF")).font(.caption).foregroundStyle(.secondary).padding(8)}
                pdfRenderer(.init(url:url,location:session.pdfLocation,onSource:{page,x,y in
                    session.reversePDF(page:page,x:x,y:y)
                    if sizeClass != .regular {showingPreview=false}
                }))
            }else {ContentUnavailableView(session.t("论文预览","Document preview"),systemImage:"doc.richtext",description:Text(session.t("点击“排版”生成 PDF。","Choose Typeset to generate the PDF.")))}
        }
    }
    private func setPreview(_ visible:Bool) {
        if visible,sizeClass == .regular,availableWidth<1_050 {panel=nil}
        showingPreview=visible
    }
    private func endEditing() {session.commitInput()}
    private func title(_ panel:Panel)->String {switch panel {case .files:session.t("文件","Files");case .outline:session.t("大纲","Outline");case .references:session.t("文献","References");case .search:session.t("查找与替换","Find and replace");case .history:session.t("历史","History");case .builds:session.t("排版记录","Builds");case .settings:session.t("项目设置","Project settings")}}
    private func symbol(_ panel:Panel)->String {switch panel {case .files:"folder";case .outline:"list.bullet.indent";case .references:"books.vertical";case .search:"magnifyingglass";case .history:"clock.arrow.circlepath";case .builds:"terminal";case .settings:"gearshape"}}
}
private struct LaTeXShareSheet:UIViewControllerRepresentable {
    var url:URL
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ view:UIActivityViewController,context:Context) {}
}
#endif
