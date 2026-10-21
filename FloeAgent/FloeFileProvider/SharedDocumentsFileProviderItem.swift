// SPDX-License-Identifier: MPL-2.0
// FloeFileProvider — NSFileProviderItem materialization (S5 C4).
//
// Read-only value view over a committed `SharedDocumentsItem`. The adapter
// owns NO mutable state: the version identifier is derived from the
// committed content+metadata versions, capabilities reflect the actually
// implemented local operations (folders and regular files only — no
// package/symlink/trash capabilities are advertised), and documentSize /
// childItemCount describe the committed truth. Local-only semantics: the
// item is always uploaded/downloaded against the authoritative local
// backend; missing backend bytes are reported as errors upstream, never
// presented as remotely recoverable.

import Foundation
import FileProvider
import UniformTypeIdentifiers
import FloePersistence

/// Bridges the store's stable identity to FileProvider identifiers.
enum SharedDocumentsFileProviderIdentity {
    static func providerIdentifier(for storeID: String) -> NSFileProviderItemIdentifier {
        storeID == SharedDocumentsIdentity.rootItemID
            ? .rootContainer
            : NSFileProviderItemIdentifier(storeID)
    }

    static func storeIdentifier(for providerID: NSFileProviderItemIdentifier) throws -> String {
        if providerID == .rootContainer { return SharedDocumentsIdentity.rootItemID }
        let raw = providerID.rawValue
        guard !raw.isEmpty, raw != ".", raw != "..", !raw.contains("/") else {
            throw SharedDocumentsError.invalidItemID(raw)
        }
        return raw
    }
}

final class SharedDocumentsFileProviderItem: NSObject, NSFileProviderItem {
    let item: SharedDocumentsItem
    private let isRoot: Bool

    init(item: SharedDocumentsItem) {
        self.item = item
        self.isRoot = item.id == SharedDocumentsIdentity.rootItemID
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        SharedDocumentsFileProviderIdentity.providerIdentifier(for: item.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        SharedDocumentsFileProviderIdentity.providerIdentifier(for: item.parentID)
    }

    var filename: String { item.name }

    var contentType: UTType {
        if item.kind == .folder { return .folder }
        let ext = (item.name as NSString).pathExtension
        if let typed = UTType(filenameExtension: ext) { return typed }
        return .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if item.kind == .folder {
            var caps: NSFileProviderItemCapabilities = [
                .allowsReading,
                .allowsContentEnumerating,
                .allowsAddingSubItems,
            ]
            if !isRoot {
                caps.insert(.allowsReparenting)
                caps.insert(.allowsRenaming)
                caps.insert(.allowsDeleting)
            }
            return caps
        }
        return [
            .allowsReading,
            .allowsWriting,
            .allowsReparenting,
            .allowsRenaming,
            .allowsDeleting,
        ]
    }

    var documentSize: NSNumber? {
        item.kind == .file ? NSNumber(value: item.byteCount) : nil
    }

    var versionIdentifier: Data? {
        Data("c\(item.contentVersion).m\(item.metadataVersion)".utf8)
    }

    var contentModificationDate: Date? { item.modificationDate }

    var creationDate: Date? { item.creationDate }

    /// The local backend IS the server: content is always materialized.
    var isUploaded: Bool { true }
    var isDownloaded: Bool { true }
    var isMostRecentVersionDownloaded: Bool { true }
}
