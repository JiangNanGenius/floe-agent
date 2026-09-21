// FloeApp — Archive browsing surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// Reuses the shared archive service (`ArchiveBrowserService` →
// `WorkspaceArchiveTool`) so bounds, traversal/symlink rejection and
// no-overwrite rules are enforced in one place. Zip/TAR/7z are read natively;
// formats that need the environment's Linux runtime report that truthfully
// instead of silently starting a guest. Extraction is bounded and staged into
// a hidden workspace directory that is removed when the browser closes.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeWorkspace

struct ArchiveBrowserView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    /// Disabled when the browser is already hosted inside the IDE tab.
    var showsClose: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var listing: ArchiveBrowseListing?
    @State private var listingError: String?
    @State private var loading = false
    @State private var selection: ArchiveBrowseEntry?
    @State private var previewText: String?
    @State private var previewMessage: String?
    @State private var previewing = false
    @State private var extractedDirectory: String?
    @State private var extractMessage: String?
    @State private var extracting = false
    @State private var confirmingExtract = false
    /// iPhone/compact presentation: the selected entry opens in a sheet
    /// instead of a side-by-side pane.
    @State private var compactPreview: ArchiveBrowseEntry?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var rootURL: URL? {
        center.fileService?.guardResolver.rootURL ?? center.currentRootURL
    }

    var body: some View {
        VStack(spacing: 0) {
            if let extractMessage {
                banner(extractMessage, isError: false)
            }
            if let listingError {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("无法读取压缩包", "Can't Read Archive"), systemImage: "doc.zipper")
                } description: {
                    Text(listingError)
                } actions: {
                    Button(IDELanguageRunText.t("重试", "Retry")) { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else if loading, listing == nil {
                ProgressView(IDELanguageRunText.t("正在读取压缩包…", "Reading archive…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listing {
                if sizeClass == .compact {
                    entryList(listing)
                } else {
                    HStack(spacing: 0) {
                        entryList(listing)
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                        Divider()
                        previewPane
                            .frame(minWidth: 260)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("没有可浏览的内容", "Nothing to Browse"), systemImage: "doc.zipper")
                } description: {
                    Text(IDELanguageRunText.t("选择左侧的文件可预览内容。", "Select a file on the left to preview it."))
                }
            }
        }
        .navigationTitle((relativePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmingExtract = true
                } label: {
                    Label(IDELanguageRunText.t("解压到工作区", "Extract"), systemImage: "square.and.arrow.down")
                }
                .disabled(listing == nil || extracting || !canExtract)
                .accessibilityIdentifier("archive.extract")
            }
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() }
                }
            }
        }
        .confirmationDialog(
            IDELanguageRunText.t("解压到新目录？", "Extract into a new folder?"),
            isPresented: $confirmingExtract,
            titleVisibility: .visible
        ) {
            Button(IDELanguageRunText.t("解压", "Extract")) { Task { await extract() } }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: IDELanguageRunText.t("将创建“%@”，已存在的目录不会被覆盖。", "Creates “%@”; an existing folder is never overwritten."), extractDestination))
        }
        .sheet(item: $compactPreview) { entry in
            NavigationStack {
                previewPane
                    .navigationTitle(entry.path)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(IDELanguageRunText.t("关闭", "Close")) { compactPreview = nil }
                        }
                    }
            }
        }
        .task(id: relativePath) { await cleanUpPreview(); await load() }
        .onDisappear { Task { await cleanUpPreview() } }
    }

    // MARK: - entries

    private var rows: [ArchiveNode] {
        ArchiveNode.tree(from: listing?.entries ?? [])
    }

    @ViewBuilder
    private func entryList(_ listing: ArchiveBrowseListing) -> some View {
        List(selection: Binding(get: { selection?.path }, set: { path in
            selection = listing.entries.first { $0.path == path }
        })) {
            Section {
                if rows.isEmpty {
                    Text(IDELanguageRunText.t("压缩包是空的。", "The archive is empty."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { node in
                        ArchiveNodeRow(node: node, selection: $selection)
                    }
                }
            } header: {
                Text(String(format: IDELanguageRunText.t("条目 %lld", "%lld entries"), Int64(listing.entries.count)))
            } footer: {
                if listing.truncated {
                    Text(IDELanguageRunText.t("条目过多，仅显示前 %lld 项。", "Too many entries; only the first %lld are shown."))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, newValue in
            guard let newValue, !newValue.isDirectory else { return }
            if sizeClass == .compact { compactPreview = newValue }
            Task { await preview(newValue) }
        }
    }

    private var previewPane: some View {
        Group {
            if let selection, !selection.isDirectory {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(selection.path, systemImage: "doc")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Text(ByteCountFormatter.string(fromByteCount: selection.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    if previewing {
                        ProgressView(IDELanguageRunText.t("正在准备预览…", "Preparing preview…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let previewText {
                        ScrollView {
                            Text(previewText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                    } else {
                        ContentUnavailableView {
                            Label(IDELanguageRunText.t("无法预览该文件", "Preview Unavailable"), systemImage: "doc.questionmark")
                        } description: {
                            Text(previewMessage ?? IDELanguageRunText.t("该文件不是可预览的文本。", "This file is not previewable text."))
                        }
                    }
                }
                .padding(12)
            } else {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("选择一个文件", "Select a File"), systemImage: "sidebar.left")
                } description: {
                    Text(IDELanguageRunText.t("文件内容在解压后按需读取，不会修改压缩包。", "File content is read on demand after a bounded extraction; the archive itself is never modified."))
                }
            }
        }
    }

    // MARK: - actions

    private var canExtract: Bool {
        guard let format = listing?.format else { return false }
        return ArchiveBrowserService.nativeFormats.contains(format)
    }

    private var extractDestination: String {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(name.isEmpty ? "archive" : name)-unpacked"
    }

    private func load() async {
        guard let rootURL else {
            listingError = IDELanguageRunText.t("当前工作区不可用。", "The workspace is unavailable.")
            return
        }
        loading = true
        defer { loading = false }
        let service = ArchiveBrowserService(rootProvider: { rootURL })
        do {
            listing = try await service.listing(
                relativePath: relativePath,
                rootURL: rootURL,
                cancellation: CancellationToken()
            )
            listingError = nil
        } catch {
            listing = nil
            listingError = error.localizedDescription
        }
    }

    /// Extracts once into a hidden preview directory and reads the selected
    /// entry lazily. Nothing is extracted for directory selections, and the
    /// preview directory is removed when this surface goes away.
    private func preview(_ entry: ArchiveBrowseEntry) async {
        guard let rootURL else { return }
        previewing = true
        previewText = nil
        previewMessage = nil
        defer { previewing = false }
        do {
            let directory = try await ensureExtracted(rootURL: rootURL)
            guard let url = safeChild(of: directory, child: entry.path, rootURL: rootURL) else {
                previewMessage = IDELanguageRunText.t("该条目不在解压目录内。", "This entry is outside the extracted folder.")
                return
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                previewMessage = IDELanguageRunText.t("该条目不是普通文件。", "This entry is not a regular file.")
                return
            }
            let size = values.fileSize ?? 0
            guard size <= 1_024 * 1_024 else {
                previewMessage = String(format: IDELanguageRunText.t("文件较大（%@），请解压到工作区后查看。", "The file is large (%@); extract it to the workspace to view it."),
                                        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                return
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                previewMessage = IDELanguageRunText.t("这不是 UTF-8 文本文件，无法内联预览。", "This is not a UTF-8 text file, so it can't be previewed inline.")
                return
            }
            let bound = 256 * 1_024
            previewText = text.count > bound
                ? String(text.prefix(bound)) + "\n…\n" + IDELanguageRunText.t("（内容过长，已截断）", "(truncated)")
                : text
        } catch {
            previewMessage = error.localizedDescription
        }
    }

    /// Reuses one extraction for the whole browser session.
    private func ensureExtracted(rootURL: URL) async throws -> String {
        if let extractedDirectory { return extractedDirectory }
        let directory = ".floe-archive-preview/\(UUID().uuidString)"
        let service = ArchiveBrowserService(rootProvider: { rootURL })
        _ = try await service.extract(
            relativePath: relativePath,
            destinationDir: directory,
            rootURL: rootURL,
            cancellation: CancellationToken()
        )
        extractedDirectory = directory
        return directory
    }

    private func extract() async {
        guard let rootURL else { return }
        extracting = true
        defer { extracting = false }
        let service = ArchiveBrowserService(rootProvider: { rootURL })
        do {
            _ = try await service.extract(
                relativePath: relativePath,
                destinationDir: extractDestination,
                rootURL: rootURL,
                cancellation: CancellationToken()
            )
            extractMessage = String(format: IDELanguageRunText.t("已解压到“%@”。", "Extracted to “%@”."), extractDestination)
        } catch {
            extractMessage = error.localizedDescription
        }
    }

    private func cleanUpPreview() async {
        guard let extractedDirectory, let rootURL else { return }
        let url = rootURL.appendingPathComponent(extractedDirectory, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        self.extractedDirectory = nil
    }

    /// The extracted path must stay inside the preview directory, even though
    /// the archive service already rejected traversal entries.
    private func safeChild(of directory: String, child: String, rootURL: URL) -> URL? {
        let base = rootURL.appendingPathComponent(directory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(child).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }

    private func banner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).font(.caption)
            Spacer(minLength: 0)
            Button {
                extractMessage = nil
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel(IDELanguageRunText.t("关闭提示", "Dismiss"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

/// One archive row with its directory children, sorted directories first.
struct ArchiveNode: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    var children: [ArchiveNode]?

    var id: String { path }

    private final class Builder {
        let name: String
        let path: String
        var isDirectory = true
        var size: Int64 = 0
        var children: [String: Builder] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func node() -> ArchiveNode {
            let ordered = children.values
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                .map { $0.node() }
            return ArchiveNode(
                name: name,
                path: path,
                isDirectory: isDirectory,
                size: size,
                children: ordered.isEmpty ? nil : ordered
            )
        }
    }

    static func tree(from entries: [ArchiveBrowseEntry]) -> [ArchiveNode] {
        let root = Builder(name: "", path: "")
        for entry in entries {
            let parts = entry.path
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { continue }
            var cursor = root
            for (index, part) in parts.enumerated() {
                let isLeaf = index == parts.count - 1
                let childPath = cursor.path.isEmpty ? part : cursor.path + "/" + part
                let child = cursor.children[part] ?? Builder(name: part, path: childPath)
                if isLeaf {
                    child.isDirectory = entry.isDirectory
                    child.size = entry.size
                }
                cursor.children[part] = child
                cursor = child
            }
        }
        return root.node().children ?? []
    }
}

private struct ArchiveNodeRow: View {
    let node: ArchiveNode
    @Binding var selection: ArchiveBrowseEntry?

    var body: some View {
        if let children = node.children, node.isDirectory {
            DisclosureGroup {
                ForEach(children) { child in
                    ArchiveNodeRow(node: child, selection: $selection)
                }
            } label: {
                rowLabel
            }
        } else {
            rowLabel
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !node.isDirectory else { return }
                    selection = ArchiveBrowseEntry(path: node.path, isDirectory: false, size: node.size)
                }
                .tag(node.path)
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(node.isDirectory ? FloeTheme.primary : Color.secondary)
                .frame(width: 20)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 0)
            if !node.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }
}
#endif
