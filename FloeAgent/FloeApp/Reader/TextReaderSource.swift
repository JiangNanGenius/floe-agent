// FloeApp — Reading-mode source construction (workspace file / Notes text).
//
// SPDX-License-Identifier: MPL-2.0
//
// Reading mode is an alternate READ-ONLY view of the same original
// file/document. This file only builds a bounded byte source plus a
// change-detection fingerprint:
//   - workspace files resolve through the existing WorkspacePathGuard, and
//     local files are streamed (never loaded whole);
//   - cloud/network text is staged by the existing bounded remote reader
//     (`WorkspaceCenter.readRemotePreview`, ≤32 MiB) and the UI says so;
//   - Notes text documents read their own text content (the document is not
//     modified and no new store is introduced).
// A position is persisted only for durable documents (not task-private
// workspace files) and only when its fingerprint still matches.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeNotes
import FloeWorkspace

/// Bounded byte source plus the revision fingerprint it was built from.
struct TextReaderBytes {
    var source: any ReaderByteSource
    var fingerprint: String
}

struct TextReaderSource {
    var kind: ReaderSourceKind
    /// Stable owner id (workspace id / "notes") for position storage.
    var ownerID: String
    /// Relative path for workspace files; note id for Notes documents.
    var documentKey: String
    var displayName: String
    /// Short format label shown in the reader ("txt", "md", "notes").
    var format: String
    var markdown: Bool
    /// True when the bytes are a fully staged remote/cloud snapshot: the
    /// reader states that honestly instead of pretending to stream.
    var isRemoteSnapshot: Bool
    /// False for task-private workspace files: their reading position is not
    /// remembered (temporary task data must not outlive the task).
    var persistsPosition: Bool
    /// True when the Notes document also contains ink/images: reading mode
    /// shows the text content only and says so.
    var hasNonTextContent: Bool
    var limits: ReaderLimits
    /// Produces the byte source and fingerprint on demand (off the view body).
    var makeBytes: @MainActor () async throws -> TextReaderBytes

    // MARK: - Fingerprints

    /// Change-detection fingerprint for a local file: size + mtime + a
    /// sha256 over the first and last 32 KiB. It is deliberately cheap (no
    /// whole-file read) and only decides whether a stored position may be
    /// restored; it is never used as a content address.
    static func fileFingerprint(url: URL, byteLength: Int64, mtime: Double) -> String {
        let window = 32 * 1024
        var sample = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let first = try? handle.read(upToCount: window) {
                sample.append(first)
            }
            if byteLength > Int64(window) {
                let tailStart = max(0, byteLength - Int64(window))
                if (try? handle.seek(toOffset: UInt64(tailStart))) != nil,
                   let last = try? handle.read(upToCount: window) {
                    sample.append(last)
                }
            }
        }
        return "\(byteLength)-\(String(format: "%.3f", mtime))-\(FloeDigest.sha256Hex(sample))"
    }

    /// Fingerprint for fully staged bytes (remote snapshots, Notes text).
    static func dataFingerprint(_ data: Data, revision: Int? = nil) -> String {
        let digest = FloeDigest.sha256Hex(data)
        if let revision { return "\(data.count)-\(digest)-r\(revision)" }
        return "\(data.count)-\(digest)"
    }

    // MARK: - Notes documents

    /// Text content of a Notes document in page order. Only `.text` elements
    /// are read; the document itself is untouched.
    static func notesText(_ document: NoteDocument) -> (text: String, hasNonTextContent: Bool) {
        var segments: [String] = []
        var hasNonText = false
        for page in document.pages {
            if page.drawingResourceID != nil || page.backgroundResourceID != nil { hasNonText = true }
            for element in page.elements {
                switch element.kind {
                case .text:
                    if !element.text.isEmpty { segments.append(element.text) }
                default:
                    hasNonText = true
                }
            }
            // A page boundary is a paragraph boundary in reading mode.
            segments.append("")
        }
        return (segments.joined(separator: "\n"), hasNonText)
    }

    static func notes(document: NoteDocument) -> TextReaderSource {
        let extracted = notesText(document)
        let data = Data(extracted.text.utf8)
        let fingerprint = dataFingerprint(data, revision: document.revision)
        return TextReaderSource(
            kind: .notesDocument,
            ownerID: "notes",
            documentKey: document.id.uuidString,
            displayName: document.title,
            format: "notes",
            markdown: false,
            isRemoteSnapshot: false,
            persistsPosition: true,
            hasNonTextContent: extracted.hasNonTextContent,
            limits: ReaderLimits(),
            makeBytes: {
                TextReaderBytes(source: ReaderDataByteSource(data: data), fingerprint: fingerprint)
            }
        )
    }
}
#endif
