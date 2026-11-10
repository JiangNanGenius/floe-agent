// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

nonisolated struct PersonalFileActionRequest: Identifiable {
    let record: PersonalContentRecord
    let action: PersonalFileAction
    var id: String { record.id.uuidString + ":" + action.rawValue }
}

/// Selects an organizational destination through the existing personal library.
/// Draft creation stays in its presenting sheet until this choice is accepted.
struct PersonalLibraryFolderPicker: View {
    let initialFolders: [String]
    let onSelected: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String]
    @State private var children: [String] = []
    @State private var loading = false
    @State private var valid = false
    @State private var creating = false
    @State private var showsNewFolder = false
    @State private var folderName = ""
    @State private var diagnostic: String?
    @State private var generation = UUID()

    init(initialFolders: [String], onSelected: @escaping ([String]) -> Void) {
        self.initialFolders = initialFolders
        self.onSelected = onSelected
        _folders = State(initialValue: initialFolders)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(IDELanguageRunText.t("当前位置", "Current folder"),
                        value: ([IDELanguageRunText.t("我的文件", "My files")] + folders).joined(separator: " / "))
                    if !folders.isEmpty {
                        Button(IDELanguageRunText.t("上一级", "Parent folder"), systemImage: "arrow.up") {
                            folders.removeLast(); Task { await load() }
                        }.disabled(loading || creating)
                        .accessibilityIdentifier("space.creation.folder.parent")
                    }
                    ForEach(children, id: \.self) { child in
                        Button {
                            folders.append(child); Task { await load() }
                        } label: {
                            HStack {
                                Label(child, systemImage: "folder")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }.disabled(loading || creating)
                    }
                    if loading || creating { ProgressView() }
                    Button(IDELanguageRunText.t("新建文件夹", "New folder"), systemImage: "folder.badge.plus") {
                        folderName = ""; showsNewFolder = true
                    }
                    .disabled(loading || creating || !valid)
                    .accessibilityIdentifier("space.creation.folder.new")
                }
                if let diagnostic {
                    Section { Text(diagnostic).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(IDELanguageRunText.t("选择位置", "Choose location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("使用此位置", "Use this folder")) {
                        onSelected(folders); dismiss()
                    }
                    .disabled(loading || creating || !valid)
                    .accessibilityIdentifier("space.creation.folder.use")
                }
            }
            .alert(IDELanguageRunText.t("新建文件夹", "New folder"), isPresented: $showsNewFolder) {
                TextField(IDELanguageRunText.t("名称", "Name"), text: $folderName)
                Button(IDELanguageRunText.t("创建", "Create")) { Task { await createFolder() } }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(creating)
        .task { await load() }
    }

    @MainActor private func load() async {
        let path = folders, ticket = UUID()
        generation = ticket; loading = true; valid = false; children = []
        do {
            let values = try await PersonalContentService.shared.library().folders(in: path)
            guard generation == ticket, folders == path else { return }
            children = values; valid = true; diagnostic = nil
        } catch {
            if generation == ticket { diagnostic = error.localizedDescription }
        }
        if generation == ticket { loading = false }
    }

    @MainActor private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines), parent = folders
        guard !creating, !loading, valid, !name.isEmpty else { return }
        if children.contains(name) {
            diagnostic = IDELanguageRunText.t("已有同名文件夹，请换个名称。", "A folder with that name exists. Choose another name.")
            return
        }
        creating = true
        defer { creating = false }
        do {
            try await PersonalContentService.shared.library().createFolder(name, in: parent)
            folders = parent + [name]
            await load()
        } catch { diagnostic = error.localizedDescription }
    }
}

