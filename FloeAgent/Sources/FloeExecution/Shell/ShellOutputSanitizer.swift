// FloeExecution — Shell output sanitizer.
// Command output can contain ANSI escapes, control bytes, or extremely long
// single lines. The sanitizer keeps stdout/stderr safe for the transcript
// while preserving newlines and tabs.

import Foundation

public enum ShellOutputSanitizer {
    public static let maximumLineBytes = 32 * 1024
    public static let maximumTotalBytes = 512 * 1024

    /// Removes ANSI escape sequences and non-printing control characters
    /// (except `\n` and `\t`), collapses runs of more than two newlines, and
    /// bounds each line to `maximumLineBytes`.
    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = String()
        output.reserveCapacity(min(text.utf8.count, 64 * 1024))
        var lineBytes = 0
        var newlineRun = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\u{1B}" {
                // Skip CSI/OSC/other escape introducers up to the final byte.
                skipEscapeSequence(text, &index)
                continue
            }
            if character == "\r" { continue }
            if character == "\n" {
                if newlineRun < 2 { output.append(character) }
                newlineRun += 1
                lineBytes = 0
                continue
            }
            if character == "\t" {
                output.append(character)
                lineBytes += 1
                newlineRun = 0
                continue
            }
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                output.append(character)
                lineBytes += 1
                newlineRun = 0
                continue
            }
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if lineBytes >= maximumLineBytes {
                output.append("\n[line truncated]")
                // Fast-forward to the next newline without emitting content.
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                lineBytes = 0
                newlineRun = 0
                continue
            }
            output.append(character)
            lineBytes += 1
            newlineRun = 0
            if output.utf8.count >= maximumTotalBytes {
                output.append("\n[output truncated]")
                break
            }
        }
        return output
    }

    private static func skipEscapeSequence(_ text: String, _ index: inout String.Index) {
        guard index < text.endIndex else { return }
        if text[index] == "[" {
            index = text.index(after: index)
            while index < text.endIndex {
                let next = text[index]
                index = text.index(after: index)
                if let scalar = next.unicodeScalars.first, scalar.value >= 0x40, scalar.value <= 0x7E {
                    return
                }
            }
            return
        }
        if text[index] == "]" {
            // OSC … terminated by BEL or ST (ESC \).
            index = text.index(after: index)
            while index < text.endIndex {
                let next = text[index]
                index = text.index(after: index)
                if next == "\u{07}" { return }
                if next == "\u{1B}" {
                    if index < text.endIndex, text[index] == "\\" { index = text.index(after: index) }
                    return
                }
            }
            return
        }
        // Two-character escape: consume one more scalar.
        if index < text.endIndex { index = text.index(after: index) }
    }
}
