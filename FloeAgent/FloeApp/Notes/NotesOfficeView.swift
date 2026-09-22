// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeDocuments
import FloeNotes
import FloeCore

/// Office owns its native working-copy lifecycle. Notes only promotes a successfully saved
/// copy into a new immutable resource revision; the original resource is never modified.
struct NotesOfficeView: View {
    let session: NotesSession
    let document: NoteDocument
    var onAssistant: () -> Void
    var onLinkedMaps: () -> Void
    @StateObject private var office = OfficeFileSession()
    @State private var draftURL: URL?
    @State private var baseRevision: Int?
    @State private var baseResourceID: UUID?
    @State private var pendingCommit = false
    @State private var committing = false
    @State private var message: String?
    @State private var recoveryURL: URL?
    @State private var recoveries: [Recovery] = []
    @State private var showingRecoveries = false
    @State private var keepingCopy = false
    @State private var isVisible = false
    /// Latch so only the first completed open of this mounted document counts.
    @State private var openCounted = false
    @State private var externalRefreshTask: Task<Void, Never>?
    @State private var externalUpdateAvailable = false
    @State private var pendingExternalResource: UUID?
    @State private var externalRefreshRunning = false
    /// True when the last staged-open attempt failed before the engine ever
    /// mounted. The Notes bar then offers an explicit retry instead of leaving
    /// the surface on an unowned "opening" spinner.
    @State private var canRetryOpen = false
    private struct Recovery: Identifiable, Sendable {
        let url: URL
        let date: Date
        var id: URL { url }
    }
    private struct StagedDraft {
        let target: URL
        let recovery: URL
        let resource: UUID
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            // The shared Notes header is hidden for Office editors, so a build
            // without the native engine (or one whose document failed to load)
            // must still expose the same compact Notes navigation: back, tabs
            // and assistant/mind maps. Without it the unavailable placeholder
            // traps the reader with no way back to the library.
            if !OfficeFileSession.available { unavailableHeader }
            if !recoveries.isEmpty {
                Button("发现 \(recoveries.count) 份 Office 恢复副本", systemImage: "clock.arrow.circlepath") { showingRecoveries = true }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.callout)
                    HStack {
                        if canRetryOpen { Button("重试打开") { Task { await prepare(force: true) } }.disabled(committing) }
                        if pendingCommit { Button("重试保存到手记") { Task { if await office.saveInPlace() { await commit() } } }.disabled(committing) }
                        if let recoveryURL { ShareLink("导出恢复副本", item: recoveryURL) }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            }
            if externalUpdateAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("notes.office.externalUpdate.banner", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                        if keepingCopy || externalRefreshRunning { ProgressView().controlSize(.small) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            externalUpdateActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            externalUpdateActions
                        }
                    }
                    .disabled(keepingCopy || externalRefreshRunning || committing)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("notes.office.externalUpdate")
            }
            if !OfficeFileSession.available {
                ContentUnavailableView("Office 编辑器不可用", systemImage: "doc", description: Text("此构建不包含原生 Office 引擎。原文件已保留。"))
            } else {
                OfficeDocumentEditorView(relativePath: document.officeFileName ?? document.title,
                                         session: office,
                                         stableInkIdentity: inkIdentity,
                                         onSaved: {
                    pendingCommit = true
                    await commit()
                    return !pendingCommit
                }, onClose: {
                    // The Office host calls this only after a successful save,
                    // explicit discard, or closing its failed editor. Do not
                    // let SwiftUI dismiss the cover before Notes clears selection.
                    session.removeLeaveGuard(for: document.id)
                    Task { await session.select(nil) }
                }, inlineHeader: AnyView(
                    HStack(spacing: 4) {
                        NotesDocumentTabs(session: session)
                        Menu {
                            Button("Floe 助手", systemImage: "bubble.left.and.bubble.right", action: onAssistant)
                            Button("思维导图", systemImage: "point.3.connected.trianglepath.dotted", action: onLinkedMaps)
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("notes.office.assistantAndMindMaps")
                            .accessibilityIdentifier("notes.office.assistant")
                    }
                ), requestsEditingOnAppear: false)
                // Notes owns the first intent: the remembered mode resolved
                // in `prepare()` decides preview versus editor, so the editor
                // surface must not auto-request editing when it appears.

            }
        }
        .onAppear {
            isVisible = true
            session.registerLeaveGuard(for: document.id) {
                guard !committing else { session.errorMessage = "正在保存 Office 文档，请稍后切换。"; return false }
                if !OfficeFileSession.available { return true }
                if office.phase == .failed, !pendingCommit, !office.hasUncommittedChanges { return true }
                guard office.canAct else { session.errorMessage = "Office 正在打开或保存，请稍后切换。"; return false }
                if !office.readOnly {
                    guard await office.saveInPlace() else {
                        session.errorMessage = office.error ?? "Office 保存未完成，编辑副本已保留。"
                        return false
                    }
                    pendingCommit = true
                }
                if pendingCommit { await commit() }
                if pendingCommit { session.errorMessage = message ?? "未能保存到手记，请重试。"; return false }
                return true
            }
        }
        .task { await prepare() }
        .onChange(of: office.phase) { _, phase in
            // `open()` returns before the engine reports readiness, so the
            // entry is counted here instead: one completed open — preview or
            // editor — makes the next entry of this document default to the
            // editor. A failed open is never counted.
            guard phase == .ready, !openCounted, office.error == nil else { return }
            openCounted = true
            OfficeDocumentModeStore.shared.markOpened(scope: modeScope, document: modeDocument)
        }
        .onChange(of: document.officeResourceID) { _, value in
            guard let value, value != baseResourceID else { return }
            externalResourceChanged(value)
        }
        .sheet(isPresented: $showingRecoveries) {
            NavigationStack {
                List(recoveries) { recovery in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recovery.url.lastPathComponent).font(.headline)
                        Text(recovery.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("恢复为独立文档") {
                                Task {
                                    do {
                                        guard let store = session.store else { return }
                                        var restored = try await NoteFileImporter.importFile(recovery.url, notebookID: document.notebookID, store: store)
                                        restored.title = document.title + " · 恢复副本"
                                        session.importDocument(restored)
                                        showingRecoveries = false
                                    } catch { message = error.localizedDescription }
                                }
                            }
                            ShareLink("导出", item: recovery.url)
                        }
                    }.padding(.vertical, 6)
                }
                .navigationTitle("Office 恢复")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingRecoveries = false } } }
            }
        }
        .onDisappear {
            isVisible = false
            pendingExternalResource = nil
            externalRefreshTask?.cancel()
            session.removeLeaveGuard(for: document.id)
            Task { await office.release() }
        }
    }

    /// Compact Notes-owned navigation for the no-engine branch. It mirrors the
    /// native editor's inline header (tabs plus the assistant/mind-map menu)
    /// and leaves through the same registered session leave guard as the shared
    /// `notes.back` header (`session.select(nil)`); the guard already returns
    /// true immediately when the engine is unavailable, so no working copy is
    /// silently discarded.
    private var unavailableHeader: some View {
        HStack(spacing: 4) {
            Button("notes.navigation.backToNotes", systemImage: "chevron.left") {
                Task { await session.select(nil) }
            }
            .labelStyle(.iconOnly).frame(width: 44, height: 44)
            .accessibilityIdentifier("notes.back")
            NotesDocumentTabs(session: session)
            Spacer(minLength: 0)
            Menu {
                Button("Floe 助手", systemImage: "bubble.left.and.bubble.right", action: onAssistant)
                Button("思维导图", systemImage: "point.3.connected.trianglepath.dotted", action: onLinkedMaps)
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("notes.office.assistantAndMindMaps")
            .accessibilityIdentifier("notes.office.assistant")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
        .buttonStyle(NotesToolbarButtonStyle())
        // Scope the header identifier to its own accessibility container so
        // the back button, tabs and assistant keep their individual identities.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.office.header")
    }

    /// Stable identity for the ink settings and the remembered open mode. The
    /// staged working copy lives in a fresh UUID folder on every open, so the
    /// physical draft path can never key per-source-document state.
    private var modeScope: String { "notes-office-document-\(document.id.uuidString)" }
    private var modeDocument: String { document.officeFileName ?? document.title }
    private var inkIdentity: OfficeInkDocumentIdentity {
        OfficeInkDocumentIdentity(workspaceIdentity: modeScope, relativePath: modeDocument)
    }

    private func prepare(force: Bool = false) async {
        if force {
            canRetryOpen = false
            message = nil
        }
        guard force || draftURL == nil, session.store != nil else {
            // A missing store is a real, terminal failure: never leave the
            // surface on an unowned "opening" spinner.
            if message == nil {
                reportStagingFailure(OfficeInkText.t(
                    "无法读取该手记的文档存储；原文件未被修改。",
                    "This note's document storage is unavailable. Nothing was changed."))
            }
            return
        }
        do {
            // Every early return below is a terminal, user-visible outcome: an
            // unbounded "正在打开文档…" spinner is never an acceptable result of
            // a staging failure.
            guard let latest = await latestOfficeDocument() else {
                reportStagingFailure(OfficeInkText.t(
                    "该手记中的 Office 文档已不存在或缺少资源；原文件未被修改。",
                    "This note's Office document is missing its resource. Nothing was changed."))
                return
            }
            guard let root = try? draftsRoot() else {
                reportStagingFailure(OfficeInkText.t(
                    "无法创建 Office 编辑草稿目录；原文件未被修改。",
                    "The Office draft directory could not be created. Nothing was changed."))
                return
            }
            if let resource = latest.officeResourceID, let store = session.store,
               let source = try? await store.resourceURL(resource) {
                recoveries = (try? await scanRecoveries(documentID: latest.id, source: source, root: root)) ?? []
            }
            guard let staged = try await stageWorkingCopy(latest) else {
                reportStagingFailure(OfficeInkText.t(
                    "无法准备该 Office 文档的编辑副本；原文件未被修改。",
                    "This Office document's editing copy could not be prepared. Nothing was changed."))
                return
            }
            apply(staged)
            // Resolve the entry mode before the open begins: `open()` reports
            // readiness through the engine's async callback, and the
            // completion hook marks the document as opened. Reading the memory
            // first keeps the decision independent of that timing.
            let shouldEdit = session.consumeEditorOnNextOpen(documentID: document.id)
                || OfficeDocumentModeStore.shared.mode(scope: modeScope, document: modeDocument) == .edit
            await office.open(staged.target)
            // First entry of an existing/imported document is a read-only
            // preview; from the second entry onwards it opens directly in the
            // editor, even when the first visit never left the preview. A
            // document created in this app run is an explicit authoring action
            // and goes straight to the editor on its first open. A refused
            // edit entry reports the real reason instead of silently staying
            // preview.
            if shouldEdit { _ = await office.requestEditing() }
            canRetryOpen = false
            if let error = office.error { message = error }
            else if let reason = office.editUnavailableReason { message = reason }
        } catch {
            // A thrown staging/scan error is the same terminal outcome: make it
            // visible and retryable instead of dropping the intent silently.
            reportStagingFailure(error.localizedDescription)
        }
    }

    /// Publishes a staging failure as a visible, retryable state. The engine
    /// never mounted, so the session is failed explicitly (the surface then
    /// shows the error instead of an unowned "opening" spinner) while the
    /// original resource and any retained drafts stay untouched.
    private func reportStagingFailure(_ text: String) {
        message = text
        canRetryOpen = true
        office.reportOpenFailure(NSError(
            domain: "org.floeagent.notes.office.staging",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: text]))
    }

    /// Resolve the freshest persisted revision instead of trusting the value
    /// captured by this SwiftUI view.
    private func latestOfficeDocument() async -> NoteDocument? {
        guard let store = session.store, let latest = try? await store.document(document.id),
              latest.deletedAt == nil, latest.officeResourceID != nil, latest.officeFileName != nil else { return nil }
        return latest
    }

    private func draftsRoot() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/OfficeDrafts/\(document.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stageWorkingCopy(_ latest: NoteDocument) async throws -> StagedDraft? {
        guard let store = session.store, let resource = latest.officeResourceID,
              let fileName = latest.officeFileName, !fileName.isEmpty,
              fileName == (fileName as NSString).lastPathComponent else { return nil }
        let root = try draftsRoot()
        let source = try await store.resourceURL(resource)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: target)
        let metadata: [String: String] = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                                          "revision": String(latest.revision), "fileName": fileName, "sourceHash": source.lastPathComponent]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: folder.appendingPathComponent("recovery.json"), options: .atomic)
        return StagedDraft(target: target, recovery: target, resource: resource, revision: latest.revision)
    }

    private func apply(_ staged: StagedDraft) {
        draftURL = staged.target
        baseRevision = staged.revision
        baseResourceID = staged.resource
        recoveryURL = staged.recovery
    }

    private func scanRecoveries(documentID: UUID, source: URL, root: URL) async throws -> [Recovery] {
        guard let store = session.store else { return [] }
        var sourceHashes: [String: String] = [:]
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let metadataURL = folder.appendingPathComponent("recovery.json")
            guard let data = try? Data(contentsOf: metadataURL), data.count < 16_384,
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let resourceID = fields["resourceID"], let id = UUID(uuidString: resourceID),
                  let original = try? await store.resourceURL(id) else { continue }
            sourceHashes[resourceID] = original.lastPathComponent
        }
        let originalHashes = sourceHashes
        return try await Task.detached(priority: .utility) {
            var result: [Recovery] = []
            let currentHash = try FloeDigest.sha256Hex(ofFileAt: source)
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                try Task.checkCancellation()
                let metadataURL = folder.appendingPathComponent("recovery.json")
                guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                      let metadata = try? Data(contentsOf: metadataURL), metadata.count < 16_384,
                      let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: String],
                      fields["documentID"] == documentID.uuidString,
                      let name = fields["fileName"], name == (name as NSString).lastPathComponent else { continue }
                let file = folder.appendingPathComponent(name)
                guard file.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
                      let hash = try? FloeDigest.sha256Hex(ofFileAt: file), hash != currentHash,
                      hash != (fields["sourceHash"] ?? originalHashes[fields["resourceID"] ?? ""]) else { continue }
                result.append(Recovery(url: file, date: values.contentModificationDate ?? .distantPast))
            }
            return result.sorted { $0.date > $1.date }
        }.value
    }

    // MARK: - External revision changes

    @ViewBuilder private var externalUpdateActions: some View {
        Button("notes.office.externalUpdate.keepCopyAndOpen") {
            Task { await keepCopyAndOpenLatest() }
        }
        .buttonStyle(.borderedProminent)
        Button("notes.office.externalUpdate.continueEditing") { externalUpdateAvailable = false }
            .buttonStyle(.bordered)
    }

    private func externalResourceChanged(_ value: UUID) {
        guard value != baseResourceID else { return }
        pendingExternalResource = value
        startExternalRefreshIfIdle()
    }

    private func startExternalRefreshIfIdle() {
        guard isVisible, !committing, !keepingCopy, !externalRefreshRunning else { return }
        externalRefreshRunning = true
        externalRefreshTask = Task {
            await drainExternalResources()
            externalRefreshRunning = false
            externalRefreshTask = nil
            if pendingExternalResource != nil { startExternalRefreshIfIdle() }
        }
    }

    private func drainExternalResources() async {
        var attempts = 0
        while isVisible, !Task.isCancelled, let value = pendingExternalResource {
            pendingExternalResource = nil
            guard value != baseResourceID else { continue }
            if committing || pendingCommit {
                externalUpdateAvailable = true
                return
            }
            if office.beginExternalRefresh() {
                await applyExternalResource()
                office.endExternalRefresh()
                return
            }
            // The initial open, a save or an attachment insert owns the session.
            // Let it settle instead of closing it from underneath the owner.
            attempts += 1
            if attempts > 20 { externalUpdateAvailable = true; return }
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard isVisible, !Task.isCancelled else { return }
            if pendingExternalResource == nil { pendingExternalResource = value }
        }
    }

    /// Caller holds and releases `office.beginExternalRefresh()` on every path.
    private func applyExternalResource(forceReload: Bool = false) async {
        guard isVisible, !Task.isCancelled, let latest = await latestOfficeDocument(),
              let resource = latest.officeResourceID, resource != baseResourceID else { return }
        if !forceReload {
            // The engine working-copy digest cannot see a save that only wrote
            // back the draft (the explicit-save bridge clears its latch). Compare
            // the draft file itself against the immutable Notes resource captured
            // in `baseResourceID`; this runs even when `office.readOnly` because a
            // read-only preview is not a committed Notes revision.
            if await draftDiffersFromBaseResource() {
                externalUpdateAvailable = true
                return
            }
            // Only the engine's in-memory unsaved-edit probe is read-only gated.
            if !office.readOnly, await office.hasLocalEditsToProtect() {
                externalUpdateAvailable = true
                return
            }
        }
        do {
            guard let staged = try await stageWorkingCopy(latest) else {
                externalUpdateAvailable = true
                return
            }
            guard isVisible, !Task.isCancelled else { return }
            let reopenReadOnly = office.readOnly
            try await office.replaceWithExternalVersion(url: staged.target, readOnly: reopenReadOnly)
            apply(staged)
            pendingCommit = false
            externalUpdateAvailable = false
            message = nil
        } catch {
            message = error.localizedDescription
            externalUpdateAvailable = true
        }
    }

    /// Engine-independent guard for the external-refresh path: the current draft
    /// file must still hash to the immutable Notes resource pointed to by
    /// `baseResourceID`. Missing draft, unresolvable resource or any digest
    /// failure is treated as a local modification so a refresh can never
    /// silently discard a draft that was saved back but never committed.
    private func draftDiffersFromBaseResource() async -> Bool {
        guard let url = draftURL, let baseResourceID, let store = session.store,
              let source = try? await store.resourceURL(baseResourceID) else { return true }
        return await Task.detached(priority: .utility) {
            guard let draftHash = try? FloeDigest.sha256Hex(ofFileAt: url),
                  let sourceHash = try? FloeDigest.sha256Hex(ofFileAt: source) else { return true }
            return draftHash != sourceHash
        }.value
    }

    private func keepCopyAndOpenLatest() async {
        guard isVisible, !keepingCopy, !externalRefreshRunning, !committing,
              let store = session.store, let url = draftURL else { return }
        keepingCopy = true
        defer {
            keepingCopy = false
            if pendingExternalResource != nil { startExternalRefreshIfIdle() }
        }
        // Flush the visible editor into the working copy and draft file first so
        // the independent document actually contains the user's edits.
        guard await office.saveInPlace() else {
            message = office.error ?? String(localized: "notes.office.externalUpdate.keepCopyFailed")
            return
        }
        // No await between the completed flush and freezing input. The copied
        // version must include every edit accepted before this decision.
        guard isVisible, office.beginExternalRefresh() else { return }
        defer { office.endExternalRefresh() }
        do {
            var restored = try await NoteFileImporter.importFile(url, notebookID: document.notebookID, store: store)
            restored.title = document.title + " · " + String(localized: "notes.office.externalUpdate.copySuffix")
            _ = try await store.create(restored)
            try await session.reload()
        } catch {
            message = error.localizedDescription
            return
        }
        externalUpdateAvailable = false
        message = nil
        await applyExternalResource(forceReload: true)
    }

    private func commit() async {
        guard !committing, let url = draftURL, let store = session.store, baseRevision != nil else { return }
        committing = true
        defer {
            committing = false
            if pendingExternalResource == baseResourceID { pendingExternalResource = nil }
            if pendingExternalResource != nil { startExternalRefreshIfIdle() }
        }
        do {
            // OfficeFileSession's save path has already validated its native save receipt and
            // working-copy commit. Re-import never overwrites the former immutable resource.
            let resource = try await store.importResource(from: url, mediaType: "application/octet-stream")
            let current = try await store.document(document.id)
            guard current.officeResourceID == baseResourceID else { throw NoteError.conflict }
            let updated = try await session.commit([.replaceOfficeResource(resource)], documentID: document.id, expectedRevision: current.revision)
            let savedResource = try await store.resourceURL(resource)
            let metadata = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                            "revision": String(updated.revision), "fileName": url.lastPathComponent, "sourceHash": savedResource.lastPathComponent]
            // The content transaction has committed. A metadata failure must not retry an old revision.
            baseRevision = updated.revision; baseResourceID = resource; pendingCommit = false; message = nil
            do {
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: url.deletingLastPathComponent().appendingPathComponent("recovery.json"), options: .atomic)
            } catch { message = "文档已保存，但恢复记录未能更新：\(error.localizedDescription)" }
        } catch {
            message = "未能保存到手记：\(error.localizedDescription) Office 编辑副本已保留，可重试或导出。"
            recoveryURL = url
        }
    }
}
#endif
