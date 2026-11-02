// SPDX-License-Identifier: MPL-2.0
// Derived from ConversationCenter.exportStructuredConversation at fixed iOS
// donor a59b4d4005f616c611df67fab7620e9853c525b9. Uses original stores and
// the C07 owned file-job/read lifecycle, never the currently loaded UI page.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAndroidDataExchange

enum C08TaskTranscript {
    static let maximumBytes = 64 * 1024 * 1024

    static func scrub(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth <= 32 else { throw C07DataExchangeError.invalidScope("transcriptDepth") }
        if let text = value as? String {
            if (text.hasPrefix("{") || text.hasPrefix("[")),
               let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                return try scrub(nested, depth: depth + 1)
            }
            let grant = #"(?i)(Single-use grant )[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"#
            let safe = text.replacingOccurrences(of: grant, with: "$1[REDACTED]", options: .regularExpression)
            return SecretRedactor.redact(safe)
        }
        if let array = value as? [Any] { return try array.map { try scrub($0, depth: depth + 1) } }
        if let object = value as? [String: Any] {
            let secretKeys: Set<String> = ["password", "passwd", "passphrase", "token", "accesstoken", "refreshtoken", "apikey", "authorization", "cookie", "setcookie", "clientsecret", "privatekey", "grantid", "confirmationgrantid"]
            var result: [String: Any] = [:]
            for (key, item) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                if secretKeys.contains(normalized) { result[key] = "[REDACTED]" }
                else { result[key] = try scrub(item, depth: depth + 1) }
            }
            return result
        }
        return value
    }

    static func export(database: DatabaseManager, conversationID: UUID, to url: URL) async throws {
        let conversations = SQLiteConversationStore(database: database)
        let runsStore = SQLiteRunStore(database: database)
        guard let conversation = try await conversations.conversation(id: conversationID),
              conversation.purpose == .ordinary else { throw C07DataExchangeError.invalidScope("ordinaryTaskRequired") }
        // Refuse oversized source collections BEFORE the original hydration APIs.
        // No truncation or success marker is emitted for a refused export.
        try await database.reader { db in
            let id = conversationID.uuidString
            let messageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?", arguments: [id]) ?? 0
            let runCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?", arguments: [id]) ?? 0
            let contentBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(content AS BLOB))),0) FROM messages WHERE conversation_id = ?", arguments: [id]) ?? 0
            let partBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(COALESCE(p.text,'') AS BLOB))+length(CAST(p.metadata_json AS BLOB))),0) FROM message_parts p JOIN messages m ON m.id=p.message_id WHERE m.conversation_id = ?", arguments: [id]) ?? 0
            let partCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_parts p JOIN messages m ON m.id=p.message_id WHERE m.conversation_id = ?", arguments: [id]) ?? 0
            let auxiliaryRows = try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM run_usage u JOIN runs r ON r.id=u.run_id WHERE r.conversation_id=?) + (SELECT COUNT(*) FROM run_errors e JOIN runs r ON r.id=e.run_id WHERE r.conversation_id=?)", arguments: [id, id]) ?? 0
            guard messageCount <= 50_000, runCount <= 4096, partCount <= 100_000, auxiliaryRows <= 100_000,
                  contentBytes + partBytes <= Int64(maximumBytes / 2) else { throw C07DataExchangeError.totalTooLarge }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw C07DataExchangeError.storageUnavailable("transcriptCreate") }
        let file = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer { try? file.close(); if !succeeded { try? FileManager.default.removeItem(at: url) } }
        var written = 0
        func write(_ object: [String: Any]) throws {
            try Task.checkCancellation()
            let bytes = try JSONSerialization.data(withJSONObject: scrub(object), options: [.sortedKeys])
            guard bytes.count <= 4 * 1024 * 1024, written + bytes.count + 1 <= maximumBytes else { throw C07DataExchangeError.totalTooLarge }
            try file.write(contentsOf: bytes); try file.write(contentsOf: Data([10])); written += bytes.count + 1
        }
        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try write(["type": "manifest", "format": "floe.task.jsonl", "version": 1,
            "conversationID": conversationID.uuidString, "exportedAt": iso.string(from: Date()),
            "scope": "All persisted messages and per-run events through recorded watermarks. Tool results retain stored summaries and artifact references; unavailable or truncated raw output cannot be reconstructed. Secrets are redacted; referenced artifact bytes are not embedded."])
        let messages = try await conversations.messages(conversationID: conversationID)
        for message in messages {
            try write(["type": "message", "id": message.id.uuidString, "role": message.role,
                "content": message.content, "createdAt": iso.string(from: message.createdAt),
                "runID": message.runID?.uuidString ?? "",
                "parts": try JSONSerialization.jsonObject(with: encoder.encode(message.parts))])
        }
        let runs = try await runsStore.runs(conversationID: conversationID)
        guard runs.count <= 4096 else { throw C07DataExchangeError.totalTooLarge }
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            for usage in try await runsStore.usage(runID: run.id) {
                try write(["type": "usage", "runID": run.id.uuidString, "record": try JSONSerialization.jsonObject(with: encoder.encode(usage))])
            }
            for error in try await runsStore.errors(runID: run.id) {
                try write(["type": "error", "runID": run.id.uuidString, "record": try JSONSerialization.jsonObject(with: encoder.encode(error))])
            }
            let watermark = try await runsStore.recentEvents(runID: run.id, limit: 1).last?.sequence ?? 0
            try write(["type": "run", "id": run.id.uuidString, "state": run.state, "goal": run.goal,
                "startedAt": iso.string(from: run.startedAt), "provider": run.providerName ?? "", "model": run.modelName ?? "", "eventWatermark": watermark])
            var cursor = 0
            while cursor < watermark {
                let page = try await runsStore.events(runID: run.id, afterSequence: cursor, limit: 200).filter { $0.sequence <= watermark }
                guard !page.isEmpty else { throw C07DataExchangeError.restoreIncomplete }
                for event in page {
                    let payload = (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))) ?? event.payloadJSON
                    try write(["type": "event", "runID": run.id.uuidString, "id": event.id.uuidString,
                        "sequence": event.sequence, "kind": event.kind.rawValue, "createdAt": iso.string(from: event.createdAt), "payload": payload])
                }
                cursor = page.last!.sequence
            }
        }
        try write(["type": "exportComplete", "runCount": runs.count, "messageCount": messages.count])
        try file.synchronize(); succeeded = true
    }
}
