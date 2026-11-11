// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloeTools
import FloeMarkdown

/// One live timer card projected into an assistant body. Carries only the
/// verified artifact identity (the resolver already proved the exact run,
/// conversation and successful tool receipt); all mutable time/control state
/// is read from the native service at render time, never stored here.
struct InlineTimerCardSource: Sendable, Hashable {
    var artifact: ToolArtifactReference
    var runID: UUID
    var tool: String
    var producerCallID: String? = nil
    var creationSequence = 0
    var aliasArtifactIDs: [UUID] = []

    /// A repeated success can carry a newly written artifact UUID. Keep the
    /// card's UI identity on the creation call rather than that retry's file.
    var creationID: String { runID.uuidString + ":" + (producerCallID ?? artifact.sha256) }
}

enum InlineTimerCardPhase: Equatable {
    case running, paused, finished, cancelled, unknown
}

/// Deterministic body projection for native countdown timers.
///
/// When a run schedules a real AlarmKit timer, the schedule tool emits an
/// immutable `NativeTimerBinding` artifact. If the model copied the reference
/// into its answer (`chat.content.list` / inlineMarkdown), the ordinary
/// reference route renders the card. When the model OMITTED the markup, this
/// projection inserts the card exactly once per whole answer — appended after
/// the parsed blocks, never per paragraph — bound to the body's own run. The
/// same run's later answers and reopened conversations compute the identical
/// projection, so a creation is never duplicated.
enum InlineTimerBodyProjection {
    /// At most this many timer cards are ever appended to one answer.
    static let projectionLimit = 3

    /// One candidate per creation call, using its first successful receipt.
    /// Later receipts remain aliases so explicit markup for a retry cannot
    /// cause an additional fallback card. These locators grant no authority.
    static func timerArtifacts(events: [RunEventRecord]) -> [InlineTimerCardSource] {
        var sources: [InlineTimerCardSource] = []
        var indexByCreation: [String: Int] = [:]
        let ordered = events.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        for event in ordered where event.kind == .toolResult {
            guard let payload = payload(event),
                  payload["status"] == "ok", payload["outcomeUnknown"] != "true",
                  payload["tool"] == "apple.alarm.schedule",
                  let callID = payload["id"], !callID.isEmpty, callID.utf8.count <= 1_024 else { continue }
            let artifacts: [ToolArtifactReference] = decode(payload["artifactRefsJSON"])
            for artifact in artifacts where artifact.mimeType == NativeTimerBinding.mimeType && ChatInlineContentCatalog.accepts(
                artifact, runID: event.runID, tool: "apple.alarm.schedule") {
                let key = event.runID.uuidString + ":" + callID
                if let index = indexByCreation[key] {
                    if !sources[index].aliasArtifactIDs.contains(artifact.id), sources[index].artifact.id != artifact.id {
                        sources[index].aliasArtifactIDs.append(artifact.id)
                    }
                } else {
                    indexByCreation[key] = sources.count
                    sources.append(.init(artifact: artifact, runID: event.runID,
                        tool: "apple.alarm.schedule", producerCallID: callID, creationSequence: event.sequence))
                }
            }
        }
        return sources
    }

    /// Authoritative remaining seconds from a native snapshot at one instant;
    /// nil when the timeline is missing (the card shows syncing, never a
    /// fabricated 00:00 or createdAt+duration math).
    static func remainingSeconds(
        snapshot: SystemAlarmNativeSnapshot,
        at now: Date
    ) -> TimeInterval? {
        switch snapshot.state {
        case "countdown":
            guard let fireDate = snapshot.fireDate, now.timeIntervalSince1970.isFinite,
                  fireDate.timeIntervalSince1970.isFinite else { return nil }
            let remaining = fireDate.timeIntervalSince(now)
            return remaining.isFinite ? max(0, remaining) : nil
        case "paused":
            guard let total = snapshot.totalDuration,
                  let elapsed = snapshot.previousElapsed,
                  total.isFinite, elapsed.isFinite, total >= 0, elapsed >= 0 else { return nil }
            return max(0, total - elapsed)
        default:
            return nil
        }
    }

    static func cardPhase(for status: SystemAlarmTimerStatus) -> InlineTimerCardPhase {
        if status.record.nativeState == "alerting",
           status.snapshot == nil || status.snapshot?.id == status.record.id && status.record.state == .cancelled {
            return .finished
        }
        if status.record.state == .cancelled { return .cancelled }
        guard status.record.state == .created, status.snapshot?.id == status.record.id else { return .unknown }
        switch status.snapshot?.state {
        case "countdown": return .running
        case "paused": return .paused
        case "alerting": return .finished
        default: return .unknown
        }
    }

