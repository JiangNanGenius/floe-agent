import Foundation
import SwiftUI
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct ToolboxTextUtilityView: View {
    public enum Mode: Sendable { case json, encoding }
    private let mode: Mode
    @Environment(\.locale) private var locale
    @State private var input = ""
    @State private var output = ""
    @State private var failed = false
    public init(mode: Mode) { self.mode = mode }
    public var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(workbenchText("输入","Input",locale)).font(.headline)
            TextEditor(text:$input).font(.system(.body,design:.monospaced)).frame(minHeight:120)
            ScrollView(.horizontal) {
                HStack {
                    if mode == .json {
                        Button(workbenchText("格式化","Format",locale)) { convert { try ToolboxJSON.format(input) } }
                        Button(workbenchText("压缩","Compact",locale)) { convert { try ToolboxJSON.format(input,style:.compact) } }
                        Button(workbenchText("排序键","Sort keys",locale)) { convert { try ToolboxJSON.format(input,style:.sorted) } }
                    } else {
                        Button("Base64 +") { convert { try ToolboxTextEncoding.base64Encode(input) } }
                        Button("Base64 −") { convert { try ToolboxTextEncoding.base64Decode(input) } }
                        Button("URL +") { convert { try ToolboxTextEncoding.urlEncode(input) } }
                        Button("URL −") { convert { try ToolboxTextEncoding.urlDecode(input) } }
                    }
                }.buttonStyle(.bordered)
            }
            if failed { Text(workbenchText("请检查内容格式和大小。","Check the input format and size.",locale)).foregroundStyle(.secondary) }
            Text(workbenchText("结果","Result",locale)).font(.headline)
            ScrollView { Text(output).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
        }.padding().navigationTitle(mode == .json ? workbenchText("JSON 格式化","JSON formatter",locale) : workbenchText("文本编码","Text encoding",locale))
    }
    private func convert(_ action: () throws -> String) { do { output = try action(); failed = false } catch { failed = true } }
}
public struct ToolboxQRView: View {
    @Environment(\.locale) private var locale
    @State private var input = ""
    @State private var result: [String] = []
    @State private var png: Data?
    @State private var failed = false
    private let importImage: @MainActor () async throws -> Data?
    private let exportImage: (Data)->Void
    public init(importImage: @escaping @MainActor () async throws -> Data?,exportImage: @escaping (Data)->Void) { self.importImage = importImage; self.exportImage = exportImage }
    public var body: some View {
        Form {
            Section(workbenchText("内容","Content",locale)) {
                TextField(workbenchText("文本或网址","Text or URL",locale),text:$input,axis:.vertical)
                Button(workbenchText("生成二维码","Generate QR code",locale)) { do { png = try ToolboxQR.png(text:input); failed = false } catch { failed = true } }
            }
            if let png {
                Section {
                    qrImage(png).interpolation(.none).resizable().scaledToFit().frame(maxWidth:320,maxHeight:320).accessibilityLabel(workbenchText("生成的二维码","Generated QR code",locale))
                    Button(workbenchText("导出图片","Export image",locale)) { exportImage(png) }
                }
            }
            Section {
                Button(workbenchText("从图片识别","Read from image",locale)) { Task { do { if let data = try await importImage() { result = try ToolboxQR.read(imageData:data); failed = false } } catch { failed = true } } }
                ForEach(Array(result.enumerated()),id:\.offset) { _,text in Text(text).textSelection(.enabled) }
            }
            if failed { Section { Text(workbenchText("请检查内容或选择其他图片。","Check the content or choose another image.",locale)).foregroundStyle(.secondary) } }
        }.navigationTitle(workbenchText("二维码","QR code",locale))
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
    @Published public var algorithm = ToolboxChecksumAlgorithm.sha256
    @Published public var comparison = ""
    @Published public private(set) var result: ToolboxChecksum?
    @Published public private(set) var title = ""
    @Published public private(set) var completedBytes: UInt64 = 0
    @Published public private(set) var busy = false
    @Published public private(set) var failed = false
    private let selectFile: @MainActor () async throws -> ToolboxSelectedChecksumFile?
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    public init(selectFile: @escaping @MainActor () async throws -> ToolboxSelectedChecksumFile?) { self.selectFile = selectFile }
    public func selectAndCalculate() {
        guard !busy else { return }; busy = true; failed = false; completedBytes = 0; let run = UUID(); generation = run
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let file = try await selectFile() else { if generation == run { busy = false }; return }
                guard generation == run, !Task.isCancelled else { return }; title = file.title
                let value = try await ToolboxFileChecksum.calculate(algorithm,expectedByteCount:file.byteCount,read:file.read,progress:{ [weak self] bytes in await self?.progress(bytes,run:run) })
                guard generation == run, !Task.isCancelled else { return }; result = value; busy = false; operation = nil
            } catch { guard generation == run else { return }; failed = !(error is CancellationError); busy = false; operation = nil }
        }
    }
    private func progress(_ bytes: UInt64,run: UUID) { if generation == run { completedBytes = bytes } }
    public func cancel() { generation = UUID(); operation?.cancel(); operation = nil; busy = false }
}
public struct ChecksumWorkbenchView: View {
    @ObservedObject private var model: ChecksumWorkbenchModel
    @Environment(\.locale) private var locale
    public init(model: ChecksumWorkbenchModel) { self.model = model }
    public var body: some View {
        Form {
            Picker(workbenchText("算法","Algorithm",locale),selection:$model.algorithm) { ForEach(ToolboxChecksumAlgorithm.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }.disabled(model.busy)
            Button(workbenchText("选择文件并计算","Choose file and calculate",locale)) { model.selectAndCalculate() }.disabled(model.busy)
            if !model.title.isEmpty { Text(model.title) }
            if model.busy { HStack { ProgressView(); Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:model.completedBytes),countStyle:.file)); Spacer(); Button(workbenchText("取消","Cancel",locale)) { model.cancel() } } }
            if let result = model.result {
                Text(result.hexadecimal).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                TextField(workbenchText("粘贴校验值以比较","Paste checksum to compare",locale),text:$model.comparison).autocorrectionDisabled()
                if !model.comparison.isEmpty { Label(result.matches(model.comparison) ? workbenchText("一致","Match",locale) : workbenchText("不一致","Does not match",locale),systemImage:result.matches(model.comparison) ? "checkmark.circle" : "xmark.circle") }
            }
            if model.failed { Text(workbenchText("未完成校验，请重新选择文件。","Checksum did not finish. Select the file again.",locale)).foregroundStyle(.secondary) }
        }.navigationTitle(workbenchText("文件校验","File checksum",locale))
    }
}
