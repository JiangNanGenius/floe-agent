// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeLaTeXParsing

struct LaTeXRichTextEditor:UIViewRepresentable {
    var source:String
    var fontSize:CGFloat=18
    var bold=false
    var formulaRenderer:LaTeXFormulaRenderer?
    // The coordinator can receive several keystrokes before SwiftUI refreshes
    // its captured block. Validate against the immediately preceding source.
    var onChange:(_ original:String,_ replacement:String)->Bool
    var onFocus:()->Void
    var onAttachment:(NSRange,LaTeXInlineNode)->Void
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->UITextView {
        let view=UITextView(usingTextLayoutManager:false);view.isScrollEnabled=false
        view.backgroundColor = .clear;view.textContainerInset = .init(top:4,left:0,bottom:4,right:0)
        view.textContainer.lineFragmentPadding=0;view.delegate=context.coordinator
        view.adjustsFontForContentSizeCategory=true;view.accessibilityIdentifier="latex.visualText"
        let bar=UIToolbar();bar.sizeToFit()
        bar.items=[UIBarButtonItem(title:"B",style:.plain,target:context.coordinator,action:#selector(Coordinator.bold)),
                   UIBarButtonItem(title:"I",style:.plain,target:context.coordinator,action:#selector(Coordinator.italic)),
                   UIBarButtonItem(title:"U",style:.plain,target:context.coordinator,action:#selector(Coordinator.underline))]
        view.inputAccessoryView=bar;context.coordinator.view=view;context.coordinator.render(view)
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        context.coordinator.parent=self
        guard view.markedTextRange == nil,context.coordinator.document.source != source else{return}
        context.coordinator.document=LaTeXInlineDocument(source:source);context.coordinator.render(view)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextView,context:Context)->CGSize? {
        guard let width=proposal.width else{return nil}
        return uiView.sizeThatFits(.init(width:width,height:.greatestFiniteMagnitude))
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:LaTeXRichTextEditor
        var document:LaTeXInlineDocument
        weak var view:UITextView?
        var rendering=false
        init(_ parent:LaTeXRichTextEditor) {self.parent=parent;document = .init(source:parent.source)}
        func textViewDidBeginEditing(_ textView:UITextView) {parent.onFocus()}
        func textViewDidEndEditing(_ view:UITextView) {view.unmarkText();textViewDidChange(view)}
        func textViewDidChangeSelection(_ view:UITextView) {if !rendering,view.markedTextRange == nil,view.text != document.visibleText {textViewDidChange(view)}}
        func textViewDidChange(_ view:UITextView) {
            guard !rendering,view.markedTextRange == nil else{return}
            let old=Array(document.visibleText),new=Array(view.text ?? "")
            guard old != new else{return}
            var prefix=0,suffix=0
            while prefix<min(old.count,new.count),old[prefix]==new[prefix] {prefix+=1}
            while suffix<min(old.count-prefix,new.count-prefix),old[old.count-suffix-1]==new[new.count-suffix-1] {suffix+=1}
            let location=String(old.prefix(prefix)).utf16.count,length=String(old[prefix..<(old.count-suffix)]).utf16.count
            let replacement=String(new[prefix..<(new.count-suffix)])
            do {
                let source=try document.replacing(.init(location:location,length:length),with:replacement)
                publish(source,in:view)
            } catch {render(view)}
        }
        func render(_ view:UITextView) {
            rendering=true;defer {rendering=false}
            let selected=view.selectedRange
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=4
            let value=NSMutableAttributedString(string:document.visibleText,attributes:[.font:UIFont.systemFont(ofSize:parent.fontSize,weight:parent.bold ? .semibold:.regular),.foregroundColor:UIColor.label,.paragraphStyle:paragraph])
            for style in document.styleRanges() where style.range.length>0 {
                switch style.command {
                case "textbf":value.addAttribute(.font,value:UIFont.systemFont(ofSize:parent.fontSize,weight:.bold),range:style.range)
                case "emph","textit":value.addAttribute(.font,value:UIFont.italicSystemFont(ofSize:parent.fontSize),range:style.range)
                case "underline":value.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:style.range)
                case "texttt":value.addAttribute(.font,value:UIFont.monospacedSystemFont(ofSize:parent.fontSize,weight:.regular),range:style.range)
                default:break
                }
            }
            for item in document.attachments().reversed() {
                if case .attachment(_,let kind,let title,let expression)=item.node {
                    let attachment=NSTextAttachment()
                    let image=kind == "formula" ? parent.formulaRenderer?(expression,parent.fontSize):nil
                    attachment.image=image ?? FormulaSnapshot.chip(title.isEmpty ? "LaTeX":title,size:parent.fontSize)
                    if let size=attachment.image?.size {attachment.bounds=CGRect(x:0,y:-4,width:min(480,size.width),height:size.height)}
                    value.replaceCharacters(in:item.range,with:NSAttributedString(attachment:attachment))
                }
            }
            view.attributedText=value
            view.selectedRange=NSRange(location:min(selected.location,value.length),length:min(selected.length,max(0,value.length-selected.location)))
            view.typingAttributes=[.font:UIFont.systemFont(ofSize:parent.fontSize),.foregroundColor:UIColor.label,.paragraphStyle:paragraph]
        }
        func textView(_ textView:UITextView,shouldInteractWith attachment:NSTextAttachment,in characterRange:NSRange,interaction:UITextItemInteraction)->Bool {
            if let item=document.attachments().first(where:{$0.range==characterRange}) {parent.onAttachment(item.range,item.node)}
            return false
        }
        private func format(_ command:String) {
            guard let view,view.selectedRange.length>0,let source=try? document.formatting(view.selectedRange,command:command) else{return}
            publish(source,in:view)
        }
        private func publish(_ source:String,in view:UITextView) {
            let original=document.source
            guard original != source else{return}
            if parent.onChange(original,source) {document = .init(source:source)}
            render(view)
        }
        @objc func bold() {format("textbf")}
        @objc func italic() {format("textit")}
        @objc func underline() {format("underline")}
    }
}

@MainActor enum FormulaSnapshot {
    static func chip(_ title:String,size:CGFloat)->UIImage {
        let text=String(title.prefix(48)),font=UIFont.systemFont(ofSize:size-2,weight:.medium)
        let bounds=(text as NSString).size(withAttributes:[.font:font]),canvas=CGSize(width:min(420,bounds.width+16),height:max(26,bounds.height+8))
        return UIGraphicsImageRenderer(size:canvas).image {_ in
            UIColor.secondarySystemFill.setFill();UIBezierPath(roundedRect:CGRect(origin:.zero,size:canvas),cornerRadius:6).fill()
            (text as NSString).draw(in:CGRect(x:8,y:4,width:canvas.width-16,height:canvas.height-8),withAttributes:[.font:font,.foregroundColor:UIColor.label])
        }
    }
}
struct LaTeXFormulaPreview:View {
    var expression:String
    var renderer:LaTeXFormulaRenderer?
    var body:some View {
        if let image=renderer?(expression,24) {Image(uiImage:image).resizable().scaledToFit().frame(maxWidth:500,maxHeight:200).accessibilityLabel(expression)}
        else {Text(expression).font(.system(.body,design:.monospaced)).textSelection(.enabled)}
    }
}
#endif
