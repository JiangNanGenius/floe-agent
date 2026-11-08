// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import Observation
import FloeFontKit
import FloeHeavyEditorSupport

enum FontDesignText {
    static func t(_ chinese: String, _ english: String) -> String { EditorText.t(chinese, english) }
}

/// Retains opening, saving, compilation and installation independently of the
/// Settings view. Each manager window owns its own controllers and presenter;
/// only the authoritative on-disk library and DeviceFontStore are shared.
@MainActor @Observable final class FontDesignCoordinator {
    private(set) var projects: [FontDesignProject] = []
    private(set) var isOpening = false
    var presented: FontDesignSession?
    var errorMessage: String?
    private(set) var installedMessage: String?
    @ObservationIgnored private let library = FontDesignLibrary.shared
    @ObservationIgnored private var sessions: [UUID: FontDesignSession] = [:]
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    init() {}

    func reload() async {
        do { projects = try await library.list() }
        catch { errorMessage = error.localizedDescription }
    }
    func newProject(store: DeviceFontStore) { begin(store: store) { try await self.library.create() } }
    func edit(_ record: ManagedFontRecord, store: DeviceFontStore) {
        begin(store: store) {
            let projects = try await self.library.list()
            if let existing = projects.first(where: { $0.sourceID == record.id }) { return existing }
            let source = try await store.editableSource(id: record.id)
            return try await self.library.create(source: source)
        }
    }
    func open(_ project: FontDesignProject, store: DeviceFontStore) {
        begin(store: store) { try await self.library.project(project.id) }
    }
    private func begin(store: DeviceFontStore, resolve: @escaping @MainActor () async throws -> FontDesignProject) {
        guard openingTask == nil else { return }
        isOpening = true; errorMessage = nil
        openingTask = Task { @MainActor [self] in
            defer { isOpening = false; openingTask = nil }
            do {
                let project = try await resolve()
                if let existing = sessions[project.id] {
                    if !existing.isBusy { try await existing.controller.reload() }
                    presented = existing
                } else {
                    let id = project.id, directory = try await library.directory(for: id)
                    let scope = FontDesignAccessSession(designID: id, library: library)
                    let hooks = HeavyEditorHostHooks(
                        authorize: { request in try await scope.authorize(request) },
                        // Document.json is the library's authoritative title /
                        // revision index; list() reads that same durable store.
                        didSave: { _ in },
                        export: { documentID, artifact in try await scope.export(documentID: documentID, artifact: artifact) })
                    let controller = try await FontWorkbench.open(directory: directory, documentID: id, owner: .fontLibrary(id), hooks: hooks)
                    try await controller.waitUntilReady()
                    if let input = try await library.sourceForImport(id) {
                        let original = controller.document.content.fontDesignData["original"]["base64"].string.flatMap { Data(base64Encoded: $0) }
                        // Recover a process exit between the successful source
                        // import commit and the small host metadata update.
                        if original.map(FontDesignLibrary.digest) != FontDesignLibrary.digest(input.data) {
                            try await controller.importFile(name: input.name, data: input.data)
                        }
                        try await library.markSourceImported(id)
                    }
                    let installed = await store.list()
                    let family = controller.presentation["info"]["familyName"].string ?? project.title
                    let session = FontDesignSession(projectID: id, controller: controller, library: library, store: store,
                        installFamily: Self.suggestedFamily(family, installed: installed),
                        onClose: { [weak self] id in
                            guard let self else { return }
                            if self.presented?.id == id {
                                if let installed = self.sessions[id]?.installedRecord { self.installedMessage = FontDesignText.t("已安装：", "Installed: ") + installed.displayName }
                                self.presented = nil
                            }
                            self.sessions[id] = nil
                            Task { @MainActor [weak self] in await self?.reload() }
                        })
                    sessions[id] = session; presented = session
                }
                await reload()
            } catch { errorMessage = error.localizedDescription; await reload() }
        }
    }
    private static func suggestedFamily(_ base: String, installed: [ManagedFontRecord]) -> String {
        // A distinct ASCII family also yields a distinct generated PostScript
        // identity when the source has only localized family/style names.
        let latin = base.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripCombiningMarks, reverse: false) ?? base
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
        let ascii = String(latin.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String((ascii.isEmpty ? "Floe Typeface" : ascii).prefix(70)) + " Edited"
        let names = installed.flatMap(\.familyNames)
        var candidate = stem, index = 2
        while names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { candidate = stem + " " + String(index); index += 1 }
        return candidate
    }
}

