// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import FloeMacBridgeProtocol
import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct MacWorkspaceFilesView: View {
    let insertInDraft: (String) -> Void
    var canInsertInDraft: Bool
    @Environment(\.locale) private var locale
    @State private var root: URL?
    @State private var directory: URL?
    @State private var entries: [MacWorkspaceFileEntry] = []
    @State private var selection: URL?
    @State private var filter = ""
    @State private var reloadID = UUID()
    @State private var loading = false
    @State private var limited = false
    @State private var failed = false
    @State private var preview: MacWorkspaceFileEntry?
    @State private var importingText = false
    @State private var showTextImportError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if directory == nil {
                ContentUnavailableView {
                    Label(t("选择文件夹", "Choose a Folder"), systemImage: "folder")
                } description: {
                    Text(t("查看文件，或在其他应用中打开。", "Browse files and open them in other apps."))
                } actions: {
                    Button(t("选择文件夹…", "Choose Folder…"), action: chooseFolder)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                ContentUnavailableView(t("无法读取此文件夹", "Couldn’t Read This Folder"), systemImage: "folder.badge.questionmark")
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: reloadID) { await loadDirectory() }
        .sheet(item: $preview) { entry in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: entry.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button(t("完成", "Done")) { preview = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding()
                Divider()
                MacWorkspaceQuickLook(url: entry.url)
            }
            .frame(minWidth: 460, idealWidth: 680, minHeight: 360, idealHeight: 520)
        }
        .alert(t("无法读取文本", "Couldn’t Read Text"), isPresented: $showTextImportError) {
            Button(t("确定", "OK"), role: .cancel) {}
        } message: {
            Text(t("请选择 32 KB 以内的 UTF-8 文本文件。", "Choose a UTF-8 text file of 32 KB or less."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(directory?.lastPathComponent.nonEmpty ?? t("文件", "Files"), systemImage: "folder")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if directory != nil {
                    Button { goUp() } label: { Image(systemName: "arrow.up") }
                        .help(t("上一级", "Enclosing Folder"))
                        .accessibilityLabel(t("上一级", "Enclosing Folder"))
                        .disabled(directory == root)
                    Button { reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .help(t("刷新", "Refresh"))
                        .accessibilityLabel(t("刷新", "Refresh"))
                    Button(t("更换文件夹…", "Change Folder…"), action: chooseFolder)
                }
            }
            if directory != nil {
                TextField(t("筛选当前文件夹", "Filter This Folder"), text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding()
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            let visible = entries.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) }
            if visible.isEmpty {
                ContentUnavailableView(t("没有匹配的文件", "No Matching Files"), systemImage: "doc")
            } else {
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        Label(entry.name, systemImage: entry.folder ? "folder" : "doc")
                            .lineLimit(1)
                            .tag(entry.url)
                            .contextMenu { actions(for: entry) }
                    }
                }
            }
            Divider()
            HStack {
                if limited {
                    Text(t("仅显示扫描到的前 2,000 项", "Showing the first 2,000 scanned items"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let selected = visible.first(where: { $0.url == selection }) {
                    actions(for: selected)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder private func actions(for entry: MacWorkspaceFileEntry) -> some View {
        if entry.folder || entry.openable {
            Button(t("打开", "Open")) { open(entry) }
        }
        if entry.openable {
            Button(t("快速查看", "Quick Look")) {
                if canAccess(entry) { preview = entry }
            }
            if UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .text) == true {
                Button(t("将文本插入新任务", "Insert Text in New Task")) { quoteText(entry) }
                    .disabled(!canInsertInDraft || importingText)
            }
        }
        Button(t("在 Finder 中显示", "Show in Finder")) {
            if canAccess(entry, allowLink: true) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            root = resolved
            navigate(to: resolved)
        }
    }

    private func navigate(to url: URL) {
        directory = url
        selection = nil
        filter = ""
        entries = []
        reloadID = UUID()
    }

    private func goUp() {
        guard let root, let directory, directory != root else { return }
        navigate(to: directory.deletingLastPathComponent())
    }

    private func open(_ entry: MacWorkspaceFileEntry) {
        guard canAccess(entry) else { return }
        if entry.folder { navigate(to: entry.url) }
        else if entry.openable { NSWorkspace.shared.open(entry.url) }
    }

    private func quoteText(_ entry: MacWorkspaceFileEntry) {
        guard canInsertInDraft, !importingText, let root, canAccess(entry) else { return }
        importingText = true
        Task {
            defer { importingText = false }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try MacWorkspaceFolderSnapshot.readPlainText(entry.url, in: root)
                }.value
                guard self.root == root, canAccess(entry) else { return }
                let name = entry.name.components(separatedBy: .newlines).joined(separator: " ")
                let quote = text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                insertInDraft("\(name)\n\n\(quote)")
            } catch { showTextImportError = true }
        }
    }

    private func canAccess(_ entry: MacWorkspaceFileEntry, allowLink: Bool = false) -> Bool {
        guard let root, let directory, entry.url.deletingLastPathComponent().path == directory.path,
              MacWorkspaceFolderSnapshot.contains(directory, in: root),
              directory.resolvingSymlinksInPath().path == directory.path else { return false }
        if allowLink { return true }
        let freshURL = URL(fileURLWithPath: entry.url.path, isDirectory: entry.folder)
        guard let values = try? freshURL.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey,
                                                                 .isDirectoryKey, .isPackageKey, .isRegularFileKey]),
              values.isAliasFile == false, values.isSymbolicLink == false,
              freshURL.resolvingSymlinksInPath().path == freshURL.path else { return false }
        return entry.folder ? values.isDirectory == true && values.isPackage != true : values.isRegularFile == true
    }

    private func loadDirectory() async {
        guard let root, let directory else { return }
        loading = true
        failed = false
        let worker = Task.detached(priority: .userInitiated) { try MacWorkspaceFolderSnapshot.read(directory, in: root) }
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        guard !Task.isCancelled, self.directory == directory else { return }
        switch result {
        case .success(let snapshot):
            entries = snapshot.entries
            limited = snapshot.limited
        case .failure:
            entries = []
            limited = false
            failed = true
        }
        loading = false
    }

    private func t(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}

private struct MacWorkspaceFileEntry: Identifiable, Sendable {
    let url: URL
    let name: String
    let folder: Bool
    let openable: Bool
    var id: URL { url }
}

private struct MacWorkspaceFolderSnapshot: Sendable {
    let entries: [MacWorkspaceFileEntry]
    let limited: Bool

    static func contains(_ directory: URL, in root: URL) -> Bool {
        directory.pathComponents.starts(with: root.pathComponents)
    }

    static func readPlainText(_ url: URL, in root: URL) throws -> String {
        let limit = 32 * 1024
        guard let rootPath = physicalPath(root.path), let requested = physicalPath(url.path),
              contains(URL(fileURLWithPath: requested), in: URL(fileURLWithPath: rootPath)),
              !BridgeAbsoluteFileRead.isSecretPath(requested) else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              fcntl(descriptor, F_GETPATH, &path) == 0, let openedPath = path.withUnsafeBufferPointer({ buffer in
                  buffer.baseAddress.flatMap { String(validatingCString: $0) }
              }),
              physicalPath(openedPath) == requested else {
            throw CocoaError(.fileReadNoPermission)
        }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= limit, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    static func read(_ directory: URL, in root: URL) throws -> Self {
        guard contains(directory, in: root), directory.resolvingSymlinksInPath().path == directory.path,
              FileManager.default.isReadableFile(atPath: directory.path),
              try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
                                         .isRegularFileKey, .localizedNameKey]
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries: [MacWorkspaceFileEntry] = []
        var limited = false
        for (index, item) in enumerator.enumerated() {
            try Task.checkCancellation()
            guard index < 2_000 else { limited = true; break }
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: keys) else { continue }
            let real = values.isSymbolicLink == false && values.isAliasFile == false
            entries.append(MacWorkspaceFileEntry(url: url, name: values.localizedName ?? url.lastPathComponent,
                                                folder: real && values.isDirectory == true && values.isPackage != true,
                                                openable: real && values.isRegularFile == true))
        }
        if let enumerationError { throw enumerationError }
        entries.sort {
            if $0.folder != $1.folder { return $0.folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Self(entries: entries, limited: limited)
    }
}

private struct MacWorkspaceQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        (container.subviews.first as? QLPreviewView)?.previewItem = url as NSURL
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
