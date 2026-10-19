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
    @State private var previewAttemptedSource: UUID?
    @State private var canRetryPreview = false
    /// Handle for the in-flight read-only cover backfill so a read-only exit
    /// can give it a bounded window to bind the generated preview instead of
    /// abandoning it one step before the library card updates.
    @State private var previewRefreshTask: Task<Void, Never>?
    /// Typed separation for the passive cover backfill. Unlike `committing`
    /// (a real Notes commit/save transaction), the backfill changes no user
    /// data, so it must never freeze the editor's hit testing or refuse
    /// navigation — it only serializes against other cover/store mutations
    /// and marks the window in which a retained read-only close intent must
    /// wait for the FULL preview result. Claimed synchronously at every
    /// spawn site so a tap arriving between the schedule and the task's
    /// first execution still waits instead of seeing a stale idle flag.
    @State private var coverRefreshRunning = false
    /// Narrow host-owned run identity for the cover backfill. `Task` is a
    /// struct, so handle comparison (`===`) is not valid Swift; instead this
    /// counter is bumped synchronously at the spawn site and captured /
    /// re-checked by a parked close through the full settlement: a re-bump
    /// means a new run replaced the captured context (refusal), while
    /// completion without a re-bump is the permit. A close that prepares
    /// the cover itself re-captures this token right after its own
    /// synchronous spawn, so its own bump is never a false self-refusal
    /// while a concurrent replacement still is. A genuinely opening,
    /// failed or unavailable surface keeps the instant ordinary cancel
    /// (no artificial wait, no blocked opening cancel).
    @State private var coverRefreshRunToken = 0
    @State private var coverBackfillReady = false
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
                Button(FloeL10n.l("notes.notes_office_view.found_office_recovery_copies", recoveries.count), systemImage: "clock.arrow.circlepath") { showingRecoveries = true }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.callout)
                    HStack {
                        if canRetryOpen { Button("notes.notes_office_view.retry_opening") { Task { await prepare(force: true) } }.disabled(committing) }
                        if pendingCommit { Button("notes.notes_office_view.retry_saving_to_notes") { Task { if await office.saveInPlace() { await commit() } } }.disabled(committing) }
                        if canRetryPreview { Button("notes.office.preview.retry") { startCoverRefresh() }.disabled(committing || coverRefreshRunning || !office.canAct) }
                        if let recoveryURL { ShareLink("notes.office.externalUpdate.exportCopy", item: recoveryURL) }
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
                    .disabled(keepingCopy || externalRefreshRunning || committing || coverRefreshRunning)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("notes.office.externalUpdate")
            }
            if !OfficeFileSession.available {
                ContentUnavailableView("notes.office.unavailable.title", systemImage: "doc", description: Text("notes.office.unavailable.description"))
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
                    // Fenced dismissal: a host that has already left, or a
                    // session that now selects a different document, must
                    // never have that selection torn down by this old view's
                    // retained close intent.
                    guard isVisible, session.document?.id == document.id else {
                        recordStage("notes.exit.refused.staleClose")
                        return
                    }
                    session.removeLeaveGuard(for: document.id)
                    Task {
                        // Re-fence INSIDE the scheduled task, immediately
                        // before the navigation: whatever selects a new
                        // document (or leaves) after this close is enqueued
                        // cannot be cleared by the old intent.
                        guard !Task.isCancelled, isVisible,
                              session.document?.id == document.id else {
                            recordStage("notes.exit.refused.staleClose")
                            return
                        }
                        await session.select(nil)
                    }
                }, inlineHeader: AnyView(
                    HStack(spacing: 4) {
                        NotesDocumentTabs(session: session)
                        Menu {
                            Button("notes.notes_linked_mind_maps.floe_assistant", systemImage: FloeTheme.assistantSymbol, action: onAssistant)
                            Button("notes.notes_office_view.mind_map", systemImage: "point.3.connected.trianglepath.dotted", action: onLinkedMaps)
                        } label: {
                            Image(systemName: FloeTheme.assistantSymbol)
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("notes.office.assistantAndMindMaps")
                            .accessibilityIdentifier("notes.office.assistant")
                    }
                ), requestsEditingOnAppear: false,
                   prepareForPassiveClose: {
                    await allowCloseAfterCoverCommitted()
                })
                .allowsHitTesting(!committing)
                // Notes owns the first intent: the remembered mode resolved
                // in `prepare()` decides preview versus editor, so the editor
                // surface must not auto-request editing when it appears.

            }
        }
        .onChange(of: office.documentActionsReady) { _, ready in
            if ready { scheduleMissingPreview() }
        }
        .onChange(of: office.coverRenderObserved) { _, observed in
            if observed { scheduleMissingPreview() }
        }
        .onChange(of: baseResourceID) { _, _ in scheduleMissingPreview() }
        .onAppear {
            isVisible = true
            session.registerLeaveGuard(for: document.id) {
                if coverRefreshRunning, !pendingCommit, office.readOnly {
                    // The only in-flight work is the read-only cover backfill
                    // (typed `coverRefreshRunning`, never `committing`).
                    // Refusing the exit here would strand the just-generated
                    // preview one step before it binds to the library card,
                    // so let the backfill settle within the same bounded
                    // window the Back route waits on, then re-check below.
                    // (The Back button route is additionally fenced by
                    // `allowCloseAfterCoverCommitted` before the editor ever
                    // dismisses; this guard remains the second wall for
                    // sidebar/tab navigation.)
                    await settleInFlightPreviewRefresh()
                }
                guard !committing else {
                    recordStage("notes.exit.refused.committing")
                    session.errorMessage = FloeL10n.l("notes.notes_office_view.saving_the_office_document_switch_again")
                    return false
                }
                if coverRefreshRunning, !pendingCommit, office.readOnly {
                    // The bounded settle above elapsed with the backfill
                    // still running: keep the editor mounted, exactly like
                    // the committing refusal, and surface the existing
                    // truthful, retryable preview failure instead of
                    // silently abandoning the cover binding or blocking
                    // navigation unbounded.
                    recordStage("notes.exit.refused.coverRefresh")
                    session.errorMessage = String(localized: "notes.office.preview.failed",
                                                  defaultValue: "The preview could not be updated. Try again.")
                    return false
                }
                if !OfficeFileSession.available {
                    recordStage("notes.exit.engineUnavailable")
                    return true
                }
                if office.phase == .failed, !pendingCommit, !office.hasUncommittedChanges {
                    recordStage("notes.exit.failedNoChanges")
                    return true
                }
                guard office.canAct else {
                    recordStage("notes.exit.refused.operating")
                    session.errorMessage = FloeL10n.l("notes.notes_office_view.office_is_opening_or_saving_switch")
                    return false
                }
                if !office.readOnly {
                    guard await office.saveInPlace() else {
                        recordStage("notes.exit.saveFailed")
                        session.errorMessage = office.error ?? FloeL10n.l("notes.notes_office_view.the_office_save_did_not_finish")
                        return false
                    }
                    pendingCommit = true
                }
                if pendingCommit { await commit() }
                if pendingCommit {
                    recordStage("notes.exit.commitFailed")
                    session.errorMessage = message ?? FloeL10n.l("notes.notes_office_view.could_not_save_to_notes_please")
                    return false
                }
                recordStage("notes.exit.ok")
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
                            Button("notes.notes_office_view.restore_as_a_standalone_document") {
                                Task {
                                    do {
                                        guard let store = session.store else { return }
                                        var restored = try await NoteFileImporter.importFile(recovery.url, notebookID: document.notebookID, store: store)
                                        restored.title = document.title + FloeL10n.l("notes.notes_office_view.recovery_copy")
                                        session.importDocument(restored)
                                        showingRecoveries = false
                                    } catch { message = error.localizedDescription }
                                }
                            }
                            ShareLink("files.export", item: recovery.url)
                        }
                    }.padding(.vertical, 6)
                }
                .navigationTitle("notes.notes_office_view.office_recovery")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("workspace.workspace_canvas_view.done") { showingRecoveries = false } } }
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
                Button("notes.notes_linked_mind_maps.floe_assistant", systemImage: FloeTheme.assistantSymbol, action: onAssistant)
                Button("notes.notes_office_view.mind_map", systemImage: "point.3.connected.trianglepath.dotted", action: onLinkedMaps)
            } label: {
                Image(systemName: FloeTheme.assistantSymbol)
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

    /// Notes bracket stages are recorded under the shared session's
    /// correlation identity, so one durable trace carries the whole chain
    /// (Notes staging -> shared open -> engine stages -> exit interlock).
    private func recordStage(_ stage: String, _ detail: [String: String] = [:]) {
        office.recordOwnerStage(stage, detail)
    }

    private func prepare(force: Bool = false) async {
        if !OfficeFileSession.available {
            recordStage("notes.engine.unavailable", [
                "format": (document.officeFileName as NSString?)?.pathExtension.lowercased() ?? "",
            ])
        }
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
        coverBackfillReady = false
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
            recordStage("notes.staged", [
                "format": (staged.target.pathExtension).lowercased(),
                "revision": String(staged.revision),
            ])
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
            if shouldEdit {
                let entered = await office.requestEditing()
                recordStage("notes.edit.requested", ["entered": entered ? "true" : "false"])
            }
            canRetryOpen = false
            if let error = office.error {
                recordStage("notes.open.failed")
                message = error
            } else if let reason = office.editUnavailableReason {
                recordStage("notes.edit.unavailable")
                message = reason
            } else {
                recordStage("notes.open.ready", ["readOnly": office.readOnly ? "true" : "false"])
            }
            // Never let cover work race the remembered/explicit edit intent.
            coverBackfillReady = !shouldEdit && office.error == nil && office.readOnly
            scheduleMissingPreview()
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
        recordStage("notes.staging.failed")
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
        guard isVisible, !committing, !coverRefreshRunning, !keepingCopy, !externalRefreshRunning else { return }
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
            if committing || coverRefreshRunning || pendingCommit {
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
        guard isVisible, !keepingCopy, !externalRefreshRunning, !committing, !coverRefreshRunning,
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
            recordStage("notes.commit.started")
            let resource = try await store.importResource(from: url, mediaType: "application/octet-stream")
            let current = try await store.document(document.id)
            guard current.officeResourceID == baseResourceID else { throw NoteError.conflict }
            let updated = try await session.commit([.replaceOfficeResource(resource)], documentID: document.id, expectedRevision: current.revision)
            let savedResource = try await store.resourceURL(resource)
            let metadata = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                            "revision": String(updated.revision), "fileName": url.lastPathComponent, "sourceHash": savedResource.lastPathComponent]
            // The content transaction has committed. A metadata failure must not retry an old revision.
            baseRevision = updated.revision; baseResourceID = resource; pendingCommit = false; message = nil
            recordStage("notes.commit.ok", ["revision": String(updated.revision)])
            previewAttemptedSource = resource
            if updated.matchingOfficePreviewResourceID == nil {
                do {
                    try await refreshGeneratedPreview(sourceID: resource, revision: updated.revision)
                    canRetryPreview = false
                } catch {
                    // The content transaction already succeeded. A cache
                    // failure cannot turn it into a stale-revision save retry.
                    canRetryPreview = true
                    message = String(localized: "notes.office.preview.failed",
                                     defaultValue: "The preview could not be updated. Try again.")
                    recordStage("notes.preview.failed", ["domain": (error as NSError).domain,
                                                         "code": String((error as NSError).code)])
                }
            }
            do {
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: url.deletingLastPathComponent().appendingPathComponent("recovery.json"), options: .atomic)
            } catch { message = FloeL10n.l("notes.notes_office_view.the_document_was_saved_but_the", error.localizedDescription) }
        } catch {
            recordStage("notes.commit.failed", ["domain": (error as NSError).domain])
            message = FloeL10n.l("notes.notes_office_view.could_not_save_to_notes_the", error.localizedDescription)
            recoveryURL = url
        }
    }

    /// The single spawn site for the read-only cover backfill. It claims
    /// `coverRefreshRunning` synchronously inside the scheduling turn —
    /// before the task's first step — so a close intent landing between the
    /// schedule and the task's first execution still sees, waits for and
    /// fences the FULL preview result instead of dropping past a flag the
    /// task had not yet raised. `refreshPreviewOnly` owns releasing the
    /// claim on every path, including its early guard exits. The run token
    /// bumps synchronously in the same turn, so a parked close can detect a
    /// replacement of its captured run without comparing Task handles (Task
    /// is a struct; handle identity is not a thing in Swift).
    private func startCoverRefresh() {
        guard !coverRefreshRunning else { return }
        coverRefreshRunToken += 1
        coverRefreshRunning = true
        previewRefreshTask = Task { await refreshPreviewOnly() }
    }

    /// Backfill existing Office notes while their real read-only editor is
    /// already open. Library cards never start an engine. An editable canvas
    /// waits for Save, so background cover work cannot interrupt handwriting.
    /// The export needs the engine's document loaded: for open-only formats
    /// `documentActionsReady` settles at the open, which used to make this
    /// backfill export into a half-loaded document and fail the native
    /// conversion (code 32). `coverRenderObserved` is set only by the host's
    /// fenced visible-render callback for the current open generation (and
    /// preset for hosts without that contract), so the latch below is taken
    /// only once the document can actually be converted.
    private func scheduleMissingPreview() {
        guard coverBackfillReady, isVisible, office.readOnly, office.canAct,
              office.coverRenderObserved, !committing, !coverRefreshRunning,
              !externalRefreshRunning, let source = baseResourceID,
              previewAttemptedSource != source,
              document.matchingOfficePreviewResourceID == nil else { return }
        previewAttemptedSource = source
        startCoverRefresh()
    }

    /// The one shared close-preparation budget. A retained read-only close
    /// that must prepare the cover uses this single deadline across the real
    /// first-paint readiness wait AND the full-preview settle together; the
    /// two phases never stack a fresh window each (no 20 s + 20 s).
    private static let closePreparationBudgetNanoseconds: UInt64 = 20_000_000_000

    /// Gives an in-flight read-only cover backfill a bounded window to finish
    /// before a read-only exit proceeds. Modeled on the session's real
    /// one-shot/deadline pattern (`OfficeSaveReceipt` / `withNativeDeadline`):
    /// the receipt is settled by either the backfill's actual completion or
    /// the deadline, so this returns at the deadline even when the backfill
    /// never finishes — unlike a task group, which would keep waiting for the
    /// slow child. The export already holds the session fence (release defers
    /// to it); on timeout the exit keeps the previous behavior — the card
    /// stays on the content summary and the editor offered the retry action.
    /// The default window is the full shared budget (the leave-guard and
    /// already-running close paths); a prepared close that already spent part
    /// of the same deadline on first-paint readiness passes only the time
    /// left, so first paint plus full preview share one bounded budget.
    private func settleInFlightPreviewRefresh(budgetNanoseconds: UInt64 = 20_000_000_000) async {
        guard let task = previewRefreshTask, !task.isCancelled else { return }
        let receipt = OfficeSaveReceipt()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: budgetNanoseconds)
            receipt.resolve(.failure(NSError(domain: "org.floeagent.notes.office.preview",
                                             code: 3,
                                             userInfo: [NSLocalizedDescriptionKey: "preview-backfill-settle-timeout"])))
        }
        Task { @MainActor in
            await task.value
            receipt.resolve(.success(()))
        }
        do {
            try await receipt.wait()
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
        }
    }

    /// Outcome of the bounded first-paint readiness wait a retained
    /// read-only close performs when the document is already logically
    /// ready but its cover backfill has not been scheduled yet.
    private enum PassiveCoverReadiness {
        /// The host's real visible-render signal arrived for the mounted
        /// document; the cover can be prepared now.
        case renderObserved
        /// A cover run was scheduled while waiting (the paint signal
        /// arrived and the passive scheduler ran); its full result is
        /// consumed instead of starting a second run.
        case existingRunScheduled
        /// A cover run started AND finished entirely between two polls,
        /// committing the exact source+revision native cover. The
        /// committed result is consumed as the prepared outcome instead
        /// of refusing the close for a token that moved without a live
        /// run.
        case existingRunCommitted
        /// The exact context is no longer a prepared-close candidate:
        /// left, navigating away, failed, real work took over, the source
        /// or revision was replaced, or the intent was cancelled.
        case unavailable
        /// The shared close-preparation deadline elapsed without the real
        /// signal ever arriving.
        case timedOut
    }

    /// The settled UI7 rule's entry decision: a live, logically-ready,
    /// read-only document with a known source and revision, no matching
    /// native preview and no cover run started or attempted yet — the
    /// window where the passive scheduler cannot have run only because
    /// the host's visible-render signal has not arrived. Everything else
    /// keeps its prior behavior: a still-opening, failed or unavailable
    /// surface exits through the ordinary instant cancel, an already
    /// running backfill uses the original settle path, a previously
    /// attempted (failed) backfill keeps its existing retry affordance,
    /// and a pre-existing matching cover needs no new work.
    private func passiveCoverPreparationNeeded(source: UUID) -> Bool {
        guard coverBackfillReady, isVisible, session.document?.id == document.id,
              office.readOnly, office.documentActionsReady,
              !committing, !pendingCommit, !keepingCopy, !coverRefreshRunning,
              !externalRefreshRunning, baseRevision != nil,
              previewAttemptedSource != source,
              session.document?.matchingOfficePreviewResourceID == nil else { return false }
        return true
    }

    /// Bounded poll of the host's EXISTING real readiness state. This is
    /// not a fixed readiness delay: every tick re-reads the live session
    /// and host-owned flags, returns the moment genuine readiness (or an
    /// already-scheduled run) arrives, and stops at the shared deadline,
    /// on cancellation, or when the captured context changes. No new
    /// observer API, queue or service is introduced; the only sleep is
    /// between checks and is capped by the time left on the close-
    /// preparation budget.
    private func awaitPassiveCoverRenderReadiness(
        until deadlineUptimeNanoseconds: UInt64,
        capturedRunToken: Int,
        capturedSource: UUID,
        capturedRevision: Int
    ) async -> PassiveCoverReadiness {
        while !Task.isCancelled {
            if coverRefreshRunning {
                // A run was scheduled while waiting; consume it while the
                // intent still owns the exact document context.
                guard isVisible, session.document?.id == document.id,
                      !committing, !pendingCommit, !keepingCopy, !externalRefreshRunning,
                      baseResourceID == capturedSource, baseRevision == capturedRevision else {
                    return .unavailable
                }
                return .existingRunScheduled
            }
            if coverRefreshRunToken != capturedRunToken {
                // A run started AND finished entirely between two readiness
                // polls: `coverRefreshRunning` has already dropped and the
                // token moved. That completed run is consumed ONLY when it
                // was the exact attempt for this captured context and it
                // COMMITTED a matching source+revision cover — the store's
                // `cacheOfficePreview` CAS on this revision plus the
                // session reload are its own proof of success, never a
                // fabricated flag. A failed run, a superseded binding,
                // busy real work or a changed document keeps the refusal,
                // so a concurrent replacement can never be accepted as
                // readiness either.
                guard isVisible, session.document?.id == document.id,
                      office.readOnly, office.documentActionsReady,
                      !committing, !pendingCommit, !keepingCopy, !externalRefreshRunning,
                      baseResourceID == capturedSource, baseRevision == capturedRevision,
                      previewAttemptedSource == capturedSource,
                      session.document?.matchingOfficePreviewResourceID != nil else {
                    return .unavailable
                }
                return .existingRunCommitted
            }
            guard isVisible, session.document?.id == document.id,
                  office.readOnly, office.documentActionsReady,
                  !committing, !pendingCommit, !keepingCopy, !externalRefreshRunning,
                  baseResourceID == capturedSource, baseRevision == capturedRevision else { return .unavailable }
            if office.coverRenderObserved { return .renderObserved }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadlineUptimeNanoseconds > now else { return .timedOut }
            do {
                try await Task.sleep(nanoseconds: min(100_000_000, deadlineUptimeNanoseconds - now))
            } catch {
                return .unavailable
            }
        }
        return .unavailable
    }

    /// Host-owned prepare-for-close allowance installed on the read-only
    /// Office editor. A retained Back intent may only continue after the
    /// FULL host preview result has committed — the native export, the PNG
    /// render, `cacheOfficePreview` and the immutable source/revision card
    /// binding — not merely after the export's own fence. Two cases exist.
    /// A backfill ALREADY RUNNING is awaited through the existing bounded,
    /// waiter-local settle (the producer task and its state are untouched).
    /// A ready document whose backfill cannot have been scheduled only
    /// because the real first paint has not arrived yet is PREPARED by
    /// this intent: it waits the actual visible-render readiness, then
    /// synchronously starts (or consumes) the one full cover run and
    /// awaits its committed result, all under the single shared 20 s
    /// close-preparation deadline. A run that both starts and finishes
    /// between two readiness polls is consumed when — and only when — it
    /// committed the exact source+revision matching cover. A close on a
    /// surface that is genuinely still opening, failed, unavailable, or
    /// already covered stays the instant ordinary cancel it was before
    /// (no artificial delay, no new work for a preexisting matching
    /// cover). Permission is granted only for the exact captured
    /// context: the intent's own synchronous run-token bump is captured
    /// as the waited run, while any concurrent replacement refuses. The
    /// prepared path additionally proves the FULL result boundary: it may
    /// only allow once a successful matching native cover binding is
    /// actually committed, so a no-op schedule, a failed export/render/
    /// cache step or a vanished binding never reads as success. A timed-
    /// out, canceled, left or superseded context refuses and keeps the
    /// editor mounted with the existing actionable state, so a vanished
    /// capture can never be mistaken for readiness and a close never
    /// arrives late.
    private func allowCloseAfterCoverCommitted() async -> Bool {
        let capturedRunToken = coverRefreshRunToken
        let capturedSource = baseResourceID
        let capturedRevision = baseRevision
        // The run this intent waits on. It normally equals the captured
        // token; own preparation (or consuming an exact already-scheduled
        // task) re-captures it synchronously right after the start, so the
        // intent's own spawn bump is never falsely read as a replacement,
        // while any later bump is.
        var settledRunToken = capturedRunToken
        // Set only when this intent entered the prepare-the-cover path.
        // The permit then additionally requires the committed matching
        // native cover binding, never just an idle flag/token match. The
        // legacy already-running settle path stays untouched.
        var preparedCloseRequiresCommittedCover = false
        if coverRefreshRunning {
            await settleInFlightPreviewRefresh()
        } else if let source = capturedSource, let revision = capturedRevision,
                  passiveCoverPreparationNeeded(source: source) {
            let deadlineUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                + Self.closePreparationBudgetNanoseconds
            let readiness = await awaitPassiveCoverRenderReadiness(
                until: deadlineUptimeNanoseconds,
                capturedRunToken: capturedRunToken,
                capturedSource: source,
                capturedRevision: revision)
            switch readiness {
            case .renderObserved, .existingRunScheduled, .existingRunCommitted:
                // Synchronous start/claim: `scheduleMissingPreview` starts
                // the run when the real paint just arrived, and is a no-op
                // when the paint's own passive scheduler already started
                // the exact run, or when that run already finished and
                // committed the matching cover between polls (its own
                // observable result is the committed binding, checked at
                // the permit). The run captured here — bumped once by
                // this same MainActor turn or by that existing schedule —
                // is what the settlement then awaits in full, within the
                // time left on the one shared deadline.
                preparedCloseRequiresCommittedCover = true
                scheduleMissingPreview()
                settledRunToken = coverRefreshRunToken
                recordStage("notes.exit.coverPrepare", ["run": String(settledRunToken)])
                if coverRefreshRunning {
                    let now = DispatchTime.now().uptimeNanoseconds
                    await settleInFlightPreviewRefresh(
                        budgetNanoseconds: deadlineUptimeNanoseconds > now
                            ? deadlineUptimeNanoseconds - now : 0)
                }
            case .timedOut:
                // The real signal never arrived within the shared budget.
                // Keep the editor mounted, surface the existing actionable
                // copy only for the still-owned view, and never close late.
                guard !Task.isCancelled, isVisible, session.document?.id == document.id else {
                    recordStage("notes.exit.refused.staleClose")
                    return false
                }
                recordStage("notes.exit.refused.coverPrepare")
                session.errorMessage = String(localized: "notes.office.preview.failed",
                                              defaultValue: "The preview could not be updated. Try again.")
                return false
            case .unavailable:
                recordStage("notes.exit.refused.coverPrepareState")
                return false
            }
        }
        guard !Task.isCancelled, isVisible, session.document?.id == document.id else {
            recordStage("notes.exit.refused.staleClose")
            return false
        }
        if coverRefreshRunning {
            // The bounded settle elapsed while the full task still ran: keep
            // the editor mounted and surface the existing truthful,
            // retryable preview failure instead of consuming the tap.
            recordStage("notes.exit.refused.coverRefresh")
            session.errorMessage = String(localized: "notes.office.preview.failed",
                                          defaultValue: "The preview could not be updated. Try again.")
            return false
        }
        guard !committing, !pendingCommit, !keepingCopy, !externalRefreshRunning,
              coverRefreshRunToken == settledRunToken,
              baseResourceID == capturedSource, baseRevision == capturedRevision else {
            // A previously captured context disappeared or was superseded
            // between the snapshot and the idle re-check: that is not a
            // readiness signal for this intent.
            recordStage("notes.exit.refused.staleContext")
            return false
        }
        if preparedCloseRequiresCommittedCover,
           session.document?.matchingOfficePreviewResourceID == nil {
            // Full-result boundary for a prepared close: the exact
            // source+revision native cover binding must have COMMITTED —
            // `cacheOfficePreview` CAS'd on this revision plus the session
            // reload that re-synced the live document. A schedule that
            // no-opped (nothing spawned or consumed), an export/render/
            // cache step that failed, or a binding that vanished during
            // the wait never permits: the still-owned view keeps the
            // editor mounted with the existing actionable retry state
            // under the same single bounded deadline, and no success flag
            // is invented. The legacy already-running settle path above
            // is unchanged.
            recordStage("notes.exit.refused.coverPrepareMissing")
            session.errorMessage = String(localized: "notes.office.preview.failed",
                                          defaultValue: "The preview could not be updated. Try again.")
            return false
        }
        return true
    }

    private func refreshPreviewOnly() async {
        // `startCoverRefresh` claimed `coverRefreshRunning` before this task
        // was enqueued; this task owns releasing it, including on every early
        // guard exit, so no retained close can observe a stale idle flag.
        defer { coverRefreshRunning = false }
        guard !committing, isVisible, office.canAct, let source = baseResourceID,
              let revision = baseRevision else { return }
        do {
            try await refreshGeneratedPreview(sourceID: source, revision: revision)
            canRetryPreview = false; message = nil
        } catch {
            canRetryPreview = true
            message = String(localized: "notes.office.preview.failed",
                             defaultValue: "The preview could not be updated. Try again.")
            recordStage("notes.preview.failed", ["domain": (error as NSError).domain,
                                                 "code": String((error as NSError).code)])
        }
    }

    private func refreshGeneratedPreview(sourceID: UUID, revision: Int) async throws {
        guard let store = session.store else { throw NoteError.resourceUnavailable }
        let sourceURL = try await store.resourceURL(sourceID)
        let pdf = try await office.exportCommittedCoverPDF(expectedSHA256: sourceURL.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let data = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try OfficeSavedCoverRenderer.firstPageData(at: pdf)
        }.value
        try Task.checkCancellation()
        let preview = try await NotesCoverImageProcessor.importCover(data: data, store: store)
        do {
            _ = try await store.cacheOfficePreview(documentID: document.id, sourceResourceID: sourceID,
                                                   previewResourceID: preview, expectedRevision: revision)
        } catch {
            _ = try? await store.discardUnreferencedResource(preview)
            throw error
        }
        try await session.reload()
        recordStage("notes.preview.updated")
    }
}
#endif
