//
//  CADImportSourceReader.swift
//  FloeCADKit
//
//  E31-R3 manual import file preparation: the bytes of a USER-SELECTED import
//  source are read OFF the MainActor, under the security-scoped lease the
//  picker result needs, and that lease is closed only after the read has
//  actually finished (or failed). The bytes are copied into `Data` while the
//  lease is still open, so nothing a caller keeps after this returns depends
//  on the lease.
//
//  Why this exists: the Workbench used to call `Data(contentsOf:)` on the
//  document MainActor, inside the security-scoped scope, before starting the
//  off-main parser. A multi-hundred-megabyte exchange file therefore blocked
//  the UI for the whole read. The parse was already off-main; the read was
//  not. This is the one shared read entry for every Import-menu entry
//  (mesh/STL/OBJ/GLB, STEP, IGES, DXF, image); their feature semantics are
//  unchanged — they receive the same bytes and the same file name.
//
//  Ownership / authorization:
//    * The URL is the user's own picker selection. Reading it is the user's
//      import action, NOT a model/tool/file-system grant: no tool, provider or
//      agent path may reuse this entry to read an arbitrary path.
//    * No new byte cap is introduced here. The parsers keep their existing
//      `MeshImportLimits.standard` budget and refusal semantics; a raw
//      exchange file is not a file-declared compressed expansion, so adding an
//      arbitrary read cap would be a new, undocumented restriction.
//    * A file read cannot be interrupted. Cancellation therefore stops the
//      import (no prompt, no commit, no UI mutation) but the read itself is
//      JOINED; the worker that opened the lease also closes it after the read,
//      so it is never closed underneath a read in progress.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// One read import source: the user-selected URL identity plus its bytes.
public nonisolated struct CADImportSource: Sendable {
    /// The URL the user selected, kept for identity/diagnostics only. The
    /// bytes below are already materialized; no later step reopens the URL.
    public let url: URL
    public let fileName: String
    public let data: Data
    /// True when the read ran under an active security-scoped lease.
    public let usedSecurityScope: Bool
}

public nonisolated enum CADImportSourceReadError: Error, Sendable, Equatable {
    /// The caller was already cancelled (or was cancelled while the read ran):
    /// no bytes are handed out.
    case cancelled
    /// The file could not be read; the value is safe user-facing detail.
    case unreadable(String)

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// The security-scoped lease operations, injectable so tests can prove the
/// begin/end balance and the worker thread without a real document picker.
/// Production always uses `CADImportSourceLease.system`.
public nonisolated struct CADImportSourceLease: Sendable {
    public var begin: @Sendable (URL) -> Bool
    public var end: @Sendable (URL) -> Void

    public init(begin: @escaping @Sendable (URL) -> Bool,
                end: @escaping @Sendable (URL) -> Void) {
        self.begin = begin
        self.end = end
    }

    /// The platform security-scoped access calls. `end` is only called when
    /// `begin` returned true (the platform contract).
    public static let system = CADImportSourceLease(
        begin: { $0.startAccessingSecurityScopedResource() },
        end: { $0.stopAccessingSecurityScopedResource() })
}

public nonisolated enum CADImportSourceReader {
    /// Read `url` on a detached worker and JOIN it.
    ///
    /// A caller that is already cancelled returns `.cancelled` without taking
    /// the lease or reading the file. A cancellation that arrives while the
    /// read runs cannot interrupt it, so the worker finishes the read, closes
    /// the lease, and this returns `.cancelled` (no bytes reach the caller).
    /// In both cases the caller may not mutate any UI or document state; the
    /// Workbench additionally fences its own manual-import identity.
    public static func read(
        url: URL,
        lease: CADImportSourceLease = .system
    ) async -> Result<CADImportSource, CADImportSourceReadError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let worker = Task.detached(priority: .userInitiated) {
            () -> Result<CADImportSource, CADImportSourceReadError> in
            let scoped = lease.begin(url)
            defer { if scoped { lease.end(url) } }
            // No `.mappedIfSafe`: a memory-mapped Data could fault after the
            // lease closes. Plain `Data(contentsOf:)` materializes the bytes
            // while the lease is still held.
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                guard !name.isEmpty else {
                    return .failure(.unreadable("The selected file has no readable name."))
                }
                return .success(CADImportSource(url: url, fileName: name,
                                                data: data,
                                                usedSecurityScope: scoped))
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
        }
        let result = await worker.value
        // The read is joined and the lease is closed at this point. A caller
        // cancelled while it ran must not act on the bytes.
        if Task.isCancelled { return .failure(.cancelled) }
        return result
    }
}
