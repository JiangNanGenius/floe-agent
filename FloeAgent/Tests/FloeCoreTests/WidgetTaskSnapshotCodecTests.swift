// FloeCoreTests — Widget task snapshot codec, bounds and file store.
//
// These tests define the contract both processes rely on: a versioned,
// privacy-minimal schema; bounded rows/title/bytes; deterministic canonical
// task links; tolerant first-launch reads; and an atomic writer that never
// replaces a valid snapshot with a failed/partial one.

import Foundation
import Testing
@testable import FloeCore

@Suite("Widget task snapshot contract")
struct WidgetTaskSnapshotCodecTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let conversationID = UUID(uuidString: "2A9BB479-F614-473C-B8E4-008E2DFE8222")!
    private let runID = UUID(uuidString: "8B3AC9A0-4F46-4A9A-9A0D-6C6D9E1C2B77")!

    // MARK: - Codec and links

    @Test func roundTripPreservesBoundedFieldsAndProducesCanonicalLinks() throws {
        let snapshot = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: [
                .init(
                    id: conversationID,
                    runID: runID,
                    title: "Quarterly report",
                    state: .running,
                    updatedAt: now.addingTimeInterval(-30)
                )
            ]
        )
        let data = try JSONEncoder.widgetEncoder().encode(snapshot)
        let decoded = try JSONDecoder.widgetDecoder().decode(WidgetTaskSnapshot.self, from: data)
        #expect(decoded == snapshot)
        try decoded.validate()

        let item = try #require(decoded.tasks.first)
        #expect(item.taskURL.absoluteString == "floe://task/\(conversationID.uuidString.lowercased())")
        #expect(try FloeAppEntryRoute.parse(item.taskURL) == .task(conversationID))
        #expect(WidgetTaskSnapshot.newTaskURL.absoluteString == "floe://new")
        #expect(try FloeAppEntryRoute.parse(WidgetTaskSnapshot.newTaskURL) == .newTask)
    }

    @Test func encodedRowsContainNoMessageBodyOrSecretFields() throws {
        let snapshot = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: [
                .init(id: conversationID, runID: runID, title: "Task", state: .starting, updatedAt: now)
            ]
        )
        let data = try JSONEncoder.widgetEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == Set(["schemaVersion", "generatedAt", "tasks"]))
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        let row = try #require(tasks.first)
        #expect(Set(row.keys) == Set(["id", "runID", "title", "state", "updatedAt"]))
    }

    @Test func actualRunStatesMapToTruthfulWidgetStates() {
        let cases: [(String, WidgetTaskState)] = [
            ("queued", .starting),
            ("submitted", .starting),
            ("preparing", .starting),
            ("starting", .starting),
            ("streamingModel", .running),
            ("reconnecting", .running),
            ("executingTool", .running),
            ("committingResults", .running),
            ("compacting", .running),
            ("verifying", .running),
            ("waitingApproval", .waiting),
            ("waitingInput", .waiting),
            ("reviewingApproval", .waiting),
            ("checkpointed", .paused),
            ("interrupted", .paused),
            ("recoveryFailed", .paused),
            ("someFutureInternalState", .unknown)
        ]
        for (raw, expected) in cases {
            #expect(WidgetTaskState(runState: raw) == expected, "unexpected mapping for \(raw)")
        }
    }

    @Test func titleSanitizerCollapsesLinesAndBoundsByCharacter() {
        #expect(WidgetTaskSnapshot.sanitizedTitle("  Line one\nLine two  ") == "Line one Line two")
        #expect(WidgetTaskSnapshot.sanitizedTitle("A\u{0007}B\u{202E}C") == "A B C")
        let long = String(repeating: "a", count: 120)
        #expect(WidgetTaskSnapshot.sanitizedTitle(long).count == WidgetTaskSnapshot.maximumTitleCharacters)
        #expect(WidgetTaskSnapshot.sanitizedTitle("   ").isEmpty)
    }

    @Test func structuralValidationRejectsOversizeAndInvalidRows() throws {
        let base = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: [
                .init(id: conversationID, runID: runID, title: "Task", state: .running, updatedAt: now)
            ]
        )
        try base.validate()

        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                schemaVersion: 99,
                generatedAt: now,
                tasks: base.tasks
            ).validate()
        }
        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                generatedAt: now,
                tasks: (0..<6).map { index in
                    .init(
                        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                        runID: runID,
                        title: "Task",
                        state: .running,
                        updatedAt: now
                    )
                }
            ).validate()
        }
        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                generatedAt: now,
                tasks: [base.tasks[0], base.tasks[0]]
            ).validate()
        }
        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                generatedAt: now,
                tasks: [
                    base.tasks[0],
                    .init(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                        runID: runID,
                        title: "Task",
                        state: .running,
                        updatedAt: now
                    )
                ]
            ).validate()
        }
        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                generatedAt: now,
                tasks: [
                    .init(
                        id: conversationID,
                        runID: runID,
                        title: String(repeating: "a", count: 81),
                        state: .running,
                        updatedAt: now
                    )
                ]
            ).validate()
        }
        #expect(throws: WidgetTaskSnapshotError.self) {
            try WidgetTaskSnapshot(
                generatedAt: now,
                tasks: [
                    .init(
                        id: conversationID,
                        runID: runID,
                        title: "line\nbreak",
                        state: .running,
                        updatedAt: now
                    )
                ]
            ).validate()
        }
    }

    @Test func freshnessDistinguishesLiveStaleAndFutureSkew() {
        let snapshot = WidgetTaskSnapshot(generatedAt: now, tasks: [])
        #expect(snapshot.freshness(at: now) == .fresh)
        #expect(snapshot.freshness(at: now.addingTimeInterval(60)) == .fresh)
        #expect(snapshot.freshness(at: now.addingTimeInterval(WidgetTaskSnapshot.freshnessInterval + 1)) == .stale)
        #expect(snapshot.freshness(at: now.addingTimeInterval(-(WidgetTaskSnapshot.futureTolerance + 1))) == .invalidFuture)
    }

    // MARK: - File store

    @Test func missingSnapshotIsTheExpectedFirstLaunchState() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.load(now: now) == .missing)
        #expect(store.snapshotURL?.lastPathComponent == WidgetTaskSnapshotStore.fileName)
        #expect(
            store.snapshotURL?.deletingLastPathComponent().lastPathComponent
                == WidgetTaskSnapshotStore.directoryName
        )
        #expect(WidgetTaskSnapshotStore.appGroupIdentifier == "group.org.floeagent.ios")
        #expect(WidgetTaskSnapshotStore(containerURL: nil).load(now: now) == .unavailable)
        #expect(throws: WidgetTaskSnapshotStoreError.self) {
            try WidgetTaskSnapshotStore(containerURL: nil).write(
                WidgetTaskSnapshot(generatedAt: now, tasks: [])
            )
        }
    }

    @Test func writeIsAtomicAndLeavesOnlyTheSnapshotFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = makeSnapshot()
        try store.write(snapshot)

        let directory = try #require(store.directoryURL)
        let names = try Set(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
        )
        #expect(names == [WidgetTaskSnapshotStore.fileName])
        #expect(store.load(now: now) == .fresh(snapshot))

        let replacement = WidgetTaskSnapshot(
            generatedAt: now.addingTimeInterval(5),
            tasks: []
        )
        try store.write(replacement)
        #expect(store.load(now: now) == .fresh(replacement))
    }

    @Test func staleAndFutureSnapshotsAreNotReportedAsLive() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = WidgetTaskSnapshot(
            generatedAt: now.addingTimeInterval(-(WidgetTaskSnapshot.freshnessInterval + 60)),
            tasks: makeSnapshot().tasks
        )
        try store.write(stale)
        #expect(store.load(now: now) == .stale(stale))

        let future = WidgetTaskSnapshot(
            generatedAt: now.addingTimeInterval(WidgetTaskSnapshot.futureTolerance + 60),
            tasks: []
        )
        try store.write(future)
        guard case .invalid(.invalidSnapshot(.invalidDate)) = store.load(now: now) else {
            Issue.record("future snapshot must be invalid")
            return
        }
    }

    @Test func readerRejectsMalformedOversizeUnknownSchemaAndInvalidRows() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try #require(store.directoryURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try #require(store.snapshotURL)

        try Data("{".utf8).write(to: url)
        #expect(store.load(now: now) == .invalid(.malformed))

        try Data(repeating: 0x20, count: WidgetTaskSnapshot.maximumEncodedBytes + 1).write(to: url)
        #expect(store.load(now: now) == .invalid(.tooLarge))

        let unknownSchema = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "generatedAt": Int(now.timeIntervalSince1970 * 1000),
            "tasks": []
        ])
        try unknownSchema.write(to: url)
        guard case .invalid(.invalidSnapshot(.unsupportedSchema(99))) = store.load(now: now) else {
            Issue.record("unknown schema must be rejected")
            return
        }

        let tooMany = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: (0..<6).map { index in
                WidgetTaskSnapshot.Item(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                    runID: runID,
                    title: "Task",
                    state: .running,
                    updatedAt: now
                )
            }
        )
        try JSONEncoder.widgetEncoder().encode(tooMany).write(to: url)
        guard case .invalid(.invalidSnapshot(.tooManyTasks)) = store.load(now: now) else {
            Issue.record("too many rows must be rejected")
            return
        }

        let duplicate = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: [
                .init(id: conversationID, runID: runID, title: "Task", state: .running, updatedAt: now),
                .init(id: conversationID, runID: runID, title: "Task", state: .running, updatedAt: now)
            ]
        )
        try JSONEncoder.widgetEncoder().encode(duplicate).write(to: url)
        guard case .invalid(.invalidSnapshot(.duplicateTaskID)) = store.load(now: now) else {
            Issue.record("duplicate conversation rows must be rejected")
            return
        }
    }

    @Test func readerRejectsSymlinkedFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try #require(store.directoryURL)
        let url = try #require(store.snapshotURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("outside.json")
        try JSONEncoder.widgetEncoder().encode(makeSnapshot()).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        #expect(store.load(now: now) == .invalid(.unsafePath))
        #expect(throws: WidgetTaskSnapshotStoreError.self) {
            try store.write(makeSnapshot())
        }
        let targetBytes = try Data(contentsOf: target)
        #expect(try JSONDecoder.widgetDecoder().decode(WidgetTaskSnapshot.self, from: targetBytes) == makeSnapshot())
    }

    @Test func readerAndWriterRejectSymlinkedSnapshotDirectory() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try #require(store.directoryURL)
        let outside = root.appendingPathComponent("outside-widget", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)

        #expect(store.load(now: now) == .invalid(.unsafePath))
        #expect(throws: WidgetTaskSnapshotStoreError.self) {
            try store.write(makeSnapshot())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func failedWriteRetainsThePreviousValidSnapshot() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = makeSnapshot()
        try store.write(good)

        let invalid = WidgetTaskSnapshot(
            generatedAt: now,
            tasks: (0..<6).map { index in
                WidgetTaskSnapshot.Item(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                    runID: runID,
                    title: "Task",
                    state: .running,
                    updatedAt: now
                )
            }
        )
        #expect(throws: WidgetTaskSnapshotError.self) {
            try store.write(invalid)
        }
        #expect(store.load(now: now) == .fresh(good))
    }

    @Test func snapshotFileUsesWidgetAppropriateProtection() throws {
        // The Simulator host filesystem does not implement iOS data
        // protection; this assertion is meaningful on a real device.
        #if os(iOS) && !targetEnvironment(simulator)
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.write(makeSnapshot())
        let url = try #require(store.snapshotURL)
        let values = try url.resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection == URLFileProtection.completeUntilFirstUserAuthentication)
        #endif
    }

    // MARK: - Helpers

    private func makeSnapshot() -> WidgetTaskSnapshot {
        WidgetTaskSnapshot(
            generatedAt: now,
            tasks: [
                .init(
                    id: conversationID,
                    runID: runID,
                    title: "Quarterly report",
                    state: .running,
                    updatedAt: now.addingTimeInterval(-30)
                )
            ]
        )
    }

    private func makeStore() throws -> (WidgetTaskSnapshotStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeWidgetSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WidgetTaskSnapshotStore(containerURL: root), root)
    }
}

private extension JSONEncoder {
    static func widgetEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static func widgetDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
