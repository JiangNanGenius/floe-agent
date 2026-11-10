// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeDocuments

extension PersonalContentService {
    /// Real OOXML creation, published through the existing library transaction.
    /// A replay validates the requested format instead of replacing old bytes.
    func createDocument(format: PersonalOfficeFormat, title: String, folders: [String] = [], id: UUID = UUID()) async throws -> PersonalContentRecord {
        let record = try await library().create(kind: .document, title: title, in: folders, id: id) { directory, _ in
            try await Task.detached(priority: .userInitiated) {
                _ = try PersonalOfficeOriginalFactory.create(format: format, title: title, directory: directory)
            }.value
        }
        let file = try await originalFile(record.id)
        try await Task.detached(priority: .userInitiated) {
            try PersonalOfficeOriginalFactory.verify(format: format, url: file)
        }.value
        return record
    }
}

extension PersonalOfficeFormat {
    var title: String {
        switch self {
        case .word: IDELanguageRunText.t("Word 文档", "Word document")
        case .workbook: IDELanguageRunText.t("Excel 表格", "Excel workbook")
        case .presentation: IDELanguageRunText.t("PowerPoint 演示文稿", "PowerPoint presentation")
        case .plainText: IDELanguageRunText.t("纯文本", "Plain text")
        }
    }
    var systemImage: String {
        switch self {
        case .word: "doc.text"
        case .workbook: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .plainText: "text.alignleft"
        }
    }
}

/// The existing native session remains responsible for permissions, protected
/// documents, working copies, CAS save, recovery, undo and bounded engine close.
/// This owner only binds that session to the actual personal original/root.
@MainActor final class PersonalOfficeDocument {
    private static var sessions: [UUID: PersonalOfficeDocument] = [:]
    let record: PersonalContentRecord
    let directory: URL
    let url: URL
    let session = OfficeFileSession()
    private let contentService: PersonalContentService
    private let openedDigest: String
    private var started = false
    private var mounted = false
    private var closed = false
    private var ownershipGeneration = UUID()
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Bool, Never>?

    private init(record: PersonalContentRecord, directory: URL, url: URL, contentService: PersonalContentService) throws {
        self.record = record; self.directory = directory; self.url = url; self.contentService = contentService
        openedDigest = try FloeDigest.sha256Hex(ofFileAt: url)
    }

