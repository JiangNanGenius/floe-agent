// FloeExecution — Shell operation journal.
// Mirrors PDFOperationJournal: append-only JSONL with bounded rotation, so a
// reviewer can reconstruct exactly which commands ran, where, and with what
// outcome even after the live transcript scrolls away.

import Foundation
import FloeCore
import FloeTools

public actor ShellOperationJournal {
    public struct Entry: Codable, Sendable {
        public var timestamp: Date
        public var runID: String
        public var toolCallID: String?
        public var sessionID: String
        public var commandSHA256: String
        public var cwd: String
        public var exitCode: Int32?
        public var stdoutBytes: Int
        public var stderrBytes: Int
        public var truncated: Bool
        public var durationMs: Int
        public var outcome: String
        public var approvalGrantID: String?

        public init(
            timestamp: Date = Date(),
            runID: String,
            toolCallID: String?,
            sessionID: String,
            commandSHA256: String,
            cwd: String,
            exitCode: Int32?,
            stdoutBytes: Int,
            stderrBytes: Int,
            truncated: Bool,
            durationMs: Int,
            outcome: String,
            approvalGrantID: String?
        ) {
            self.timestamp = timestamp
            self.runID = runID
            self.toolCallID = toolCallID
            self.sessionID = sessionID
            self.commandSHA256 = commandSHA256
            self.cwd = cwd
            self.exitCode = exitCode
            self.stdoutBytes = stdoutBytes
            self.stderrBytes = stderrBytes
            self.truncated = truncated
            self.durationMs = durationMs
            self.outcome = outcome
            self.approvalGrantID = approvalGrantID
        }
    }

    public static let defaultFileName = "shell-journal.jsonl"
    private static let maximumBytes = 4 * 1024 * 1024
    private static let rotatedFiles = 3

    private let fileURL: URL
    private let encoder: JSONEncoder
    private var pendingWrites = 0

    public init(rootURL: URL? = nil) {
        let directory: URL
        if let rootURL {
            directory = rootURL
        } else {
            directory = (try? FloeArtifactStore.root())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
        }
        fileURL = directory.appendingPathComponent(Self.defaultFileName)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func record(_ entry: Entry) {
        do {
            let data = try encoder.encode(entry)
            try rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            pendingWrites += 1
        } catch {
            FloeLogger(category: .tools).error("shellJournalWriteFailed error=\(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded() throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= Self.maximumBytes else { return }
        let fileManager = FileManager.default
        let oldest = fileURL.appendingPathExtension("\(Self.rotatedFiles)")
        try? fileManager.removeItem(at: oldest)
        var index = Self.rotatedFiles - 1
        while index >= 1 {
            let source = fileURL.appendingPathExtension("\(index)")
            let destination = fileURL.appendingPathExtension("\(index + 1)")
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
            index -= 1
        }
        try? fileManager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
    }
}
