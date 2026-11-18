import Foundation

/// Normalized records derived by a trusted host from an exclusive range of
/// Floe RunStore events. This does not decode raw runtime payloads, authenticate
/// a remote peer, authorize tools or prove that the source events were read.
public struct LocalRunProjectionBatch: Sendable {
    public let taskID: TaskID
    public let runID: RunID
    public let executionEpoch: ExecutionEpoch
    public let afterSequence: Int64
    public let throughSequence: Int64
    public let records: [SyncRecord]

    public init(taskID: TaskID, runID: RunID, executionEpoch: ExecutionEpoch,
                afterSequence: Int64, throughSequence: Int64, records: [SyncRecord]) {
        self.taskID = taskID
        self.runID = runID
        self.executionEpoch = executionEpoch
        self.afterSequence = afterSequence
        self.throughSequence = throughSequence
        self.records = records
    }

    func validate() throws {
        guard afterSequence >= 0, throughSequence > afterSequence else {
            throw SyncStoreError.invalidRunProjection("source range must strictly advance from a nonnegative sequence")
        }
        for record in records {
            guard record.taskID == taskID else {
                throw SyncStoreError.targetTaskMismatch(
                    RecordKey(kind: record.kind, entityID: record.entityID), expected: taskID, found: record.taskID)
            }
            switch record.kind {
            case .task:
                guard record.entityID.canonical == taskID.canonical else {
                    throw SyncStoreError.invalidRunProjection("task record identity does not match projection")
                }
            case .run:
                guard record.entityID.canonical == runID.canonical else {
                    throw SyncStoreError.invalidRunProjection("run record identity does not match projection")
                }
            case .message, .childRun, .checkpoint, .artifact:
                break
            case .workspaceFile, .schedule, .scheduleOccurrence:
                throw SyncStoreError.invalidRunProjection("record family requires its own source projection")
            }
        }
    }

    func digest(ownerDeviceID: DeviceID) -> ContentDigest {
        ContentDigest.compute(JSONValue.object([
            "domain": .string("floe.local.run-projection.v1"),
            "taskID": .string(taskID.canonical),
            "runID": .string(runID.canonical),
            "ownerDeviceID": .string(ownerDeviceID.canonical),
            "executionEpoch": .string(executionEpoch.decimalString),
            "afterSequence": .string(String(afterSequence)),
            "throughSequence": .string(String(throughSequence)),
            "records": .array(records.map(IncrementalWire.recordValue))
        ]).canonicalUTF8)
    }
}

/// A device-local source position, distinct from the cross-device change
/// cursor. Stored in the local meta namespace, never exported by snapshots.
/// One latest receipt is retained per run; older ranges require reconciliation.
public struct RunProjectionCheckpoint: Sendable, Equatable {
    public let taskID: TaskID
    public let runID: RunID
    public let ownerDeviceID: DeviceID
    public let executionEpoch: ExecutionEpoch
    public let afterSequence: Int64
    public let sourceSequence: Int64
    public let batchDigest: ContentDigest
    public let appendedRecords: Int
    public let unchangedRecords: Int
    public let changeCursor: ChangeCursor

    var wireValue: JSONValue {
        .object([
            "version": .integer(1),
            "taskID": .string(taskID.canonical),
            "runID": .string(runID.canonical),
            "ownerDeviceID": .string(ownerDeviceID.canonical),
            "executionEpoch": .string(executionEpoch.decimalString),
            "afterSequence": .string(String(afterSequence)),
            "sourceSequence": .string(String(sourceSequence)),
            "batchDigest": .string(batchDigest.description),
            "appendedRecords": .string(String(appendedRecords)),
            "unchangedRecords": .string(String(unchangedRecords)),
            "changeCursor": .string(changeCursor.decimalString)
        ])
    }

    init(taskID: TaskID, runID: RunID, ownerDeviceID: DeviceID, executionEpoch: ExecutionEpoch,
         afterSequence: Int64, sourceSequence: Int64, batchDigest: ContentDigest,
         appendedRecords: Int, unchangedRecords: Int, changeCursor: ChangeCursor) {
        self.taskID = taskID
        self.runID = runID
        self.ownerDeviceID = ownerDeviceID
        self.executionEpoch = executionEpoch
        self.afterSequence = afterSequence
        self.sourceSequence = sourceSequence
        self.batchDigest = batchDigest
        self.appendedRecords = appendedRecords
        self.unchangedRecords = unchangedRecords
        self.changeCursor = changeCursor
    }

    init(storedJSON: String, runID expected: RunID) throws {
        do {
            let value = try JSONValue.parse(storedJSON, maxBytes: 8_192, maxNodes: 64)
            guard value["version"]?.integerValue == 1,
                  let task = value["taskID"]?.stringValue,
                  let run = value["runID"]?.stringValue,
                  let owner = value["ownerDeviceID"]?.stringValue,
                  let epoch = value["executionEpoch"]?.stringValue,
                  let afterText = value["afterSequence"]?.stringValue, let after = Int64(afterText),
                  let sourceText = value["sourceSequence"]?.stringValue, let source = Int64(sourceText),
                  let digest = value["batchDigest"]?.stringValue,
                  let appendedText = value["appendedRecords"]?.stringValue, let appended = Int(appendedText),
                  let unchangedText = value["unchangedRecords"]?.stringValue, let unchanged = Int(unchangedText),
                  let cursor = value["changeCursor"]?.stringValue,
                  after >= 0, source > after,
                  appended >= 0, unchanged >= 0,
                  appended <= 100_000, unchanged <= 100_000, appended + unchanged <= 100_000 else {
                throw SyncStoreError.runProjectionCheckpointCorrupt(expected)
            }
            self.init(taskID: try TaskID(validating: task), runID: try RunID(validating: run),
                      ownerDeviceID: try DeviceID(validating: owner),
                      executionEpoch: try ExecutionEpoch(decimalString: epoch),
                      afterSequence: after, sourceSequence: source,
                      batchDigest: try ContentDigest(validating: digest), appendedRecords: appended,
                      unchangedRecords: unchanged, changeCursor: try ChangeCursor(decimalString: cursor))
            guard runID == expected else { throw SyncStoreError.runProjectionCheckpointCorrupt(expected) }
        } catch {
            throw SyncStoreError.runProjectionCheckpointCorrupt(expected)
        }
    }
}

public struct RunProjectionCommit: Sendable, Equatable {
    public let checkpoint: RunProjectionCheckpoint
    public let isDuplicate: Bool
}