struct PersonalLibraryActionSheet: View {
    let request: PersonalFileActionRequest
    var onFinished: (PersonalContentRecord) -> Void
    var onOpenEditor: (PersonalContentRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var children: [String] = []
    @State private var title = ""
    @State private var busy = false
    @State private var diagnostic: String?
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var loadingFolders = false
    @State private var folderValid = false
    @State private var folderGeneration = UUID()

    private var supported: Bool { PersonalLibraryFileActions.supports(request.action, kind: request.record.kind) }
    private var actionTitle: String {
        switch request.action {
        case .move: IDELanguageRunText.t("移动", "Move")
        case .duplicate: IDELanguageRunText.t("复制", "Duplicate")
        case .share: IDELanguageRunText.t("分享", "Share")
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if !supported {
                    Section {
                        Text(PersonalLibraryFileActions.limitation(request.action, kind: request.record.kind))
                            .foregroundStyle(.secondary)
                        Button(IDELanguageRunText.t("打开编辑器", "Open editor"), systemImage: "square.and.pencil") {
                            onOpenEditor(request.record)
                        }
                    }
                } else {
                    if request.action == .duplicate {
                        Section { TextField(IDELanguageRunText.t("名称", "Name"), text: $title).disabled(busy) }
                    }
                    Section {
                        Button(IDELanguageRunText.t("我的文件", "My files"), systemImage: "folder") {
                            folders = []; Task { await loadFolders() }
                        }.disabled(busy || loadingFolders || folders.isEmpty)
                        if !folders.isEmpty {
                            LabeledContent(IDELanguageRunText.t("当前位置", "Current folder"), value: folders.joined(separator: " / "))
                            Button(IDELanguageRunText.t("上一级", "Parent folder"), systemImage: "arrow.up") {
                                folders.removeLast(); Task { await loadFolders() }
                            }.disabled(busy || loadingFolders)
                        }
                        ForEach(children, id: \.self) { name in
                            Button {
                                folders.append(name); Task { await loadFolders() }
                            } label: {
                                HStack { Label(name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }.disabled(busy || loadingFolders)
                        }
                        Button(IDELanguageRunText.t("新建文件夹", "New folder"), systemImage: "folder.badge.plus") {
                            folderName = ""; creatingFolder = true
                        }.disabled(busy || loadingFolders || !folderValid)
                        if loadingFolders { ProgressView() }
                    } header: { Text(IDELanguageRunText.t("选择文件夹", "Choose folder")) }
                    if request.record.kind == .printing, request.action == .duplicate {
                        Section { Text(IDELanguageRunText.t("复制已保存的盘、模型和设置。打印文件可在新工程中重新生成。", "Copy saved plates, models and settings. Generate print files again in the new project.")).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button { perform() } label: {
                            HStack {
                                Text(request.action == .move ? IDELanguageRunText.t("移动到这里", "Move here") : IDELanguageRunText.t("复制到这里", "Duplicate here"))
                                Spacer(); if busy { ProgressView() }
                            }
                        }.disabled(busy || loadingFolders || !folderValid || (request.action == .move && folders == request.record.folders)
                            || (request.action == .duplicate && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            .accessibilityIdentifier("space.files.commitAction")
                    }
                }
                if let diagnostic { Section { Text(diagnostic).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(actionTitle + " · " + request.record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }.disabled(busy)
                }
            }
            .alert(IDELanguageRunText.t("新建文件夹", "New folder"), isPresented: $creatingFolder) {
                TextField(IDELanguageRunText.t("名称", "Name"), text: $folderName)
                Button(IDELanguageRunText.t("创建", "Create")) { Task { await createFolder() } }
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(busy)
        .task(id: request.id) {
            folders = request.record.folders
            title = String(request.record.title.prefix(50)) + IDELanguageRunText.t(" 副本", " copy")
            if supported { await loadFolders() }
        }
    }
    @MainActor private func loadFolders() async {
        let target = folders, ticket = UUID()
        folderGeneration = ticket; loadingFolders = true; folderValid = false; children = []
        do {
            let values = try await PersonalContentService.shared.library().folders(in: target)
            guard folderGeneration == ticket, folders == target else { return }
            children = values; diagnostic = nil; folderValid = true
        } catch {
            if folderGeneration == ticket { diagnostic = error.localizedDescription }
        }
        if folderGeneration == ticket { loadingFolders = false }
    }
    @MainActor private func createFolder() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await PersonalContentService.shared.library().createFolder(folderName, in: folders); await loadFolders() }
        catch { diagnostic = error.localizedDescription }
    }
    @MainActor private func perform() {
        guard !busy, !loadingFolders, folderValid else { return }; busy = true; diagnostic = nil
        let target = folders, name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { busy = false }
            do {
                let value: PersonalContentRecord
                switch request.action {
                case .move: value = try await PersonalLibraryFileActions.move(request.record, to: target)
                case .duplicate: value = try await PersonalLibraryFileActions.duplicate(request.record, title: name, to: target)
                case .share: throw PersonalFileActionError.unsupported
                }
                onFinished(value)
            } catch { diagnostic = error.localizedDescription }
        }
    }
}

struct PersonalLibraryShareSheet: UIViewControllerRepresentable {
    let artifact: PersonalShareArtifact
    var onFinished: @MainActor @Sendable () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [artifact.url], applicationActivities: nil)
        let completed = onFinished
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completed() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
