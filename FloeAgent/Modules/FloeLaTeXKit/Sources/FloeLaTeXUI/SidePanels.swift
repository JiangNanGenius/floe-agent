// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXReferences
import FloeLaTeXEngine

struct LaTeXSidePanel:View {
    @Bindable var session:LaTeXEditorSession
    let panel:LaTeXWorkbench.Panel
    @State private var newFile=false
    @State private var filename=""
    @State private var renameFrom:String?
    @State private var selectedRevision:LaTeXHistoryEntry?
    @State private var editingReference=false
    @State private var paperInformation=false
    var body:some View {
        Group {
            switch panel {case .files:files;case .outline:outline;case .references:references;case .search:search;case .history:history;case .builds:builds;case .settings:settings}
        }
        .background(Color(uiColor:.secondarySystemBackground))
        .task(id:panel.rawValue+"/"+String(session.manifest?.revision ?? -1)) {
            if panel == .history {await session.reloadHistory()}
        }
        .alert(session.t("文件名称","Filename"),isPresented:$newFile) {
            TextField("chapters/methods.tex",text:$filename).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(session.t("取消","Cancel"),role:.cancel) {renameFrom=nil}
            Button(session.t("保存","Save")) {let value=filename,old=renameFrom;renameFrom=nil;Task {if let old {await session.renameFile(old,to:value)}else {await session.createFile(path:value)}}}
        }message:{Text(session.t("可以用 / 创建子文件夹。","Use / for subfolders."))}
        .sheet(item:$selectedRevision) {entry in LaTeXRevisionSheet(session:session,entry:entry)}
        .sheet(isPresented:$editingReference) {LaTeXReferenceSheet(session:session)}
        .sheet(isPresented:$paperInformation) {LaTeXPaperInformation(session:session)}
    }
    private var files:some View {
        List {
            Section {
                ForEach(session.manifest?.files ?? []) {file in
                    Button {
                        if file.kind.isText {Task {await session.open(file.path)}}
                    }label:{HStack {
                        Image(systemName:file.kind == .image ? "photo":file.kind == .bibliography ? "book":"doc.text")
                        VStack(alignment:.leading) {Text(file.path).font(.callout).lineLimit(2);if session.manifest?.mainFile==file.path {Text(session.t("主文件","Main file")).font(.caption2).foregroundStyle(.secondary)}}
                        Spacer(minLength:0)
                        if session.path==file.path {Image(systemName:"pencil.tip").foregroundStyle(.tint)}
                    }}.buttonStyle(.plain).accessibilityIdentifier("latex.file."+file.path)
                    .contextMenu {
                        if file.kind == .source {Button(session.t("设为主文件","Set as main file")) {Task {await session.setMain(file.path)}}}
                        Button(session.t("重命名","Rename")) {renameFrom=file.path;filename=file.path;newFile=true}
                        Button(session.t("删除","Delete"),role:.destructive) {Task {await session.deleteFile(file.path)}}.disabled(file.path==session.manifest?.mainFile)
                    }
                }
            }header:{HStack {Text(session.t("工程文件","Project files"));Spacer();Button {filename="";renameFrom=nil;newFile=true}label:{Image(systemName:"plus")}.accessibilityLabel(session.t("新建文件","New file"))}}
        }.listStyle(.sidebar)
    }
    private var outline:some View {
        List {
            Section(session.t("大纲","Outline")) {
                ForEach(session.structure.blocks.filter{$0.kind == .heading}) {block in
                    Button {session.focusedBlock=block.id;if session.mode == .source {Task {await session.selectSource(path:session.path,line:line(block.range.start))}}}label:{Text(LaTeXInlineDocument(source:block.content).visibleText).padding(.leading,block.name=="subsection" ? 12:block.name=="subsubsection" ? 24:0)}.buttonStyle(.plain)
                }
            }
            Section(session.t("关联文件","Included files")) {
                ForEach(Array(Set(session.structure.includes)).sorted(),id:\.self) {path in
                    Button(path) {let selected=session.manifest?.files.first {$0.path==path || $0.path==path+".tex"};if let selected,selected.kind.isText {Task {await session.open(selected.path)}}}.buttonStyle(.plain)
                }
            }
            Section(session.t("引用标记","Labels")) {ForEach(Array(Set(session.structure.labels)).sorted(),id:\.self) {key in Button(key) {session.insert("\\ref{\(key)}")}.buttonStyle(.plain)}}
        }.listStyle(.sidebar)
    }
    private var references:some View {
        List {
            Section {
                ForEach(session.references) {entry in
                    VStack(alignment:.leading,spacing:6) {
                        Text(entry.displayTitle).font(.callout.weight(.medium)).lineLimit(3)
                        Text([entry.field("author"),entry.field("year")].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        HStack {Text(entry.key).font(.system(.caption,design:.monospaced)).lineLimit(1);Spacer();Button(session.t("引用","Cite")) {Task {await session.cite(entry.key)}}.buttonStyle(.borderless)}
                    }.padding(.vertical,4)
                }
                if session.references.isEmpty {Text(session.t("添加文献，或导入 .bib 文件。","Add a reference or import a .bib file.")).font(.callout).foregroundStyle(.secondary)}
            }header:{HStack {Text(session.t("文献库","Bibliography"));Spacer();Button {editingReference=true}label:{Image(systemName:"plus")}.accessibilityLabel(session.t("添加文献","Add reference"))}}
            Section {ForEach(session.manifest?.files.filter{$0.kind == .bibliography} ?? []) {file in Button(file.path) {Task {await session.open(file.path)}}}}
        }.listStyle(.sidebar)
    }
    private var search:some View {
        VStack(alignment:.leading,spacing:10) {
            TextField(session.t("查找","Find"),text:$session.searchQuery).textFieldStyle(.roundedBorder).onSubmit {Task {await session.search()}}
            TextField(session.t("替换为","Replace with"),text:$session.replacement).textFieldStyle(.roundedBorder)
            Toggle(session.t("区分大小写","Case sensitive"),isOn:$session.searchCaseSensitive)
            Toggle(session.t("正则表达式","Regular expression"),isOn:$session.searchRegex)
            HStack {Button(session.t("查找","Find")) {Task {await session.search()}};Spacer();Button(session.t("全部替换","Replace all")) {Task {await session.replaceAll()}}}.buttonStyle(.bordered)
            List(Array(session.searchResults.enumerated()),id:\.offset) {_,hit in
                Button {Task {await session.selectSource(path:hit.path,line:hit.line)}}label:{VStack(alignment:.leading) {Text("\(hit.path):\(hit.line)").font(.caption).foregroundStyle(.secondary);Text(hit.excerpt).font(.callout).lineLimit(3)}}.buttonStyle(.plain)
            }.listStyle(.plain)
        }.font(.callout).padding(12)
    }
    private var history:some View {
        List {
            Section(session.t("修订历史","Revision history")) {ForEach(session.history) {entry in
                Button {selectedRevision=entry}label:{VStack(alignment:.leading,spacing:4) {
                    Text("\(entry.label) · r\(entry.manifest.revision)").font(.callout)
                    Text(entry.manifest.modifiedAt,style:.date).font(.caption).foregroundStyle(.secondary)
                    Text(entry.origin).font(.caption2).foregroundStyle(.secondary)
                }}.buttonStyle(.plain)
            }}
        }.listStyle(.sidebar)
    }
    private var builds:some View {
        List {
            if let build=session.build {
                Section(session.t("当前排版","Current build")) {
                    Text("\(build.engine.title) · r\(build.revision)").font(.callout)
                    if build.isActive {ProgressView();Button(session.t("停止排版","Stop typesetting")) {session.stop()}}
                    ForEach(build.diagnostics) {diagnostic in
                        Button {if let line=diagnostic.line {Task {await session.selectSource(path:diagnostic.path ?? session.path,line:line)}}}label:{VStack(alignment:.leading,spacing:4) {
                            Label(diagnostic.message,systemImage:diagnostic.severity == .error ? "xmark.circle":"exclamationmark.triangle").font(.callout).foregroundStyle(diagnostic.severity == .error ? Color.red:Color.secondary)
                            if let path=diagnostic.path {Text(path+(diagnostic.line.map{":\($0)"} ?? "")).font(.caption).foregroundStyle(.secondary)}
                        }}.buttonStyle(.plain)
                    }
                    DisclosureGroup(session.t("查看日志","Show log")) {Text(build.messages.joined(separator:"\n")).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
                }
            }
            Section(session.t("排版历史","Build history")) {ForEach(session.buildHistory) {record in
                VStack(alignment:.leading) {Label("r\(record.revision) · \(record.state.rawValue)",systemImage:record.succeeded ? "checkmark.circle":"doc");Text(record.startedAt,style:.time).font(.caption).foregroundStyle(.secondary)}.font(.callout)
            }}
        }.listStyle(.sidebar)
    }
    private var settings:some View {
        Form {
            Section {Button(session.t("论文信息","Paper information")) {paperInformation=true}}
            Section(session.t("排版","Typesetting")) {
                Picker(session.t("引擎","Engine"),selection:Binding(get:{session.manifest?.engine ?? .xeLaTeX},set:{value in Task {await session.setEngine(value)}})) {
                    ForEach(LaTeXEngine.allCases,id:\.self) {engine in Text(engine.title).tag(engine).disabled(!session.capabilities.contains{$0.engine==engine})}
                }
                Toggle(session.t("自动排版","Automatic typesetting"),isOn:$session.autoCompile)
                Toggle(session.t("离线排版","Offline typesetting"),isOn:$session.offline)
                Text(session.t("使用已准备的排版环境；缺少宏包或字体时，可让论文助手补齐。离线排版前请先准备资源。","Use a prepared typesetting environment. Ask the writing assistant to add missing packages or fonts. Prepare resources before working offline.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(session.t("工程","Project")) {
                LabeledContent(session.t("主文件","Main file"),value:session.manifest?.mainFile ?? "")
                LabeledContent(session.t("修订","Revision"),value:String(session.manifest?.revision ?? 0))
                LabeledContent(session.t("文件数量","Files"),value:String(session.manifest?.files.count ?? 0))
                Text(session.t("自定义样式、模板和字体可以作为工程文件导入。","Import custom styles, templates and fonts as project files.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(session.t("写作统计（估算）","Writing statistics (estimated)")) {
                LabeledContent(session.t("英文等词数","Words"),value:String(session.statistics.words))
                LabeledContent(session.t("汉字数","Han characters"),value:String(session.statistics.hanCharacters))
                LabeledContent(session.t("公式","Equations"),value:String(session.statistics.formulas))
                LabeledContent(session.t("图片／表格","Figures / tables"),value:"\(session.statistics.figures) / \(session.statistics.tables)")
            }
            Section(session.t("详细信息","Details")) {
                ForEach(session.capabilities) {capability in Text(capability.engine.title+" · "+capability.version).font(.caption)}
                if let digest=session.pdfBuild?.bundleDigest {Text(digest).font(.system(.caption2,design:.monospaced)).textSelection(.enabled)}
            }
        }
    }
    private func line(_ offset:Int)->Int {String(decoding:Array(session.source.utf8).prefix(offset),as:UTF8.self).components(separatedBy:"\n").count}
}

private struct LaTeXRevisionSheet:View {
    @Bindable var session:LaTeXEditorSession
    let entry:LaTeXHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var changes=[LaTeXLineChange]()
    var body:some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {ForEach(changes) {change in
                    Text((change.kind == .inserted ? "+ ":change.kind == .removed ? "− ":"  ")+change.text).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,2)
                        .background(change.kind == .inserted ? Color.green.opacity(0.12):change.kind == .removed ? Color.red.opacity(0.12):Color.clear).textSelection(.enabled)
                }}
            }.navigationTitle(session.t("修订比较","Compare revision")+" r\(entry.manifest.revision)")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button(session.t("关闭","Close")) {dismiss()}}
                    ToolbarItem(placement:.confirmationAction) {Button(session.t("恢复此修订","Restore revision")) {Task {await session.restore(entry.manifest.revision);dismiss()}}}
                }
                .task {
                    do {let before=(try? await session.store.text(session.path,at:entry.manifest.revision)) ?? "";changes=LaTeXTextDiff.lines(before:before,after:session.source)}
                }
        }
    }
}

