// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeElectronicsCore
import FloeElectronicsUI

/// One user library store, separate from immutable project snapshots and the
/// signed-content staging service. An unavailable library never blocks opening
/// an existing original.
@MainActor enum ElectronicsLibraryService {
    private static var instance: EDLibraryController?
    private static var consumingContent = false
    private static var pendingContent: ContentUpdateCenter?
    /// Called only after ContentUpdateCenter has verified/activated and read
    /// back its existing signed template files. No new download/installer.
    static func applySignedContent(from center: ContentUpdateCenter) async {
        pendingContent = center
        guard !consumingContent else { return }
        consumingContent = true; defer { consumingContent = false; pendingContent = nil }
        while let center = pendingContent {
            pendingContent = nil
            await consumeOneSnapshot(from: center)
        }
    }
    private static func consumeOneSnapshot(from center: ContentUpdateCenter) async {
        for (id, record) in center.installed.sorted(by: { $0.key < $1.key }) where id.hasPrefix(EDALibraryContent.packagePrefix) && record.kind == "templates" {
            guard let metadata = center.installedDocument(id: id, preferredPath: "content.json"),
                  let document = center.installedDocument(id: id, preferredPath: "Library.json") else { continue }
            do {
                let files = ["content.json": Data(metadata.utf8), "Library.json": Data(document.utf8)]
                let package = try EDALibraryContent.decode(packageID: id, version: record.version, files: files)
                let library = try shared(); _ = try await library.prepare()
                _ = try await library.store.install(package, deliveredContentSHA256: record.digest)
                try await library.refresh()
            } catch {
                // Signed staging still retains its verified download; the
                // previous user-library version and every original stay put.
                instance?.reportContentFailure(error)
            }
        }
    }
    static func shared() throws -> EDLibraryController {
        if let instance { return instance }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try EDALibraryStore(root: support.appendingPathComponent("FloeAgent/ElectronicsLibraries", isDirectory: true))
        let value = EDLibraryController(store: store, importer: { try await ElectronicsLibraryImportIO.inspect($0) })
        instance = value; value.start(); return value
    }
}
#endif
