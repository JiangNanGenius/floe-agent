// FloeApp — persisted per-document Office open mode.
//
// SPDX-License-Identifier: MPL-2.0
//
// Notes enters an existing/imported Office document as a read-only preview
// the first time; from the second entry onwards it opens the editor directly,
// even when the first visit only previewed. The rule itself lives in
// `FloeDocuments.OfficeDocumentModeMemory` (pure and unit tested); this
// wrapper owns the UserDefaults-backed snapshot and the App-side document
// identity.

#if canImport(UIKit)
import Foundation
import FloeDocuments

@MainActor
final class OfficeDocumentModeStore {
    static let shared = OfficeDocumentModeStore()

    private let defaults: UserDefaults
    private var memory: OfficeDocumentModeMemory

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        memory = OfficeDocumentModeMemory(data: defaults.data(forKey: OfficeDocumentModeMemory.storageKey))
    }

    /// Persisted key for a document inside a stable scope. `scope` is a Notes
    /// document identity (never a transient draft directory), so the same
    /// document keeps one slot across staged working copies and restarts.
    func key(scope: String?, document: String) -> String {
        OfficeDocumentModeMemory.scopedKey(scope: scope, document: document)
    }

    /// Preview for a first entry, editor from the second entry onwards.
    func mode(scope: String?, document: String) -> OfficeDocumentOpenMode {
        memory.resolvedMode(forKey: key(scope: scope, document: document))
    }

    /// Records one completed open; the next entry of this document defaults
    /// to the editor.
    func markOpened(scope: String?, document: String) {
        memory.markOpened(forKey: key(scope: scope, document: document))
        if let data = memory.snapshotData {
            defaults.set(data, forKey: OfficeDocumentModeMemory.storageKey)
        }
    }
}
#endif
