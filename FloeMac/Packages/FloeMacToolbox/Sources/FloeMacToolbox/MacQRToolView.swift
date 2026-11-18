import AppKit
import Combine
import SwiftUI
import FloeToolboxCore
import FloeToolboxUtilities
import FloeMacMediaSystem

@MainActor
final class MacQRModel: ObservableObject {
    @Published var input = "" {
        didSet {
            if input != oldValue {
                png = nil
                generationFailed = false
            }
        }
    }
    @Published private(set) var png: Data?
    @Published private(set) var generationFailed = false
    @Published private(set) var result: [String] = []
    @Published private(set) var reading = false
    @Published private(set) var readingFailed = false
    @Published private(set) var didRead = false

    private let importImage: @MainActor () async throws -> URL?
    private var readTask: Task<Void, Never>?
    private var readGeneration = UUID()

    init(importImage: @escaping @MainActor () async throws -> URL?) {
        self.importImage = importImage
    }

    func generate() {
        do {
            png = try ToolboxQR.png(text: input)
            generationFailed = false
        } catch {
            png = nil
            generationFailed = true
        }
    }

    func readImage() {
        guard !reading else { return }
        reading = true
        readingFailed = false
        let token = UUID()
        readGeneration = token
        readTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.readGeneration == token {
                    self.reading = false
                    self.readTask = nil
                }
            }
            do {
                guard let url = try await self.importImage() else { return }
                guard self.readGeneration == token, !Task.isCancelled else { return }
                self.result = []
                self.didRead = false
                let work = Task.detached(priority: .userInitiated) { () throws -> [String] in
                    try Task.checkCancellation()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 16 * 1024 * 1024 else { throw ToolboxError.limit("QR image") }
                    try Task.checkCancellation()
                    return try ToolboxQR.read(imageData: data)
                }
                let values = try await withTaskCancellationHandler(
                    operation: { try await work.value },
                    onCancel: { work.cancel() }
                )
                guard self.readGeneration == token, !Task.isCancelled else { return }
                self.result = values
                self.didRead = true
            } catch is CancellationError {
            } catch {
                guard self.readGeneration == token, !Task.isCancelled else { return }
                self.result = []
                self.didRead = false
                self.readingFailed = true
            }
        }
    }

    func useResult(_ text: String) {
        input = text
    }

    func acceptCameraResult(_ text: String) {
        result = [text]
        didRead = true
        readingFailed = false
    }

    func cancelRead() {
        readGeneration = UUID()
        readTask?.cancel()
        readTask = nil
        reading = false
    }

    func clearResult() {
        result = []
        didRead = false
        readingFailed = false
    }
}

/// A QR payload opens as a link only when it already contains an absolute
/// HTTP(S) URL. Path, query and fragment are preserved; control characters
/// and invalid hosts are rejected.
enum MacQRLink {
    nonisolated static func destination(for payload: String) -> URL? {
        guard payload.utf8.count <= 8192 else { return nil }
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let invalidHostCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\?#@"))
        guard !host.unicodeScalars.contains(where: { invalidHostCharacters.contains($0) }) else { return nil }
        return url
    }
}

struct MacQRToolView: View {
    private let mediaEnvironment: MacToolboxMediaEnvironment
    @ObservedObject private var cameraRegistry: MacCameraRegistry
    @Environment(\.locale) private var locale
    @StateObject private var model: MacQRModel
    @State private var copied = false
    @State private var exportError: String?
    @State private var showingCamera = false
    @State private var cameraPresentation = MacQRPresentationGate()

