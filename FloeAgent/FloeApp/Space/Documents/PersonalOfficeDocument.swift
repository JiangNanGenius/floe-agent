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
    private let openedDigest: String
    private var started = false
    private var mounted = false
    private var closed = false
    private var closing = false

    private init(record: PersonalContentRecord, directory: URL, url: URL) throws {
        self.record = record; self.directory = directory; self.url = url
        openedDigest = try FloeDigest.sha256Hex(ofFileAt: url)
    }

    static func open(record: PersonalContentRecord, directory: URL, url: URL) async throws -> PersonalOfficeDocument {
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
        let owner = try Self(record: record, directory: directory, url: url)
        sessions[record.id] = owner
        return owner
    }

    static func requireClosedForFileAction(projectID: UUID) throws {
        guard sessions[projectID] == nil else { throw PersonalFileActionError.closeFirst }
    }

    func start(environment: AppEnvironment) async {
        mounted = true
        guard !started, !closed, Self.sessions[record.id] === self else { return }
        started = true
        do {
            let location = try await PersonalContentService.shared.library().resolve(record.id)
            let original = try await PersonalContentService.shared.originalFile(record.id)
            guard mounted, location.url.standardizedFileURL == directory.standardizedFileURL,
                  original.standardizedFileURL == url.standardizedFileURL else { throw PersonalContentError.changedDocument }
            session.shedIdleLocalModelForOffice = { [weak environment] reason in
                await environment?.shedIdleLocalModelForOffice(reason: reason)
            }
            session.officeDeviceFontFacts = { [weak environment] in
                await environment?.officeDeviceFontFacts() ?? [:]
            }
            await session.open(url)
            guard mounted, !closed, Self.sessions[record.id] === self else { _ = await close(); return }
            if session.error == nil { await session.requestEditing() }
        } catch { session.reportOpenFailure(error) }
    }

    /// Called by OfficeDocumentEditorView only after its real save/discard/keep
    /// decision. A failed original save never reaches this close callback.
    func close() async -> Bool {
        if closed { return true }
        guard !closing else { return false }
        closing = true; defer { closing = false }
        await session.release()
        // A requested teardown may still be queued behind an engine operation.
        // Keep the owner/file-action barrier until a real idle close is observed.
        guard session.phase == .idle else { return false }
        do {
            let current = try await PersonalContentService.shared.library().resolve(record.id)
            guard current.url.standardizedFileURL == directory.standardizedFileURL else { throw PersonalContentError.changedDocument }
            if try FloeDigest.sha256Hex(ofFileAt: url) != openedDigest {
                try await PersonalContentService.shared.library().markChanged(record.id)
                NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: record.id)
            }
            closed = true; mounted = false
            if Self.sessions[record.id] === self { Self.sessions.removeValue(forKey: record.id) }
            return true
        } catch { session.error = error.localizedDescription; return false }
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
            inlineHeader: AnyView(HStack(spacing: 8) {
                Text(document.record.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button(IDELanguageRunText.t("作品助手", "Work assistant"), systemImage: "sparkles", action: onAssistant)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("space.editor.assistant")
            }),
            requestsEditingOnAppear: false)
        .accessibilityIdentifier("space.office.editor")
        .task { visible = true; await document.start(environment: environment) }
        .onDisappear { visible = false; Task { await document.unmount() } }
    }
}
#endif
