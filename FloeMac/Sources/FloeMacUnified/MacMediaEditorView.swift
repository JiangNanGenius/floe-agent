// SPDX-License-Identifier: MPL-2.0

// Thin Mac editor chrome for basic image crop/adjustment and video
// trim/export. All editing semantics live in the UI-free
// `MacMediaEditing.swift` core; this file only renders the source, collects
// user input, runs the bounded/cancellable exports and routes the finished
// file back through the same task/canvas routes as generated media.
//
// The original asset is never touched: exports always write a fresh,
// verified copy in a per-session staging directory, and the routing actions
// copy from there into the task folder or the canvas library.

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// One editor presentation. The routing closures are captured by the owning
/// view when the editor opens, so the task/canvas owner is fixed for the
/// whole edit even if the selection changes underneath.
struct MacMediaEditSession: Identifiable {
    let id = UUID()
    let source: MacMediaEditSource
    var saveToTask: ((URL) async -> Bool)?
    var addToCanvas: ((URL) -> Void)?
}

struct MacMediaEditorView: View {
    let session: MacMediaEditSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.source.kind {
            case .image:
                MacImageEditPane(session: session, staging: staging)
            case .video:
                MacVideoEditPane(session: session, staging: staging)
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .onDisappear { staging.clear() }
    }

    @StateObject private var staging = MacMediaEditStagingOwner()

    private var header: some View {
        HStack {
            Text(session.source.kind == .image
                 ? MacMediaEditStrings.titleImage
                 : MacMediaEditStrings.titleVideo)
                .font(.headline)
            Text(verbatim: session.source.title)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(MacMediaEditStrings.close) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mac.mediaEditor.close")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Observable staging owner so the sheet and its panes share one scratch
/// directory that is removed when the editor closes.
@MainActor
final class MacMediaEditStagingOwner: ObservableObject {
    private(set) lazy var staging: MacMediaEditStaging? = try? MacMediaEditStaging()
    func clear() { staging?.clear() }
}

/// Sendable bridge for exporter progress callbacks that arrive on a
/// background thread; the wrapped closure performs its own MainActor hop.
final class MacMediaEditProgressSink: @unchecked Sendable {
    private let emit: @Sendable (Double) -> Void
    init(_ emit: @escaping @Sendable (Double) -> Void) { self.emit = emit }
    func report(_ value: Double) { emit(value) }
}

// MARK: - Shared export footer

/// Export button + progress + post-export routing actions shared by both
/// panes. `performExport` runs the pane-specific export into the staging
/// directory and returns the finished file URL.
private struct MacMediaExportFooter: View {
    let canExport: Bool
    let exportTitle: String
    /// The pane runs its export, reporting progress (0...1) when available.
    let performExport: (@escaping @Sendable (Double) -> Void) async throws -> URL
    let session: MacMediaEditSession

    @State private var isExporting = false
    @State private var progress = 0.0
    @State private var exported: URL?
    @State private var exportError: String?
    @State private var routeFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let exportError {
                Text(exportError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if isExporting {
                HStack(spacing: 10) {
                    ProgressView(value: progress).controlSize(.small)
                    Text(MacMediaEditStrings.exportProgress).foregroundStyle(.secondary)
                    Spacer()
                    Button(MacMediaEditStrings.cancelExport) { cancelExport() }
                        .accessibilityIdentifier("mac.mediaEditor.cancelExport")
                }
            } else if let exported {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(MacMediaEditStrings.exportedReady).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let addToCanvas = session.addToCanvas {
                        Button(MacMediaEditStrings.addToCanvas) {
                            addToCanvas(exported)
                            dismissAfterRoute()
                        }
                        .accessibilityIdentifier("mac.mediaEditor.addToCanvas")
                    }
                    if let saveToTask = session.saveToTask {
                        Button(MacMediaEditStrings.saveToTask) {
                            Task { @MainActor in
                                if await saveToTask(exported) { dismissAfterRoute() } else { routeFailed = true }
                            }
                        }
                        .accessibilityIdentifier("mac.mediaEditor.saveToTask")
                    }
                    Button(MacMediaEditStrings.export) { saveAs(exported) }
                    Button(MacMediaEditStrings.done) { dismissEnvironment() }
                        .keyboardShortcut(.defaultAction)
                }
                .alert(MacCanvasText.routeFailed, isPresented: $routeFailed) {
                    Button("OK", role: .cancel) {}
                }
            } else {
                HStack {
                    Spacer()
                    Button(exportTitle) { startExport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExport)
                        .accessibilityIdentifier("mac.mediaEditor.export")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @Environment(\.dismiss) private var dismissEnvironment
    @State private var exportTask: Task<Void, Never>?

    private func startExport() {
        isExporting = true
        progress = 0
        exportError = nil
        exported = nil
        // The exporter reports from a background thread; the sink hops the
        // value onto MainActor without erasing the actor isolation of the
        // state it touches.
        let sink = MacMediaEditProgressSink { value in
            Task { @MainActor in progress = value }
        }
        exportTask = Task { @MainActor in
            defer { isExporting = false }
            do {
                let url = try await performExport { value in sink.report(value) }
                progress = 1
                exported = url
            } catch is CancellationError {
                exportError = MacMediaEditStrings.cancelled
            } catch let editError as MacMediaEditError {
                exportError = editError.localizedDescription
            } catch {
                exportError = String(format: MacMediaEditStrings.exportFailedFormat, error.localizedDescription)
            }
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
    }

    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .data]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                let manager = FileManager.default
                if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: url) }
                else { try manager.copyItem(at: url, to: target) }
            } catch {
                routeFailed = true
            }
        }
    }

    private func dismissAfterRoute() {
        // The routed copy belongs to the task/canvas now; close the editor.
        dismissEnvironment()
    }
}

// MARK: - Image pane

private struct MacImageEditPane: View {
    let session: MacMediaEditSession
    @ObservedObject var staging: MacMediaEditStagingOwner

