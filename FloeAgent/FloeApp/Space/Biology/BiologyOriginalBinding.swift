// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// The folder is organizational. It carries an exact native identity, never
/// a host path or authority; the App-owned Biology service keeps its root.
struct BiologyOriginalBinding: Codable, Sendable {
    var schemaVersion = 1
    let projectID: UUID
    func write(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("biology-binding.json"), options: .atomic)
    }
    static func verify(id: UUID, directory: URL) throws {
        let file = try PersonalPreviewFile(root: directory,
            url: directory.appendingPathComponent("biology-binding.json"), maximumBytes: 4_096)
        let binding = try JSONDecoder().decode(Self.self, from: file.data())
        guard binding.schemaVersion == 1, binding.projectID == id else { throw PersonalContentError.invalidProject }
        try file.validate()
    }
}
#endif
