// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import Observation
import CryptoKit

@MainActor @Observable final class PersonalTextDocument {
    private static var sessions: [URL: PersonalTextDocument] = [:]
    let url: URL
    let projectID: UUID
    private(set) var text: String
    private(set) var revision: String
    private(set) var saving = false
    private(set) var isClosed = false
    private(set) var isClosing = false
    var diagnostic: String?
    private var pending: Task<Void, Never>?
    private var editRevision = 0
    private init(url: URL, projectID: UUID, data: Data) throws {
        guard data.count <= 4 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else { throw PersonalContentError.invalidProject }
        self.url = url; self.projectID = projectID; self.text = text
        revision = Self.digest(data)
    }
    static func open(url: URL, projectID: UUID) throws -> PersonalTextDocument {
        try PersonalLibraryFileActions.requireAvailable(projectID)
        if let session = sessions[url] {
            guard session.projectID == projectID, !session.isClosed else { throw PersonalContentError.changedDocument }
            return session
        }
        let value = try Self(url: url, projectID: projectID, data: Data(contentsOf: url))
        sessions[url] = value; return value
    }
    private nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func setText(_ value: String) {
        guard !isClosed, !isClosing, value != text else { return }
        text = value; editRevision += 1
        pending?.cancel()
        pending = Task { [self] in
            do { try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation(); _ = await save() }
            catch {}
        }
    }
    /// Old views retain a closed value but cannot write back to a moved root.
    static func requireClosedForFileAction(projectID: UUID) throws {
        guard !sessions.values.contains(where: { $0.projectID == projectID && !$0.isClosed }) else {
            throw PersonalFileActionError.closeFirst
        }
    }
    @discardableResult func close() async -> Bool {
        if isClosed { return true }
        guard !saving, !isClosing else {
            diagnostic = IDELanguageRunText.t("仍在保存，请稍后再关闭。", "Still saving. Close again shortly."); return false
        }
        isClosing = true; defer { isClosing = false }
        pending?.cancel(); pending = nil
        guard await save() else { return false }
        isClosed = true
        if Self.sessions[url] === self { Self.sessions.removeValue(forKey: url) }
        return true
    }
    @discardableResult func save() async -> Bool {
        guard !isClosed else {
            diagnostic = IDELanguageRunText.t("文档已关闭，请重新打开。", "This document is closed. Reopen it to edit."); return false
        }
        guard !saving else { return false }
        let data = Data(text.utf8), expected = revision, stamp = editRevision
        guard data.count <= 4 * 1_024 * 1_024 else { diagnostic = IDELanguageRunText.t("文档过大，请缩小内容后保存。", "Reduce this document before saving."); return false }
        guard Self.digest(data) != expected else { return true }
        saving = true; defer { saving = false }
        do {
            let file = url
            try await Task.detached(priority: .userInitiated) {
                var coordinationError: NSError?, outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { target in
                    outcome = Result {
                        let targetCanonical = target.standardizedFileURL.resolvingSymlinksInPath()
                        let originalCanonical = file.standardizedFileURL.resolvingSymlinksInPath()
                        let targetValues = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard targetCanonical == originalCanonical, targetValues.isRegularFile == true,
                              targetValues.isSymbolicLink != true else { throw PersonalContentError.changedDocument }
                        let current = try Data(contentsOf: target)
                        guard Self.digest(current) == expected else { throw PersonalContentError.changedDocument }
                        let history = target.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DocumentHistory")
                        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
                        try current.write(to: history.appendingPathComponent(UUID().uuidString + ".md"), options: .atomic)
                        try data.write(to: target, options: .atomic)
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let outcome else { throw PersonalContentError.storageUnavailable }
                try outcome.get()
            }.value
            revision = Self.digest(data); diagnostic = nil
            try await PersonalContentService.shared.library().markChanged(projectID)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: projectID)
            if stamp != editRevision { pending = Task { [self] in _ = await save() } }
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }
}

struct PersonalTextDocumentView: View {
    @Bindable var document: PersonalTextDocument
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if document.saving { ProgressView() }
                Button(IDELanguageRunText.t("保存", "Save"), systemImage: "checkmark") { Task { await document.save() } }
                    .disabled(document.saving || document.isClosing || document.isClosed).frame(minHeight: 44)
            }.padding(.horizontal)
            Divider()
            TextEditor(text: Binding(get: { document.text }, set: { document.setText($0) }))
                .font(.body).padding(12).disabled(document.isClosing || document.isClosed).accessibilityIdentifier("space.document.editor")
            if let error = document.diagnostic {
                DisclosureGroup(IDELanguageRunText.t("尚未保存，查看详情", "Not saved. View details")) { Text(error).font(.caption) }.padding()
            }
        }.background(Color(uiColor: .systemBackground))
    }
}
#endif