    @State private var image: NSImage?
    @State private var imageSize: CGSize = .zero
    @State private var crop: MacNormalizedCropRect = .identity
    @State private var saturation: Double = 1
    @State private var contrast: Double = 1
    @State private var brightness: Double = 0
    @State private var exposure: Double = 0
    @State private var preview: NSImage?
    @State private var previewTask: Task<Void, Never>?

    private var adjustment: MacImageAdjustment? {
        get throws {
            try MacImageAdjustment(
                saturation: saturation == 1 ? nil : saturation,
                contrast: contrast == 1 ? nil : contrast,
                brightness: brightness == 0 ? nil : brightness,
                exposureEV: exposure == 0 ? nil : exposure)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let preview {
                    MacImageCropCanvas(
                        image: preview,
                        container: geo.size,
                        crop: $crop)
                } else if image == nil {
                    ContentUnavailableView(MacMediaEditStrings.sourceUnreadable, systemImage: "photo")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            controls
            Divider()
            MacMediaExportFooter(
                canExport: image != nil,
                exportTitle: MacMediaEditStrings.export,
                performExport: { try await export(reportProgress: $0) },
                session: session)
        }
        .onAppear(perform: load)
        .onDisappear { previewTask?.cancel() }
        .onChange(of: crop) { _, _ in schedulePreview() }
        .onChange(of: saturation) { _, _ in schedulePreview() }
        .onChange(of: contrast) { _, _ in schedulePreview() }
        .onChange(of: brightness) { _, _ in schedulePreview() }
        .onChange(of: exposure) { _, _ in schedulePreview() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(MacMediaEditStrings.cropSection).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(MacMediaEditStrings.reset) { crop = .identity }
                    .disabled(crop.isIdentity)
                    .accessibilityIdentifier("mac.mediaEditor.resetCrop")
            }
            Text(MacMediaEditStrings.cropHint).font(.caption).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 2)
            HStack {
                Text(MacMediaEditStrings.adjustSection).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(MacMediaEditStrings.reset) { resetAdjustments() }
                    .disabled(saturation == 1 && contrast == 1 && brightness == 0 && exposure == 0)
                    .accessibilityIdentifier("mac.mediaEditor.resetAdjust")
            }
            adjustmentSlider(title: MacMediaEditStrings.saturation, value: $saturation, range: 0...2)
            adjustmentSlider(title: MacMediaEditStrings.contrast, value: $contrast, range: 0...4)
            adjustmentSlider(title: MacMediaEditStrings.brightness, value: $brightness, range: -1...1)
            adjustmentSlider(title: MacMediaEditStrings.exposure, value: $exposure, range: -2...2)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func adjustmentSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 76, alignment: .trailing).foregroundStyle(.secondary)
            Slider(value: value, in: range) { Text(title) }.labelsHidden()
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func resetAdjustments() {
        saturation = 1; contrast = 1; brightness = 0; exposure = 0
    }

