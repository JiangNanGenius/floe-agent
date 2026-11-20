// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Full-project asset browser: import, replace, rename, delete and
/// reference-safe diagnostics. Image *editing* is delegated to the host
/// image editor by exporting bytes; this view never re-implements one.
public struct AssetBrowserView: View {
    @ObservedObject public var session: GameEditingSession
    @Environment(\.gameEditLocale) private var locale
    @State private var importRequest = false
    @State private var renameTarget: GameRelativePath?
    @State private var renameText = ""
    @State private var replaceTarget: GameRelativePath?
    @State private var referenceTarget: GameRelativePath?
    @State private var references: [AssetReference] = []
    @State private var issue: GameEditIssue?
    @State private var search = ""

    public init(session: GameEditingSession) { self.session = session }

    public var body: some View {
        List(filteredPaths, id: \.self) { path in
            AssetRowView(session: session, path: path)
                .contentShape(Rectangle())
                .onTapGesture { referenceTarget = path }
                .contextMenu {
                    Button { Task { await showReferences(for: path) } } label: {
                        Label { EditText(.references) } icon: { Image(systemName: "link") }
                    }
                    Button { renameTarget = path; renameText = path.value.split(separator: "/").last.map(String.init) ?? "" } label: {
                        Label { EditText(.rename) } icon: { Image(systemName: "pencil") }
                    }
                    Button { replaceTarget = path } label: {
                        Label { EditText(.replace) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    Button(role: .destructive) {
                        Task { await delete(path) }
                    } label: {
                        Label { EditText(.deleted) } icon: { Image(systemName: "trash") }
                    }
                }
        }
        .searchable(text: $search, prompt: GameEditCopy("Search files", "搜索文件").text(locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton { importRequest = true } label: {
                    Label { EditText(.addAsset) } icon: { Image(systemName: "doc.badge.plus") }
                }
            }
        }
        .fileImporter(isPresented: $importRequest, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .fileImporter(isPresented: Binding(get: { replaceTarget != nil }, set: { if !$0 { replaceTarget = nil } }),
                      allowedContentTypes: [.item]) { result in
            guard let target = replaceTarget else { return }
            Task { await replace(target, with: result) }
        }
        .alert(Text(GameEditCopy("Rename file", "重命名文件").text(locale)), isPresented: renameAlertBinding) {
            TextField("", text: $renameText)
            Button {
                guard let target = renameTarget else { return }
                Task { await rename(target, newName: renameText) }
            } label: { EditText(.rename) }
            Button(role: .cancel) { renameTarget = nil } label: { EditText(.cancel) }
        } message: {
            if let target = renameTarget { Text(target.value) }
        }
        .sheet(isPresented: Binding(get: { referenceTarget != nil }, set: { if !$0 { referenceTarget = nil } })) {
            ReferenceListView(session: session, path: Binding(get: { referenceTarget! }, set: { referenceTarget = $0 }),
                              references: $references)
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueBinding) {
            Button(role: .cancel) { issue = nil } label: { EditText(.close) }
        } message: {
            Text(issue?.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n") ?? "")
        }
    }

    private var filteredPaths: [GameRelativePath] {
        let paths = session.assetBrowserPaths
        guard !search.isEmpty else { return paths }
        return paths.filter { $0.value.localizedCaseInsensitiveContains(search) }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var issueBinding: Binding<Bool> {
        Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        var items: [(name: String, bytes: Data)] = []
        var failures: [GameEditDiagnostic] = []
        for url in urls {
            do {
                items.append((url.lastPathComponent, try await GameAssetByteLoader.load(url)))
            } catch {
                failures.append(GameEditDiagnostic(severity: .error,
                    message: GameEditCopy("Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                                          "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")))
            }
        }
        if !failures.isEmpty {
            issue = GameEditIssue(failures)
            guard !items.isEmpty else { return }
        }
        do { _ = try await session.importAssets(items) }
        catch let error as GameEditIssue { issue = error }
        catch { issue = GameEditIssue([GameEditDiagnostic(severity: .error,
            message: GameEditCopy(String(describing: error), String(describing: error)))]) }
    }

    private func replace(_ path: GameRelativePath, with result: Result<URL, Error>) async {
        guard case .success(let url) = result else { replaceTarget = nil; return }
        do {
            let bytes = try await GameAssetByteLoader.load(url)
            try await session.replaceAsset(at: path, with: bytes)
        } catch {
            issue = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("Could not replace \(path.value): \(error.localizedDescription)",
                                      "无法替换 \(path.value)：\(error.localizedDescription)"))])
        }
        replaceTarget = nil
    }

    private func rename(_ path: GameRelativePath, newName: String) async {
        do {
            let plan = try await session.renameAsset(at: path, newName: newName)
            if !plan.diagnostics.isEmpty { issue = GameEditIssue(plan.diagnostics) }
        } catch let error as GameEditIssue { issue = error }
        catch { issue = GameEditIssue([GameEditDiagnostic(severity: .error,
            message: GameEditCopy(String(describing: error), String(describing: error)))]) }
        renameTarget = nil
    }

    private func delete(_ path: GameRelativePath) async {
        do { _ = try await session.deleteAsset(at: path) }
        catch let error as GameEditIssue { issue = error }
        catch { /* already gone */ }
    }

    private func showReferences(for path: GameRelativePath) async {
        references = (try? await session.references(to: path)) ?? []
        referenceTarget = path
    }
}

struct AssetRowView: View {
    @ObservedObject var session: GameEditingSession
    let path: GameRelativePath
    @Environment(\.gameEditLocale) private var locale
    @State private var preview: Data?

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(path.value.split(separator: "/").last.map(String.init) ?? path.value)
                    .lineLimit(1)
                Text(path.value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.isDocumentDirty(at: path) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
            }
            Text(kindName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .frame(minHeight: 44)
        .task(id: path) {
            guard preview == nil,
                  session.adapter.assetKind(for: path, in: session.baseProject) == .image else { return }
            preview = try? await session.documentBytes(at: path)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            ByteImage(bytes: preview).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: icon).frame(width: 36, height: 36).foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch session.adapter.assetKind(for: path, in: session.baseProject) ?? .unknown {
        case .image, .tileset: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .map: return "map"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .data, .manifest: return "tablecells"
        case .save: return "internaldrive"
        case .unknown: return "doc"
        }
    }

    private var kindName: String {
        let kind = session.adapter.assetKind(for: path, in: session.baseProject) ?? .unknown
        switch kind {
        case .image: return GameEditCopy("Image", "图像").text(locale)
        case .audio: return GameEditCopy("Audio", "音频").text(locale)
        case .video: return GameEditCopy("Video", "视频").text(locale)
        case .tileset: return GameEditCopy("Tileset", "图块集").text(locale)
        case .map: return GameEditCopy("Map", "地图").text(locale)
        case .script: return GameEditCopy("Script", "脚本").text(locale)
        case .data: return GameEditCopy("Data", "数据").text(locale)
        case .manifest: return GameEditCopy("Manifest", "清单").text(locale)
        case .save: return GameEditCopy("Save", "存档").text(locale)
        case .unknown: return GameEditCopy("Unknown", "未知").text(locale)
        }
    }
}

struct ReferenceListView: View {
    @ObservedObject var session: GameEditingSession
    @Binding var path: GameRelativePath
    @Binding var references: [AssetReference]
    @Environment(\.gameEditLocale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if references.isEmpty {
                    ContentUnavailableView {
                        EditText(GameEditCopy("No references", "没有引用"))
                    } description: {
                        EditText(GameEditCopy("Nothing in the project points to this file.",
                                              "项目中没有文件引用它。"))
                    }
                } else {
                    List(references, id: \.self) { reference in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reference.referencingPath.value)
                                .font(.callout)
                            if let jsonPath = reference.jsonPath {
                                Text(jsonPath.components.map(describe).joined(separator: "."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let line = reference.line {
                                Text(locale == .chinese ? "第 \(line) 行" : "Line \(line)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(path.value)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    EditButton { dismiss() } label: { EditText(.close) }
                }
            }
        }
    }

    private func describe(_ component: JSONFieldComponent) -> String {
        switch component {
        case .key(let key): return key
        case .index(let index): return "[\(index)]"
        }
    }
}

/// Fallback detail for files without a structured editor (images, scripts,
/// unknown files). Image editing stays with the host editor: this view only
/// previews bytes and offers replace/export-free actions through the browser.
struct AssetPreviewView: View {
    @ObservedObject var session: GameEditingSession
    let path: GameRelativePath
    @State private var bytes: Data?

    var body: some View {
        Group {
            if let bytes {
                VStack(spacing: 12) {
                    ByteImage(bytes: bytes)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(contentMode: .fit)
                        .padding()
                    Text(byteCount(bytes.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            bytes = try? await session.documentBytes(at: path)
        }
    }

    private func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
