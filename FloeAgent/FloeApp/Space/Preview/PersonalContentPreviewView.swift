// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

/// A content surface usable in a list/grid cell or an editor's material row.
/// The caller controls its size and navigation; this view never opens an editor.
struct PersonalContentPreviewView: View {
    private enum Input {
        case request(PersonalContentPreviewRequest)
        case library(PersonalContentRecord, PersonalContentService)
    }
    private struct LoadID: Hashable { let source: String; let retry: UUID }
    private let input: Input
    private let service: PersonalContentPreviewService
    private let contentScale: CGFloat
    @State private var artifact: PersonalContentPreviewArtifact?
    @State private var failure: PersonalContentPreviewError?
    @State private var loadID: UUID?
    @State private var retry = UUID()

    init(request: PersonalContentPreviewRequest, contentScale: CGFloat = 1, service: PersonalContentPreviewService = .shared) {
        input = .request(request); self.service = service; self.contentScale = min(4, max(1, contentScale))
    }
    init(record: PersonalContentRecord, contentService: PersonalContentService = .shared,
         service: PersonalContentPreviewService = .shared) {
        input = .library(record, contentService); self.service = service; contentScale = 1
    }
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let artifact { PersonalPreviewContent(artifact: artifact, contentScale: contentScale) }
            else if let failure {
                VStack(spacing: 8) {
                    Text(failureTitle(failure)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if failure == .unavailable || failure == .queueFull || failure == .timedOut {
                        Button(previewText("重试", "Retry")) { retry = UUID() }.font(.caption).frame(minHeight: 44)
                    }
                }.padding(8)
            } else { ProgressView().accessibilityLabel(previewText("正在载入预览", "Loading preview")) }
        }
        .clipped()
        .task(id: LoadID(source: sourceID, retry: retry)) { await load() }
    }
    private var sourceID: String {
        switch input {
        case .request(let request):
            "\(request.key.ownerID)|\(request.key.objectID)|\(request.key.revision)|\(request.key.variant)|\(request.key.maximumPixelSize)"
        case .library(let record, let contentService): "\(ObjectIdentifier(contentService))|\(record.id)|\(record.kind)|\(record.modifiedAt.timeIntervalSince1970)|\(record.relativePath)"
        }
    }
    private func load() async {
        let token = UUID(); loadID = token; artifact = nil; failure = nil
        do {
            let request: PersonalContentPreviewRequest
            switch input {
            case .request(let value): request = value
            case .library(let record, let contentService): request = try await service.request(for: record, contentService: contentService)
            }
            let value = try await service.preview(request)
            guard !Task.isCancelled, loadID == token else { return }
            artifact = value
        } catch {
            guard !Task.isCancelled, loadID == token else { return }
            failure = (error as? PersonalContentPreviewError) ?? .unavailable
        }
    }
    private func failureTitle(_ error: PersonalContentPreviewError) -> String {
        switch error {
        case .notPrepared: previewText("尚无可用预览", "No preview prepared")
        case .unsupported: previewText("请打开原件查看", "Open the original to view")
        case .sourceChanged: previewText("内容已更新，请重新打开", "Content changed. Open it again")
        case .tooLarge: previewText("内容较大，请打开原件查看", "Open the original to view this large item")
        case .queueFull: previewText("预览正忙，稍后重试", "Preview is busy. Try again shortly")
        case .timedOut: previewText("预览未能及时载入", "Preview took too long to load")
        case .unavailable: previewText("暂时无法预览", "Preview is unavailable")
        }
    }
}

/// A native, reusable quick-preview route. Its own dismiss restores the
/// caller's original list/selection. It owns no document or editing session.
struct PersonalContentQuickPreview: View {
    let request: PersonalContentPreviewRequest
    var title = ""
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    PersonalContentPreviewView(request: request, contentScale: zoom)
                        .frame(width: max(1, geometry.size.width) * zoom, height: max(1, geometry.size.height) * zoom)
                }
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    zoom = min(4, max(1, committedZoom * value.magnification))
                }.onEnded { _ in committedZoom = zoom })
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(previewText("完成", "Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(previewText("缩小", "Zoom out"), systemImage: "minus.magnifyingglass") { setZoom(zoom / 1.5) }.disabled(zoom <= 1)
                    Button(previewText("适合窗口", "Fit")) { setZoom(1) }
                    Button(previewText("放大", "Zoom in"), systemImage: "plus.magnifyingglass") { setZoom(zoom * 1.5) }.disabled(zoom >= 4)
                }
            }
        }
    }
    private func setZoom(_ value: CGFloat) { zoom = min(4, max(1, value)); committedZoom = zoom }
}

private struct PersonalPreviewContent: View {
    let artifact: PersonalContentPreviewArtifact
    let contentScale: CGFloat
    var body: some View {
        VStack(spacing: 4) {
            switch artifact.content {
            case .image(let data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(previewText("内容预览", "Content preview"))
                }
            case .text(let text):
                ScrollView { Text(text).font(.system(size: 12 * contentScale, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(10) }
            case .waveform(let waveform): PersonalPreviewWaveform(value: waveform)
            }
            if let detail = artifact.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

private struct PersonalPreviewWaveform: View {
    let value: PersonalContentPreviewArtifact.Waveform
    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let height = size.height / CGFloat(max(1, value.channels.count))
                for (index, channel) in value.channels.enumerated() {
                    let count = min(channel.minimum.count, channel.maximum.count)
                    guard count > 0 else { continue }
                    let extent = max(1, (channel.minimum + channel.maximum).filter(\.isFinite).map { abs($0) }.max() ?? 1)
                    let middle = height * (CGFloat(index) + 0.5)
                    var path = Path()
                    for i in 0..<count where channel.minimum[i].isFinite && channel.maximum[i].isFinite {
                        let x = (CGFloat(i) + 0.5) / CGFloat(count) * size.width
                        path.move(to: CGPoint(x: x, y: middle - CGFloat(channel.maximum[i] / extent) * height * 0.44))
                        path.addLine(to: CGPoint(x: x, y: middle - CGFloat(channel.minimum[i] / extent) * height * 0.44))
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: max(1, size.width / CGFloat(count) * 0.65))
                }
            }.accessibilityHidden(true)
            Text(String(format: "%.2f–%.2f s / %.2f s", value.startSeconds, value.endSeconds, value.durationSeconds))
                .font(.caption2).monospacedDigit()
        }.padding(8).accessibilityElement(children: .combine)
            .accessibilityLabel(previewText("实测音频波形", "Measured audio waveform"))
    }
}
#endif
