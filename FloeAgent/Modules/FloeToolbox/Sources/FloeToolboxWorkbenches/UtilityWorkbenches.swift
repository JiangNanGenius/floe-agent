import Foundation
import SwiftUI
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// JSON and text conversions have one current input/result pair. Editing the
/// next input or attempting a failed conversion cannot retain old output.
@MainActor public final class ToolboxTextUtilityModel: ObservableObject {
    public enum Action: Sendable, Hashable { case formatJSON, compactJSON, sortJSON, base64Encode, base64Decode, urlEncode, urlDecode }
    @Published public var input = "" {
        didSet { if input != oldValue { output = ""; errorDetail = nil; lastAction = nil } }
    }
    @Published public private(set) var output = ""
    @Published public private(set) var errorDetail: String?
    @Published public private(set) var lastAction: Action?
    public var failed: Bool { errorDetail != nil }
    public init() {}
    public func perform(_ action: Action) {
        let frozen = input
        output = ""; errorDetail = nil; lastAction = action
        do {
            switch action {
            case .formatJSON: output = try ToolboxJSON.format(frozen)
            case .compactJSON: output = try ToolboxJSON.format(frozen,style:.compact)
            case .sortJSON: output = try ToolboxJSON.format(frozen,style:.sorted)
            case .base64Encode: output = try ToolboxTextEncoding.base64Encode(frozen)
            case .base64Decode: output = try ToolboxTextEncoding.base64Decode(frozen)
            case .urlEncode: output = try ToolboxTextEncoding.urlEncode(frozen)
            case .urlDecode: output = try ToolboxTextEncoding.urlDecode(frozen)
            }
        } catch { output = ""; errorDetail = String(reflecting:error) }
    }
}

