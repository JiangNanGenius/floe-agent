// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore
import FloeLaTeXParsing

enum LaTeXInsertion:String,CaseIterable,Identifiable {
    case heading,paragraph,formula,table,figure,list,code,reference,footnote,pageBreak
    var id:String {rawValue}
    @MainActor func title(_ m:LaTeXEditorSession)->String {
        switch self {case .heading:m.t("标题","Heading");case .paragraph:m.t("段落","Paragraph");case .formula:m.t("公式","Equation");case .table:m.t("表格","Table");case .figure:m.t("图片","Figure");case .list:m.t("列表","List");case .code:m.t("代码","Code");case .reference:m.t("交叉引用","Cross-reference");case .footnote:m.t("脚注","Footnote");case .pageBreak:m.t("分页","Page break")}
    }
}
struct LaTeXInsertSheet:View {
    @Bindable var session:LaTeXEditorSession
    let kind:LaTeXInsertion
    @Environment(\.dismiss) private var dismiss
    @State private var text=""
    @State private var label=""
    @State private var caption=""
    @State private var image=""
    @State private var numbered=true
    @State private var level=0
    @State private var width=0.8
    @State private var rows=[["",""],["",""]]
    var body:some View {
        NavigationStack {
            Form {
                switch kind {
                case .heading:
                    TextField(session.t("标题","Heading"),text:$text)
                    Picker(session.t("级别","Level"),selection:$level) {Text(session.t("一级标题","Section")).tag(0);Text(session.t("二级标题","Subsection")).tag(1);Text(session.t("三级标题","Subsubsection")).tag(2)}
                case .formula:
                    TextEditor(text:$text).font(.system(.body,design:.monospaced)).frame(minHeight:130).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("latex.formulaInput")
                    LaTeXFormulaPreview(expression:text,renderer:session.formulaRenderer).frame(maxWidth:.infinity,minHeight:60)
                    Toggle(session.t("自动编号","Number equation"),isOn:$numbered)
                    TextField(session.t("引用标记（可选）","Label (optional)"),text:$label).textInputAutocapitalization(.never).autocorrectionDisabled()
                case .table:
                    ScrollView(.horizontal) {
                        VStack(spacing:4) {ForEach(rows.indices,id:\.self) {r in
                            HStack(spacing:4) {ForEach(rows[r].indices,id:\.self) {c in TextField("",text:Binding(get:{rows[r][c]},set:{rows[r][c]=$0})).textFieldStyle(.roundedBorder).frame(width:140)}}
                        }}.padding(.vertical,4)
                    }
                    HStack {Button(session.t("添加行","Add row")) {rows.append(Array(repeating:"",count:rows[0].count))};Button(session.t("添加列","Add column")) {for r in rows.indices {rows[r].append("")}}}
                    TextField(session.t("表格说明","Caption"),text:$caption)
                    TextField(session.t("引用标记（可选）","Label (optional)"),text:$label).textInputAutocapitalization(.never).autocorrectionDisabled()
                case .figure:
                    Picker(session.t("工程图片","Project image"),selection:$image) {
                        Text(session.t("选择图片","Choose image")).tag("")
                        ForEach(session.manifest?.files.filter{$0.kind == .image} ?? []) {file in Text(file.path).tag(file.path)}
                    }
                    TextField(session.t("图片说明","Caption"),text:$caption)
                    Slider(value:$width,in:0.1...1.0) {Text(session.t("图片宽度","Width"))}
                    Text("\(Int(width*100))%").font(.caption)
                    TextField(session.t("引用标记（可选）","Label (optional)"),text:$label).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(session.t("先通过工具栏导入图片，再插入正文。","Import an image from the toolbar, then insert it here.")).font(.caption).foregroundStyle(.secondary)
                case .list:
                    Toggle(session.t("编号列表","Numbered list"),isOn:$numbered)
                    Text(session.t("每行一个条目","One item per line")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$text).frame(minHeight:180)
                case .reference:
                    Picker(session.t("引用标记","Label"),selection:$text) {
                        Text(session.t("选择标记","Choose label")).tag("")
                        ForEach(Array(Set(session.projectLabels+session.structure.labels)).sorted(),id:\.self) {Text($0).tag($0)}
                    }
                case .pageBreak:Text(session.t("在当前位置开始新的一页。","Start a new page at the current position."))
                case .paragraph,.footnote,.code:
                    TextEditor(text:$text).font(kind == .code ? .system(.body,design:.monospaced):.body).frame(minHeight:220)
                }
            }.navigationTitle(kind.title(session))
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button(session.t("取消","Cancel")) {dismiss()}}
                    ToolbarItem(placement:.confirmationAction) {Button(session.t("插入","Insert")) {insert()}.accessibilityIdentifier("latex.insertConfirm")}
                }
        }.presentationDetents([.medium,.large])
    }
    private func insert() {
        do {
            let source:String,packages:[String]
            switch kind {
            case .heading:source=LaTeXBlockBuilder.heading(text,level:level);packages=[]
            case .paragraph:source=LaTeXParser.escapeText(text);packages=[]
            case .formula:source=try LaTeXBlockBuilder.formula(text,numbered:numbered,label:label.isEmpty ? nil:label);packages=["amsmath"]
            case .table:source=try LaTeXBlockBuilder.table(rows,caption:caption.isEmpty ? nil:caption,label:label.isEmpty ? nil:label);packages=["booktabs"]
            case .figure:source=try LaTeXBlockBuilder.figure(path:image,caption:caption,label:label.isEmpty ? nil:label,width:width);packages=["graphicx"]
            case .list:source=try LaTeXBlockBuilder.list(text.components(separatedBy:"\n").filter{!$0.isEmpty},numbered:numbered);packages=[]
            case .code:guard !text.contains("\\end{verbatim}") else {throw LaTeXError.invalidOperation(session.t("代码中包含环境结束标记，请在源码模式编辑。","Edit this code in source mode because it contains the environment's closing marker."))};source="\\begin{verbatim}\n"+text+"\n\\end{verbatim}\n";packages=[]
            case .reference:try LaTeXBlockBuilder.identifier(text);source="\\ref{\(text)}";packages=[]
            case .footnote:source="\\footnote{"+LaTeXParser.escapeText(text)+"}";packages=[]
            case .pageBreak:source="\\newpage\n";packages=[]
            }
            session.insert(source)
            Task {await session.ensurePackages(packages)}
            dismiss()
        }catch {session.report(error)}
    }
}
#endif