private struct LaTeXReferenceSheet:View {
    @Bindable var session:LaTeXEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var key=""
    @State private var title=""
    @State private var author=""
    @State private var year=""
    @State private var journal=""
    @State private var doi=""
    @State private var url=""
    @State private var type="article"
    var body:some View {
        NavigationStack {
            Form {
                Picker(session.t("类型","Type"),selection:$type) {Text(session.t("期刊文章","Journal article")).tag("article");Text(session.t("图书","Book")).tag("book");Text(session.t("会议论文","Conference paper")).tag("inproceedings");Text(session.t("其他","Other")).tag("misc")}
                TextField(session.t("引用键","Citation key"),text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(session.t("标题","Title"),text:$title,axis:.vertical)
                TextField(session.t("作者（用 and 分隔）","Authors (separated by and)"),text:$author)
                TextField(session.t("年份","Year"),text:$year)
                TextField(session.t("期刊或出版物","Journal or publisher"),text:$journal)
                TextField("DOI",text:$doi).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("URL",text:$url).textInputAutocapitalization(.never).autocorrectionDisabled()
            }.navigationTitle(session.t("添加文献","Add reference"))
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button(session.t("取消","Cancel")) {dismiss()}}
                    ToolbarItem(placement:.confirmationAction) {Button(session.t("添加","Add")) {Task {await add()}}.disabled(key.isEmpty || title.isEmpty)}
                }
        }
    }
    private func add() async {
        do {
            guard !session.references.contains(where:{$0.key == key}) else {throw LaTeXError.duplicatePath(key)}
            var fields=["title":title,"author":author,"year":year,type=="book" ? "publisher":"journal":journal,"doi":doi,"url":url]
            fields=fields.filter{!$0.value.isEmpty}
            let entry=try LaTeXBibParser.source(type:type,key:key,fields:fields)
            let path=session.manifest?.files.first{$0.kind == .bibliography}?.path ?? "references.bib"
            let existing=(try? await session.store.text(path)) ?? ""
            await session.mutate([.put(path:path,data:Data((existing+"\n"+entry).utf8))],label:"Add reference")
            if session.error == nil {dismiss()}
        }catch {session.report(error)}
    }
}
#endif
