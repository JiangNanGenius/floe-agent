import Foundation
import CryptoKit
import FloeCore

/// Append-only crash forensics journal for PDF operations. PDFKit crashes
/// cannot be caught in-process, so every risky mutation writes a synchronous
/// "begin" line before it runs and an "end" line after. A crash leaves the
/// last begin unmatched; the next process reports the orphan so TestFlight
/// crash feedback can be mapped to one exact operation. Never contains
/// document text, names or secrets — only operation type, page counts and a
/// truncated input/output digest.
enum PDFOperationJournal {
    struct Token: Sendable {
        let tool: String
        let startedAt: Date
    }

    private static let lock = NSLock()
    private static let logger = FloeLogger(category: .tools)
    private static let maxBytes = 256 * 1024

    private static let journalURL: URL? = {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return caches
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("pdf-operation-journal.jsonl")
    }()

    /// Begins one journaled operation. Reports any unmatched "begin" left by
    /// a previous process before appending the new line.
    static func begin(tool: String, detail: String) -> Token {
        lock.lock()
        defer { lock.unlock() }
        reportOrphansLocked()
        trimLocked()
        appendLocked(["phase": "begin", "tool": tool, "detail": detail, "at": timestamp()])
        logger.info("pdfOpBegin tool=\(tool) \(detail)")
        return Token(tool: tool, startedAt: Date())
    }

    static func end(_ token: Token, status: String) {
        let durationMs = max(0, Int(Date().timeIntervalSince(token.startedAt) * 1_000))
        lock.lock()
        defer { lock.unlock() }
        appendLocked(["phase": "end", "tool": token.tool, "status": status, "durationMs": "\(durationMs)", "at": timestamp()])
        logger.info("pdfOpEnd tool=\(token.tool) durationMs=\(durationMs) status=\(status)")
    }

    /// Short digest prefix used for cross-referencing instructions with
    /// inspect/render evidence without storing document content.
    static func digest(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func appendLocked(_ fields: [String: String]) {
        guard let journalURL else { return }
        let line = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: " ")
            + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try data.write(to: journalURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }

    private static func trimLocked() {
        guard let journalURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: journalURL.path),
              let size = attributes[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: journalURL) else { return }
        let tail = data.suffix(maxBytes / 2)
        let firstNewline = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[firstNewline...]).write(to: journalURL, options: .atomic)
    }

    /// A previous process wrote "begin" without "end": that operation died.
    private static func reportOrphansLocked() {
        guard let journalURL,
              let data = try? Data(contentsOf: journalURL),
              let text = String(data: data, encoding: .utf8) else { return }
        var openTools: [String] = []
        for line in text.split(separator: "\n").suffix(40) {
            if line.contains("phase=begin"), let tool = value(of: "tool", in: line) {
                openTools.append(tool)
            } else if line.contains("phase=end"), let tool = value(of: "tool", in: line),
                      let index = openTools.lastIndex(of: tool) {
                openTools.remove(at: index)
            }
        }
        for tool in openTools {
            logger.warning("pdfOpOrphan tool=\(tool) previousProcessDidNotFinish")
        }
        if !openTools.isEmpty {
            appendLocked(["phase": "orphan", "tool": openTools.joined(separator: ","), "at": timestamp()])
        }
    }

    private static func value(of key: String, in line: Substring) -> String? {
        for token in line.split(separator: " ") where token.hasPrefix("\(key)=") {
            return String(token.dropFirst(key.count + 1))
        }
        return nil
    }
}