    static func clockString(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite else { return nil }
        let rounded = max(0, seconds.rounded(.up))
        guard rounded < Double(Int.max) else { return nil }
        let total = Int(rounded)
        if total >= 3_600 { return "\(total / 3_600):" + String(format: "%02d:%02d", (total % 3_600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Immutable binding <-> durable ledger verification. Every field must
    /// match the authoritative record the service just returned, or the card
    /// fails closed (foreign/deleted/run-mismatch/receipt-mismatch/incarnation
    /// drift all refuse).
    static func verifyBinding(
        _ binding: NativeTimerBinding,
        status: SystemAlarmTimerStatus,
        conversationID: UUID,
        runID: UUID,
        producerCallID: String? = nil
    ) -> Bool {
        let record = status.record
        guard binding.version == NativeTimerBinding.currentVersion,
              binding.ownerTaskID == conversationID, record.ownerTaskID == conversationID,
              !binding.producerCallID.isEmpty,
              producerCallID == nil || producerCallID == binding.producerCallID,
              binding.duration.isFinite, binding.duration > 0, record.timerDuration == binding.duration,
              binding.label.count <= 64,
              record.kind == .timer,
              record.id == binding.timerID,
              record.ownerRunID == binding.producerRunID,
              record.ownerRunID == runID,
              record.operationID == binding.producerCallID,
              record.operationReceiptID == binding.creationReceiptID,
              NativeTimerBinding.incarnation(
                timerID: record.id, payloadDigest: record.payloadDigest) == binding.incarnation
        else { return false }
        return status.snapshot == nil || status.snapshot?.id == record.id
    }

    /// Sources whose reference URI the body text omitted. Used both by the
    /// per-run projection and by a body that already carries an explicit
    /// projection environment (so a model-markup card is never duplicated).
    static func unreferencedSources(
        _ sources: [InlineTimerCardSource],
        text: String,
        isStreaming: Bool = false
    ) -> [InlineTimerCardSource] {
        let references = parsedReferences(text: text, isStreaming: isStreaming)
        return sources.filter { source in
            !references.contains { matches($0, source: source) }
        }
    }

    /// Main's block loop can omit only these duplicate native-reference blocks;
    /// ordinary Markdown, examples in fences and unrelated artifacts stay put.
    static func suppressedReferenceBlockIDs(
        text: String, sources: [InlineTimerCardSource], isStreaming: Bool = false
    ) -> Set<Int> {
        var seen = Set<String>(), suppressed = Set<Int>()
        for block in InlineContentBlockParser.parse(text, streaming: isStreaming) {
            guard case .reference(_, let uri) = block.content, let reference = ChatContentReference(uri),
                  let source = sources.first(where: { matches(reference, source: $0) }) else { continue }
            if !seen.insert(source.creationID).inserted { suppressed.insert(block.id) }
        }
        return suppressed
    }

    /// Candidates assigned to this ONE body. A creation belongs to the first
    /// assistantText after its first success, or to the live tail until that
    /// segment is durable. Legacy runs require an explicitly chosen fallback
    /// message ID; an arbitrary unknown message never adopts every timer.
    /// `unreferencedSources` decides which candidates need appended cards.
    static func project(
        text: String,
        events: [RunEventRecord],
        answerID: UUID? = nil,
        legacyAnswerID: UUID? = nil,
        isStreaming: Bool = false,
        limit: Int = projectionLimit
    ) -> [InlineTimerCardSource] {
        guard limit > 0 else { return [] }
        let answers = events.filter { $0.kind == .assistantText && !(payload($0)?["text"] ?? "").isEmpty }
        return Array(timerArtifacts(events: events).filter { source in
            let runAnswers = answers.filter { $0.runID == source.runID }
            let nextAnswer = runAnswers.filter { $0.sequence > source.creationSequence }.min { $0.sequence < $1.sequence }
            if isStreaming { return nextAnswer == nil }
            if let nextAnswer { return nextAnswer.id == answerID }
            return runAnswers.isEmpty && answerID != nil && answerID == legacyAnswerID
        }.prefix(min(limit, projectionLimit)))
    }

    private static func parsedReferences(text: String, isStreaming: Bool) -> [ChatContentReference] {
        InlineContentBlockParser.parse(text, streaming: isStreaming).compactMap { block in
            guard case .reference(_, let uri) = block.content else { return nil }
            return ChatContentReference(uri)
        }
    }

    private static func matches(_ reference: ChatContentReference, source: InlineTimerCardSource) -> Bool {
        reference.kind == .artifact && reference.ownerID == source.runID
            && (reference.contentID == source.artifact.id.uuidString
                || source.aliasArtifactIDs.contains(where: { $0.uuidString == reference.contentID }))
    }

    private static func payload(_ event: RunEventRecord) -> [String: String]? {
        guard event.payloadJSON.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
    }

    private static func decode<Value: Decodable>(_ text: String?) -> [Value] {
        guard let text, text.utf8.count <= 1 * 1_024 * 1_024 else { return [] }
        return (try? JSONDecoder().decode([Value].self, from: Data(text.utf8))) ?? []
    }
}

private struct InlineTimerProjectionKey: EnvironmentKey {
    static let defaultValue: [InlineTimerCardSource] = []
}

extension EnvironmentValues {
    /// Assistant-body timer cards for the answer being rendered. Set per-row
    /// by the thread detail view (assistant rows + live tail); empty default
    /// keeps every other surface unchanged.
    var inlineTimerProjection: [InlineTimerCardSource] {
        get { self[InlineTimerProjectionKey.self] }
        set { self[InlineTimerProjectionKey.self] = newValue }
    }
}
#endif
