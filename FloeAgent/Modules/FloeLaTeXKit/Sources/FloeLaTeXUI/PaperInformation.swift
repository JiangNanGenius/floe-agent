// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXParsing

struct LaTeXPaperInformation:View {
    @Bindable var session:LaTeXEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var values=[String:String]()
    @State private var source=""
    @State private var path=""
    @State private var revision:Int64?
    @State private var saving=false
    var body:some View {
        NavigationStack {
            Form {
                if revision == nil {ProgressView()}
                ForEach(["title","author","date"],id:\.self) {key in
                    Section(title(key)) {
                        LaTeXRichTextEditor(source:values[key] ?? "",fontSize:18,formulaRenderer:session.formulaRenderer,onChange:{_,value in values[key]=value;return true},onFocus:{},onAttachment:{_,_ in})
                            .frame(minHeight:60)
                    }
                }
            }.navigationTitle(session.t("论文信息","Paper information"))
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button(session.t("取消","Cancel")) {dismiss()}}
                    ToolbarItem(placement:.confirmationAction) {Button(session.t("保存","Save")) {Task {await save()}}.disabled(revision == nil || saving)}
                }
                .task {
                    do {
                        try await session.save();guard let main=session.manifest?.mainFile else {return}
                        let captured=try await session.store.file(main)
                        guard let text=String(data:captured.data,encoding:.utf8) else {throw LaTeXError.invalidText}
                        source=text;path=main;revision=captured.manifest.revision
                        let index=LaTeXParser.parse(text)
                        for key in ["title","author","date"] {values[key]=index.commands.last(where:{$0.name==key && $0.range.start<index.bodyRange.start})?.arguments.last(where:{!$0.optional})?.value ?? ""}
                    }catch {session.report(error)}
                }
        }.presentationDetents([.medium,.large])
    }
    private func title(_ key:String)->String {switch key {case "title":session.t("论文标题","Title");case "author":session.t("作者","Authors");default:session.t("日期","Date")}}
    private func save() async {
        session.commitInput()
        guard let revision else{return};saving=true;defer {saving=false}
        do {
            let edits=try LaTeXProjectEditing.preambleEdits(source:source,path:path,values:values)
            if !edits.isEmpty {_=try await session.store.apply(edits,expectedRevision:revision,label:"Paper information")}
            await session.refresh();dismiss()
        }catch {session.report(error)}
    }
}
#endif
