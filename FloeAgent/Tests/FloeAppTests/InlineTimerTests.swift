// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeMarkdown
@testable import FloeApp

@Suite("Inline timer binding and body ownership")
@MainActor
struct InlineTimerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(task: UUID = UUID(), run: UUID = UUID(), call: String = "timer-create") -> SystemAlarmRecord {
        .init(id: UUID(), ownerTaskID: task, ownerRunID: run, operationID: call,
            idempotencyKey: "fixture-key", payloadDigest: String(repeating: "a", count: 64),
            kind: .timer, intendedTimezone: "UTC", timerDuration: 120,
            labelDigest: FloeDigest.sha256Hex(Data("Tea".utf8)), state: .created,
            nativeState: "countdown", operationReceiptID: UUID(), createdAt: now, updatedAt: now)
    }

    private func binding(_ record: SystemAlarmRecord) throws -> NativeTimerBinding {
        try #require(NativeTimerBinding(record: record, label: "Tea", duration: 120))
    }

    private func artifact(_ record: SystemAlarmRecord) throws -> ToolArtifactReference {
        let data = try JSONEncoder().encode(binding(record)), id = UUID()
        return .init(id: id,
            relativePath: "TimerArtifacts/\(record.ownerRunID.uuidString)/\(id.uuidString).timer.json",
            mimeType: NativeTimerBinding.mimeType, byteCount: data.count, sha256: FloeDigest.sha256Hex(data))
    }

    private func payload(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    private func result(_ record: SystemAlarmRecord, artifact: ToolArtifactReference, sequence: Int,
                        status: String = "ok", tool: String = "apple.alarm.schedule", unknown: Bool = false) throws -> RunEventRecord {
        .init(runID: record.ownerRunID, sequence: sequence, kind: .toolResult,
            payloadJSON: try payload(["id": record.operationID, "tool": tool, "status": status,
                "outcomeUnknown": unknown ? "true" : "false",
                "artifactRefsJSON": String(decoding: try JSONEncoder().encode([artifact]), as: UTF8.self)]))
    }

    private func answer(run: UUID, sequence: Int, text: String = "The timer is ready.") throws -> RunEventRecord {
        .init(runID: run, sequence: sequence, kind: .assistantText, payloadJSON: try payload(["text": text]))
    }

    private func reference(_ artifact: ToolArtifactReference, run: UUID) throws -> String {
        try #require(ChatContentReference(kind: .artifact, ownerID: run, contentID: artifact.id.uuidString)).markdown(title: "Tea")
    }

    @Test func bindingRoundTripRejectsForeignMissingAndChangedIdentity() throws {
        let row = record(), value = try binding(row)
        let restored = try JSONDecoder().decode(NativeTimerBinding.self, from: JSONEncoder().encode(value))
        let status = SystemAlarmTimerStatus(record: row, snapshot: .init(id: row.id, state: "countdown"), revision: 1)
        let task = try #require(row.ownerTaskID)
        #expect(InlineTimerBodyProjection.verifyBinding(restored, status: status, conversationID: task,
            runID: row.ownerRunID, producerCallID: row.operationID))
        var invalid: [NativeTimerBinding] = []
        var changed = value; changed.version += 1; invalid.append(changed)
        changed = value; changed.ownerTaskID = UUID(); invalid.append(changed)
        changed = value; changed.ownerTaskID = nil; invalid.append(changed)
        changed = value; changed.timerID = UUID(); invalid.append(changed)
        changed = value; changed.producerRunID = UUID(); invalid.append(changed)
        changed = value; changed.producerCallID = "other-call"; invalid.append(changed)
        changed = value; changed.creationReceiptID = UUID(); invalid.append(changed)
        changed = value; changed.incarnation = "old-incarnation"; invalid.append(changed)
        changed = value; changed.duration = 121; invalid.append(changed)
        for candidate in invalid {
            #expect(!InlineTimerBodyProjection.verifyBinding(candidate, status: status,
                conversationID: task, runID: row.ownerRunID, producerCallID: row.operationID))
        }
        var foreign = status; foreign.record.ownerTaskID = nil
        #expect(!InlineTimerBodyProjection.verifyBinding(value, status: foreign, conversationID: task, runID: row.ownerRunID))
        foreign = status; foreign.snapshot?.id = UUID()
        #expect(!InlineTimerBodyProjection.verifyBinding(value, status: foreign, conversationID: task, runID: row.ownerRunID))
        #expect(!InlineTimerBodyProjection.verifyBinding(value, status: status, conversationID: task,
            runID: row.ownerRunID, producerCallID: "wrong-receipt-call"))
    }

    @Test func bindingBytesUseTheVerifiedArtifactReaderAndDetectTampering() throws {
        let row = record(), data = try JSONEncoder().encode(binding(row)), id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InlineTimer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ToolArtifactReference(id: id,
            relativePath: "TimerArtifacts/\(row.ownerRunID.uuidString)/\(id.uuidString).timer.json",
            mimeType: NativeTimerBinding.mimeType, byteCount: data.count, sha256: FloeDigest.sha256Hex(data))
        let file = root.appendingPathComponent(source.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let verified = try VerifiedChatInlineArtifact.load(source, runID: row.ownerRunID, tool: "apple.alarm.schedule", root: root)
        #expect(try JSONDecoder().decode(NativeTimerBinding.self, from: verified.data) == binding(row))
        var tampered = data; tampered[0] ^= 1; try tampered.write(to: file)
        #expect(throws: (any Error).self) {
            try VerifiedChatInlineArtifact.load(source, runID: row.ownerRunID, tool: "apple.alarm.schedule", root: root)
        }
    }

    @Test func phasesRequireNativeStateAndRespectDurableCancellation() {
        let row = record()
        var status = SystemAlarmTimerStatus(record: row, snapshot: nil, revision: 0)
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .unknown)
        status.snapshot = .init(id: row.id, state: "countdown")
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .running)
        status.snapshot?.state = "paused"
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .paused)
        status.snapshot?.state = "alerting"
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .finished)
        status.record.state = .unknown
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .unknown)
        status.record.state = .cancelled
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .cancelled)
        // An acknowledged alert can disappear after Stop. Only durable
        // positive firing proof distinguishes it from pre-deadline cancel.
        status.snapshot = nil
        status.record.nativeState = "alerting"
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .finished)
        status.record.state = .created
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .finished)
        status.record.nativeState = "countdown"
        #expect(InlineTimerBodyProjection.cardPhase(for: status) == .unknown)
    }

    @Test func countdownTicksFromDeadlineAndPausedTimeStaysFixed() {
        var snapshot = SystemAlarmNativeSnapshot(id: UUID(), state: "countdown")
        snapshot.fireDate = now.addingTimeInterval(65.25)
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now) == 65.25)
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now.addingTimeInterval(10)) == 55.25)
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now.addingTimeInterval(90)) == 0)
        snapshot.state = "paused"; snapshot.totalDuration = 120; snapshot.previousElapsed = 17
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now) == 103)
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now.addingTimeInterval(90)) == 103)
        snapshot.totalDuration = .infinity
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now) == nil)
        snapshot.state = "countdown"; snapshot.fireDate = nil
        #expect(InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: now) == nil)
        #expect(InlineTimerBodyProjection.clockString(65.25) == "01:06")
        #expect(InlineTimerBodyProjection.clockString(3_661) == "1:01:01")
        #expect(InlineTimerBodyProjection.clockString(-1) == "00:00")
        #expect(InlineTimerBodyProjection.clockString(.nan) == nil)
        #expect(InlineTimerBodyProjection.clockString(.infinity) == nil)
    }

    @Test func duplicateSuccessesKeepOneCreationAndAllReferenceAliases() throws {
        let row = record(), first = try artifact(row), retry = try artifact(row)
        let events = try [result(row, artifact: retry, sequence: 2), result(row, artifact: first, sequence: 1)]
        let sources = InlineTimerBodyProjection.timerArtifacts(events: events)
        #expect(sources.count == 1 && sources.first?.artifact.id == first.id)
        #expect(sources.first?.aliasArtifactIDs == [retry.id])
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: try reference(retry, run: row.ownerRunID)).isEmpty)
        let invalid = try [result(row, artifact: first, sequence: 3, status: "failed"),
            result(row, artifact: first, sequence: 4, tool: "mcp.apple.alarm.schedule"),
            result(row, artifact: first, sequence: 5, unknown: true)]
        #expect(InlineTimerBodyProjection.timerArtifacts(events: invalid).isEmpty)
    }

    @Test func onlyRenderedStandaloneMarkupSuppressesTheFallback() throws {
        let row = record(), file = try artifact(row)
        let sources = InlineTimerBodyProjection.timerArtifacts(events: try [result(row, artifact: file, sequence: 1)])
        let markup = try reference(file, run: row.ownerRunID)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: markup).isEmpty)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: "```markdown\n" + markup + "\n```").count == 1)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: "Example: " + markup).count == 1)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: markup, isStreaming: true).count == 1)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: markup + "\n", isStreaming: true).isEmpty)
    }

    @Test func repeatedExplicitReferencesRenderOneCreation() throws {
        let row = record(), first = try artifact(row), retry = try artifact(row)
        let sources = InlineTimerBodyProjection.timerArtifacts(events: try [result(row, artifact: first, sequence: 1),
            result(row, artifact: retry, sequence: 2)])
        let text = try reference(first, run: row.ownerRunID) + "\n\n" + reference(retry, run: row.ownerRunID)
        let suppressed = InlineTimerBodyProjection.suppressedReferenceBlockIDs(text: text, sources: sources)
        let visibleReferences = InlineContentBlockParser.parse(text).filter {
            if case .reference = $0.content { return !suppressed.contains($0.id) }; return false
        }
        #expect(visibleReferences.count == 1)
        #expect(InlineTimerBodyProjection.unreferencedSources(sources, text: text).isEmpty)
    }

    @Test func oneRunAssignsEachCreationToOnlyItsNextAssistantSegment() throws {
        let task = UUID(), run = UUID()
        let first = record(task: task, run: run, call: "first"), second = record(task: task, run: run, call: "second")
        let firstFile = try artifact(first), secondFile = try artifact(second)
        let before = try answer(run: run, sequence: 1), firstAnswer = try answer(run: run, sequence: 3)
        let secondAnswer = try answer(run: run, sequence: 6)
        let events = try [before, result(first, artifact: firstFile, sequence: 2), firstAnswer,
            result(first, artifact: artifact(first), sequence: 4), result(second, artifact: secondFile, sequence: 5), secondAnswer]
        #expect(InlineTimerBodyProjection.project(text: "", events: events, answerID: before.id).isEmpty)
        #expect(InlineTimerBodyProjection.project(text: "", events: events, answerID: firstAnswer.id).map(\.artifact.id) == [firstFile.id])
        #expect(InlineTimerBodyProjection.project(text: "", events: events, answerID: secondAnswer.id).map(\.artifact.id) == [secondFile.id])
        #expect(InlineTimerBodyProjection.project(text: "", events: events, isStreaming: true).isEmpty)
    }

    @Test func streamingCreationMovesToTheDurableSegmentWithoutRepeatingInTheTail() throws {
        let row = record(), file = try artifact(row), completion = try answer(run: row.ownerRunID, sequence: 2)
        let pending = try [result(row, artifact: file, sequence: 1)]
        let streaming = InlineTimerBodyProjection.project(text: "Starting", events: pending, isStreaming: true)
        let persisted = InlineTimerBodyProjection.project(text: "Ready", events: pending + [completion], answerID: completion.id)
        #expect(streaming.map(\.creationID) == persisted.map(\.creationID))
        #expect(InlineTimerBodyProjection.project(text: "Later", events: pending + [completion], isStreaming: true).isEmpty)
        #expect(InlineTimerBodyProjection.project(text: "", events: pending, isStreaming: true, limit: 0).isEmpty)
    }

    @Test func unknownMessageIDNeverActsAsEveryLegacyAnswer() throws {
        let row = record(), file = try artifact(row), legacyID = UUID(), otherID = UUID()
        let events = try [result(row, artifact: file, sequence: 1)]
        #expect(InlineTimerBodyProjection.project(text: "Legacy", events: events, answerID: otherID).isEmpty)
        #expect(InlineTimerBodyProjection.project(text: "Legacy", events: events, answerID: otherID, legacyAnswerID: legacyID).isEmpty)
        #expect(InlineTimerBodyProjection.project(text: "Legacy", events: events, answerID: legacyID, legacyAnswerID: legacyID).count == 1)
        let actual = try answer(run: row.ownerRunID, sequence: 2)
        #expect(InlineTimerBodyProjection.project(text: "Legacy", events: events + [actual], answerID: legacyID, legacyAnswerID: legacyID).isEmpty)
    }

    @Test func sqliteReopenKeepsTheSameCreationAndAnswerOwnership() async throws {
        let row = record(), file = try artifact(row), task = try #require(row.ownerTaskID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InlineTimerDB-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("chat.sqlite")
        let database = try DatabaseManager(path: path); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        try await conversations.saveConversation(.init(id: task, title: "Synthetic timer", createdAt: now, updatedAt: now))
        try await runs.saveRun(.init(id: row.ownerRunID, conversationID: task, state: "completed", goal: "Timer", startedAt: now))
        let success = try result(row, artifact: file, sequence: 1)
        _ = try await runs.appendEvent(runID: row.ownerRunID, kind: .toolResult, payloadJSON: success.payloadJSON)
        let answer = try await runs.appendEvent(runID: row.ownerRunID, kind: .assistantText, payloadJSON: payload(["text": "Ready"]))
        let retry = try result(row, artifact: artifact(row), sequence: 3)
        _ = try await runs.appendEvent(runID: row.ownerRunID, kind: .toolResult, payloadJSON: retry.payloadJSON)
        let later = try await runs.appendEvent(runID: row.ownerRunID, kind: .assistantText, payloadJSON: payload(["text": "Later"]))
        let initial = InlineTimerBodyProjection.project(text: "Ready", events: try await runs.events(runID: row.ownerRunID), answerID: answer.id)
        let reopened = try DatabaseManager(path: path)
        let stored = try await SQLiteRunStore(database: reopened).events(runID: row.ownerRunID)
        #expect(InlineTimerBodyProjection.project(text: "Ready", events: stored, answerID: answer.id) == initial)
        #expect(InlineTimerBodyProjection.project(text: "Later", events: stored, answerID: later.id).isEmpty)
        #expect(initial.count == 1 && initial.first?.artifact.id == file.id)
    }
}
#endif