enum FontDesignInstallFormat: String, CaseIterable, Identifiable, Hashable {
    case ttf, otf
    var id: String { rawValue }
    var title: String { self == .ttf ? "TTF" : FontDesignText.t("OTF（静态）", "OTF (static)") }
}

@MainActor @Observable final class FontDesignSession: Identifiable {
    let id: UUID
    let controller: HeavyEditorController
    var installFamily: String
    var format: FontDesignInstallFormat = .ttf
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var outputs: [FontDesignShareItem] = []
    private(set) var installedRecord: ManagedFontRecord?
    var errorMessage: String?
    var assistantRoute: FontDesignAssistantRoute?
    @ObservationIgnored private let library: FontDesignLibrary
    @ObservationIgnored private let store: DeviceFontStore
    @ObservationIgnored private let onClose: @MainActor (UUID) -> Void
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(projectID: UUID, controller: HeavyEditorController, library: FontDesignLibrary, store: DeviceFontStore,
         installFamily: String, onClose: @escaping @MainActor (UUID) -> Void) {
        id = projectID; self.controller = controller; self.library = library; self.store = store
        self.installFamily = installFamily; self.onClose = onClose
    }
    func refreshOriginal() {
        guard operation == nil, !controller.isWorking else { return }
        isBusy = true; status = FontDesignText.t("正在刷新…", "Refreshing…")
        operation = Task { @MainActor [self] in
            defer { operation = nil; isBusy = false; status = nil }
            do { try await controller.reload(); await reloadOutputs() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func openAssistant(host: FontDesignAIHost) {
        guard operation == nil else { return }
        isBusy = true; status = FontDesignText.t("正在打开助手…", "Opening assistant…")
        operation = Task { @MainActor [self] in
            defer { operation = nil; isBusy = false; status = nil }
            do { assistantRoute = .init(id: try await host.assistant(for: id)) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func close() {
        guard operation == nil else { return }
        isBusy = true; status = FontDesignText.t("正在保存…", "Saving…")
        operation = Task { @MainActor [self] in
            defer { isBusy = false; operation = nil }
            do {
                try await controller.save()
                await controller.endPresentation()
                onClose(id)
            } catch is CancellationError { status = FontDesignText.t("已取消", "Cancelled") }
              catch { errorMessage = error.localizedDescription; status = nil }
        }
    }
    func compileAndInstall() {
        guard operation == nil, controller.isReady, !controller.isWorking else { return }
        let family = installFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, family.count <= 100 else {
            errorMessage = FontDesignText.t("请输入不超过 100 字的字体名称。", "Enter a font family name of up to 100 characters."); return
        }
        let chosen = format
        isBusy = true; errorMessage = nil; installedRecord = nil; status = FontDesignText.t("正在编译编辑版本…", "Compiling the edited version…")
        operation = Task { @MainActor [self] in
            defer { isBusy = false; operation = nil }
            do {
                // The shared queue/CAS path remains authoritative for every
                // source edit. Only the requested family changes here.
                let units = controller.presentation["info"]["unitsPerEm"].number ?? 1000
                _ = try await controller.execute("font.info", arguments: .object(["familyName": .string(family), "unitsPerEm": .number(units)]))
                let revision = controller.document.revision
                let axes = controller.document.content.fontDesignData["axes"].array
                let preview = controller.presentation["ui"]["previewLocation"]
                let location = axes.compactMap { axis -> String? in
                    guard let tag = axis["tag"].string, let initial = axis["default"].number else { return nil }
                    let value = min(axis["max"].number ?? initial, max(axis["min"].number ?? initial, preview[tag].number ?? initial))
                    return tag + "=" + String(value)
                }.joined(separator: ",")
                let response = try await controller.execute("file.export", arguments: .object([
                    "format": .string(chosen.rawValue), "instance": .bool(chosen == .otf && !axes.isEmpty), "location": .string(location)
                ]), expectedRevision: revision)
                try Task.checkCancellation()
                guard let receipt = response["exports"].array.first, let fileID = receipt["fileID"].string else { throw FontDesignError.invalidOutput }
                let item = try await library.compiledOutput(designID: id, fileID: fileID, sourceRevision: revision, format: chosen.rawValue)
                guard item.output.receipt.sha256 == receipt["sha256"].string, item.output.receipt.byteCount == Int(receipt["byteCount"].number ?? -1),
                      controller.document.revision == revision else { throw HeavyEditorError.revisionConflict }
                try await library.requireRevision(designID: id, revision: revision)
                try Task.checkCancellation()
                status = FontDesignText.t("正在安装编辑版本…", "Installing the edited version…")
                let result = try await store.importDesignedFont(from: item.url)
                // Read the real managed store back before showing success.
                let registered = await store.list()
                guard let installed = registered.first(where: { $0.id == result.id }),
                      installed.id == item.output.receipt.sha256,
                      installed.byteCount == Int64(item.output.receipt.byteCount) else { throw FontDesignError.invalidOutput }
                installedRecord = installed
                StorageDiagnosticService.shared.invalidate(.other("fontStore"))
                try await library.recordInstallation(item, installed: installed)
                outputs = try await library.outputs(id)
                status = FontDesignText.t("已安装：", "Installed: ") + installed.displayName
            } catch is CancellationError {
                status = FontDesignText.t("已取消；草稿和原件已保留。", "Cancelled. The draft and original have been retained.")
                await reloadOutputs()
            } catch {
                // No old font is removed, even if compilation, registration or
                // saving the installation receipt fails. A real installedRecord
                // remains visible if registration succeeded before a disk error.
                errorMessage = error.localizedDescription
                status = installedRecord.map { FontDesignText.t("已安装：", "Installed: ") + $0.displayName }
                await reloadOutputs()
            }
        }
    }
    func cancel() { operation?.cancel(); controller.cancel() }
    func reloadOutputs() async {
        do { outputs = try await library.outputs(id) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct FontDesignEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Bindable var session: FontDesignSession
    @State private var showsOutputs = false
    var body: some View {
        VStack(spacing: 0) {
            FontEditorView(controller: session.controller, onClose: { session.close() }).disabled(session.isBusy)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { familyField; formatPicker; installButton; refreshButton; outputButton }
                    VStack(alignment: .leading) { familyField; HStack { formatPicker; installButton; refreshButton; Spacer(); outputButton } }
                }
                HStack {
                    if session.isBusy { ProgressView().controlSize(.small) }
                    Text(session.status ?? FontDesignText.t("安装为独立字体；输入原件和原字体均保留。", "Install as a separate font. The source and original font are retained."))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if session.isBusy { Button(FontDesignText.t("取消", "Cancel")) { session.cancel() } }
                }
            }.padding(12).background(.bar)
        }.interactiveDismissDisabled()
            .onAppear {
                session.controller.onAssistant = { [weak session = session, weak host = environment.fontDesignAIHost] in
                    guard let session, let host else { return }; session.openAssistant(host: host)
                }
            }
            .sheet(item: $session.assistantRoute, onDismiss: { session.refreshOriginal() }) { route in FontDesignAssistantView(conversationID: route.id) }
            .sheet(isPresented: $showsOutputs) {
                NavigationStack {
                    List {
                        if session.outputs.isEmpty { ContentUnavailableView(FontDesignText.t("尚无导出文件", "No exported files yet"), systemImage: "square.and.arrow.up") }
                        ForEach(session.outputs) { item in
                            ShareLink(item: item.url) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.output.receipt.name)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.output.receipt.byteCount), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.navigationTitle(FontDesignText.t("导出文件", "Exported files"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(FontDesignText.t("完成", "Done")) { showsOutputs = false } } }
                }.task { await session.reloadOutputs() }
            }
            .alert(FontDesignText.t("无法完成操作", "Unable to complete action"), isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button(FontDesignText.t("好", "OK")) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
    }
    private var familyField: some View {
        TextField(FontDesignText.t("安装名称", "Install family name"), text: $session.installFamily).textFieldStyle(.roundedBorder)
            .frame(minWidth: 150, maxWidth: 360).disabled(session.isBusy).accessibilityIdentifier("fontDesign.installName")
    }
    private var formatPicker: some View {
        Picker(FontDesignText.t("格式", "Format"), selection: $session.format) {
            ForEach(FontDesignInstallFormat.allCases) { format in Text(format.title).tag(format) }
        }.pickerStyle(.menu).disabled(session.isBusy)
    }
    private var installButton: some View {
        Button(FontDesignText.t("编译并安装编辑版本", "Compile & install edited version")) { session.compileAndInstall() }
            .buttonStyle(.borderedProminent).disabled(session.isBusy || session.controller.isWorking || !session.controller.isReady)
            .accessibilityIdentifier("fontDesign.compileInstall")
    }
    private var refreshButton: some View {
        Button { session.refreshOriginal() } label: { Image(systemName: "arrow.clockwise") }
            .disabled(session.isBusy || session.controller.isWorking)
            .accessibilityLabel(FontDesignText.t("刷新字体草稿", "Refresh typeface draft"))
    }
    private var outputButton: some View {
        Button { showsOutputs = true } label: { Image(systemName: "square.and.arrow.up") }
            .disabled(session.isBusy || session.controller.isWorking).accessibilityLabel(FontDesignText.t("导出文件", "Exported files"))
    }
}
#endif