    // MARK: Loading + preview

    private func load() {
        guard let data = try? Data(contentsOf: session.source.url),
              let loaded = NSImage(data: data) else { return }
        image = loaded
        imageSize = loaded.size
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, image != nil else { return }
            preview = renderPreview()
        }
    }

    /// Renders the current crop + adjustment at preview resolution so
    /// slider drags stay responsive; full-resolution render happens only
    /// at export.
    private func renderPreview() -> NSImage? {
        guard let data = try? Data(contentsOf: session.source.url),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let maxEdge: CGFloat = 720
        let scale = min(1, maxEdge / max(CGFloat(cg.width), CGFloat(cg.height)))
        let renderer = MacImageEditRenderer()
        guard let rendered = try? renderer.render(cg, crop: crop.isIdentity ? nil : crop,
                                                adjustment: try? adjustment) else { return nil }
        let previewImage: CGImage
        if scale < 1 {
            let target = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
            let context = CGContext(data: nil, width: Int(target.width), height: Int(target.height),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(rendered, in: CGRect(origin: .zero, size: target))
            previewImage = context?.makeImage() ?? rendered
        } else {
            previewImage = rendered
        }
        return NSImage(cgImage: previewImage, size: imageSize)
    }

    // MARK: Export

    private func export(reportProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let staging = staging.staging else { throw MacMediaEditError.exportFailed("staging") }
        let type = MacImageEditExporter.outputType(for: session.source.url)
        let ext = MacImageEditExporter.outputExtension(for: type)
        let base = session.source.url.deletingPathExtension().lastPathComponent
        let destination = staging.fileURL(name: "\(base)-\(MacMediaEditStrings.pickOutputName)", pathExtension: ext)
        reportProgress(0.2)
        try await MacImageEditExporter().export(
            source: session.source.url,
            crop: crop.isIdentity ? nil : crop,
            adjustment: try? adjustment,
            to: destination)
        return destination
    }
}

/// Image + draggable crop frame. The frame moves with a drag inside it and
/// resizes from the trailing-bottom corner handle; the crop rect always
/// stays inside the unit square and keeps a minimum size.
private struct MacImageCropCanvas: View {
    let image: NSImage
    let container: CGSize
    @Binding var crop: MacNormalizedCropRect

    @State private var dragStartCrop: MacNormalizedCropRect?

    private var fitted: CGSize {
        let scale = min(container.width / image.size.width, container.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    var body: some View {
        let size = fitted
        return ZStack {
            Color.clear
            Image(nsImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height)
            cropOverlay(display: size)
        }
        .frame(width: container.width, height: container.height)
    }

    @ViewBuilder private func cropOverlay(display: CGSize) -> some View {
        let origin = CGPoint(x: (container.width - display.width) / 2, y: (container.height - display.height) / 2)
        let rect = CGRect(x: origin.x + crop.x * display.width,
                          y: origin.y + (1 - crop.y - crop.height) * display.height,
                          width: crop.width * display.width,
                          height: crop.height * display.height)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Color.black.opacity(0.35)
                .frame(width: container.width, height: max(0, rect.minY))
            Color.black.opacity(0.35)
                .frame(width: container.width, height: max(0, container.height - rect.maxY))
                .offset(y: rect.maxY)
            Color.black.opacity(0.35)
                .frame(width: max(0, rect.minX), height: rect.height)
                .offset(y: rect.minY)
            Color.black.opacity(0.35)
                .frame(width: max(0, container.width - rect.maxX), height: rect.height)
                .offset(x: rect.maxX, y: rect.minY)
            Rectangle()
                .fill(Color.clear)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .position(x: rect.midX, y: rect.midY)
                .overlay(
                    Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                )
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in moveCrop(value: value, display: display) }
                    .onEnded { _ in dragStartCrop = nil })
            // Resize handle.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.55), in: Circle())
                .position(x: rect.maxX, y: rect.maxY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in resizeCrop(value: value, display: display) }
                    .onEnded { _ in dragStartCrop = nil })
        }
    }

    private func moveCrop(value: DragGesture.Value, display: CGSize) {
        if dragStartCrop == nil { dragStartCrop = crop }
        guard let start = dragStartCrop else { return }
        let dx = value.translation.width / display.width
        let dy = value.translation.height / display.height
        // Crop rect origin is bottom-left in image space; the view's y is
        // flipped, so a downward drag (positive dy) decreases y.
        let nx = min(max(start.x + dx, 0), 1 - start.width)
        let ny = min(max(start.y - dy, 0), 1 - start.height)
        crop = (try? MacNormalizedCropRect(x: nx, y: ny, width: start.width, height: start.height)) ?? crop
    }

    private func resizeCrop(value: DragGesture.Value, display: CGSize) {
        if dragStartCrop == nil { dragStartCrop = crop }
        guard let start = dragStartCrop else { return }
        let dx = value.translation.width / display.width
        let dy = value.translation.height / display.height
        // The handle sits on the lower-right image-space corner
        // (crop.x + width, crop.y): dragging right grows the width;
        // dragging down (toward the image bottom) grows the height.
        let nw = max(0.05, min(start.width + dx, 1 - start.x))
        let nh = max(0.05, min(start.height + dy, 1 - start.y))
        crop = (try? MacNormalizedCropRect(x: start.x, y: start.y, width: nw, height: nh)) ?? crop
    }
}

