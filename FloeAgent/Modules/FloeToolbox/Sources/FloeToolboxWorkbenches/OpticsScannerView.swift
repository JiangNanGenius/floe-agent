import SwiftUI
import FloeToolboxCore
import FloeToolboxUtilities

#if os(iOS)
import AVFoundation
import UIKit
import VisionKit

/// Barcode/QR live scanning, imported-image recognition (codes + on-device
/// OCR), and multi-page document scanning through VisionKit. Recognized
/// content can be copied, exported as real PNG/PDF/TXT through the host, or
/// saved to Notes. Scanned links are never opened automatically.
@MainActor public struct ToolboxScannerView: View {
    private let importImage: @MainActor () async throws -> Data?
    private let exportArtifact: @MainActor (Data, String) -> Void
    private let saveNote: (@MainActor (String) async throws -> Void)?

    public init(importImage: @escaping @MainActor () async throws -> Data?,
                exportArtifact: @escaping @MainActor (Data, String) -> Void,
                saveNote: (@MainActor (String) async throws -> Void)? = nil) {
        self.importImage = importImage
        self.exportArtifact = exportArtifact
        self.saveNote = saveNote
        _model = StateObject(wrappedValue: OpticsScannerModel())
    }

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var service = OpticsCaptureService.shared
    @StateObject private var model: OpticsScannerModel
    @State private var showDocumentCamera = false
    @State private var documentCaptureToken: UUID?

