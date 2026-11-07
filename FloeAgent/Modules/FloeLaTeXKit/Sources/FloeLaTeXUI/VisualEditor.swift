// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore
import FloeLaTeXParsing

struct LaTeXVisualEditor:View {
    @Bindable var session:LaTeXEditorSession
    var body:some View {
        ScrollViewReader {proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:20) {
                    ForEach(session.structure.blocks) {block in LaTeXVisualBlock(session:session,block:block).id(block.id)}
                    Button {session.insert(session.t("新段落","New paragraph"))}label:{Label(session.t("添加段落","Add paragraph"),systemImage:"plus")}
                        .buttonStyle(.borderless).padding(.vertical)
                }.padding(24).frame(maxWidth:780,alignment:.leading).frame(maxWidth:.infinity)
            }
            .onChange(of:session.focusedBlock) {_,id in if let id {withAnimation {proxy.scrollTo(id,anchor:.center)}}}
        }.background(Color(uiColor:.systemBackground))
    }
}
private struct LaTeXVisualBlock:View {
    @Bindable var session:LaTeXEditorSession
    let block:LaTeXBlock
    @State private var showingSource=false
    @State private var raw=""
    @State private var attachmentRange:NSRange?
    @State private var attachmentSource=""
    @State private var attachmentIsFormula=false
    @State private var paperInformation=false
    var body:some View {
        Group {
            if block.name == "maketitle" {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(["title","author","date"],id:\.self) {key in
                        if let value=session.structure.commands.last(where:{$0.name==key && $0.range.start<session.structure.bodyRange.start})?.arguments.last(where:{!$0.optional})?.value,!value.isEmpty {
                            Text(LaTeXInlineDocument(source:value).visibleText).font(key=="title" ? .title.bold():.subheadline)
                        }
                    }
                    Button(session.t("编辑论文信息","Edit paper information")) {paperInformation=true}.font(.caption)
                }.frame(maxWidth:.infinity,alignment:.leading)
            } else if ["bibliographystyle","newpage","clearpage"].contains(block.name) {
                EmptyView()
            } else if ["bibliography","printbibliography"].contains(block.name) {
                VStack(alignment:.leading,spacing:8) {
                    Text(session.t("参考文献","References")).font(.title2.bold())
                    ForEach(session.references.prefix(100),id:\.key) {entry in Text("["+entry.key+"] "+(entry.field("title") ?? entry.key)).font(.callout).textSelection(.enabled)}
                }
            } else if block.name == "tableofcontents" {
                VStack(alignment:.leading,spacing:8) {
                    Text(session.t("目录","Contents")).font(.title2.bold())
                    ForEach(session.structure.blocks.filter{$0.kind == .heading}) {heading in
                        Button(LaTeXInlineDocument(source:heading.content).visibleText) {session.focusedBlock=heading.id}.buttonStyle(.plain)
                    }
                }
            } else if block.kind == .list,let projection=LaTeXListProjection(content:block.content) {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(Array(projection.items.enumerated()),id:\.element.id) {position,item in
                        HStack(alignment:.top,spacing:10) {
                            Text(item.label ?? (block.name=="enumerate" ? String(position+1)+".":"•")).frame(minWidth:18,alignment:.trailing)
                            LaTeXRichTextEditor(source:session.editableText(in:.init(start:block.contentRange.start+item.range.start,length:item.range.length)),fontSize:18,formulaRenderer:session.formulaRenderer,onChange:{original,value in
                                session.update(range:.init(start:block.contentRange.start+item.range.start,length:original.utf8.count),original:original,replacement:value)
                            },onFocus:{session.focusedBlock=block.id},onAttachment:{_,_ in raw=block.content;attachmentRange=nil;showingSource=true;attachmentIsFormula=false})
                        }
                    }
                    Button(session.t("添加项目","Add item")) {session.update(range:block.contentRange,original:block.content,replacement:block.content+"\n\\item "+session.t("新项目","New item")+"\n")}.font(.caption).buttonStyle(.borderless)
                }
            } else if block.name == "abstract" || block.kind == .paragraph || block.kind == .heading {
                if block.name == "abstract" {Text(session.t("摘要","Abstract")).font(.title2.bold())}
                LaTeXRichTextEditor(source:session.editableText(in:block.contentRange),fontSize:block.kind == .heading ? headingSize:18,bold:block.kind == .heading,formulaRenderer:session.formulaRenderer,onChange:{original,value in
                    session.update(range:.init(start:block.contentRange.start,length:original.utf8.count),original:original,replacement:value)
                },onFocus:{session.focusedBlock=block.id},onAttachment:{range,node in
                    attachmentRange=range
                    if case .attachment(let source,let kind,_,_)=node {raw=source;attachmentSource=source;attachmentIsFormula=kind=="formula"}
                    showingSource=true
                })
            } else if block.kind == .table,let table=LaTeXTableProjection(source:block.content) {
                LaTeXTableEditor(session:session,block:block,projection:table)
            } else if block.kind == .figure {
                VStack(spacing:8) {LaTeXFigurePreview(session:session,block:block);Button(session.t("图片设置","Figure settings")) {raw=block.content;attachmentRange=nil;showingSource=true;attachmentIsFormula=false}.font(.caption).buttonStyle(.borderless)}
            } else if block.kind == .formula {
                VStack(alignment:.leading,spacing:8) {
                    LaTeXFormulaPreview(expression:formulaContent,renderer:session.formulaRenderer)
                    Button(session.t("编辑公式","Edit equation")) {raw=block.content;attachmentRange=nil;showingSource=true;attachmentIsFormula=true}
                        .font(.caption).buttonStyle(.borderless)
                }.frame(maxWidth:.infinity).padding(.vertical,8).contentShape(Rectangle()).onTapGesture {session.focusedBlock=block.id}
            } else {
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Label(title,systemImage:symbol).font(.subheadline.weight(.medium))
                        Spacer()
                        Button(session.t("编辑","Edit")) {raw=block.content;attachmentRange=nil;showingSource=true;attachmentIsFormula=false}.buttonStyle(.borderless)
                    }
                    Text(String(block.content.prefix(500))).font(.system(.callout,design:.monospaced)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }.padding(12).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                    .contentShape(Rectangle()).onTapGesture {session.focusedBlock=block.id}
            }
        }
        .contextMenu {
            Button(session.t("在源码中显示","Show in source")) {Task {await session.selectSource(path:session.path,line:String(decoding:Array(session.source.utf8).prefix(block.range.start),as:UTF8.self).components(separatedBy:"\n").count)}}
            Button(session.t("删除内容","Delete content"),role:.destructive) {session.update(range:block.range,original:session.structure.original(block.range),replacement:"")}
        }
        .sheet(isPresented:$paperInformation) {LaTeXPaperInformation(session:session)}
        .sheet(isPresented:$showingSource) {
            NavigationStack {
                VStack(alignment:.leading,spacing:16) {
                    if attachmentIsFormula {LaTeXFormulaPreview(expression:raw,renderer:session.formulaRenderer).frame(maxWidth:.infinity).padding()}
                    TextEditor(text:$raw).font(.system(.body,design:.monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).padding(8)
                }.navigationTitle(attachmentIsFormula ? session.t("公式","Equation"):title)
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction) {Button(session.t("取消","Cancel")) {showingSource=false}}
                        ToolbarItem(placement:.confirmationAction) {Button(session.t("完成","Done")) {
                            if let range=attachmentRange {
                                do {let projection=LaTeXInlineDocument(source:block.content);let replacement=try projection.replacingSource(range,with:raw);session.update(range:block.contentRange,original:block.content,replacement:replacement)}catch {session.report(error)}
                            }else {session.update(range:block.contentRange,original:block.content,replacement:raw)}
                            showingSource=false
                        }}
                    }
            }.presentationDetents([.medium,.large])
        }
    }
    private var headingSize:CGFloat {switch block.name {case "part","chapter":30;case "section":26;case "subsection":22;default:20}}
    private var formulaContent:String {block.content.replacingOccurrences(of:#"\\label\{[^}]*\}"#,with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)}
    private var title:String {
        switch block.kind {case .figure:session.t("图片","Figure");case .table:session.t("表格","Table");case .list:session.t("列表","List");case .code:session.t("代码","Code");default:block.name}
    }
    private var symbol:String {switch block.kind {case .figure:"photo";case .table:"tablecells";case .list:"list.bullet";case .code:"chevron.left.forwardslash.chevron.right";default:"curlybraces"}}
}
#endif