    init(locale: Locale, mediaEnvironment: MacToolboxMediaEnvironment) {
        self.mediaEnvironment = mediaEnvironment
        _cameraRegistry = ObservedObject(wrappedValue: mediaEnvironment.cameraRegistry)
        _model = StateObject(wrappedValue: MacQRModel(importImage: {
            await MacToolboxFilePanels.chooseImage(locale: locale)
        }))
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    private var cameraBinding: Binding<Bool> {
        Binding(get: { showingCamera }, set: { value in
            if !value { cameraPresentation.close() }
            showingCamera = value
        })
    }

    var body: some View {
        HSplitView {
            generationPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            recognitionPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { cameraPresentation.close(); model.cancelRead() }
        .onChange(of: model.result) { _, _ in copied = false }
        // A quit attempt invalidates only the camera presentation, not QR work.
        .onChange(of: cameraRegistry.cameraAdmissionEpoch) { _, _ in
            cameraPresentation.close()
            showingCamera = false
        }
        .sheet(isPresented: cameraBinding) {
            MacQRCameraSheet(mediaEnvironment: mediaEnvironment, presentation: cameraPresentation) { code in
                model.acceptCameraResult(code)
            }
        }
    }

    private var generationPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(t("生成二维码", "Generate QR code"), systemImage: "qrcode")
                    .font(.title2.weight(.semibold))
                Text(t("输入文本或网址，生成后可导出 PNG 图片。",
                       "Enter text or a URL, then export it as a PNG image."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(t("文本或网址", "Text or URL"), text: $model.input, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mac.toolbox.qr.input")
                HStack(spacing: 12) {
                    Button(t("生成二维码", "Generate QR code"), systemImage: "qrcode") {
                        model.generate()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.input.isEmpty)
                    .accessibilityIdentifier("mac.toolbox.qr.generate")
                    if model.png != nil {
                        Button(t("导出图片", "Export image"), systemImage: "square.and.arrow.up") {
                            export()
                        }
                        .accessibilityIdentifier("mac.toolbox.qr.export")
                    }
                    Spacer()
                }
                if model.generationFailed {
                    Label(t("未能生成，请检查内容长度后重试。",
                            "Unable to generate. Check the text length and retry."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let png = model.png {
                    Image(nsImage: image(from: png))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 360)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(t("生成的二维码", "Generated QR code"))
                        .accessibilityIdentifier("mac.toolbox.qr.image")
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recognitionPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(t("识别二维码", "Read a QR code"), systemImage: "photo")
                    .font(.title2.weight(.semibold))
                Text(t("选择一张包含二维码的图片，识别结果可以复制或再次生成。",
                       "Choose an image with a QR code. Recognized content can be copied or used to generate a new code."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(t("相机扫描", "Scan with camera"), systemImage: "camera") {
                        cameraPresentation.open()
                        showingCamera = true
                    }
                    .disabled(model.reading)
                    .accessibilityIdentifier("mac.toolbox.qr.camera")
                    Button(t("选择图片识别", "Choose an image to read"), systemImage: "photo") {
                        model.readImage()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.reading)
                    .accessibilityIdentifier("mac.toolbox.qr.read")
                    if model.reading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if model.reading {
                    ProgressView(t("正在读取图片", "Reading image"))
                } else if model.readingFailed {
                    Label(t("未能读取这张图片，请选择其他图片重试。",
                            "Unable to read this image. Choose another image and retry."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if model.didRead, model.result.isEmpty {
                    ContentUnavailableView(t("未发现二维码", "No QR code found"),
                                           systemImage: "qrcode",
                                           description: Text(t("请换一张二维码完整、清晰的图片。",
                                                               "Choose an image with a complete, clear QR code.")))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if !model.didRead {
                    Text(t("相机只在开始扫描时申请权限；图片识别只读取你主动选择的文件。",
                           "The camera is requested only when you start scanning; image recognition reads only the file you choose."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac.toolbox.qr.camera.status")
                }
                if model.didRead, !model.result.isEmpty {
                    ForEach(Array(model.result.enumerated()), id: \.offset) { index, text in
                        VStack(alignment: .leading, spacing: 8) {
                            if model.result.count > 1 {
                                Text(t("二维码 \(index + 1)", "QR code \(index + 1)"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 12) {
                                if let url = MacQRLink.destination(for: text) {
                                    Link(destination: url) {
                                        Label(t("打开链接", "Open link"), systemImage: "arrow.up.right.square")
                                    }
                                    .accessibilityIdentifier("mac.toolbox.qr.openLink")
                                }
                                Button(t("复制内容", "Copy content"), systemImage: "doc.on.doc") {
                                    copy(text)
                                }
                                .accessibilityIdentifier("mac.toolbox.qr.copyResult")
                                ShareLink(item: text) {
                                    Label(t("分享内容", "Share content"), systemImage: "square.and.arrow.up")
                                }
                                Button(t("用于生成", "Use to generate"), systemImage: "qrcode") {
                                    model.useResult(text)
                                }
                                .accessibilityIdentifier("mac.toolbox.qr.useResult")
                                Spacer()
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func export() {
        guard let png = model.png else { return }
        Task { @MainActor in
            do {
                _ = try await MacToolboxFilePanels.savePNG(png, suggestedName: "Floe-QR.png", locale: locale)
                exportError = nil
            } catch {
                exportError = t("未能导出图片，请检查保存位置后重试。",
                                "The image could not be exported. Check the save location and try again.")
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func image(from data: Data) -> NSImage {
        NSImage(data: data) ?? NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil) ?? NSImage()
    }
}
