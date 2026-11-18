import SwiftUI
import AppKit
import Combine
import FloeMacMediaCore
import FloeMacMediaSystem
import FloeToolboxUtilities

/// Native macOS scanner: live barcode/QR reading, still-page capture, image
/// import through a user-selected file, on-device OCR, up to 24 pages and
/// explicit PNG/PDF/TXT exports. Import and export work without camera
/// permission; nothing is saved or opened automatically.
@MainActor
public struct MacToolboxScannerView: View {
    private let environment: MacToolboxMediaEnvironment
    @State private var scan: MacScannerDraftOwner
    @State private var surface: MacScannerSurfaceLease
    @State private var surfaceVisible = false
    @ObservedObject private var cameraRegistry: MacCameraRegistry
    @State private var windowReference = MacMediaWindowReference()
    @State private var importFailure: String?
    @State private var captureFailure: String?
    @State private var exportFailure: String?
    @State private var copiedNote: String?
    @State private var confirmClear = false
    @State private var clearTicket: UUID?
    @State private var clearRevision: UInt64?

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase

    public init(environment: MacToolboxMediaEnvironment? = nil) {
        let resolved = environment ?? .shared
        self.environment = resolved
        _scan = State(initialValue: resolved.scannerDraft)
        _surface = State(initialValue: MacScannerSurfaceLease(owner: resolved.scannerCamera))
        _cameraRegistry = ObservedObject(wrappedValue: resolved.cameraRegistry)
    }

