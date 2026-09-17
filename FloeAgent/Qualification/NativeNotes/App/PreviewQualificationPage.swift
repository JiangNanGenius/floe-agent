// SPDX-License-Identifier: MPL-2.0
//
// Component-only Office thumbnail qualification host.
//
// This page exists so a human can watch `NotesDocumentThumbnail` generate real
// Quick Look previews for real Office packages. It never starts an Office
// engine, never fabricates an image and never touches the application Notes
// store: every fixture is generated into a dedicated Application Support
// qualification directory and imported into an isolated `NotesStore` rooted
// inside that directory.
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeNotes
import FloeDocuments

/// One deterministic, sensitive-data-free Office sample. The generator writes
/// real Open XML packages through `OfficeDocumentBuilder`; nothing is checked
/// in and no thumbnail is bundled.
struct PreviewFixtureSample: Sendable, Hashable {
    enum Format: String, Sendable, Hashable { case word, excel, powerpoint }

    let fileName: String
    let chineseTitle: String
    let englishTitle: String
    let formatLabel: String
    let format: Format

    var displayTitle: String { "\(chineseTitle) · \(englishTitle)" }
}

/// Builds the qualification fixtures. Kept internal (not private) so the
/// targeted NativeNotesTests can import the same samples and assert that the
/// generated packages are real, importable Office documents.
enum PreviewFixtureFactory {
    static let samples: [PreviewFixtureSample] = [
        PreviewFixtureSample(fileName: "商务周报.docx", chineseTitle: "商务周报",
                             englishTitle: "Business Weekly Report", formatLabel: "Word", format: .word),
        PreviewFixtureSample(fileName: "meeting-notes.docx", chineseTitle: "会议纪要",
                             englishTitle: "Meeting Notes", formatLabel: "Word", format: .word),
        PreviewFixtureSample(fileName: "季度数据汇总.xlsx", chineseTitle: "季度数据汇总",
                             englishTitle: "Quarterly Data Summary", formatLabel: "Excel", format: .excel),
        PreviewFixtureSample(fileName: "budget-forecast.xlsx", chineseTitle: "预算预测",
                             englishTitle: "Budget Forecast", formatLabel: "Excel", format: .excel),
        PreviewFixtureSample(fileName: "产品路线图.pptx", chineseTitle: "产品路线图",
                             englishTitle: "Product Roadmap", formatLabel: "PowerPoint", format: .powerpoint),
        PreviewFixtureSample(fileName: "design-review.pptx", chineseTitle: "设计评审",
                             englishTitle: "Design Review", formatLabel: "PowerPoint", format: .powerpoint)
    ]

    static func sample(for fileName: String) -> PreviewFixtureSample? {
        samples.first { $0.fileName == fileName }
    }

    /// Writes one real Office package per sample into `directory` and returns
    /// the created URLs in sample order. The caller owns the directory.
    @discardableResult
    static func writeSamples(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try samples.map { sample in
            let url = directory.appendingPathComponent(sample.fileName)
            switch sample.format {
            case .word:
                try OfficeDocumentBuilder.createWord(
                    at: url,
                    title: sample.displayTitle,
                    paragraphs: [
                        "中文段落：本文件是组件验证用的合成样本，不含任何真实业务数据。",
                        "English paragraph: this synthetic sample proves the preview comes from a real file.",
                        "第二段：Quick Look 应基于这个包现场生成缩略图。"
                    ])
            case .excel:
                try OfficeDocumentBuilder.createWorkbook(
                    at: url,
                    sheets: [OfficeWorkbookSheet(name: "Quarterly", rows: [
                        ["季度 Quarter", "收入 Revenue", "成本 Cost"],
                        ["Q1", "120", "80"],
                        ["Q2", "150", "96"],
                        ["Q3", "168", "101"]
                    ])])
            case .powerpoint:
                try OfficeDocumentBuilder.createPresentation(
                    at: url,
                    title: sample.displayTitle,
                    slides: [
                        OfficePresentationSlide(title: sample.displayTitle,
                                                bullets: ["里程碑 Milestone 1", "里程碑 Milestone 2"]),
                        OfficePresentationSlide(title: "风险 Risks",
                                                bullets: ["合成内容 Synthetic content", "无敏感数据 No sensitive data"])
                    ])
            }
            return url
        }
    }
}

