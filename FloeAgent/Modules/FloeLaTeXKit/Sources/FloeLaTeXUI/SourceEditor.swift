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
        view.font = .monospacedSystemFont(ofSize:15,weight:.regular);view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = .init(top:16,left:12,bottom:80,right:12)
        view.autocorrectionType = .no;view.autocapitalizationType = .none;view.smartQuotesType = .no;view.smartDashesType = .no;view.smartInsertDeleteType = .no
        view.spellCheckingType = .no;view.inlinePredictionType = .no
        view.alwaysBounceVertical=true;view.delegate=context.coordinator
        view.accessibilityIdentifier="latex.sourceEditor"
        let bar=UIToolbar();bar.sizeToFit()
        let commands=[(session.t("开头","Start"),#selector(Coordinator.documentStart)),(session.t("全选","Select all"),#selector(Coordinator.selectAll)),("↹",#selector(Coordinator.indent)),("%",#selector(Coordinator.comment)),("\\begin",#selector(Coordinator.environment)),("\\cite",#selector(Coordinator.citation)),("\\ref",#selector(Coordinator.reference))]
        bar.items=commands.map {UIBarButtonItem(title:$0.0,style:.plain,target:context.coordinator,action:$0.1)}
        view.inputAccessoryView=bar;context.coordinator.view=view
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        LaTeXInputTrace.record("update",view:view)
        context.coordinator.parent=self
        let revealSelection=session.sourceSelection
        context.coordinator.syncing=true;defer {context.coordinator.syncing=false}
        if view.markedTextRange == nil,view.text != session.source {
            let selected=view.selectedRange;view.text=session.source;context.coordinator.highlight(view)
            view.selectedRange=NSRange(location:min(selected.location,view.text.utf16.count),length:0)
        }
        if context.coordinator.reveal != session.sourceReveal {
            context.coordinator.reveal=session.sourceReveal
            view.selectedRange=revealSelection;view.scrollRangeToVisible(revealSelection)
            DispatchQueue.main.async { [weak view,weak coordinator=context.coordinator] in
                if coordinator?.parent.session.mode == .source {view?.becomeFirstResponder()}
            }
        }
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:LaTeXSourceEditor;weak var view:UITextView?;var reveal=UUID()
        var syncing=false
        init(_ parent:LaTeXSourceEditor) {self.parent=parent}
        func textViewDidChange(_ view:UITextView) {LaTeXInputTrace.record("change syncing=\(syncing)",view:view);guard !syncing,view.markedTextRange == nil else{return};parent.session.update(view.text);highlight(view)}
        func textViewDidEndEditing(_ view:UITextView) {LaTeXInputTrace.record("end",view:view);view.unmarkText();textViewDidChange(view)}
        func textViewDidChangeSelection(_ view:UITextView) {LaTeXInputTrace.record("selection syncing=\(syncing)",view:view);guard !syncing else{return};parent.session.sourceSelection=view.selectedRange;if view.markedTextRange == nil,view.text != parent.session.source {textViewDidChange(view)}}
        func highlight(_ view:UITextView) {
            guard view.markedTextRange == nil,view.text.utf16.count<300000 else{return}
            let wasSyncing=syncing;syncing=true;defer {syncing=wasSyncing}
            let range=NSRange(location:0,length:view.text.utf16.count)
            view.textStorage.beginEditing()
            view.textStorage.setAttributes([.font:UIFont.monospacedSystemFont(ofSize:15,weight:.regular),.foregroundColor:UIColor.label],range:range)
            for (pattern,color) in [(#"\\[a-zA-Z@]+\*?"#,UIColor.systemBlue),(#"[{}\[\]]"#,UIColor.systemOrange),(#"(?m)(?<!\\)%.*$"#,UIColor.secondaryLabel)] {
                if let regex=try? NSRegularExpression(pattern:pattern) {for match in regex.matches(in:view.text,range:range) {view.textStorage.addAttribute(.foregroundColor,value:color,range:match.range)}}
            }
            view.textStorage.endEditing()
            view.typingAttributes=[.font:UIFont.monospacedSystemFont(ofSize:15,weight:.regular),.foregroundColor:UIColor.label]
        }
        @objc func indent() {view?.insertText("  ");if let view {textViewDidChange(view)}}
        @objc func selectAll() {view?.becomeFirstResponder();view?.selectAll(nil)}
        @objc func documentStart() {view?.becomeFirstResponder();view?.selectedRange = .init(location:0,length:0);if let view {view.scrollRangeToVisible(view.selectedRange);LaTeXInputTrace.record("toolbarStart",view:view)}}
        @objc func comment() {
            guard let view else{return};let range=(view.text as NSString).lineRange(for:view.selectedRange)
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
    override func insertText(_ text:String) {LaTeXInputTrace.record("insert \(text.utf16.count)",view:self);super.insertText(text);LaTeXInputTrace.record("inserted",view:self)}
    override var keyCommands:[UIKeyCommand]? {
        let start=UIKeyCommand(input:UIKeyCommand.inputUpArrow,modifierFlags:.command,action:#selector(documentStart))
        let end=UIKeyCommand(input:UIKeyCommand.inputDownArrow,modifierFlags:.command,action:#selector(documentEnd))
        let comment=UIKeyCommand(input:"/",modifierFlags:.command,action:#selector(toggleComment))
        let indent=UIKeyCommand(input:"\t",modifierFlags:[],action:#selector(indentLine))
        for command in [start,end,comment,indent] {command.wantsPriorityOverSystemBehavior=true}
        return [start,end,comment,indent]+(super.keyCommands ?? [])
    }
    @objc private func documentStart() {LaTeXInputTrace.record("documentStart",view:self);selectedRange = .init(location:0,length:0);scrollRangeToVisible(selectedRange)}
    @objc private func documentEnd() {selectedRange = .init(location:text.utf16.count,length:0);scrollRangeToVisible(selectedRange)}
    @objc private func toggleComment() {commentAction?()}
    @objc private func indentLine() {indentAction?()}
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
