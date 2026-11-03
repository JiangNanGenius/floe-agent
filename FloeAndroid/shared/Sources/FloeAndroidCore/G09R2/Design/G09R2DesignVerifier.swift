// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — real format verification and bounded comparison for design bytes.
//
// Verification is deliberately format-specific: a JSON document is never
// accepted as a PNG, an arbitrary blob is never accepted as PDF, and an
// unsupported conversion is a typed `renderUnsupported` refusal. This is the
// verifyReopen closure the shared adopt/export paths run before a CAS.
import Foundation
import FloeCore

enum G09R2DesignFormatVerifier {
    static func verify(
        _ data: Data,
        format rawFormat: String,
        contentType: DesignContentType
    ) throws {
        guard !data.isEmpty else {
            throw G09R2Error(.designPayloadMissing, detail: "emptyPayload")
        }
        let format = normalized(rawFormat)
        guard !format.isEmpty, format != "bin" else {
            throw G09R2Error(.renderUnsupported, detail: "noVerifiedFormat")
        }
        if let family = DesignContentType.from(format: format),
           contentType != .composition,
           family != contentType {
            throw G09R2Error(
                .renderUnsupported, detail: "formatFamilyMismatch")
        }
        switch format {
        case "canvas.snapshot":
            _ = try json(data)
        case "png":
            try magic(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                      "pngSignature")
        case "jpg":
            try magic(data, [0xFF, 0xD8, 0xFF], "jpegSignature")
        case "gif":
            guard data.starts(with: Data("GIF87a".utf8)) ||
                    data.starts(with: Data("GIF89a".utf8)) else {
                throw G09R2Error(.renderUnsupported, detail: "gifSignature")
            }
        case "webp":
            guard data.count >= 12,
                  Data(data.prefix(4)) == Data("RIFF".utf8),
                  Data(data[8..<12]) == Data("WEBP".utf8) else {
                throw G09R2Error(.renderUnsupported, detail: "webpSignature")
            }
        case "heic", "heif":
            guard data.count >= 12,
                  Data(data[4..<8]) == Data("ftyp".utf8) else {
                throw G09R2Error(.renderUnsupported, detail: "heifSignature")
            }
        case "tiff", "tif":
            guard data.count >= 4,
                  (data.starts(with: Data([0x49, 0x49, 0x2A, 0x00])) ||
                   data.starts(with: Data([0x4D, 0x4D, 0x00, 0x2A]))) else {
                throw G09R2Error(.renderUnsupported, detail: "tiffSignature")
            }
        case "pdf":
            guard data.starts(with: Data("%PDF-".utf8)) else {
                throw G09R2Error(.renderUnsupported, detail: "pdfSignature")
            }
        case "md", "txt":
            guard let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !data.contains(0) else {
                throw G09R2Error(.renderUnsupported, detail: "textEncoding")
            }
        case "html", "htm":
            guard let text = String(data: data, encoding: .utf8),
                  text.range(of: "<", options: .literal) != nil else {
                throw G09R2Error(.renderUnsupported, detail: "htmlEncoding")
            }
        case "svg":
            guard let text = String(data: data, encoding: .utf8),
                  text.range(of: "<svg", options: .caseInsensitive) != nil else {
                throw G09R2Error(.renderUnsupported, detail: "svgSignature")
            }
        case "json":
            _ = try json(data)
        case "docx", "xlsx", "pptx":
            try magic(data, [0x50, 0x4B, 0x03, 0x04], "ooxmlSignature")
        default:
            throw G09R2Error(
                .renderUnsupported, detail: "formatNotSupported:\(format)")
        }
    }

    private static func normalized(_ raw: String) -> String {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "markdown": return "md"
        case "jpeg": return "jpg"
        case "text": return "txt"
        default:
            return raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func magic(
        _ data: Data,
        _ bytes: [UInt8],
        _ reason: String
    ) throws {
        guard data.count >= bytes.count,
              data.starts(with: bytes) else {
            throw G09R2Error(.renderUnsupported, detail: reason)
        }
    }

    private static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw G09R2Error(.renderUnsupported, detail: "jsonParse")
        }
    }
}

