// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Foundation
import FloeNotes
import FloeWorkspace

/// Standalone read-only preview for an imported engineering/CAD document.
///
/// Notes only ever hands the bundled viewer a bounded, immutable copy of the
/// note resource. Editing stays a workspace-only capability, so this view never
/// installs `onSave` or `onReview`. If the file exceeds the viewer package
/// limit the original is preserved and no preview is claimed.
struct NotesEngineeringView: View {
    let session: NotesSession
    let document: NoteDocument
    @State private var package: EngineeringPreviewPackage?
    @State private var error: String?
    @State private var loading = true
    /// Newest load identity; a cancelled predecessor must not publish an error
    /// or package that belongs to files it no longer represents.
    @State private var activeLoadID: String?

    private var loadID: String {
        "\(document.id.uuidString):\(document.engineeringResourceID?.uuidString ?? "none"):\(document.revision)"
    }

    var body: some View {
        Group {
            if let package {
                EngineeringFilePreview(package: package)
                    .id(loadID)
                    .accessibilityIdentifier("notes.engineering.preview")
            } else if let error {
                ContentUnavailableView {
                    Label("notes.engineering.failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("notes.engineering.retry") { Task { await load() } }
                }
            } else if loading {
                ProgressView("notes.engineering.loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .task(id: loadID) { await load() }
    }

    private func load() async {
        let key = loadID
        activeLoadID = key
        package = nil
        error = nil
        loading = true
        defer { if key == activeLoadID { loading = false } }
        guard let store = session.store, let resourceID = document.engineeringResourceID,
              let name = document.engineeringFileName else {
            error = NoteError.resourceUnavailable.localizedDescription
            return
        }
        do {
            let url = try await store.resourceURL(resourceID)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize else { throw NoteError.resourceUnavailable }
            guard size <= EngineeringPreviewPackage.maximumBytes else { throw Self.tooLargeError }
            // Bound the read as well as the stat: `mappedIfSafe` would allocate
            // with the file, so read at most limit + 1 through a cancellable
            // worker and reject any growth past the package limit.
            let worker = Task.detached(priority: .userInitiated) {
                try Self.boundedData(at: url)
            }
            let data = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard key == activeLoadID else { return }
            let value = try EngineeringPreviewPackage.single(name: name, bytes: data)
            try Task.checkCancellation()
            guard key == activeLoadID else { return }
            package = value
        } catch is CancellationError {
        } catch {
            guard key == activeLoadID else { return }
            self.error = error.localizedDescription
        }
    }

    private nonisolated static var tooLargeError: NoteError {
        NoteError.invalidOperation(String(localized: "notes.engineering.tooLarge"))
    }

    /// `FileHandle.read(upToCount:)` adds one byte past the limit so a file that
    /// grows after the stat can never be read without a bound.
    private nonisolated static func boundedData(at url: URL) throws -> Data {
        let maximum = EngineeringPreviewPackage.maximumBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= maximum else { throw tooLargeError }
        return data
    }
}
#endif
