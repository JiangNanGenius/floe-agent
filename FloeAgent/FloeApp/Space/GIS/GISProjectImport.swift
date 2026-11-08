// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGISKit
import FloeHeavyEditorSupport

extension PersonalContentService {
    /// Explicit native-picker creation/import. Opening a Files preview never calls this.
    func importGeography(_ source: URL, folders: [String]) async throws -> PersonalContentRecord {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let file = source.standardizedFileURL.resolvingSymlinksInPath(), name = source.lastPathComponent
        guard GISWorkbench.descriptor.importExtensions.contains(source.pathExtension.lowercased()) else { throw PersonalContentError.invalidProject }
        let input = try await personalPreviewOffMain {
            let saved = try PersonalPreviewFile(root: file.deletingLastPathComponent(), url: file, maximumBytes: 512 * 1_024 * 1_024)
            let bytes = try saved.data(); try saved.validate(); return bytes
        }
        let title = source.deletingPathExtension().lastPathComponent
        let library = try library()
        let created = try await library.create(kind: .geography, title: title, in: folders) { directory, id in
            try await GISProjectOriginal.create(id: id, title: title, directory: directory)
            let hooks = HeavyEditorHostHooks(authorize: { request in
                try Task.checkCancellation()
                guard request.documentID == id, request.owner == .space(id), request.access != .exportFile else { throw HeavyEditorError.wrongDocument }
                let saved = try GISProjectOriginal.read(id: id, directory: directory)
                guard request.revision == saved.document.revision else { throw HeavyEditorError.revisionConflict }
                try saved.validate()
            }, didSave: { _ in }, export: { _, _ in throw HeavyEditorError.invalidCommand })
            // The owned staging original is not published in the Library until
            // the actual dispatcher has imported, normalized and saved it.
            let controller = try await GISWorkbench.open(directory: GISProjectOriginal.root(in: directory), documentID: id, owner: .space(id), hooks: hooks)
            try await controller.waitUntilReady()
            try await controller.importFile(name: name, data: input, expectedRevision: controller.document.revision)
            let saved = try GISProjectOriginal.read(id: id, directory: directory)
            let committed = await controller.document
            guard saved.document == committed else { throw PersonalContentError.invalidProject }
            await controller.endPresentation()
        }
        try await verify(created)
        let value = try await library.resolve(created.id)
        let saved = try GISProjectOriginal.read(id: created.id, directory: value.url)
        try await library.markChanged(created.id, title: saved.document.title)
        return try await library.resolve(created.id).record
    }
}
#endif