    public var body: some View {
        Group {
            switch model.surface(authorization: service.authorization,
                                 issue: service.issue,
                                 running: service.running) {
            case .idle: idlePanel
            case .starting: startingPanel
            case .denied: deniedPanel
            case .busy: busyPanel
            case .interrupted: interruptedPanel
            case .running: runningSurface
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("扫描与识别", "Scanner", locale))
        .sheet(isPresented: $showDocumentCamera, onDismiss: {
            model.endDocumentCapture()
            documentCaptureToken = nil
        }) {
            if let token = documentCaptureToken {
                OpticsDocumentCamera(
                    isPresented: $showDocumentCamera,
                    onResult: { scan in model.commitDocumentScan(scan, captureToken: token) },
                    onError: { error in model.noteDocumentError(error, captureToken: token) }
                )
                .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlBar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
        .onDisappear {
            showDocumentCamera = false
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                showDocumentCamera = false
                model.stop()
            }
        }
        .onChange(of: service.latestCodes) { _, codes in
            model.appendLiveCodes(codes)
        }
    }

    // MARK: - Surfaces

    private var idlePanel: some View {
        ScrollView {
            VStack(spacing: 24) {
                OpticsMessagePanel(
                    systemImage: "qrcode.viewfinder",
                    title: workbenchText("扫描与识别", "Scanner", locale),
                    message: workbenchText("对准条码或二维码开始识别，也可以识别图片中的文字与二维码，或扫描多页文档。", "Point at a barcode or QR code to recognize it, recognize text and codes in an image, or scan multi-page documents.", locale),
                    actionTitle: workbenchText("开始扫描", "Start Scanning", locale),
                    actionIdentifier: "toolbox.scanner.start",
                    note: model.busyNotice
                        ? workbenchText("相机正被其他工具使用，请稍后再试。", "The camera is in use by another tool. Try again shortly.", locale)
                        : (model.results.isEmpty ? nil : resultsSummaryNote)
                ) { model.start() }
                if !model.results.isEmpty { resultsCard }
            }
            .padding(.vertical, 24)
        }
    }

    private var startingPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(workbenchText("正在启动相机…", "Starting the camera…", locale))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedPanel: some View {
        OpticsMessagePanel(
            systemImage: "camera.fill",
            title: workbenchText("需要相机权限", "Camera Access Needed", locale),
            message: workbenchText("请在“设置 › 隐私与安全性 › 相机”中允许访问后重新打开扫描。", "Allow camera access in Settings › Privacy & Security › Camera, then open the scanner again.", locale),
            actionTitle: nil, actionIdentifier: nil, note: nil
        ) {}
        .accessibilityIdentifier("toolbox.scanner.denied")
    }

    private var busyPanel: some View {
        OpticsMessagePanel(
            systemImage: "camera.fill",
            title: workbenchText("相机正在使用中", "Camera in Use", locale),
            message: workbenchText("系统相机或其他应用正在使用相机。关闭后再试，扫描不会抢占相机。", "The system camera or another app is using the camera. Close it and retry; the scanner will not take the camera over.", locale),
            actionTitle: workbenchText("重试", "Retry", locale),
            actionIdentifier: "toolbox.scanner.retry",
            note: nil
        ) { model.retry() }
        .accessibilityIdentifier("toolbox.scanner.busy")
    }

    private var interruptedPanel: some View {
        OpticsMessagePanel(
            systemImage: "exclamationmark.triangle",
            title: workbenchText("相机已中断", "Camera Interrupted", locale),
            message: workbenchText("相机被系统暂时中断，可尝试恢复。", "The camera was temporarily interrupted by the system. You can try to resume.", locale),
            actionTitle: workbenchText("恢复", "Resume", locale),
            actionIdentifier: "toolbox.scanner.resume",
            note: nil
        ) { model.retry() }
        .accessibilityIdentifier("toolbox.scanner.interrupted")
    }

    // MARK: - Running surface: preview beside (wide) or above (compact) results

    private var runningSurface: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    previewPane
                    Divider()
                    resultsPane.frame(width: 360)
                }
            } else {
                VStack(spacing: 0) {
                    previewPane
                    Divider()
                    resultsPane
                }
            }
        }
    }

    private var previewPane: some View {
        ZStack {
            OpticsCameraPreview(session: service.session, host: model.previewHost)
                .accessibilityLabel(workbenchText("相机预览，对准条码或二维码", "Camera preview. Point at a barcode or QR code.", locale))
                .accessibilityIdentifier("toolbox.scanner.preview")
            if let notice = model.notice {
                VStack {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.bar, in: .capsule)
                        .padding(.top, 12)
                    Spacer()
                }
            }
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            resultsHeader
            Divider()
            if model.results.isEmpty {
                ContentUnavailableView(
                    label: { Label(workbenchText("暂无识别结果", "No Results Yet", locale), systemImage: "qrcode") },
                    description: { Text(workbenchText("对准条码或二维码，或识别图片与文档。", "Point at a code, or recognize an image or document.", locale)) }
                )
                .accessibilityIdentifier("toolbox.scanner.empty")
            } else {
                List(model.results) { item in
                    OpticsResultRow(item: item, locale: locale) {
                        model.copyItem(item)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("toolbox.scanner.results")
            }
            if model.isRecognizing || model.isProcessingDocument {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.isProcessingDocument
                         ? workbenchText("正在处理文档…", "Processing document…", locale)
                         : workbenchText("正在识别…", "Recognizing…", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 16)
            }
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            Text(workbenchText("识别结果", "Results", locale))
                .font(.headline)
            Text("\(model.results.count)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            if !model.results.isEmpty || model.documentText != nil {
                Button { model.copyAll() } label: {
                    Label(workbenchText("复制", "Copy", locale), systemImage: "doc.on.doc")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("toolbox.scanner.copy")
                if let saveNote {
                    Button { model.saveToNotes(using: saveNote, locale: locale) } label: {
                        Label(workbenchText("存入手记", "Save to Notes", locale), systemImage: "note.text")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSavingNote)
                    .accessibilityIdentifier("toolbox.scanner.saveNote")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var resultsSummaryNote: String {
        workbenchText("已有 \(model.results.count) 条识别结果，可在下方查看、复制或导出。", "You have \(model.results.count) recognized results. Review, copy, or export them below.", locale)
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workbenchText("已有识别结果", "Recognized Results", locale))
                .font(.headline)
            ForEach(model.results.prefix(6)) { item in
                OpticsResultRow(item: item, locale: locale) { model.copyItem(item) }
            }
            if model.results.count > 6 {
                Text(workbenchText("共 \(model.results.count) 条，重新开始扫描可继续查看。", "\(model.results.count) results total. Start scanning to review them all.", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560)
        .padding(20)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlsRow }
            VStack(spacing: 10) { controlsRow }
        }
    }

    private var controlsRow: some View {
        Group {
            if model.ownsCapture && service.running {
                OpticsBarButton(
                    title: workbenchText("停止", "Stop", locale),
                    systemImage: "stop.fill",
                    identifier: "toolbox.scanner.stop"
                ) { model.stop() }
            } else {
                OpticsBarButton(
                    title: workbenchText("开始扫描", "Start", locale),
                    systemImage: "play.fill",
                    identifier: "toolbox.scanner.startLive"
                ) { model.start() }
            }
            OpticsBarButton(
                title: workbenchText("识别图片", "Recognize Image", locale),
                systemImage: "photo",
                identifier: "toolbox.scanner.import"
            ) { importAndRecognize() }
            .disabled(model.isRecognizing)
            if VNDocumentCameraViewController.isSupported {
                OpticsBarButton(
                    title: workbenchText("扫描文档", "Scan Document", locale),
                    systemImage: "doc.text.viewfinder",
                    identifier: "toolbox.scanner.document"
                ) { beginDocumentScan() }
                .disabled(model.isProcessingDocument)
            }
            Menu {
                if model.canExportPDF {
                    Button { exportPDF() } label: {
                        Label(workbenchText("导出 PDF", "Export PDF", locale), systemImage: "doc.fill")
                    }
                }
                if model.canExportPNG {
                    Button { exportPNG() } label: {
                        Label(workbenchText("导出图片", "Export Image", locale), systemImage: "photo")
                    }
                }
                if model.canExportTXT {
                    Button { exportTXT() } label: {
                        Label(workbenchText("导出文字", "Export Text", locale), systemImage: "doc.text")
                    }
                }
                if !model.canExportPDF && !model.canExportPNG && !model.canExportTXT {
                    Text(workbenchText("暂无可导出的内容", "Nothing to export yet", locale))
                }
            } label: {
                Label(workbenchText("导出", "Export", locale), systemImage: "square.and.arrow.up")
                    .font(.body)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("toolbox.scanner.export")
        }
    }

    // MARK: - Actions

    private func importAndRecognize() {
        Task {
            await model.recognizeImportedImage(using: importImage, locale: locale)
        }
    }

    private func beginDocumentScan() {
        guard scenePhase == .active else { return }
        Task {
            guard let token = await model.beginDocumentCapture() else { return }
            guard scenePhase == .active, model.presentDocumentCapture(token: token) else {
                model.cancelDocumentCapture(token: token)
                return
            }
            documentCaptureToken = token
            showDocumentCamera = true
        }
    }

    private func exportPDF() {
        Task {
            guard let data = await model.makePDF() else { return }
            exportArtifact(data, "pdf")
        }
    }

    private func exportPNG() {
        Task {
            guard let data = await model.makePNG() else { return }
            exportArtifact(data, "png")
        }
    }

    private func exportTXT() {
        guard let data = model.makeTXT() else { return }
        exportArtifact(data, "txt")
    }
}

// MARK: - Model

@MainActor final class OpticsScannerModel: ObservableObject {
    enum Surface: Equatable {
        case idle, starting, denied, busy, interrupted, running
    }

    @Published private(set) var results: [OpticsScanItem] = []
    @Published private(set) var documentPages: [UIImage] = []
    @Published private(set) var documentText: String?
    @Published private(set) var importedImage: UIImage?
    @Published private(set) var notice: String?
    @Published private(set) var isRecognizing = false
    @Published private(set) var isProcessingDocument = false
    @Published private(set) var isSavingNote = false
    @Published var busyNotice = false

    let previewHost = OpticsPreviewHost()

    private let service = OpticsCaptureService.shared
    private var lease: OpticsCaptureLease?
    private var documentLease: OpticsCaptureLease?
    private var documentCaptureToken: UUID?
    private var documentPresented = false
    private var generation = UUID()
    private var recognitionTask: Task<Void, Never>?
    /// The admitted import is at most OpticsImageDecoder.maximumEncodedBytes.
    /// Keep its metadata so PNG export reuses the same bounded EXIF transform.
    private var importedImageData: Data?
    private var seenPayloads = Set<String>()
    private var noticeTask: Task<Void, Never>?

    init() {}

    var ownsCapture: Bool { service.owns(lease) }

    func surface(authorization: OpticsCaptureAuthorization,
                 issue: OpticsCaptureIssue,
                 running: Bool) -> Surface {
        guard ownsCapture else { return .idle }
        if authorization == .denied { return .denied }
        if case .cameraBusy = issue { return .busy }
        if issue == .interrupted { return .interrupted }
        if running { return .running }
        if lease != nil { return .starting }
        return .idle
    }

    // MARK: - Live scanning

    func start() {
        guard lease == nil, documentLease == nil else { return }
        guard let newLease = service.acquire(.scanner) else {
            busyNotice = true
            return
        }
        busyNotice = false
        lease = newLease
        service.requestStart(lease: newLease)
    }

    func retry() {
        stop()
        start()
    }

    func stop() {
        cancelRecognition()
        if let lease {
            service.release(lease)
        }
        lease = nil
        documentCaptureToken = nil
        // The system camera keeps the reservation until its dismissal has
        // completed. A second window must not enter during that transition.
        if !documentPresented { endDocumentCapture() }
    }

    private func cancelRecognition() {
        generation = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
        isProcessingDocument = false
    }

    func appendLiveCodes(_ codes: [OpticsCapturedCode]) {
        guard ownsCapture, service.running else { return }
        for code in codes {
            guard seenPayloads.count < 512 else { break }
            let key = code.payload
            guard !key.isEmpty, !seenPayloads.contains(key) else { continue }
            seenPayloads.insert(key)
            guard results.count < OpticsRecognition.maximumResults else {
                postNotice(liveTruncatedNote)
                continue
            }
            let label = Self.symbologyLabel(code.symbology)
            let kind: OpticsScanItem.Kind = label.uppercased().contains("QR") ? .qrCode : .barcode
            results.append(OpticsScanItem(kind: kind, payload: code.payload, detail: label))
        }
    }

    private var liveTruncatedNote: String {
        Locale.current.language.languageCode?.identifier == "zh"
            ? "结果已达上限，仅保留最近 \(OpticsRecognition.maximumResults) 条。"
            : "Result limit reached; keeping the most recent \(OpticsRecognition.maximumResults)."
    }

    static func symbologyLabel(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "org.iso.", with: "")
            .replacingOccurrences(of: "org.gs1.", with: "")
            .replacingOccurrences(of: "AVMetadataObjectType", with: "")
    }

    // MARK: - Image import recognition

    /// Single in-flight Vision pass: a second tap while recognizing is
    /// ignored, and a stale result is fenced out by the generation token.
    func recognizeImportedImage(using importImage: @escaping @MainActor () async throws -> Data?,
                                locale: Locale) async {
        guard recognitionTask == nil else { return }
        let token = UUID()
        generation = token
        isRecognizing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.isRecognizing = false
                    self.recognitionTask = nil
                }
            }
            do {
                guard let data = try await importImage() else { return }
                try Task.checkCancellation()
                let recognition = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let decoded = try OpticsImageDecoder.decode(data)
                    let items = try OpticsRecognition.recognizeAll(decoded: decoded)
                    try Task.checkCancellation()
                    return (items: items, decoded: decoded)
                }
                let output = try await withTaskCancellationHandler {
                    try await recognition.value
                } onCancel: {
                    recognition.cancel()
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.commitRecognized(output.items, locale: locale)
                // Keep the same bounded, orientation-normalized pixels that
                // recognition used; exporting cgImage is now orientation-safe.
                self.importedImage = UIImage(cgImage: output.decoded.image)
                self.importedImageData = data
            } catch is CancellationError {
                // A cancelled import leaves previous results untouched.
            } catch {
                guard self.generation == token else { return }
                self.postRecognizeFailure(error, locale: locale)
            }
        }
        recognitionTask = task
        await task.value
    }

    private func commitRecognized(_ items: [OpticsScanItem], locale: Locale) {
        guard !items.isEmpty else {
            postNotice(locale.language.languageCode?.identifier == "zh"
                       ? "未在图片中识别到条码、二维码或文字。"
                       : "No barcode, QR code, or text was recognized in the image.")
            return
        }
        var added = 0
        for item in items {
            guard results.count < OpticsRecognition.maximumResults else {
                postNotice(liveTruncatedNote)
                break
            }
            let key = "\(item.kind.rawValue)|\(item.payload)"
            guard !seenPayloads.contains(key) else { continue }
            seenPayloads.insert(key)
            results.append(item)
            added += 1
        }
        if added > 0 {
            postNotice(locale.language.languageCode?.identifier == "zh"
                       ? "已识别 \(added) 条内容。"
                       : "Recognized \(added) items.")
        }
    }

    private func postRecognizeFailure(_ error: Error, locale: Locale) {
        let detail: String
        if let toolboxError = error as? ToolboxError {
            switch toolboxError {
            case .limit(let field): detail = field
            case .invalid(let field): detail = field
            default: detail = "recognition"
            }
        } else {
            detail = "recognition"
        }
        postNotice(locale.language.languageCode?.identifier == "zh"
                   ? "识别失败（\(detail)）。"
                   : "Recognition failed (\(detail)).")
    }

    // MARK: - Document scanning

    func beginDocumentCapture() async -> UUID? {
        guard documentLease == nil else { return nil }
        stop()
        guard let newLease = service.acquire(.document) else {
            busyNotice = true
            return nil
        }
        busyNotice = false
        let token = UUID()
        documentLease = newLease
        documentCaptureToken = token
        let ready = await service.prepareDocumentCapture(lease: newLease)
        guard ready, documentCaptureToken == token else {
            if documentLease == newLease, !documentPresented { endDocumentCapture() }
            return nil
        }
        return token
    }

    func presentDocumentCapture(token: UUID) -> Bool {
        guard documentCaptureToken == token, service.owns(documentLease) else { return false }
        documentPresented = true
        return true
    }

    func cancelDocumentCapture(token: UUID) {
        guard documentCaptureToken == token, !documentPresented else { return }
        endDocumentCapture()
    }

    func endDocumentCapture() {
        documentCaptureToken = nil
        documentPresented = false
        if let documentLease { service.release(documentLease) }
        documentLease = nil
    }

    /// Pages are capped and each page is bounded before retention; OCR runs
    /// sequentially with cancellation between pages, and the scan is never
    /// presented as complete while pages were dropped.
    func commitDocumentScan(_ scan: VNDocumentCameraScan, captureToken: UUID) {
        guard documentCaptureToken == captureToken, documentPresented,
              service.owns(documentLease) else { return }
        cancelRecognition()
        let token = UUID()
        generation = token
        let pageCount = min(scan.pageCount, OpticsScanExport.maximumPages)
        let dropped = scan.pageCount - pageCount
        var pages: [UIImage] = []
        pages.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            pages.append(scan.imageOfPage(at: index))
        }
        documentPages = pages
        importedImage = pages.first
        importedImageData = nil
        documentText = nil
        isProcessingDocument = true
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.isProcessingDocument = false
                    self.recognitionTask = nil
                }
            }
            var texts: [String] = []
            for (index, page) in pages.enumerated() {
                if Task.isCancelled { return }
                guard let data = page.pngData() else { continue }
                let recognition = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try OpticsRecognition.recognizeText(imageData: data)
                }
                let items: [OpticsScanItem]
                do {
                    items = try await withTaskCancellationHandler {
                        try await recognition.value
                    } onCancel: {
                        recognition.cancel()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
                guard self.generation == token, !Task.isCancelled else { return }
                let pageText = items.map(\.payload).joined(separator: "\n")
                if !pageText.isEmpty {
                    texts.append("— \(index + 1) —\n\(pageText)")
                }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            let combined = texts.joined(separator: "\n\n")
            self.documentText = combined.isEmpty ? nil : String(combined.prefix(128 * 1024))
            if dropped > 0 {
                self.postNotice(self.documentTruncatedNote(dropped: dropped))
            } else {
                self.postNotice(self.documentCompleteNote(pages: pageCount))
            }
        }
    }

    private func documentCompleteNote(pages: Int) -> String {
        Locale.current.language.languageCode?.identifier == "zh"
            ? "文档扫描完成，共 \(pages) 页，可导出 PDF。"
            : "Document scan complete with \(pages) pages. You can export a PDF."
    }

    private func documentTruncatedNote(dropped: Int) -> String {
        Locale.current.language.languageCode?.identifier == "zh"
            ? "仅保留前 \(OpticsScanExport.maximumPages) 页（省略 \(dropped) 页），导出的 PDF 不完整。"
            : "Kept the first \(OpticsScanExport.maximumPages) pages (omitted \(dropped)); the exported PDF is incomplete."
    }

    func noteDocumentError(_ error: Error, captureToken: UUID) {
        guard documentCaptureToken == captureToken else { return }
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        postNotice(zh ? "文档扫描失败，请重试。" : "Document scanning failed. Try again.")
    }

    // MARK: - Export & sharing

    var canExportPDF: Bool { !documentPages.isEmpty }
    var canExportPNG: Bool { importedImage != nil }
    var canExportTXT: Bool { aggregatedText != nil }

    func makePDF() async -> Data? {
        let images = documentPages.compactMap { $0.cgImage }
        guard !images.isEmpty else { return nil }
        do {
            let data = try OpticsScanExport.pdf(pages: images)
            postNotice(Locale.current.language.languageCode?.identifier == "zh"
                       ? "已导出 PDF。" : "PDF exported.")
            return data
        } catch {
            postNoteFailure(error)
            return nil
        }
    }

    func makePNG() async -> Data? {
        guard let image = importedImage?.cgImage else { return nil }
        do {
            let data: Data
            if let importedImageData {
                data = try OpticsScanExport.png(imageData: importedImageData)
            } else {
                data = try OpticsScanExport.png(image)
            }
            postNotice(Locale.current.language.languageCode?.identifier == "zh"
                       ? "已导出图片。" : "Image exported.")
            return data
        } catch {
            postNoteFailure(error)
            return nil
        }
    }

    func makeTXT() -> Data? {
        guard let text = aggregatedText else { return nil }
        do {
            return try OpticsScanExport.text(text)
        } catch {
            postNoteFailure(error)
            return nil
        }
    }

    private var aggregatedText: String? {
        var parts: [String] = []
        if !results.isEmpty {
            let lines = results.enumerated().map { index, item in
                "\(index + 1). [\(item.detail)] \(item.payload)"
            }
            parts.append(lines.joined(separator: "\n"))
        }
        if let documentText {
            parts.append(documentText)
        }
        let combined = parts.joined(separator: "\n\n")
        guard !combined.isEmpty else { return nil }
        return combined
    }

    func copyItem(_ item: OpticsScanItem) {
        UIPasteboard.general.string = item.payload
        postNotice(Locale.current.language.languageCode?.identifier == "zh"
                   ? "已复制。" : "Copied.")
    }

    func copyAll() {
        guard let text = aggregatedText else { return }
        UIPasteboard.general.string = text
        postNotice(Locale.current.language.languageCode?.identifier == "zh"
                   ? "已复制全部内容。" : "Copied everything.")
    }

    func saveToNotes(using saveNote: @escaping @MainActor (String) async throws -> Void, locale: Locale) {
        guard let text = aggregatedText, !isSavingNote else { return }
        isSavingNote = true
        let zh = locale.language.languageCode?.identifier == "zh"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await saveNote(text)
                self.postNotice(zh ? "已保存到手记。" : "Saved to Notes.")
            } catch {
                self.postNoteFailure(error)
            }
            self.isSavingNote = false
        }
    }

    private func postNoteFailure(_ error: Error) {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        if let toolboxError = error as? ToolboxError, case .limit(let field) = toolboxError {
            postNotice(zh ? "内容超出限制（\(field)）。" : "Content exceeded the limit (\(field)).")
        } else {
            postNotice(zh ? "操作失败，请重试。" : "The operation failed. Try again.")
        }
    }

    private func postNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }
}