/// `--preview-fixture` destination. Shows the six Office samples as
/// `NotesDocumentThumbnail` cards so the operator can observe image vs. icon
/// placeholder, rapid reordering and a full clear/reload cycle.
struct PreviewQualificationPage: View {
    @State private var store: NotesStore?
    @State private var documents: [NoteDocument] = []
    @State private var resourceBytes: [UUID: Int] = [:]
    @State private var status = "正在准备真实 Office 预览样本…"
    @State private var fixtureRoot: URL?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                scrollContent
            }
            .navigationTitle("Office 缩略图组件验证")
        }
        .task { if documents.isEmpty { await reload() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("此页面只验证 NotesDocumentThumbnail 的真实 Quick Look 生成，不代表完整应用验收。")
                .font(.caption)
            Text(status)
                .font(.headline)
                .accessibilityIdentifier("preview.qualification.status")
            Text("缩略图由系统 Quick Look 基于真实 .docx/.xlsx/.pptx 现场生成，没有静态 mock；若卡片显示图标占位，说明本次请求未返回图片。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let fixtureRoot {
                Text(fixtureRoot.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("preview.qualification.path")
            }
            HStack(spacing: 12) {
                Button("清空并重载") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("preview.qualification.reload")
                Button("随机重排") { withAnimation { documents.shuffle() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("preview.qualification.shuffle")
                Spacer()
                Text("共 \(documents.count) 项").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(documents) { document in
                    card(document)
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("preview.qualification.grid")
    }

    private func card(_ document: NoteDocument) -> some View {
        let sample = document.officeFileName.flatMap(PreviewFixtureFactory.sample(for:))
        return VStack(alignment: .leading, spacing: 8) {
            NotesDocumentThumbnail(document: document, store: store)
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
                .accessibilityIdentifier("preview.card.\(document.officeFileName ?? document.id.uuidString)")
            Text(sample?.chineseTitle ?? document.title)
                .font(.subheadline).fontWeight(.semibold).lineLimit(1)
            Text(sample?.englishTitle ?? document.title)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(metadata(document, sample: sample))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func metadata(_ document: NoteDocument, sample: PreviewFixtureSample?) -> String {
        var parts = [sample?.formatLabel ?? document.kind.rawValue, "rev \(document.revision)"]
        if let name = document.officeFileName { parts.append(name) }
        if let bytes = resourceBytes[document.id] { parts.append("源文件 \(bytes) 字节") }
        return parts.joined(separator: " · ")
    }

    /// Rebuilds everything from scratch: a fresh run directory, freshly
    /// generated Office packages and a fresh isolated NotesStore. The previous
    /// run is removed best-effort after the UI has switched away from it.
    @MainActor
    private func reload() async {
        status = "正在生成并导入真实 Office 样本…"
        do {
            let base = try Self.qualificationRoot()
            // Drop fixtures left by a previous launch; a run still referenced by
            // this session is preserved until the state has switched away from it.
            Self.pruneRuns(in: base, keeping: fixtureRoot)
            let run = base.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            let sources = run.appendingPathComponent("sources", isDirectory: true)
            let storeRoot = run.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

            let urls = try PreviewFixtureFactory.writeSamples(to: sources)
            let newStore = try NotesStore(root: storeRoot)
            var created: [NoteDocument] = []
            var sizes: [UUID: Int] = [:]
            for url in urls {
                let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: newStore)
                let document = try await newStore.create(draft)
                created.append(document)
                if let id = document.officeResourceID,
                   let resource = try? await newStore.resourceURL(id),
                   let bytes = try? resource.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    sizes[document.id] = bytes
                }
            }

            let previous = fixtureRoot
            store = newStore
            documents = created
            resourceBytes = sizes
            fixtureRoot = run
            status = "已导入 \(created.count) 个真实 Office 文档（Word/Excel/PowerPoint 中英标题）。"
            if let previous { Self.removeRunDirectory(previous) }
        } catch {
            status = "准备失败：\(error.localizedDescription)"
        }
    }

    private static func qualificationRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("FloeNotesPreviewQualification", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func pruneRuns(in root: URL, keeping current: URL?) {
        let keep = current?.standardizedFileURL.path
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("run-") && entry.standardizedFileURL.path != keep {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Files are pinned for the lifetime of the NotesStore, so delete a run only
    /// after the view has stopped referencing it. Failures are ignored: this is
    /// disposable qualification data.
    private static func removeRunDirectory(_ url: URL) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif
