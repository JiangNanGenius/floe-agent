//
//  CADPersonalMaterialLibrary.swift
//  FloeCADKit
//
//  Cross-document "My Materials" store. This is deliberately NOT the document
//  library: the document owns its own `materialsData` column (so a package stays
//  self-contained and its undo/save path agrees), while this file is the
//  user's reusable palette inside the app's managed Application Support
//  container.
//
//  SHARED FILE CONTRACT (host-defined, must not be forked):
//    <Application Support>/FloeAgent/CADMaterials/library.json
//  The host bridge already reads/writes this exact file for
//  `material libraryExport/libraryImport/libraryList global`. The payload is
//  the same `CADMaterialLibrary` JSON codec. This store writes through
//  `NSFileCoordinator` and re-reads/merges immediately before writing, so a
//  UI save and a host-side export converge instead of clobbering each other.
//  Applying a material always writes a DOCUMENT copy; deleting a personal
//  entry can therefore never change a saved model.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation

@MainActor
@Observable
final class CADPersonalMaterialLibraryStore {
    static let shared = CADPersonalMaterialLibraryStore()

    /// The ONE app-owned personal library path. Core owns the URL and the
    /// codec (`FloeCADDocument.sharedMaterialLibraryURL` /
    /// `CADMaterialLibraryFileStore`), so the UI store cannot fork a second
    /// personal library.
    nonisolated static func defaultFileURL() -> URL {
        FloeCADDocument.sharedMaterialLibraryURL
    }

    let fileURL: URL
    private(set) var library: CADMaterialLibrary = .empty
    private(set) var lastError: String?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        reload()
    }

    func reload() {
        lastError = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            library = .empty
            return
        }
        var coordinationError: NSError?
        var result: CADMaterialLibrary = .empty
        var failure: String?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [],
                                       error: &coordinationError) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard let decoded = CADMaterialLibraryFileStore.read(at: url) else {
                failure = FloeCADStrings.text(
                    "cad.material.library.unreadable",
                    "My Materials could not be read. The file was left untouched.")
                return
            }
            result = decoded.sanitized
        }
        if coordinationError != nil {
            failure = FloeCADStrings.text("cad.material.library.readFailed",
                                          "My Materials could not be read.")
        }
        library = result
        lastError = failure
    }

    @discardableResult
    func upsert(_ definition: CADMaterialDefinition) -> String? {
        write { current in
            guard current.entries.count < CADMaterialLimits.maximumLibraryEntries
                    || current.entry(definition.id) != nil else {
                return FloeCADStrings.format(
                    "cad.material.library.full",
                    "My Materials holds the maximum of %d entries.",
                    CADMaterialLimits.maximumLibraryEntries)
            }
            current.upsert(definition)
            return nil
        }
    }

    @discardableResult
    func remove(_ id: MaterialID) -> String? {
        write { current in
            current.remove(id)
            return nil
        }
    }

    /// Merge an exported library/pack file. Existing entries with the same id
    /// are replaced; everything else is added. Nothing is applied to a body.
    @discardableResult
    func importLibrary(data: Data, replace: Bool = false) -> String? {
        guard data.count <= CADMaterialLimits.maximumLibraryBytes else {
            return FloeCADStrings.text("cad.material.library.importTooLarge",
                                       "That material pack is too large to import.")
        }
        var incoming: [CADMaterialDefinition] = []
        if let decoded = try? JSONDecoder().decode(CADMaterialLibrary.self, from: data) {
            incoming = decoded.entries
        } else if let entries = try? JSONDecoder().decode([CADMaterialDefinition].self,
                                                          from: data) {
            incoming = entries
        } else {
            return FloeCADStrings.text("cad.material.library.importInvalid",
                                       "That file is not a Floe material pack.")
        }
        guard !incoming.isEmpty else {
            return FloeCADStrings.text("cad.material.library.importEmpty",
                                       "That material pack has no materials.")
        }
        return write { current in
            var updated = replace ? CADMaterialLibrary() : current
            for entry in incoming.prefix(CADMaterialLimits.maximumLibraryEntries) {
                var clean = entry.sanitized
                if updated.entry(clean.id) != nil, !replace {
                    // A pack exported from this store is idempotent; two
                    // independent packs sharing an id get fresh identities
                    // instead of silently overwriting each other.
                    clean = self.clone(clean, in: updated)
                }
                updated.upsert(clean)
            }
            current = updated
            return nil
        }
    }

    func exportLibraryData() -> Data? {
        CADMaterialLibraryCodec.encode(library)
    }

    func uniqueName(_ raw: String, excluding: MaterialID? = nil) -> String {
        let base = CADMaterialDefinition.sanitizedName(raw)
        let used = Set(library.entries.filter { $0.id != excluding }
            .map { $0.name.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return base
    }

    // MARK: Coordinated read-modify-write

    /// Re-read the host file, merge the caller's change, then replace it
    /// atomically under file coordination. This is the one write path; it
    /// keeps the shared file format identical to the host's export.
    private func write(_ mutate: (inout CADMaterialLibrary) -> String?) -> String? {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var coordinationError: NSError?
        var failure: String?
        var committed: CADMaterialLibrary?
        NSFileCoordinator().coordinate(writingItemAt: fileURL,
                                       options: .forReplacing,
                                       error: &coordinationError) { url in
            var current = CADMaterialLibraryFileStore.read(at: url)?.sanitized ?? .empty
            if let error = mutate(&current) {
                failure = error
                return
            }
            do {
                try CADMaterialLibraryFileStore.write(current, to: url)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path)
                var mutableURL = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? mutableURL.setResourceValues(values)
                committed = current.sanitized
            } catch {
                failure = FloeCADStrings.text("cad.material.library.writeFailed",
                                              "My Materials could not be saved.")
            }
        }
        if coordinationError != nil {
            failure = FloeCADStrings.text("cad.material.library.writeFailed",
                                          "My Materials could not be saved.")
        }
        if let failure {
            lastError = failure
            return failure
        }
        if let committed {
            library = committed
            lastError = nil
        }
        return nil
    }

    private func clone(_ definition: CADMaterialDefinition,
                       in library: CADMaterialLibrary) -> CADMaterialDefinition {
        var used = Set(library.entries.map { $0.name.lowercased() })
        var name = definition.name
        for index in 2...999 where used.contains(name.lowercased()) {
            name = "\(definition.name) \(index)"
        }
        return CADMaterialDefinition(
            id: MaterialID(),
            name: name,
            baseColor: definition.baseColor,
            metallic: definition.metallic,
            roughness: definition.roughness,
            opacity: definition.opacity,
            emissive: definition.emissive,
            emissiveStrength: definition.emissiveStrength,
            textures: definition.textures.map {
                CADMaterialTexture(id: MaterialTextureID(), slot: $0.slot,
                                   name: $0.name, mimeType: $0.mimeType,
                                   colorSpace: $0.colorSpace,
                                   orientation: $0.orientation, bytes: $0.bytes)
            },
            uvMapping: definition.uvMapping)
    }
}
#endif