// MARK: - Document camera

struct OpticsDocumentCamera: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onResult: (VNDocumentCameraScan) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: OpticsDocumentCamera

        init(parent: OpticsDocumentCamera) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)
            parent.isPresented = false
            parent.onResult(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            parent.isPresented = false
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true)
            parent.isPresented = false
            parent.onError(error)
        }
    }
}

// MARK: - Result row

struct OpticsResultRow: View {
    let item: OpticsScanItem
    let locale: Locale
    let onCopy: () -> Void

    private var icon: String {
        switch item.kind {
        case .qrCode: return "qrcode"
        case .barcode: return "barcode"
        case .text: return "textformat"
        }
    }

    private var kindTitle: String {
        switch item.kind {
        case .qrCode: return workbenchText("二维码", "QR Code", locale)
        case .barcode: return workbenchText("条码", "Barcode", locale)
        case .text: return workbenchText("文字", "Text", locale)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kindTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if OpticsPayloadPolicy.kind(of: item.payload) == .url {
                        Label(workbenchText("链接（不会自动打开）", "Link (never opened automatically)", locale),
                              systemImage: "link.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                Text(item.payload)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Spacer(minLength: 8)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(workbenchText("复制", "Copy", locale))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

#else
@MainActor public struct ToolboxScannerView: View {
    private let importImage: @MainActor () async throws -> Data?
    private let exportArtifact: @MainActor (Data, String) -> Void
    private let saveNote: (@MainActor (String) async throws -> Void)?

    public init(importImage: @escaping @MainActor () async throws -> Data?,
                exportArtifact: @escaping @MainActor (Data, String) -> Void,
                saveNote: (@MainActor (String) async throws -> Void)? = nil) {
        self.importImage = importImage
        self.exportArtifact = exportArtifact
        self.saveNote = saveNote
    }

    @Environment(\.locale) private var locale

    public var body: some View {
        InstrumentUnavailableSurface(
            title: workbenchText("扫描与识别", "Scanner", locale),
            message: workbenchText("此平台不支持相机采集；扫描与识别需要在 iPhone 或 iPad 上使用。", "Camera capture is not supported on this platform; scanning requires an iPhone or iPad.", locale),
            systemImage: "qrcode.viewfinder"
        )
        .navigationTitle(workbenchText("扫描与识别", "Scanner", locale))
    }
}
#endif