    private var camera: MacCameraController? { surface.camera }
    private var surfaceTicket: UUID? { surface.ticket }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    liveSection
                    pagesSection
                    resultsSection
                    notices
                }
                .padding(24)
                .frame(maxWidth: 1_040, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            controlBar
        }
        .navigationTitle(macToolboxText("扫描与识别", "Scanner", locale))
        .confirmationDialog(macToolboxText("清除扫描草稿？", "Clear the scanner draft?", locale),
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button(macToolboxText("清除草稿", "Clear Draft", locale), role: .destructive) {
                guard let ticket = clearTicket, ticket == surfaceTicket, let revision = clearRevision else { return }
                try? scan.clear(ticket: ticket, expectedRevision: revision)
            }
            Button(macToolboxText("取消", "Cancel", locale), role: .cancel) {}
        } message: {
            Text(macToolboxText("未保存的页面和识别结果将被移除。", "Unsaved pages and results will be removed.", locale))
        }
        .background(MacMediaWindowTracker(reference: windowReference))
        .disabled(surfaceTicket == nil)
        .overlay {
            if surfaceTicket == nil {
                ContentUnavailableView(macToolboxText("扫描暂不可用", "Scanner Unavailable", locale),
                                       systemImage: "doc.viewfinder",
                                       description: Text(macToolboxText("请稍后重试。", "Try again shortly.", locale)))
            }
        }
        .onAppear { surfaceVisible = true; openSurface() }
        .onDisappear { surfaceVisible = false; closeSurface() }
        .onChange(of: cameraRegistry.cameraEpoch) { _, _ in
            if surfaceVisible { closeSurface(); openSurface() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera?.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if camera?.awaitingPermissionPrompt != true { camera?.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if windowReference.shouldStop(for: notification) { closeSurface() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if windowReference.shouldStop(for: notification) { closeSurface() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if surfaceVisible, surfaceTicket == nil, windowReference.contains(notification) { openSurface() }
        }
    }

    private func openSurface() {
        guard surfaceVisible, surfaceTicket == nil else { return }
        let reference = windowReference
        surface.appear(windowAvailable: { [weak reference] in reference?.captureAvailable == true })
    }

    private func closeSurface() {
        surface.disappear()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(macToolboxText("扫描与识别", "Scanner", locale))
                .font(.largeTitle.weight(.semibold))
            Text(macToolboxText(
                "读取条码与二维码、查看图片文字并整理多页。完整文本导出暂不可用；草稿仅在 Floe 运行期间保留。",
                "Read codes, view recognized text and organize pages. Full text export is unavailable. Drafts remain only while Floe is running.",
                locale
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Label(macToolboxText(
                "链接只显示和复制，不会自动打开。导出时请选择尚不存在的文件名。",
                "Links are shown and copied only, never opened automatically. Choose a new filename when exporting.",
                locale
            ), systemImage: "lock.doc")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Live scanning

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(macToolboxText("实时扫描", "Live Scan", locale), systemImage: "qrcode.viewfinder")
                    .font(.headline)
                Spacer()
                switch camera?.surface ?? .idle {
                case .running, .frozen:
                    Text(camera?.deviceName ?? macToolboxText("相机已连接", "Camera connected", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }

            switch camera?.surface ?? .idle {
            case .running:
                if let camera {
                    MacCameraPreview(session: camera.session, onFocus: nil)
                        .frame(minHeight: 200, idealHeight: 240, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mac.toolbox.scanner.preview")
                }
                HStack(spacing: 10) {
                    Button(macToolboxText("拍摄当前页", "Capture Page", locale)) { capturePage() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac.toolbox.scanner.capture")
                    Text(macToolboxText("把条码或文字对准画面；结果会自动加入下方列表。",
                                        "Aim at a code or text; recognized items are added below.", locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(macToolboxText("正在启动相机…", "Starting the camera…", locale))
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .denied:
                inlineStatus(
                    icon: "camera.fill",
                    text: macToolboxText("未获相机权限。仍可导入图片并识别、导出。",
                                         "Camera access is not allowed. You can still import images, recognize and export.", locale),
                    action: macToolboxText("打开相机设置", "Open camera settings", locale),
                    identifier: "mac.toolbox.scanner.openSettings"
                ) { macOpenPrivacySettings(.camera) }
            case .busy:
                inlineStatus(
                    icon: "camera.fill",
                    text: macToolboxText("相机正被其他 Floe 窗口或应用使用。仍可导入图片。",
                                         "Another Floe window or app is using the camera. Image import still works.", locale),
                    action: macToolboxText("重试", "Retry", locale),
                    identifier: "mac.toolbox.scanner.busyRetry"
                ) { retryCamera() }
            case .noDevice:
                inlineStatus(
                    icon: "video.slash",
                    text: macToolboxText("未找到相机。可导入图片继续使用扫描功能。",
                                         "No camera was found. Import an image to keep using the scanner.", locale),
                    action: macToolboxText("重试", "Retry", locale),
                    identifier: "mac.toolbox.scanner.noDeviceRetry"
                ) { retryCamera() }
            case .interrupted:
                inlineStatus(
                    icon: "exclamationmark.triangle",
                    text: macToolboxText("相机被系统暂时中断。恢复会重新申请相机。",
                                         "The camera was interrupted. Resume requests it again.", locale),
                    action: macToolboxText("恢复", "Resume", locale),
                    identifier: "mac.toolbox.scanner.resume"
                ) { retryCamera() }
            case .failed:
                inlineStatus(
                    icon: "exclamationmark.octagon",
                    text: camera?.lastFailure.map { macMediaFailureText($0, locale) }
                        ?? macToolboxText("相机无法启动。", "The camera could not start.", locale),
                    action: macToolboxText("重试", "Retry", locale),
                    identifier: "mac.toolbox.scanner.failedRetry"
                ) { retryCamera() }
            case .idle, .frozen:
                Text(macToolboxText(
                    "开始实时扫描后可读取条码与二维码；也可以直接导入图片。",
                    "Start live scanning to read codes, or import an image instead.",
                    locale
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let captureFailure {
                Label(captureFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func inlineStatus(
        icon: String,
        text: String,
        action: String,
        identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - Pages

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(macToolboxText("页面", "Pages", locale), systemImage: "doc.on.doc")
                    .font(.headline)
                Text(macToolboxText("\(scan.pageCount) / \(MacScanSession.maximumPages)",
                                    "\(scan.pageCount) / \(MacScanSession.maximumPages)", locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    importImage()
                } label: {
                    Label(macToolboxText("导入图片", "Import Image", locale), systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("mac.toolbox.scanner.import")
                Button {
                    recognizeAllPages()
                } label: {
                    Label(macToolboxText("识别全部页面", "Recognize All Pages", locale),
                          systemImage: "text.viewfinder")
                }
                .disabled(scan.pages.isEmpty || scan.isRecognizing)
                .accessibilityIdentifier("mac.toolbox.scanner.recognizeAll")
                if scan.isRecognizing { ProgressView().controlSize(.small) }
            }

            if let importFailure {
                Label(importFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if scan.pages.isEmpty {
                Text(macToolboxText(
                    "尚未添加页面。导入一张图片，或在实时扫描中拍摄当前页。",
                    "No pages yet. Import an image, or capture a page while live scanning.",
                    locale
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(scan.pages.enumerated()), id: \.element.id) { index, page in
                            pageCard(page, index: index + 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text(macToolboxText("每一页都会按原始比例绘入 PDF；PNG 导出使用最后一页。",
                                    "Every page is drawn into the PDF with its own aspect ratio; PNG exports the last page.",
                                    locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pageCard(_ page: MacScanPage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Image(decorative: page.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
            .frame(width: 132, height: 96)
            HStack(spacing: 4) {
                Text(macToolboxText("第 \(index) 页", "Page \(index)", locale))
                    .font(.caption)
                Spacer()
                if page.text != nil {
                    Image(systemName: "text.magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(macToolboxText("已识别文字", "Text recognized", locale))
                }
            }
            Text("\(page.pixelWidth) × \(page.pixelHeight)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    recognizePage(page)
                } label: {
                    Image(systemName: "text.viewfinder")
                }
                .help(macToolboxText("识别此页", "Recognize this page", locale))
                .disabled(scan.isRecognizing)
                Button {
                    exportPagePNG(page)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(macToolboxText("导出此页 PNG", "Export this page as PNG", locale))
                Button(role: .destructive) {
                    guard let ticket = surfaceTicket else { return }
                    try? scan.removePage(page.id, ticket: ticket)
                } label: {
                    Image(systemName: "trash")
                }
                .help(macToolboxText("移除此页", "Remove this page", locale))
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(macToolboxText("识别结果", "Results", locale), systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Text("\(scan.results.count) / \(MacScanSession.maximumResults)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !scan.results.isEmpty {
                    Button(macToolboxText("全部复制", "Copy All", locale)) { copyAll() }
                        .accessibilityIdentifier("mac.toolbox.scanner.copyAll")
                }
            }
            if scan.results.isEmpty {
                Text(macToolboxText("识别到的条码、二维码与文字会显示在这里。",
                                    "Recognized codes and text appear here.", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scan.results) { item in
                        resultRow(item)
                        Divider()
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func resultRow(_ item: OpticsScanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(macResultKindText(item.kind, locale))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.payload)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(4)
                if OpticsPayloadPolicy.kind(of: item.payload) == .url {
                    Label(macToolboxText("链接仅复制，不会自动打开", "Link is copied only; it is not opened", locale),
                          systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                copy(item.payload)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(macToolboxText("复制", "Copy", locale))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Notices and controls

    @ViewBuilder
    private var notices: some View {
        if !scan.failedPageIndices.isEmpty {
            let pageNumbers = scan.failedPageIndices.map(String.init).joined(separator: ", ")
            Label(macToolboxText("第 \(pageNumbers) 页识别失败，请重试。",
                                 "Recognition failed on page(s) \(pageNumbers). Try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if scan.textLimitExceeded {
            Label(macToolboxText("识别文本超过 128 KiB（UTF-8）导出上限，请减少页面后重试。",
                                 "Recognized text exceeds the 128 KiB UTF-8 export limit. Remove pages and try again.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if scan.ocrCompletenessUnverified {
            Label(macToolboxText("识别结果可能不完整，暂无法导出完整文本。",
                                 "Recognition may be incomplete. Full text export is unavailable for now.", locale),
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let notice = scan.notice {
            Text(macScanNoticeText(notice, locale))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let failure = scan.lastFailure, scan.failedPageIndices.isEmpty, !scan.textLimitExceeded {
            Label(macMediaFailureText(failure, locale), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let exportFailure {
            Label(exportFailure, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let copiedNote {
            Label(copiedNote, systemImage: "doc.on.doc")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let receipt = scan.lastReceipt {
            Label(exportReceiptText(receipt), systemImage: receipt.outcome == .committed ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            if camera?.surface == .running {
                Button {
                    camera?.stop()
                } label: {
                    Label(macToolboxText("停止扫描", "Stop Scanning", locale), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mac.toolbox.scanner.stop")
            } else {
                Button {
                    startCamera()
                } label: {
                    Label(macToolboxText("开始扫描", "Start Scanning", locale), systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("mac.toolbox.scanner.start")
            }
            Button {
                importImage()
            } label: {
                Label(macToolboxText("导入图片", "Import Image", locale), systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("mac.toolbox.scanner.importBar")

            Spacer()

            Button(macToolboxText("清空", "Clear", locale)) {
                clearTicket = surfaceTicket
                clearRevision = scan.currentRevision
                confirmClear = true
            }
                .disabled(scan.pages.isEmpty && scan.results.isEmpty)
                .accessibilityIdentifier("mac.toolbox.scanner.clear")

            Menu {
                Button(macToolboxText("导出 PNG…", "Export PNG…", locale)) { exportPNG() }
                    .disabled(!scan.canExportPNG)
                Button(macToolboxText("导出 PDF…", "Export PDF…", locale)) { exportPDF() }
                    .disabled(!scan.canExportPDF)
                Button(macToolboxText("导出 TXT…", "Export TXT…", locale)) { exportTXT() }
                    .disabled(!scan.canExportTXT)
            } label: {
                Label(macToolboxText("导出", "Export", locale), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("mac.toolbox.scanner.export")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func startCamera() {
        captureFailure = nil
        guard let ticket = surfaceTicket, let selected = camera else { return }
        Task {
            let started = await environment.scannerCamera.start(ticket: ticket)
            if started, !NSApp.isActive { selected.stop() }
        }
    }

    private func retryCamera() {
        captureFailure = nil
        guard let ticket = surfaceTicket else { return }
        Task { _ = await environment.scannerCamera.start(ticket: ticket, retry: true) }
    }

    private func importImage() {
        importFailure = nil
        copyNotice(nil)
        guard let ticket = surfaceTicket else { return }
        do {
            guard let data = try environment.imageImporter.chooseImageData(isStillAuthorized: {
                scan.isCurrentSurface(ticket)
            }) else { return }
            try scan.addImage(data, source: .imported, ticket: ticket)
        } catch {
            importFailure = scannerErrorText(error)
        }
    }

    private func capturePage() {
        captureFailure = nil
        guard let ticket = surfaceTicket else { return }
        Task {
            do {
                try await environment.scannerCamera.capturePage(ticket: ticket)
            } catch {
                if scan.isCurrentSurface(ticket) { captureFailure = scannerErrorText(error) }
            }
        }
    }

    private func recognizePage(_ page: MacScanPage) {
        copyNotice(nil)
        guard let ticket = surfaceTicket else { return }
        do { try scan.recognizePage(page.id, ticket: ticket) } catch { importFailure = scannerErrorText(error) }
    }

    private func recognizeAllPages() {
        copyNotice(nil)
        guard let ticket = surfaceTicket else { return }
        do { try scan.recognizeAll(ticket: ticket) } catch { importFailure = scannerErrorText(error) }
    }

    private func exportPNG() {
        export(.png)
    }

    private func exportPagePNG(_ page: MacScanPage) {
        export(.png, pageID: page.id)
    }

    private func exportPDF() {
        export(.pdf)
    }

    private func exportTXT() {
        export(.txt)
    }

    private func export(_ format: MacScanExportFormat, pageID: UUID? = nil) {
        exportFailure = nil
        copyNotice(nil)
        guard let ticket = surfaceTicket else { return }
        do {
            let request = try scan.prepareExport(format, pageID: pageID, ticket: ticket)
            guard let url = environment.exporter.chooseDestination(format: request.format,
                suggestedFilename: request.suggestedFilename,
                isStillAuthorized: { scan.isCurrentSurface(ticket) }) else { return }
            try scan.commitExport(request, to: url)
        } catch {
            exportFailure = scannerErrorText(error)
        }
    }

    private func copyAll() {
        let text = scan.results.map(\.payload).joined(separator: "\n")
        copy(text)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyNotice(macToolboxText("已复制到剪贴板。", "Copied to the clipboard.", locale))
    }

    private func copyNotice(_ text: String?) {
        copiedNote = text
    }

    private func scannerErrorText(_ error: Error) -> String {
        if let draftError = error as? MacScannerDraftError {
            switch draftError {
            case .tooManyPixels, .tooManyBytes:
                return macToolboxText("草稿已达大小上限，请移除页面后重试。", "The draft is full. Remove pages and try again.", locale)
            case .unavailable, .invalidDestination:
                return macToolboxText("操作暂不可用，请重试。", "This action is unavailable. Try again.", locale)
            }
        }
        return macMediaFailureText((error as? MacMediaFailure) ?? .unreadable, locale)
    }

    private func exportReceiptText(_ receipt: MacScannerExportReceipt) -> String {
        switch receipt.outcome {
        case .committed:
            return macToolboxText("已导出 \(receipt.destination.lastPathComponent)。", "Exported \(receipt.destination.lastPathComponent).", locale)
        case .uncertain:
            return macToolboxText("导出状态未确认，请检查所选位置。", "Export status is unconfirmed. Check the selected location.", locale)
        case .failed:
            return macToolboxText("导出未完成，请重试。", "Export did not finish. Try again.", locale)
        }
    }
}