enum G09R2DesignDiff {
    struct Outcome: Sendable, Equatable {
        let lines: [String]
        let truncated: Bool
        let note: String?
    }

    private static let maxLinesPerSide = 4_000
    private static let maxMatrixCells = 4_000_000
    private static let maxOutputLines = 2_000

    static func diff(base: Data, proposed: Data) -> Outcome {
        guard let oldText = String(data: base, encoding: .utf8),
              let newText = String(data: proposed, encoding: .utf8) else {
            return Outcome(
                lines: [], truncated: true,
                note: "binary payload: digest comparison only")
        }
        var oldLines = split(oldText)
        var newLines = split(newText)
        var truncated = false
        var note: String?
        if oldLines.count > maxLinesPerSide {
            oldLines = Array(oldLines.prefix(maxLinesPerSide))
            truncated = true
            note = "input capped at \(maxLinesPerSide) lines per side"
        }
        if newLines.count > maxLinesPerSide {
            newLines = Array(newLines.prefix(maxLinesPerSide))
            truncated = true
            note = "input capped at \(maxLinesPerSide) lines per side"
        }
        if oldLines == newLines {
            return Outcome(lines: [], truncated: truncated, note: note)
        }
        let cells = (oldLines.count + 1) * (newLines.count + 1)
        guard cells <= maxMatrixCells else {
            return Outcome(
                lines: blockDiff(oldLines, newLines),
                truncated: true,
                note: "bounded block diff; matrix \(cells) cells")
        }
        if oldLines.isEmpty {
            return Outcome(
                lines: bounded(newLines.map { "+ \($0)" }),
                truncated: truncated || newLines.count > maxOutputLines,
                note: note)
        }
        if newLines.isEmpty {
            return Outcome(
                lines: bounded(oldLines.map { "- \($0)" }),
                truncated: truncated || oldLines.count > maxOutputLines,
                note: note)
        }
        let width = newLines.count + 1
        var table = [UInt32](repeating: 0, count: cells)
        for i in 1...oldLines.count {
            let row = i * width
            let previous = row - width
            for j in 1...newLines.count {
                if oldLines[i - 1] == newLines[j - 1] {
                    table[row + j] = table[previous + j - 1] + 1
                } else {
                    table[row + j] = max(table[previous + j], table[row + j - 1])
                }
            }
        }
        var reversed: [String] = []
        var i = oldLines.count
        var j = newLines.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, oldLines[i - 1] == newLines[j - 1] {
                reversed.append("  \(oldLines[i - 1])")
                i -= 1; j -= 1
            } else if j > 0, i == 0 ||
                table[(i - 1) * width + j] <= table[i * width + (j - 1)] {
                reversed.append("+ \(newLines[j - 1])")
                j -= 1
            } else if i > 0 {
                reversed.append("- \(oldLines[i - 1])")
                i -= 1
            }
        }
        let lines = Array(reversed.reversed())
        if lines.count > maxOutputLines {
            truncated = true
            note = "output capped at \(maxOutputLines) diff lines"
        }
        return Outcome(
            lines: bounded(lines), truncated: truncated, note: note)
    }

    private static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    private static func bounded(_ lines: [String]) -> [String] {
        Array(lines.prefix(maxOutputLines))
    }

    private static func blockDiff(_ old: [String], _ new: [String]) -> [String] {
        var prefix = 0
        let common = min(old.count, new.count)
        while prefix < common, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var lines: [String] = []
        if prefix + suffix < old.count {
            for index in prefix..<(old.count - suffix) {
                lines.append("- \(old[index])")
            }
        }
        if prefix + suffix < new.count {
            for index in prefix..<(new.count - suffix) {
                lines.append("+ \(new[index])")
            }
        }
        return bounded(lines)
    }
}