// MARK: - Video pane

private struct MacVideoEditPane: View {
    let session: MacMediaEditSession
    @ObservedObject var staging: MacMediaEditStagingOwner

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var loadFailed = false

    private var trim: MacVideoTrimRange? {
        try? MacVideoTrimRange(start: trimStart, end: trimEnd, duration: duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            if loadFailed {
                ContentUnavailableView(MacMediaEditStrings.sourceUnreadable, systemImage: "film")
            } else if duration > 0 {
                MacMediaEditPlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if duration > 0 {
                trimControls
                Divider()
            }
            MacMediaExportFooter(
                canExport: trim != nil,
                exportTitle: MacMediaEditStrings.export,
                performExport: { try await export(reportProgress: $0) },
                session: session)
        }
        .task { await load() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(MacMediaEditStrings.trimSection).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(MacMediaEditStrings.reset) { trimStart = 0; trimEnd = duration }
                    .disabled(trimStart == 0 && abs(trimEnd - duration) < 0.01)
                    .accessibilityIdentifier("mac.mediaEditor.resetTrim")
            }
            MacTrimSlider(duration: duration, start: $trimStart, end: $trimEnd)
                .frame(height: 28)
            HStack {
                Text(String(format: "%@ %.2fs", MacMediaEditStrings.trimStart, trimStart))
                Spacer()
                Text(String(format: "%@ %.2fs", MacMediaEditStrings.trimEnd, trimEnd))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func load() async {
        do {
            let duration = try await MacVideoEditExporter.verifiedDuration(of: session.source.url)
            guard !Task.isCancelled else { return }
            self.duration = duration
            trimStart = 0
            trimEnd = duration
            player = AVPlayer(url: session.source.url)
        } catch {
            loadFailed = true
        }
    }

    private func export(reportProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let staging = staging.staging, let trim else {
            throw MacMediaEditError.invalidGeometry
        }
        let ext = session.source.url.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let base = session.source.url.deletingPathExtension().lastPathComponent
        let destination = staging.fileURL(name: "\(base)-\(MacMediaEditStrings.pickOutputName)", pathExtension: ext)
        let exporter = MacVideoEditExporter()
        try await exporter.export(source: session.source.url, trim: trim, to: destination, progress: reportProgress)
        return destination
    }
}

/// Inline AVPlayerView for the trim preview (the workbench's player view is
/// file-private to its own feature file).
private struct MacMediaEditPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}

/// Two-thumb trim slider on a horizontal track.
private struct MacTrimSlider: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double

    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let track = geo.size
            let startX = CGFloat(start / duration) * track.width
            let endX = CGFloat(end / duration) * track.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 6)
                Capsule().fill(Color.accentColor).frame(width: max(2, endX - startX), height: 6)
                    .offset(x: startX)
                handle(x: startX, isStart: true, track: track)
                handle(x: endX, isStart: false, track: track)
            }
            .frame(height: track.height)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private func handle(x: CGFloat, isStart: Bool, track: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 0.5))
            .frame(width: handleWidth, height: 20)
            .shadow(radius: 1)
            .offset(x: max(0, min(x - handleWidth / 2, track.width - handleWidth)))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let t = Double(max(0, min(x + value.translation.width, track.width))) / Double(track.width) * duration
                    if isStart {
                        start = max(0, min(t, end - 0.05))
                    } else {
                        end = min(duration, max(t, start + 0.05))
                    }
                })
    }
}
