// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeElectronicsCore
import FloeElectronicsUI

nonisolated struct ElectronicsSavedSnapshot: Sendable {
    let file: PersonalPreviewFile
    let project: EDAProject
    let digest: String
    let bytes: Data
    init(id: UUID, directory: URL) throws {
        let source = try PersonalPreviewFile(root: directory, url: directory.appendingPathComponent("Electronics/project.json"), maximumBytes: 64 * 1_024 * 1_024)
        let data = try source.data(), value = try JSONDecoder().decode(EDAProject.self, from: data)
        guard value.id == id else { throw PersonalContentError.invalidProject }
        try EDAValidation.validate(value)
        file = source; bytes = data; project = value; digest = previewHash(data)
    }
    func validate() throws { try file.validate() }
}

@MainActor enum ElectronicsSnapshotRenderer {
    static func png(_ saved: ElectronicsSavedSnapshot, context: EDADocumentContext? = nil, maximumPixelSize: Int) throws -> Data {
        try Task.checkCancellation(); try saved.validate()
        let edge = min(1_024, max(64, maximumPixelSize))
        let content = EDAPreviewView(project: saved.project, context: context)
            .frame(width: CGFloat(edge), height: CGFloat(edge) * 0.75).background(.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1; renderer.isOpaque = true
        guard let bytes = renderer.uiImage?.pngData(), bytes.count <= 8 * 1_024 * 1_024 else {
            throw PersonalContentPreviewError.notPrepared
        }
        try saved.validate(); try Task.checkCancellation()
        return bytes
    }
}

extension PersonalContentPreviewService {
    func savedElectronics(record: PersonalContentRecord, directory: URL, ownerID: String,
        maximumPixelSize: Int, validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        let saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: record.id.uuidString,
            revision: String(saved.project.revision), variant: "electronics:" + saved.digest, maximumPixelSize: maximumPixelSize)
        let check: @MainActor @Sendable () async throws -> Void = { try await validate(); try saved.validate() }
        return .init(key: key, validate: check, produce: {
            try await check()
            let image = try ElectronicsSnapshotRenderer.png(saved, maximumPixelSize: key.maximumPixelSize)
            try await check()
            return .init(.image(image), provenance: .moduleSnapshot, detail: previewText("原理图", "Schematic"))
        })
    }
}
#endif