    static func open(record: PersonalContentRecord, directory: URL, url: URL,
                     contentService: PersonalContentService = .shared) async throws -> PersonalOfficeDocument {
        try PersonalLibraryFileActions.requireAvailable(record.id)
        guard record.kind == .document, WorkspaceFileType.isOffice(url.lastPathComponent),
              url.deletingLastPathComponent().lastPathComponent == "Original",
              url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw PersonalContentError.invalidProject
        }
        if let previous = sessions[record.id] {
            // A second mounted view must not create a competing working copy.
            guard !previous.mounted, await previous.close() else { throw PersonalFileActionError.closeFirst }
        }
        let owner = try Self(record: record, directory: directory, url: url, contentService: contentService)
        sessions[record.id] = owner
        return owner
    }

    static func requireClosedForFileAction(projectID: UUID) throws {
        guard sessions[projectID] == nil else { throw PersonalFileActionError.closeFirst }
    }

    /// Opening belongs to this document, not the lifetime of a SwiftUI task.
    /// A temporary cover can cancel its view task without cancelling the open.
    @discardableResult
    func start(environment: AppEnvironment) async -> Bool {
        guard !closed, closeTask == nil, Self.sessions[record.id] === self else { return false }
        mounted = true
        guard !started else { return true }
        started = true
        let generation = ownershipGeneration
        let task = Task { @MainActor in
            await self.openOwned(environment: environment, generation: generation)
        }
        openTask = task
        await task.value
        openTask = nil
        // This appearance was accepted. A real close that cancelled it must
        // never be mistaken for a request to create another owner.
        return true
    }

    private func ownsOpen(_ generation: UUID) -> Bool {
        mounted && !closed && ownershipGeneration == generation && Self.sessions[record.id] === self
    }

    private func openOwned(environment: AppEnvironment, generation: UUID) async {
        session.recordOwnerStage("space.open.resolve.started")
        do {
            try Task.checkCancellation()
            let location = try await contentService.library().resolve(record.id)
            guard ownsOpen(generation) else { return }
            let original = try await contentService.originalFile(record.id)
            try Task.checkCancellation()
            guard ownsOpen(generation) else { return }
            guard location.url.standardizedFileURL == directory.standardizedFileURL,
                  original.standardizedFileURL == url.standardizedFileURL else { throw PersonalContentError.changedDocument }
            session.shedIdleLocalModelForOffice = { [weak environment] reason in
                await environment?.shedIdleLocalModelForOffice(reason: reason)
            }
            session.officeDeviceFontFacts = { [weak environment] in
                await environment?.officeDeviceFontFacts() ?? [:]
            }
            await session.open(url)
            guard ownsOpen(generation), !Task.isCancelled else { return }
            if session.error == nil { await session.requestEditing() }
        } catch {
            guard ownsOpen(generation) else { return }
            session.reportOpenFailure(error)
        }
    }

    /// Called by OfficeDocumentEditorView only after its real save/discard/keep
    /// decision. A failed original save never reaches this close callback.
    func close() async -> Bool {
        if closed { return true }
        if let closeTask { return await closeTask.value }
        mounted = false
        ownershipGeneration = UUID()
        openTask?.cancel()
        let task = Task { @MainActor in await self.closeOwnedSession() }
        closeTask = task
        let result = await task.value
        closeTask = nil
        return result
    }

    private func closeOwnedSession() async -> Bool {
        // The cancelled opener checks the generation after every suspension.
        // Drain it before releasing its session so it cannot mount a controller
        // after close or reopen an old copy behind a replacement owner.
        if let openTask { await openTask.value }
        await session.release()
        // A requested teardown may still be queued behind an engine operation.
        // Keep the owner/file-action barrier until a real idle close is observed.
        guard session.phase == .idle else { return false }
        do {
            let current = try await contentService.library().resolve(record.id)
            guard current.url.standardizedFileURL == directory.standardizedFileURL else { throw PersonalContentError.changedDocument }
            if try FloeDigest.sha256Hex(ofFileAt: url) != openedDigest {
                try await contentService.library().markChanged(record.id)
                NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: record.id)
            }
            closed = true; mounted = false
            if Self.sessions[record.id] === self { Self.sessions.removeValue(forKey: record.id) }
            return true
        } catch { session.error = error.localizedDescription; return false }
    }

    /// The factory resolves the same owned original again after a real close.
    /// It never substitutes a working/recovery copy or revives this instance.
    func replacement() async throws -> PersonalOfficeDocument {
        guard await close() else { throw PersonalFileActionError.closeFirst }
        let location = try await contentService.library().resolve(record.id)
        let original = try await contentService.originalFile(record.id)
        guard location.url.standardizedFileURL == directory.standardizedFileURL,
              original.standardizedFileURL == url.standardizedFileURL else {
            throw PersonalContentError.changedDocument
        }
        return try await Self.open(record: location.record, directory: location.url, url: original,
                                   contentService: contentService)
    }

    func unmount() async {
        mounted = false
        _ = await close()
    }
}

/// Composed inside PersonalContentEditor's existing navigation stack. The Office
/// host owns Back/save/exit; an outer unguarded Done button must not bypass it.
struct PersonalOfficeDocumentView: View {
    let document: PersonalOfficeDocument
    let onClose: () -> Void
    let onAssistant: () -> Void
    let presentationIsActive: Bool
    let onRetryOpen: () -> Void
    var beforeClose: (@MainActor () async -> Bool)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @State private var visible = false

    var body: some View {
        OfficeDocumentEditorView(relativePath: "Original/" + document.url.lastPathComponent,
            session: document.session,
            documentRoot: document.directory,
            stableInkIdentity: .init(workspaceIdentity: "personal:" + document.record.id.uuidString,
                relativePath: "Original/" + document.url.lastPathComponent),
            onSaved: nil,
            onClose: {
                Task {
                    guard visible, await document.close(), visible else { return }
                    onClose()
                }
            },
            beforeDocumentLeave: beforeClose,
            inlineHeader: AnyView(HStack(spacing: 8) {
                Text(document.record.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button(IDELanguageRunText.t("作品助手", "Work assistant"), systemImage: "sparkles", action: onAssistant)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("space.editor.assistant")
            }),
            requestsEditingOnAppear: false,
            retryOpen: {
                // A retained working-copy recovery owns its own reopen. Only
                // the pre-mount idle outcome asks the original-file loader.
                if visible, presentationIsActive, document.session.phase == .idle { onRetryOpen() }
            })
        // Give the document its own group instead of propagating this virtual
        // identifier onto native editor controls and their readiness state.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.office.editor")
        .task {
            visible = true
            let retained = await document.start(environment: environment)
            if !retained, visible, presentationIsActive { onRetryOpen() }
        }
        .onChange(of: presentationIsActive) { _, active in
            if !active { visible = false; Task { await document.unmount() } }
        }
        .onDisappear {
            visible = false
            // The parent remains presented while an internal sheet/cover is
            // visible. Only a real departure closes this document owner.
            if !presentationIsActive { Task { await document.unmount() } }
        }
    }
}
#endif
