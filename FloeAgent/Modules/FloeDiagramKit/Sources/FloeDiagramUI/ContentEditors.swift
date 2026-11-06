// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import PencilKit
import Vision
import ImageIO
import FloeDiagramCore
import FloeDiagramExchange

struct ContentBlockEditor: View {
    @Binding var block: DiagramContentBlock
    let model: DiagramEditorModel
    @State private var exporting = false
    @State private var file: DiagramDataFile?
    @State private var fileName = "Attachment"
    var body: some View {
        Group {
            switch block {
            case .richText:
                Label(DL("富文本", "Rich text"),systemImage: "textformat").font(.caption).foregroundStyle(.secondary)
                DiagramRichTextInput(runs: Binding(get: { if case .richText(let runs) = block { runs } else { [] } },set: { block = .richText($0) })).frame(height: 150)
            case .formula(let latex):
                Label(DL("公式", "Formula"),systemImage: "function").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: stringBinding).font(.system(.body,design: .monospaced)).frame(minHeight: 70)
                FormulaPreview(latex: latex).frame(height: 56)
            case .code(let language, _):
                Label(DL("代码", "Code"),systemImage: "chevron.left.forwardslash.chevron.right").font(.caption).foregroundStyle(.secondary)
                TextField(DL("语言", "Language"),text: Binding(get: { if case .code(let value, _) = block { value } else { language } },set: { value in if case .code(_,let text) = block { block = .code(language: value,text: text) } }))
                TextEditor(text: stringBinding).font(.system(.callout,design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).frame(minHeight: 120)
            case .table:
                Label(DL("表格", "Table"),systemImage: "tablecells").font(.caption).foregroundStyle(.secondary)
                DiagramTableEditor(table: Binding(get: { if case .table(let table) = block { table } else { .init(rows: [[""]]) } },set: { block = .table($0) }))
            case .note:
                Label(DL("备注", "Note"),systemImage: "note.text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: stringBinding).frame(minHeight: 100)
            case .image(let id, _):
                if let bytes = model.assetBytes[id], let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160).accessibilityLabel(DL("主题图片", "Topic image")) }
                TextField(DL("图片说明", "Image caption"),text: stringBinding)
                attachmentButton(id)
            case .attachment(let id): attachmentButton(id)
            }
        }
        .fileExporter(isPresented: $exporting,document: file,contentType: .data,defaultFilename: fileName) { if case .failure(let error) = $0 { model.report(error) } }
    }
    private var stringBinding: Binding<String> {
        Binding(get: { block.plainText },set: { text in switch block {
        case .formula: block = .formula(text)
        case .code(let language, _): block = .code(language: language,text: text)
        case .image(let id, _): block = .image(assetID: id,caption: text)
        default: block = .note(text)
        } })
    }
    private func attachmentButton(_ id: UUID) -> some View {
        let asset = model.document.assets.first { $0.id == id }
        return Button { if let asset { model.launch { model in file = .init(data: try await model.assets.data(for: asset)); fileName = asset.fileName; exporting = true } } } label: { Label(asset?.fileName ?? DL("附件", "Attachment"),systemImage: "paperclip").lineLimit(2) }
    }
}
private struct FormulaPreview: View {
    let latex: String
    @State private var data: Data?
    @State private var valid = true
    var body: some View {
        Group { if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else if !valid { Text(DL("检查公式写法", "Check the formula syntax")).font(.caption).foregroundStyle(.secondary) } else { ProgressView() } }
            .task(id: latex) {
                data = nil
                do { data = try DiagramNativeExporter.previewFormula(latex,width: 240); valid = data != nil } catch { valid = false }
            }
    }
}
private struct DiagramTableEditor: View {
    @Binding var table: DiagramTable
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Toggle(DL("首行为表头", "Header row"),isOn: $table.header).font(.caption)
            ScrollView(.horizontal) {
                LazyVStack(spacing: 0) {
                    ForEach(table.rows.indices,id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(table.rows[row].indices,id: \.self) { column in
                                TextField("",text: $table.rows[row][column],axis: .vertical).font(.system(size: 13,weight: table.header && row == 0 ? .semibold : .regular)).padding(8).frame(width: 110).frame(minHeight: 44).background(row == 0 && table.header ? Color.secondary.opacity(0.08) : .clear).overlay(Rectangle().stroke(.quaternary,lineWidth: 0.5))
                            }
                            Button(role: .destructive) { table.rows.remove(at: row) } label: { Image(systemName: "minus.circle").frame(width: 44,height: 44) }.disabled(table.rows.count == 1).accessibilityLabel(DL("删除行", "Delete row"))
                        }
                    }
                }
            }.frame(maxHeight: 280)
            HStack {
                Button(DL("加行", "Add row")) { table.rows.append(Array(repeating: "",count: max(1,table.rows.first?.count ?? 1))) }
                Button(DL("加列", "Add column")) { for i in table.rows.indices { table.rows[i].append("") } }.disabled((table.rows.first?.count ?? 0) >= 20)
                Button(DL("删末列", "Remove last column")) { for i in table.rows.indices where table.rows[i].count > 1 { table.rows[i].removeLast() } }.disabled((table.rows.first?.count ?? 0) <= 1)
            }.font(.caption)
        }
    }
}

