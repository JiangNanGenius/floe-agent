// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeLaTeXParsing

struct LaTeXSourceEditor:UIViewRepresentable {
    @Bindable var session:LaTeXEditorSession
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->UITextView {
        let view=LaTeXSourceTextView(usingTextLayoutManager:false)
        view.commentAction={ [weak coordinator=context.coordinator] in coordinator?.comment() }
        view.indentAction={ [weak coordinator=context.coordinator] in coordinator?.indent() }
        view.copySource={ [weak coordinator=context.coordinator] in coordinator?.selectedSource() }
        view.expandSelection={ [weak coordinator=context.coordinator] in coordinator?.expandSelection() }
        view.foldAction={ [weak coordinator=context.coordinator] command in coordinator?.fold(command) }
        view.undoSource={ [weak coordinator=context.coordinator] in coordinator?.undoCanonical() }
        view.redoSource={ [weak coordinator=context.coordinator] in coordinator?.redoCanonical() }
        view.font = .monospacedSystemFont(ofSize:15,weight:.regular);view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = .init(top:16,left:12,bottom:80,right:12)
        view.autocorrectionType = .no;view.autocapitalizationType = .none;view.smartQuotesType = .no;view.smartDashesType = .no;view.smartInsertDeleteType = .no
        view.spellCheckingType = .no;view.inlinePredictionType = .no
        view.alwaysBounceVertical=true;view.delegate=context.coordinator
        view.accessibilityIdentifier="latex.sourceEditor"
        let bar=UIToolbar();bar.sizeToFit()
        let commands=[(session.t("开头","Start"),#selector(Coordinator.documentStart)),(session.t("全选","Select all"),#selector(Coordinator.selectAll)),(session.t("折叠","Fold"),#selector(Coordinator.toggleFold)),("↹",#selector(Coordinator.indent)),("%",#selector(Coordinator.comment)),("\\begin",#selector(Coordinator.environment)),("\\cite",#selector(Coordinator.citation)),("\\ref",#selector(Coordinator.reference))]
        bar.items=commands.map {UIBarButtonItem(title:$0.0,style:.plain,target:context.coordinator,action:$0.1)}
        view.inputAccessoryView=bar;context.coordinator.view=view
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        LaTeXInputTrace.record("update",view:view)
        context.coordinator.parent=self
        context.coordinator.synchronize(view)
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:LaTeXSourceEditor;weak var view:UITextView?;var reveal=UUID()
        var syncing=false
        var folding:LaTeXSourceFolding
        var path:String
        var foldRequest:UUID?
        init(_ parent:LaTeXSourceEditor) {
            self.parent=parent;path=parent.session.path
            folding = .init(source:parent.session.source,chinese:parent.session.chinese)
        }
        func synchronize(_ view:UITextView) {
            guard view.markedTextRange == nil else{return}
            let wasSyncing=syncing;syncing=true;defer {syncing=wasSyncing}
            var selection=folding.projection.sourceRange(view.selectedRange)
            if path != parent.session.path || folding.source != parent.session.source {
                path=parent.session.path;folding.reset(parent.session.source)
            }
            folding.chinese=parent.session.chinese
            if let request=parent.session.sourceFoldingRequest,request.path == parent.session.path,foldRequest != request.id {
                foldRequest=request.id;selection=folding.perform(request.command,selection:selection)
            }
            let revealing=reveal != parent.session.sourceReveal
            if revealing {
                reveal=parent.session.sourceReveal;selection=parent.session.sourceSelection
                folding.reveal(selection)
            }
            let actual=render(view,selection:selection,publish:false)
            let session=parent.session,source=folding.source,path=path,request=foldRequest
            DispatchQueue.main.async { [weak self,weak view] in
                guard let self,let view,self.parent.session === session,
                      session.path == path,session.source == source,
                      self.folding.projection.sourceRange(view.selectedRange) == actual else{return}
                if session.sourceSelection != actual {session.sourceSelection=actual}
                if let request,session.sourceFoldingRequest?.id == request {session.sourceFoldingRequest=nil}
            }
            if revealing {
                view.scrollRangeToVisible(view.selectedRange)
                DispatchQueue.main.async { [weak view,weak coordinator=self] in
                    if coordinator?.parent.session.mode == .source {view?.becomeFirstResponder()}
                }
            }
        }
        @discardableResult func render(_ view:UITextView,selection:NSRange,publish:Bool=true)->NSRange {
            let wasSyncing=syncing;syncing=true;defer {syncing=wasSyncing}
            let projection=folding.projection
            if view.text != projection.text {
                view.text=projection.text
                // UIKit cannot replay edits made against another projection.
                // The editor's canonical source undo/redo remains authoritative.
                view.undoManager?.removeAllActions()
            }
            view.selectedRange=projection.displayRange(selection)
            let canonical=projection.sourceRange(view.selectedRange)
            if publish,parent.session.sourceSelection != canonical {parent.session.sourceSelection=canonical}
            highlight(view)
            return canonical
        }
        func textViewDidChange(_ view:UITextView) {
            LaTeXInputTrace.record("change syncing=\(syncing)",view:view)
            guard !syncing,view.markedTextRange == nil else{return}
            do {
                let selection=try folding.accept(displayText:view.text,selection:view.selectedRange)
                parent.session.update(folding.source)
                render(view,selection:selection)
            }catch {
                // A display marker is never valid document text. Reveal the
                // original without committing an ambiguous projected edit.
                let selection=folding.projection.sourceRange(view.selectedRange)
                _=folding.perform(.expandAll,selection:selection)
                render(view,selection:selection)
            }
        }
        func textViewDidEndEditing(_ view:UITextView) {LaTeXInputTrace.record("end",view:view);view.unmarkText();textViewDidChange(view)}
        func textViewDidChangeSelection(_ view:UITextView) {
            LaTeXInputTrace.record("selection syncing=\(syncing)",view:view)
            guard !syncing,view.markedTextRange == nil else{return}
            if view.text != folding.projection.text {textViewDidChange(view);return}
            let selection=folding.projection.sourceRange(view.selectedRange)
            if folding.projection.touchesMarker(view.selectedRange) {
                folding.reveal(selection);render(view,selection:selection)
            }else {parent.session.sourceSelection=selection}
        }
        func textView(_ textView:UITextView,shouldChangeTextIn range:NSRange,replacementText text:String)->Bool {
            guard textView.markedTextRange == nil,folding.projection.touchesMarker(range) else{return true}
            let selection=folding.projection.sourceRange(textView.selectedRange)
            folding.reveal(folding.projection.sourceRange(range))
            render(textView,selection:selection);return false
        }
        func selectedSource()->String? {
            guard let view,view.selectedRange.length>0 else{return nil}
            return (folding.source as NSString).substring(with:folding.projection.sourceRange(view.selectedRange))
        }
        func expandSelection() {
            guard let view,view.markedTextRange == nil else{return}
            let selection=folding.projection.sourceRange(view.selectedRange)
            folding.reveal(selection);render(view,selection:selection)
        }
        func fold(_ command:LaTeXSourceFolding.Command) {
            guard let view,view.markedTextRange == nil else{return}
            let selection=folding.projection.sourceRange(view.selectedRange)
            let next=folding.perform(command,selection:selection)
            render(view,selection:next);view.scrollRangeToVisible(view.selectedRange)
        }
        func undoCanonical() {if let view {view.unmarkText();textViewDidChange(view)};parent.session.undo()}
        func redoCanonical() {if let view {view.unmarkText();textViewDidChange(view)};parent.session.redo()}
        @objc func toggleFold() {fold(.toggleCurrent)}
        func highlight(_ view:UITextView) {
            guard view.markedTextRange == nil,view.text.utf16.count<300000 else{return}
            let wasSyncing=syncing;syncing=true;defer {syncing=wasSyncing}
            let range=NSRange(location:0,length:view.text.utf16.count)
            view.textStorage.beginEditing()
            view.textStorage.setAttributes([.font:UIFont.monospacedSystemFont(ofSize:15,weight:.regular),.foregroundColor:UIColor.label],range:range)
            for (pattern,color) in [(#"\\[a-zA-Z@]+\*?"#,UIColor.systemBlue),(#"[{}\[\]]"#,UIColor.systemOrange),(#"(?m)(?<!\\)%.*$"#,UIColor.secondaryLabel)] {
                if let regex=try? NSRegularExpression(pattern:pattern) {for match in regex.matches(in:view.text,range:range) {view.textStorage.addAttribute(.foregroundColor,value:color,range:match.range)}}
            }
            for item in folding.projection.hidden {
                view.textStorage.addAttributes([.foregroundColor:UIColor.secondaryLabel,.backgroundColor:UIColor.tertiarySystemFill],range:item.display)
            }
            view.textStorage.endEditing()
            view.typingAttributes=[.font:UIFont.monospacedSystemFont(ofSize:15,weight:.regular),.foregroundColor:UIColor.label]
        }
        @objc func indent() {view?.insertText("  ");if let view {textViewDidChange(view)}}
        @objc func selectAll() {view?.becomeFirstResponder();view?.selectAll(nil)}
        @objc func documentStart() {view?.becomeFirstResponder();view?.selectedRange = .init(location:0,length:0);if let view {view.scrollRangeToVisible(view.selectedRange);LaTeXInputTrace.record("toolbarStart",view:view)}}
        @objc func comment() {
            guard let view else{return};expandSelection();let range=(view.text as NSString).lineRange(for:view.selectedRange)
            let text=(view.text as NSString).substring(with:range),lines=text.components(separatedBy:"\n")
            let uncomment=lines.filter{!$0.isEmpty}.allSatisfy{$0.hasPrefix("%")}
            let replacement=lines.enumerated().map {index,line in
                if line.isEmpty,index==lines.count-1 {return line}
                return uncomment && line.hasPrefix("%") ? String(line.dropFirst()):"%"+line
            }.joined(separator:"\n")
            view.selectedRange=range;view.insertText(replacement);textViewDidChange(view)
        }
        @objc func environment() {view?.insertText("\\begin{equation}\n\n\\end{equation}");if let view {textViewDidChange(view)}}
        @objc func citation() {view?.insertText("\\cite{}");if let view {textViewDidChange(view)}}
        @objc func reference() {view?.insertText("\\ref{}");if let view {textViewDidChange(view)}}
    }
}

/// Keep document navigation explicit while the code view owns focus. This
/// also avoids the system's floating input controls consuming Command-arrow.
private final class LaTeXSourceTextView:UITextView {
    var commentAction:(()->Void)?
    var indentAction:(()->Void)?
    var copySource:(()->String?)?
    var expandSelection:(()->Void)?
    var foldAction:((LaTeXSourceFolding.Command)->Void)?
    var undoSource:(()->Void)?
    var redoSource:(()->Void)?
    override func copy(_ sender:Any?) {if let text=copySource?() {UIPasteboard.general.string=text}else {super.copy(sender)}}
    override func cut(_ sender:Any?) {expandSelection?();super.cut(sender)}
    override func insertText(_ text:String) {LaTeXInputTrace.record("insert \(text.utf16.count)",view:self);super.insertText(text);LaTeXInputTrace.record("inserted",view:self)}
    override var keyCommands:[UIKeyCommand]? {
        let start=UIKeyCommand(input:UIKeyCommand.inputUpArrow,modifierFlags:.command,action:#selector(documentStart))
        let end=UIKeyCommand(input:UIKeyCommand.inputDownArrow,modifierFlags:.command,action:#selector(documentEnd))
        let comment=UIKeyCommand(input:"/",modifierFlags:.command,action:#selector(toggleComment))
        let indent=UIKeyCommand(input:"\t",modifierFlags:[],action:#selector(indentLine))
        let fold=UIKeyCommand(input:UIKeyCommand.inputLeftArrow,modifierFlags:[.command,.alternate],action:#selector(toggleFold))
        let expand=UIKeyCommand(input:UIKeyCommand.inputRightArrow,modifierFlags:[.command,.alternate],action:#selector(expandFolds))
        let undo=UIKeyCommand(input:"z",modifierFlags:.command,action:#selector(undoCanonical))
        let redo=UIKeyCommand(input:"z",modifierFlags:[.command,.shift],action:#selector(redoCanonical))
        let commands=[start,end,comment,indent,fold,expand,undo,redo]
        for command in commands {command.wantsPriorityOverSystemBehavior=true}
        return commands+(super.keyCommands ?? [])
    }
    @objc private func documentStart() {LaTeXInputTrace.record("documentStart",view:self);selectedRange = .init(location:0,length:0);scrollRangeToVisible(selectedRange)}
    @objc private func documentEnd() {selectedRange = .init(location:text.utf16.count,length:0);scrollRangeToVisible(selectedRange)}
    @objc private func toggleComment() {commentAction?()}
    @objc private func indentLine() {indentAction?()}
    @objc private func toggleFold() {foldAction?(.toggleCurrent)}
    @objc private func expandFolds() {foldAction?(.expandAll)}
    @objc private func undoCanonical() {undoSource?()}
    @objc private func redoCanonical() {redoSource?()}
}

/// Opt-in qualification trace contains positions/counts, never document text.
@MainActor private enum LaTeXInputTrace {
    static func record(_ event:String,view:UITextView) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--qualification-events"),let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        let url=directory.appendingPathComponent("LaTeXInput-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        let entry:[String:Any] = ["time":ProcessInfo.processInfo.systemUptime,"event":event,"location":view.selectedRange.location,"selectionLength":view.selectedRange.length,"textLength":view.text.utf16.count,"focused":view.isFirstResponder,"marked":view.markedTextRange != nil]
        guard let bytes=try? JSONSerialization.data(withJSONObject:entry) else{return}
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:Data())}
        guard let handle=try? FileHandle(forWritingTo:url) else{return};defer {try? handle.close()}
        _=try? handle.seekToEnd();try? handle.write(contentsOf:bytes+Data([10]))
        #endif
    }
}
#endif
