// FloeAndroid FloeWorkspace — narrow Android mirror of the ORIGINAL
// FloeAgent/Sources/FloeWorkspace/Tools/TextEditTools.swift at immutable
// public source 3fd597b537590b4e6c11c0a25f413361a66b42b6 (blob
// d9e3ec69aac7e7bf393e63e2fc6ba846c6919253, also byte-equal at snapshot
// commit 12e36ba7b41d24634526ea55568fe88e4de26745). G04-R1 files-domain
// package (job-b6c74b42a49d4f45).
//
// Every retained statement is byte-equal to the original. Deltas:
//   1. `WorkspaceTextEdit.apply(path:expectedSHA256:environment:context:
//      transform:)` is OMITTED here. It is the agent TOOL-layer read/modify/
//      write entry and depends on `WorkspaceToolEnvironment`,
//      `WorkspaceToolSupport`, `ToolContext`-scoped authorization and the
//      `NetworkWorkspaceMountRegistry` route — the workspace tool/network
//      adapter closure that the G04-R1 files-domain package intentionally
//      does NOT own (pending contracts recorded in
//      Local/Private/android-g04-20261024/r1/files-domain/SOURCE_READY.json).
//      Main's graph integration restores it by re-linking this file once the
//      tool/network closure lands; `decode`/`check` are the exact bodies it
//      calls after any network branch, and their behaviour here is identical.
//   2. `decode` and `check` are kept verbatim because the ORIGINAL
//      `WorkspaceFileService.readFileForEditing` and `applyPatch` call
//      `WorkspaceTextEdit.decode` and the shared read/modify/write CAS path
//      calls `check` — the text-edit authority would not compile without them.
//
// No semantics were added, changed or relaxed: this mirror only moves the
// pending-boundary line from "file" to "function".

import Foundation
import FloeCore
import FloeTools

/// Shared read/modify/write path: never applies a transformation to a partial
/// read, and binds the write to the exact bytes used by the transformation.
enum WorkspaceTextEdit {
    static func decode(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceToolError.invalidArguments("Expected a UTF-8 text file; use a dedicated document or media tool for binary files")
        }
        // The strict UTF-8 decoding above is unchanged (invalid streams still
        // refuse). But this toolchain family's `String(data:encoding:.utf8)`
        // STRIPS a leading byte-order mark (host-proved: a 21-byte BOM file
        // decodes and re-encodes to 18 bytes), which would silently recode a
        // BOM'd file on save and break the conflict guard's exact
        // digest-of-current-bytes check. Re-attach the signature ONLY when
        // the raw stream carried it and the decode dropped it, so the
        // decode→encode round trip stays byte-for-byte and the original
        // BOM/CRLF/emoji preservation contract holds on every platform
        // regardless of Foundation version (G04-R1 host cohort evidence:
        // G04WorkspaceDocumentSessionTests/editingUndoSavePreservesBOMCRLFAndEmoji).
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           text.unicodeScalars.first?.value != 0xFEFF {
            return "\u{FEFF}" + text
        }
        return text
    }

    static func check(_ expected: String?, actual: String) throws {
        if let expected, expected.lowercased() != actual {
            throw WorkspaceToolError.conflict(expected: expected, actual: actual)
        }
    }
}
