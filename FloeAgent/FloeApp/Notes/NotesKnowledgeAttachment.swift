// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes
import FloeModels

/// Shared selection payload; each product keeps its own composer and undo state.
@MainActor
enum NotesKnowledgeAttachment {
    static func prepare(document: NoteDocument, store: NotesStore, files: FilesCenter) async throws -> AttachmentRef? {
        guard let resource = document.officeResourceID, let name = document.officeFileName else { return nil }
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, name != ".", name != ".." else { throw NoteError.resourceUnavailable }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try await store.resourceURL(resource), to: file)
        return try await files.registerPickedDocument(url: file, compressImage: false)
    }
    static func reference(_ document: NoteDocument) -> String {
        "已选择手记资料：\(document.title)。documentID=\(document.id.uuidString)。可使用 notes.read 读取最新内容；笔迹及图片需另行提供选区图像，不能当作已识别的文字。"
    }
}
#endif
