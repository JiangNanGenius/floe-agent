// FloeApp — Read-aloud owns one final answer, never an execution transcript.
#if canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence

enum FinalAnswerSpeech {
    struct Answer: Equatable {
        let id: UUID
        let runID: UUID
        let text: String
    }

    static func answer(runID: UUID, events: [RunEventRecord], messages: [PersistedMessage]) -> Answer? {
        let owned = events.filter { $0.runID == runID }.sorted { $0.sequence < $1.sequence }
        let lastTool = owned.last { $0.kind == .toolRequest || $0.kind == .toolResult }?.sequence
        if let event = owned.last(where: { $0.kind == .assistantText }),
           lastTool.map({ event.sequence > $0 }) ?? true,
           let data = event.payloadJSON.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Answer(id: event.id, runID: runID, text: text)
        }
        if lastTool != nil { return nil }
        // Bound durable answers are the canonical legacy fallback. Unbound
        // notices and messages from another run are never inferred as answers.
        guard let message = messages.last(where: { $0.role == "assistant" && $0.runID == runID }) else { return nil }
        let parts = message.parts.filter { $0.kind == .text }.sorted { $0.partIndex < $1.partIndex }.compactMap(\.text)
        let text = parts.isEmpty ? message.content : parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Answer(id: message.id, runID: runID, text: text)
    }
}
#endif
