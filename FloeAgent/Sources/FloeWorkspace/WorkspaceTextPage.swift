// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

/// Shared local, network and authorized-Mac text-page contract. Byte offsets
/// never silently skip bytes or emit replacement characters at a page boundary.
enum WorkspaceTextPage {
    static let maximumSummaryCharacters = 196_608

    static func decode(data: Data, offset: Int, totalBytes: Int, limit: Int) throws -> FileContent {
        guard offset >= 0, totalBytes >= offset, limit > 0,
              data.count <= totalBytes - offset else {
            throw WorkspaceToolError.invalidArguments("Invalid text page bounds; refresh the file")
        }
        if offset == totalBytes {
            return FileContent(text: "", truncated: false, totalLines: 0,
                byteOffset: offset, totalBytes: totalBytes)
        }
        guard let first = data.first, first & 0xc0 != 0x80 else {
            throw WorkspaceToolError.invalidArguments("offset must be a UTF-8 boundary; use nextOffset from the previous page")
        }
        // Content classification is bounded to this page and is not based on
        // the path extension. Binary bytes are refused instead of being
        // returned as text or silently converted on a later write.
        guard !data.contains(0) else {
            throw WorkspaceToolError.invalidArguments(
                "Expected UTF-8 text; the file contains binary NUL bytes. Use the native viewer/tool for this format")
        }
        let bounded = Data(data.prefix(min(limit, WorkspaceFileService.readChunkBytes)))
        // A valid UTF-8 scalar has at most four bytes. Trim at most three
        // incomplete suffix bytes; an invalid interior remains an error.
        for trim in 0...min(3, bounded.count) {
            let visible = bounded.prefix(bounded.count - trim)
            guard !visible.isEmpty else { break }
            // decodeUTF8 keeps a leading UTF-8 BOM as U+FEFF, so the page
            // text and bytesReturned still account for the real bytes.
            if let text = WorkspaceTextPolicy.decodeUTF8(Data(visible)) {
                let end = offset + visible.count
                return FileContent(text: text, truncated: end < totalBytes,
                    totalLines: text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } },
                    byteOffset: offset, totalBytes: totalBytes)
            }
        }
        throw WorkspaceToolError.invalidArguments("Expected UTF-8 text; limit must fit the next full character (use at least 4 bytes). No bytes were skipped")
    }

    static func readNetwork(route: NetworkWorkspaceMountRegistry.Route, offset: Int,
                            limit: Int, cancellation: CancellationToken) async throws -> FileContent {
        try cancellation.throwIfCancelled()
        guard offset >= 0, limit > 0 else {
            throw WorkspaceToolError.invalidArguments("offset must be nonnegative and limit positive")
        }
        let before = try await route.adapter.metadata(path: route.relativePath)
        guard !before.isDirectory, before.byteCount >= 0,
              let total = Int(exactly: before.byteCount) else {
            throw WorkspaceToolError.invalidArguments("Expected a regular file with a known byte count")
        }
        let start = min(offset, total)
        let data = try await route.adapter.read(path: route.relativePath, offset: start,
            limit: min(limit, WorkspaceFileService.readChunkBytes))
        let after = try await route.adapter.metadata(path: route.relativePath)
        try cancellation.throwIfCancelled()
        guard before == after else {
            throw WorkspaceToolError.conflict(expected: "unchanged file page", actual: "remote file changed; restart the read")
        }
        return try decode(data: data, offset: start, totalBytes: total, limit: limit)
    }

    static func output(path: String, content: FileContent, extra: String = "", totalLinesKnown: Bool = true) -> ToolExecutionOutput {
        let next = content.nextOffset.map(String.init) ?? "none"
        let lines = totalLinesKnown ? "totalLines" : "pageLines"
        let digest = WorkspaceFileService.sha256Hex(of: Data(content.text.utf8))
        let summary = "path=\(path) offset=\(content.byteOffset) truncated=\(content.truncated) \(lines)=\(content.totalLines) bytes=\(content.bytesReturned) totalBytes=\(content.totalBytes) nextOffset=\(next) pageSHA256=\(digest)\(extra)\n\(content.text)"
        return WorkspaceToolSupport.output(summary, maximumSummaryCharacters: maximumSummaryCharacters)
    }
}