public struct ToolboxTextUtilityView: View {
    public enum Mode: Sendable { case json, encoding }
    private let mode: Mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = ToolboxTextUtilityModel()
    @State private var action:ToolboxTextUtilityModel.Action
    @State private var copied=false
    @FocusState private var inputFocused:Bool
    public init(mode: Mode) {
        self.mode = mode
        _action=State(initialValue:mode == .json ? .formatJSON:.base64Encode)
    }
    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width>=760 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment:.top,spacing:16) {
                    GroupBox { inputEditor.frame(maxHeight:.infinity) } label:{ Label(workbenchText("输入","Input",locale),systemImage:"text.cursor") }
                    GroupBox { resultContent.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading) } label:{ Label(workbenchText("结果","Result",locale),systemImage:"text.alignleft") }
                }.padding(16)
            } else {
                Form {
                    Section(workbenchText("输入","Input",locale)) { inputEditor.frame(minHeight:160,maxHeight:240) }
                    Section(workbenchText("结果","Result",locale)) { resultContent.frame(minHeight:180) }
                }
            }
        }
        .safeAreaInset(edge:.bottom,spacing:0) {
            operationControls.padding(.horizontal,16).padding(.vertical,10).background(.bar)
        }
        .navigationTitle(mode == .json ? workbenchText("JSON 格式化","JSON formatter",locale) : workbenchText("文本编码","Text encoding",locale))
        .onChange(of:model.output) {_,_ in copied=false}
    }
    private var actions:[ToolboxTextUtilityModel.Action] {
        mode == .json ? [.formatJSON,.compactJSON,.sortJSON]:[.base64Encode,.base64Decode,.urlEncode,.urlDecode]
    }
    private func title(_ action:ToolboxTextUtilityModel.Action)->String {
        switch action {
        case .formatJSON:workbenchText("格式化 JSON","Format JSON",locale)
        case .compactJSON:workbenchText("压缩 JSON","Compact JSON",locale)
        case .sortJSON:workbenchText("按键名排序","Sort JSON keys",locale)
        case .base64Encode:workbenchText("Base64 编码","Base64 encode",locale)
        case .base64Decode:workbenchText("Base64 解码","Base64 decode",locale)
        case .urlEncode:workbenchText("URL 编码","URL encode",locale)
        case .urlDecode:workbenchText("URL 解码","URL decode",locale)
        }
    }
    private var inputEditor:some View {
        ZStack(alignment:.topLeading) {
            TextEditor(text:$model.input).font(.system(.body,design:.monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled().focused($inputFocused)
                .accessibilityLabel(workbenchText("输入内容","Input text",locale))
                .accessibilityIdentifier("toolbox.utility.input")
            if model.input.isEmpty {
                Text(mode == .json ? workbenchText("粘贴 JSON 内容","Paste JSON here",locale):workbenchText("输入要编码或解码的文本","Enter text to encode or decode",locale))
                    .foregroundStyle(.secondary).padding(.horizontal,6).padding(.vertical,8)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    private var operationControls:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:16) { operationPicker;Spacer(minLength:8);runButton }
            VStack(alignment:.leading,spacing:8) { operationPicker;runButton.frame(maxWidth:.infinity,alignment:.trailing) }
        }
    }
    private var operationPicker:some View {
        Picker(workbenchText("转换方式","Conversion",locale),selection:$action) {
            ForEach(actions,id:\.self) { action in Text(title(action)).tag(action) }
        }.pickerStyle(.menu).accessibilityIdentifier("toolbox.utility.operation")
    }
    private var runButton:some View {
        Button {
            inputFocused=false;model.perform(action)
        } label: {
            Label(model.failed ? workbenchText("重试转换","Retry conversion",locale):title(action),systemImage:"arrow.left.arrow.right")
                .frame(minHeight:44)
        }.buttonStyle(.borderedProminent).disabled(model.input.isEmpty)
            .accessibilityIdentifier("toolbox.utility.convert")
    }
    @ViewBuilder private var resultContent:some View {
        if let detail=model.errorDetail {
            VStack(alignment:.leading,spacing:12) {
                Label(workbenchText("未能转换","Unable to convert",locale),systemImage:"exclamationmark.triangle")
                Text(workbenchText("请检查输入格式，修改后重新转换。","Check the input format, edit it and convert again.",locale)).foregroundStyle(.secondary)
                DisclosureGroup(workbenchText("查看详情","View details",locale)) {Text(detail).font(.caption.monospaced()).textSelection(.enabled)}
            }
        } else if let lastAction=model.lastAction {
            VStack(alignment:.leading,spacing:12) {
                Text(title(lastAction)).font(.subheadline).foregroundStyle(.secondary)
                if model.output.isEmpty {
                    ContentUnavailableView(workbenchText("结果为空","Empty result",locale),systemImage:"text.alignleft",description:Text(workbenchText("转换已完成，输出为空。","Conversion completed with empty output.",locale)))
                } else {
                    ScrollView {Text(model.output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                        .accessibilityIdentifier("toolbox.utility.result")
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:12) { resultActions }
                        VStack(alignment:.leading,spacing:8) { resultActions }
                    }
                }
            }
        } else {
            ContentUnavailableView(workbenchText("等待转换","Ready to convert",locale),systemImage:"arrow.left.arrow.right",description:Text(workbenchText("输入内容并选择转换方式，结果会显示在这里。","Enter text and choose a conversion. The result appears here.",locale)))
        }
    }
    @ViewBuilder private var resultActions:some View {
        Button(copied ? workbenchText("已复制","Copied",locale):workbenchText("复制结果","Copy result",locale),systemImage:copied ? "checkmark":"doc.on.doc") {
            workbenchCopy(model.output);copied=true
        }.frame(minHeight:44).accessibilityIdentifier("toolbox.utility.copy")
        ShareLink(item:model.output) {Label(workbenchText("分享结果","Share result",locale),systemImage:"square.and.arrow.up")}
            .frame(minHeight:44).accessibilityIdentifier("toolbox.utility.share")
    }
}

@MainActor private func workbenchCopy(_ value:String) {
    #if os(iOS)
    UIPasteboard.general.string=value
    #elseif os(macOS)
    NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)
    #endif
}
public struct ToolboxQRView: View {
    @Environment(\.locale) private var locale
    @State private var input = ""
    @State private var result: [String] = []
    @State private var png: Data?
    @State private var generationFailed = false
    @State private var readingFailed = false
    @State private var reading = false
    @State private var didRead = false
    private let importImage: @MainActor () async throws -> Data?
    private let exportImage: (Data)->Void
    public init(importImage: @escaping @MainActor () async throws -> Data?,exportImage: @escaping (Data)->Void) { self.importImage = importImage; self.exportImage = exportImage }
    public var body: some View {
        Form {
            Section(workbenchText("生成二维码","Generate QR code",locale)) {
                TextField(workbenchText("文本或网址","Text or URL",locale),text:$input,axis:.vertical)
                    .autocorrectionDisabled().accessibilityIdentifier("toolbox.qr.input")
                Button(workbenchText("生成二维码","Generate QR code",locale),systemImage:"qrcode") {
                    do {png = try ToolboxQR.png(text:input);generationFailed=false}
                    catch {png=nil;generationFailed=true}
                }.disabled(input.isEmpty).accessibilityIdentifier("toolbox.qr.generate")
                if generationFailed {
                    Label(workbenchText("未能生成，请检查内容长度后重试。","Unable to generate. Check the text length and retry.",locale),systemImage:"exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            if let png {
                Section {
                    qrImage(png).interpolation(.none).resizable().scaledToFit().frame(maxWidth:320,maxHeight:320).accessibilityLabel(workbenchText("生成的二维码","Generated QR code",locale))
                    Button(workbenchText("导出图片","Export image",locale),systemImage:"square.and.arrow.up") { exportImage(png) }
                        .accessibilityIdentifier("toolbox.qr.export")
                }
            }
            Section(workbenchText("识别图片","Read an image",locale)) {
                Button(workbenchText("选择图片识别","Choose an image to read",locale),systemImage:"photo") {readImage()}
                    .disabled(reading).accessibilityIdentifier("toolbox.qr.read")
                if reading {ProgressView(workbenchText("正在读取图片","Reading image",locale))}
                else if readingFailed {
                    Label(workbenchText("未能读取这张图片，请选择其他图片重试。","Unable to read this image. Choose another image and retry.",locale),systemImage:"exclamationmark.triangle").foregroundStyle(.secondary)
                } else if didRead,result.isEmpty {
                    ContentUnavailableView(workbenchText("未发现二维码","No QR code found",locale),systemImage:"qrcode",description:Text(workbenchText("请换一张二维码完整、清晰的图片。","Choose an image with a complete, clear QR code.",locale)))
                } else if !didRead {
                    Text(workbenchText("选择图片后，识别出的内容可复制或分享。","Choose an image to read its QR codes, then copy or share their content.",locale)).foregroundStyle(.secondary)
                }
            }
            if didRead,!reading,!result.isEmpty {
                Section(workbenchText("识别结果","Recognized content",locale)) {
                    ForEach(Array(result.enumerated()),id:\.offset) { index,text in
                        VStack(alignment:.leading,spacing:8) {
                            if result.count>1 {Text(workbenchText("二维码 \(index+1)","QR code \(index+1)",locale)).font(.subheadline).foregroundStyle(.secondary)}
                            Text(text).textSelection(.enabled)
                            ViewThatFits(in:.horizontal) {
                                HStack(spacing:12) {qrResultActions(text)}
                                VStack(alignment:.leading,spacing:8) {qrResultActions(text)}
                            }
                        }.padding(.vertical,4)
                    }
                }
            }
        }.navigationTitle(workbenchText("二维码","QR code",locale))
            .onChange(of:input) {_,_ in png=nil;generationFailed=false}
    }
    private func readImage() {
        guard !reading else {return};reading=true;readingFailed=false
        Task { @MainActor in
            defer {reading=false}
            do {
                guard let data=try await importImage() else {return}
                result=[];didRead=false
                let work=Task.detached(priority:.userInitiated) {
                    try Task.checkCancellation()
                    let values=try ToolboxQR.read(imageData:data)
                    try Task.checkCancellation();return values
                }
                result=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                didRead=true
            } catch is CancellationError {} catch {result=[];didRead=false;readingFailed=true}
        }
    }
    @ViewBuilder private func qrResultActions(_ text:String)->some View {
        Button(workbenchText("复制内容","Copy content",locale),systemImage:"doc.on.doc") {workbenchCopy(text)}.frame(minHeight:44)
        ShareLink(item:text) {Label(workbenchText("分享内容","Share content",locale),systemImage:"square.and.arrow.up")}.frame(minHeight:44)
    }
    private func qrImage(_ bytes: Data) -> Image {
        #if os(iOS)
        if let image = UIImage(data:bytes) { return Image(uiImage:image) }
        #elseif os(macOS)
        if let image = NSImage(data:bytes) { return Image(nsImage:image) }
        #endif
        return Image(systemName:"qrcode")
    }
}
public struct ToolboxSelectedChecksumFile: Sendable {
    public let title: String
    public let byteCount: UInt64?
    public let read: ToolboxByteReader
    public init(title: String,byteCount: UInt64?,read: @escaping ToolboxByteReader) { self.title = title; self.byteCount = byteCount; self.read = read }
}
@MainActor public final class ChecksumWorkbenchModel: ObservableObject {
    @Published public var algorithm = ToolboxChecksumAlgorithm.sha256 {
        didSet {
            guard algorithm != oldValue else {return}
            cancel();result=nil;title="";completedBytes=0;expectedBytes=nil;failed=false;cancelled=false
        }
    }
    @Published public var comparison = ""
    @Published public private(set) var result: ToolboxChecksum?
    @Published public private(set) var title = ""
    @Published public private(set) var completedBytes: UInt64 = 0
    @Published public private(set) var expectedBytes: UInt64?
    @Published public private(set) var busy = false
    @Published public private(set) var failed = false
    @Published public private(set) var cancelled = false
    @Published public private(set) var stopping = false
    private let selectFile: @MainActor () async throws -> ToolboxSelectedChecksumFile?
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    public init(selectFile: @escaping @MainActor () async throws -> ToolboxSelectedChecksumFile?) { self.selectFile = selectFile }
    public func selectAndCalculate() {
        guard !busy else { return }
        let selectedAlgorithm=algorithm
        busy=true;failed=false;cancelled=false;completedBytes=0;expectedBytes=nil;result=nil;title=""
        let run = UUID(); generation = run
        operation = Task { [weak self] in
            guard let self else { return }
            defer {if generation==run {busy=false;stopping=false;operation=nil}}
            do {
                guard let file = try await selectFile() else { if generation == run { busy = false;operation=nil }; return }
                guard generation == run, !Task.isCancelled else { return }; title = file.title;expectedBytes=file.byteCount
                let work=Task.detached(priority:.userInitiated) { [weak self] in
                    try await ToolboxFileChecksum.calculate(selectedAlgorithm,expectedByteCount:file.byteCount,read:file.read,progress:{ [weak self] bytes in await self?.progress(bytes,run:run) })
                }
                let value=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                guard generation == run, !Task.isCancelled else { return }; result = value; busy = false; operation = nil
            } catch { guard generation == run else { return };let wasCancelled=error is CancellationError || Task.isCancelled;failed = !wasCancelled;cancelled=wasCancelled }
        }
    }
    private func progress(_ bytes: UInt64,run: UUID) { if generation == run,busy,!stopping { completedBytes = bytes } }
    public func cancel() {
        guard busy || operation != nil else {return}
        operation?.cancel();stopping=true;cancelled=true
    }
}
public struct ChecksumWorkbenchView: View {
    @ObservedObject private var model: ChecksumWorkbenchModel
    @Environment(\.locale) private var locale
    @State private var copied=false
    public init(model: ChecksumWorkbenchModel) { self.model = model }
    public var body: some View {
        Form {
            Section(workbenchText("校验文件","File to verify",locale)) {
                Picker(workbenchText("算法","Algorithm",locale),selection:$model.algorithm) {
                    ForEach(ToolboxChecksumAlgorithm.allCases,id:\.self) {Text($0.rawValue.uppercased()).tag($0)}
                }.disabled(model.busy).accessibilityIdentifier("toolbox.checksum.algorithm")
                Button(model.failed ? workbenchText("重新选择文件并计算","Choose a file and retry",locale):workbenchText("选择文件并计算","Choose file and calculate",locale),systemImage:"doc.badge.plus") {model.selectAndCalculate()}
                    .disabled(model.busy).accessibilityIdentifier("toolbox.checksum.choose")
                if !model.title.isEmpty {
                    LabeledContent(workbenchText("文件","File",locale)) {Text(model.title).lineLimit(3).textSelection(.enabled)}
                }
            }
            if model.busy {
                Section {
                    if model.stopping {ProgressView(workbenchText("正在停止校验","Stopping checksum",locale))}
                    else if let total=model.expectedBytes,total>0 {
                        ProgressView(workbenchText("正在计算摘要","Calculating checksum",locale),value:Double(min(model.completedBytes,total)),total:Double(total))
                    } else {ProgressView(model.title.isEmpty ? workbenchText("等待选择文件","Waiting for a file",locale):workbenchText("正在计算摘要","Calculating checksum",locale))}
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:model.completedBytes),countStyle:.file)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button(workbenchText("停止校验","Stop checksum",locale),systemImage:"stop.circle") {model.cancel()}.frame(minHeight:44).disabled(model.stopping)
                    }
                }.accessibilityIdentifier("toolbox.checksum.progress")
            }
            if let result = model.result {
                Section(workbenchText("校验结果","Checksum result",locale)) {
                    LabeledContent(workbenchText("算法","Algorithm",locale),value:result.algorithm.rawValue.uppercased())
                    LabeledContent(workbenchText("文件大小","File size",locale),value:ByteCountFormatter.string(fromByteCount:Int64(clamping:result.byteCount),countStyle:.file))
                    Text(result.hexadecimal).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("toolbox.checksum.result")
                    Button(copied ? workbenchText("已复制","Copied",locale):workbenchText("复制校验值","Copy checksum",locale),systemImage:copied ? "checkmark":"doc.on.doc") {workbenchCopy(result.hexadecimal);copied=true}
                        .accessibilityIdentifier("toolbox.checksum.copy")
                    ShareLink(item:result.hexadecimal) {Label(workbenchText("分享校验值","Share checksum",locale),systemImage:"square.and.arrow.up")}
                }
                Section(workbenchText("比较校验值","Compare checksum",locale)) {
                    TextField(workbenchText("粘贴来源提供的校验值","Paste the checksum supplied by the source",locale),text:$model.comparison,axis:.vertical)
                        .autocorrectionDisabled().font(.body.monospaced()).accessibilityIdentifier("toolbox.checksum.comparison")
                    if !model.comparison.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        let matches=result.matches(model.comparison)
                        Label(matches ? workbenchText("校验值一致","Checksums match",locale):workbenchText("校验值不一致","Checksums do not match",locale),systemImage:matches ? "checkmark.circle.fill":"xmark.circle.fill")
                            .foregroundStyle(matches ? .green:.red).accessibilityIdentifier("toolbox.checksum.match")
                    }
                }
            } else if model.failed {
                Section {Label(workbenchText("未能完成校验","Unable to complete checksum",locale),systemImage:"exclamationmark.triangle");Text(workbenchText("请重新选择文件再试，未生成新的校验结果。","Choose the file again to retry. No new checksum was produced.",locale)).foregroundStyle(.secondary)}
            } else if model.cancelled {
                Section {Label(workbenchText("校验已停止","Checksum stopped",locale),systemImage:"stop.circle");Text(workbenchText("可以重新选择文件继续。","Choose a file to start again.",locale)).foregroundStyle(.secondary)}
            } else if !model.busy {
                Section {ContentUnavailableView(workbenchText("尚无校验结果","No checksum yet",locale),systemImage:"doc.text.magnifyingglass",description:Text(workbenchText("选择文件后计算摘要，并可与来源提供的校验值比较。","Choose a file to calculate its checksum and compare it with the value supplied by the source.",locale)))}
            }
        }.navigationTitle(workbenchText("文件校验","File checksum",locale))
            .onChange(of:model.result) {_,_ in copied=false}
    }
}