private struct DiagramRichTextInput: UIViewRepresentable {
    @Binding var runs: [DiagramTextRun]
    func makeCoordinator() -> Coordinator { Coordinator(runs: $runs) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.delegate = context.coordinator; view.backgroundColor = .secondarySystemGroupedBackground
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.allowsEditingTextAttributes = true; view.layer.cornerRadius = 8; context.coordinator.view = view
        let toolbar = UIToolbar(); toolbar.items = [UIBarButtonItem(image: UIImage(systemName: "bold"),style: .plain,target: context.coordinator,action: #selector(Coordinator.bold)), UIBarButtonItem(image: UIImage(systemName: "italic"),style: .plain,target: context.coordinator,action: #selector(Coordinator.italic)), UIBarButtonItem(image: UIImage(systemName: "underline"),style: .plain,target: context.coordinator,action: #selector(Coordinator.underline)), UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(systemItem: .done,primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder() })]
        toolbar.sizeToFit(); view.inputAccessoryView = toolbar; return view
    }
    func updateUIView(_ view: UITextView,context: Context) {
        context.coordinator.runs = $runs
        guard !view.isFirstResponder else { return }
        let text = NSMutableAttributedString(string: "")
        for run in runs {
            var traits: UIFontDescriptor.SymbolicTraits = []; if run.bold { traits.insert(.traitBold) }; if run.italic { traits.insert(.traitItalic) }
            let base = UIFont.preferredFont(forTextStyle: .body), font = base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0,size: base.pointSize) } ?? base
            var attributes: [NSAttributedString.Key: Any] = [.font: font,.foregroundColor: UIColor.label]
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }; if let link = run.link { attributes[.link] = link }
            text.append(.init(string: run.text,attributes: attributes))
        }
        if view.attributedText != text { view.attributedText = text }
    }
    @MainActor final class Coordinator: NSObject,UITextViewDelegate {
        var runs: Binding<[DiagramTextRun]>
        weak var view: UITextView?
        init(runs: Binding<[DiagramTextRun]>) { self.runs = runs }
        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            var result: [DiagramTextRun] = []
            textView.attributedText.enumerateAttributes(in: NSRange(location: 0,length: textView.attributedText.length)) { attributes,range,_ in
                let font = attributes[.font] as? UIFont, traits = font?.fontDescriptor.symbolicTraits ?? []
                result.append(.init((textView.attributedText.string as NSString).substring(with: range),bold: traits.contains(.traitBold),italic: traits.contains(.traitItalic),underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,link: (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String))
            }; runs.wrappedValue = result
        }
        @objc func bold() { toggle(.traitBold) }
        @objc func italic() { toggle(.traitItalic) }
        @objc func underline() {
            guard let view else { return }; let range = view.selectedRange
            if range.length == 0 { let existing = view.typingAttributes[.underlineStyle] as? Int ?? 0; view.typingAttributes[.underlineStyle] = existing == 0 ? NSUnderlineStyle.single.rawValue : 0 }
            else { let value = view.textStorage.attribute(.underlineStyle,at: range.location,effectiveRange: nil) as? Int ?? 0; view.textStorage.addAttribute(.underlineStyle,value: value == 0 ? NSUnderlineStyle.single.rawValue : 0,range: range); textViewDidChange(view) }
        }
        private func toggle(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let view else { return }; let range = view.selectedRange
            func font(_ current: UIFont) -> UIFont { let traits = current.fontDescriptor.symbolicTraits.symmetricDifference(trait); return current.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0,size: current.pointSize) } ?? current }
            if range.length == 0 { view.typingAttributes[.font] = font(view.typingAttributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)) }
            else { view.textStorage.beginEditing(); view.textStorage.enumerateAttribute(.font,in: range) { value,part,_ in view.textStorage.addAttribute(.font,value: font(value as? UIFont ?? .preferredFont(forTextStyle: .body)),range: part) }; view.textStorage.endEditing(); textViewDidChange(view) }
        }
    }
}

@MainActor public extension DiagramEditorModel {
    func recognizeInkText() {
        guard let data = page.ink else { return }; let p = pageID, selected = selectedElement?.id
        launch { model in
            let drawing = try PKDrawing(data: data), bounds = drawing.bounds.insetBy(dx: -12,dy: -12)
            guard !drawing.strokes.isEmpty, bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw DiagramError.invalid("empty ink") }
            let scale = min(2,4096/max(bounds.width,bounds.height)), size = CGSize(width: max(1,bounds.width*scale),height: max(1,bounds.height*scale))
            let image = drawing.image(from: bounds,scale: scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let png = UIGraphicsImageRenderer(size: size,format: format).image { context in UIColor.white.setFill(); context.fill(CGRect(origin: .zero,size: size)); image.draw(in: CGRect(origin: .zero,size: size)) }.pngData()!
            let text = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(png as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw DiagramError.invalid("ink image") }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                let supported = try request.supportedRecognitionLanguages(); request.recognitionLanguages = ["zh-Hans","en-US"].filter(supported.contains)
                try VNImageRequestHandler(cgImage: image,options: [:]).perform([request])
                return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(20_000))
            }.value
            guard !text.isEmpty else { throw DiagramError.invalid(DL("未识别到文字，笔迹已保留", "No text recognized. Your ink is retained.")) }
            model.perform(DL("识别笔迹文字", "Recognize ink text")) { doc in
                if let selected, var node = doc.page(p)?.elements.first(where: { $0.id == selected }) { node.content.append(.note(text)); node.contentExpanded = true; return [.upsertElement(pageID: p,element: node)] }
                return [.upsertElement(pageID: p,element: .init(kind: .floatingTopic,title: text,frame: .init(x: bounds.minX,y: bounds.maxY+24,width: 260,height: 100)))]
            }
        }
    }
}
#endif
