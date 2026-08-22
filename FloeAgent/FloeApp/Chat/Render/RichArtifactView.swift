#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Charts
import WebKit
import CryptoKit
import FloeExecution
import FloeModels

struct RichArtifactGallery: View {
    let artifacts: [ToolArtifactReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(artifacts) { artifact in
                RichArtifactView(artifact: artifact)
            }
        }
    }
}

private struct RichArtifactView: View {
    let artifact: ToolArtifactReference
    @State private var data: Data?
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var showExpandedWeb = false

    var body: some View {
        Group {
            if let data, let fileURL {
                verifiedContent(data: data, fileURL: fileURL)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.destructive)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: artifact.id) { loadVerifiedData() }
        .fullScreenCover(isPresented: $showExpandedWeb) {
            NavigationStack {
                if let data, let html = String(data: data, encoding: .utf8) {
                    SandboxedArtifactWebView(html: html)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("交互预览")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showExpandedWeb = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func verifiedContent(data: Data, fileURL: URL) -> some View {
        switch artifact.mimeType {
        case "application/vnd.floe.table+json":
            if let document = try? JSONDecoder().decode(PresentationTableDocument.self, from: data) {
                NativeArtifactTable(document: document, fileURL: fileURL)
            } else { invalidContent }
        case "application/vnd.floe.chart+json":
            if let document = try? JSONDecoder().decode(PresentationChartDocument.self, from: data) {
                NativeArtifactChart(document: document, fileURL: fileURL)
            } else { invalidContent }
        case "text/html":
            if let html = String(data: data, encoding: .utf8) {
                VStack(alignment: .leading, spacing: 8) {
                    SandboxedArtifactWebView(html: html)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    HStack {
                        Button("展开交互预览", systemImage: "arrow.up.left.and.arrow.down.right") {
                            showExpandedWeb = true
                        }
                        Spacer()
                        ShareLink(item: fileURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                    .font(FloeTheme.Typography.metadata)
                }
            } else { invalidContent }
        default:
            HStack(spacing: 10) {
                Image(systemName: "doc")
                VStack(alignment: .leading, spacing: 2) {
                    Text((artifact.relativePath as NSString).lastPathComponent)
                        .font(FloeTheme.Typography.metadata.weight(.semibold))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private var invalidContent: some View {
        Label("产物已校验，但结构无法解析", systemImage: "exclamationmark.triangle")
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(FloeTheme.destructive)
    }

    private func loadVerifiedData() {
        let allowedRoots = ["PresentationArtifacts/", "ChangeArtifacts/"]
        let limit: Int
        switch artifact.mimeType {
        case "text/html": limit = 1 * 1_024 * 1_024
        case "application/vnd.floe.table+json", "application/vnd.floe.chart+json": limit = 2 * 1_024 * 1_024
        default: limit = 512 * 1_024
        }
        guard artifact.byteCount > 0, artifact.byteCount <= limit,
              !artifact.relativePath.hasPrefix("/"),
              !artifact.relativePath.split(separator: "/").contains(".."),
              allowedRoots.contains(where: artifact.relativePath.hasPrefix),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            error = "产物路径或大小不受支持"
            return
        }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(artifact.relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix),
              let loaded = try? Data(floeContentsOf: candidate, options: [.mappedIfSafe]),
              loaded.count == artifact.byteCount else {
            error = "无法读取产物"
            return
        }
        let digest = SHA256.hash(data: loaded).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else {
            error = "产物校验失败"
            return
        }
        data = loaded
        fileURL = candidate
    }
}

private struct NativeArtifactTable: View {
    let document: PresentationTableDocument
    let fileURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = document.title, !title.isEmpty { Text(title).font(.headline) }
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        ForEach(Array(document.columns.enumerated()), id: \.offset) { _, column in
                            Text(column).font(FloeTheme.Typography.metadata.weight(.semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(document.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 8))
            ShareLink(item: fileURL) { Label("分享表格数据", systemImage: "square.and.arrow.up") }
                .font(FloeTheme.Typography.metadata)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NativeArtifactChart: View {
    private struct Datum: Identifiable {
        let id = UUID()
        let series: String
        let label: String
        let value: Double
    }
    let document: PresentationChartDocument
    let fileURL: URL
    private var data: [Datum] {
        document.series.flatMap { series in
            series.points.map { Datum(series: series.name, label: $0.label, value: $0.value) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = document.title, !title.isEmpty { Text(title).font(.headline) }
            Chart(data) { datum in
                switch document.type {
                case .line:
                    LineMark(x: .value("类别", datum.label), y: .value("值", datum.value))
                        .foregroundStyle(by: .value("系列", datum.series))
                    PointMark(x: .value("类别", datum.label), y: .value("值", datum.value))
                        .foregroundStyle(by: .value("系列", datum.series))
                case .bar:
                    BarMark(x: .value("类别", datum.label), y: .value("值", datum.value))
                        .foregroundStyle(by: .value("系列", datum.series))
                case .area:
                    AreaMark(x: .value("类别", datum.label), y: .value("值", datum.value))
                        .foregroundStyle(by: .value("系列", datum.series))
                        .opacity(0.6)
                case .pie:
                    SectorMark(angle: .value("值", max(0, datum.value)), innerRadius: .ratio(0.45))
                        .foregroundStyle(by: .value("项目", "\(datum.series) · \(datum.label)"))
                case .scatter:
                    PointMark(x: .value("类别", datum.label), y: .value("值", datum.value))
                        .foregroundStyle(by: .value("系列", datum.series))
                }
            }
            .frame(minHeight: 240)
            .chartLegend(position: .bottom, alignment: .leading)
            ShareLink(item: fileURL) { Label("分享图表数据", systemImage: "square.and.arrow.up") }
                .font(FloeTheme.Typography.metadata)
        }
        .padding(10)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct SandboxedArtifactWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedDigest != html.hashValue else { return }
        context.coordinator.loadedDigest = html.hashValue
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedDigest: Int?
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let isInitialDocument = url?.scheme == "about" || url?.absoluteString == nil
            return isInitialDocument ? .allow : .cancel
        }
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }
    }
}
#endif
