// SPDX-License-Identifier: MPL-2.0
//
// C07 owned-data integrity regressions. Authored for the coordinated Android
// build; this authoring lane cannot run XCTest on the host toolchain.
//
// The tests cover the exact gaps reported by Main:
//   * no silent skip of referenced attachment bytes,
//   * duplicate-entry de-duplication is byte-identical only,
//   * tool-result records must map onto a real task/run/call identity,
//   * configuration documents never carry secret-shaped keys,
//   * RDP endpoints require the remote-host section that names them,
//   * a partial package must carry explicit omission receipts.
import XCTest
import Foundation
import Crypto
import FloeAndroidDataExchange

final class C07OwnedDataIntegrityTests: XCTestCase {
    private final class Root {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "c07-integrity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func file(_ name: String, _ data: Data) throws -> URL {
            let target = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: target)
            return target
        }
    }

    private func writeTable(_ name: String, rows: [C07DBRow],
                            root: Root) throws -> C07ClosureTable {
        var data = Data()
        for row in rows { data.append(try C07RowStream.encodeLine(row)) }
        let url = try root.file("\(name).jsonl", data)
        return C07ClosureTable(name: name, url: url, rowCount: rows.count)
    }

    private func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testAttachmentClosureFailsWithoutArtifactOrExactOmission() throws {
        let root = try Root()
        let conversationID = UUID()
        let attachmentID = UUID()
        let conversations = try writeTable("conversations", rows: [[
            "id": .string(conversationID.uuidString),
        ]], root: root)
        let attachments = try writeTable("attachments", rows: [[
            "id": .string(attachmentID.uuidString),
            "storage": .string("applicationSupport"),
            "relative_path": .string("\(attachmentID.uuidString)/a.bin"),
            "byte_count": .int(4),
            "sha256": .string(String(repeating: "a", count: 64)),
        ]], root: root)
        XCTAssertThrowsError(try C07OwnedDataClosure.validate(
            tables: [conversations, attachments], artifacts: [],
            toolResults: nil, configs: [], omissions: [])) { error in
            guard case C07DataExchangeError.referenceMissing = error else {
                return XCTFail("expected referenceMissing, got \(error)")
            }
        }
        let report = try C07OwnedDataClosure.validate(
            tables: [conversations, attachments], artifacts: [],
            toolResults: nil, configs: [],
            omissions: [C07DataOmission(
                scope: "attachmentBytes", subject: attachmentID.uuidString,
                reason: "missing", byteCount: 4)])
        XCTAssertEqual(report.completeness, .partial)
        XCTAssertEqual(report.omissions, 1)
    }

    func testDuplicateArtifactEntryIsOnlyDeduplicatedForIdenticalBytes() throws {
        let root = try Root()
        let data = Data("same bytes".utf8)
        let file = try root.file("same.bin", data)
        let hash = digestHex(data)
        let record = C07ArtifactRecord(
            role: .appArtifact, ownerID: nil, containerID: nil,
            logicalPath: "GeneratedImages/same.png",
            entry: "artifacts/app/GeneratedImages/same.png",
            byteCount: Int64(data.count), sha256: hash)
        let report = try C07OwnedDataClosure.validate(
            tables: [], artifacts: [
                C07ClosureArtifact(record: record, url: file),
                C07ClosureArtifact(record: record, url: file),
            ], toolResults: nil, configs: [], omissions: [])
        XCTAssertEqual(report.deduplicatedArtifacts, 1)
        XCTAssertEqual(report.artifacts, 1)

        var different = record
        different.sha256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try C07OwnedDataClosure.validate(
            tables: [], artifacts: [
                C07ClosureArtifact(record: record, url: file),
                C07ClosureArtifact(record: different, url: file),
            ], toolResults: nil, configs: [], omissions: [])) { error in
            guard case C07DataExchangeError.artifactCollision = error else {
                return XCTFail("expected artifactCollision, got \(error)")
            }
        }
    }

    func testToolResultRecordMustMatchTheRealTaskRunCallIdentity() throws {
        let root = try Root()
        let conversationID = UUID()
        let runID = UUID()
        let callID = "call-1"
        let conversations = try writeTable("conversations", rows: [[
            "id": .string(conversationID.uuidString),
        ]], root: root)
        let runs = try writeTable("runs", rows: [[
            "id": .string(runID.uuidString),
            "conversation_id": .string(conversationID.uuidString),
        ]], root: root)
        let calls = try writeTable("tool_calls", rows: [[
            "id": .string(callID),
            "run_id": .string(runID.uuidString),
        ]], root: root)
        let text = Data("tool output".utf8)
        func record(run: UUID, conversation: UUID) -> [String: Any] {
            [
                "taskID": conversation.uuidString,
                "runID": run.uuidString,
                "callID": callID,
                "toolName": "exec.shell",
                "status": "ok",
                "textBase64": text.base64EncodedString(),
                "byteCount": text.count,
                "sha256": digestHex(text),
                "capturedAt": "2026-11-02T00:00:00Z",
                "executionReportedTruncation": false,
                "retentionTruncated": false,
            ]
        }
        let valid = try JSONSerialization.data(
            withJSONObject: record(run: runID, conversation: conversationID),
            options: [.sortedKeys]) + Data([0x0A])
        let file = try root.file("tool-results.jsonl", valid)
        let section = C07OwnedToolResultSection(
            count: 1, byteCount: Int64(valid.count),
            sha256: digestHex(valid))
        XCTAssertNoThrow(try C07OwnedDataClosure.validate(
            tables: [conversations, runs, calls], artifacts: [],
            toolResults: C07ClosureToolResults(url: file, section: section),
            configs: [], omissions: []))

        // Same call/run ids but the wrong owning task is a stale reference.
        let wrong = try JSONSerialization.data(
            withJSONObject: record(run: runID, conversation: UUID()),
            options: [.sortedKeys]) + Data([0x0A])
        let wrongFile = try root.file("tool-results-wrong.jsonl", wrong)
        let wrongSection = C07OwnedToolResultSection(
            count: 1, byteCount: Int64(wrong.count),
            sha256: digestHex(wrong))
        XCTAssertThrowsError(try C07OwnedDataClosure.validate(
            tables: [conversations, runs, calls], artifacts: [],
            toolResults: C07ClosureToolResults(
                url: wrongFile, section: wrongSection),
            configs: [], omissions: []))
    }

    func testConfigDocumentsRejectSecretShapedKeysEvenWhenTypedDecoderIgnoresThem() {
        let secret = Data("""
        {"format":"floe.config.remoteHosts","formatVersion":1,
         "hosts":[{"id":"\(UUID().uuidString)","displayName":"a",
         "address":"host","port":22,"user":"u","deviceKind":"nas",
         "isRemoteExecutionEnvironment":true,"jumpHostCount":0,
         "vncEndpointCount":0,"auxiliaryConnectionCount":0,
         "hostKeyPolicy":"trustOnFirstUse","allowsLegacyAlgorithms":false,
         "auth":{"password":"x"}}]}
        """.utf8)
        XCTAssertTrue(C07ConfigSafety.containsForbiddenKey(secret))
        let clean = Data("""
        {"format":"floe.config.remoteHosts","formatVersion":1,
         "hosts":[{"id":"\(UUID().uuidString)","displayName":"a",
         "address":"host","port":22,"user":"u","deviceKind":"nas",
         "isRemoteExecutionEnvironment":true,"jumpHostCount":0,
         "vncEndpointCount":0,"auxiliaryConnectionCount":0,
         "hostKeyPolicy":"trustOnFirstUse","allowsLegacyAlgorithms":false}]}
        """.utf8)
        XCTAssertFalse(C07ConfigSafety.containsForbiddenKey(clean))
    }

    func testRDPEndpointsRequireTheRemoteHostSection() {
        let rdp = C07OwnedConfigSection(
            kind: .rdpEndpoints, count: 1, byteCount: 1,
            sha256: String(repeating: "a", count: 64))
        var tables: [C07OwnedTableRecord] = []
        for name in C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: 52).sorted() {
            tables.append(C07OwnedTableRecord(
                name: name, entry: c07OwnedTableEntry(name), rowCount: 0,
                byteCount: 0, sha256: String(repeating: "a", count: 64)))
        }
        let manifest = C07OwnedDataManifest(
            sourceAppSchemaVersion: 52,
            tables: tables,
            workspaceCount: 0,
            workspaceByteCount: 0,
            workspaceSHA256: String(repeating: "b", count: 64),
            counts: C07OwnedDataCounts(),
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable",
            configSections: [rdp])
        XCTAssertThrowsError(try manifest.validate()) { error in
            guard case C07DataExchangeError.referenceMissing = error else {
                return XCTFail("expected referenceMissing, got \(error)")
            }
        }
    }

    func testPartialCompletenessRequiresAnExactOmission() {
        var tables: [C07OwnedTableRecord] = []
        for name in C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: 52).sorted() {
            tables.append(C07OwnedTableRecord(
                name: name, entry: c07OwnedTableEntry(name), rowCount: 0,
                byteCount: 0, sha256: String(repeating: "a", count: 64)))
        }
        let base = C07OwnedDataManifest(
            sourceAppSchemaVersion: 52,
            tables: tables,
            workspaceCount: 0,
            workspaceByteCount: 2,
            workspaceSHA256: String(repeating: "b", count: 64),
            counts: C07OwnedDataCounts(),
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable",
            completeness: .partial)
        XCTAssertThrowsError(try base.validate())

        let omission = C07DataOmission(
            scope: "attachmentBytes", subject: UUID().uuidString,
            reason: "missing")
        var counts = C07OwnedDataCounts()
        counts.omissions = 1
        let declared = C07OwnedDataManifest(
            sourceAppSchemaVersion: 52,
            tables: tables,
            workspaceCount: 0,
            workspaceByteCount: 2,
            workspaceSHA256: String(repeating: "b", count: 64),
            counts: counts,
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable",
            completeness: .partial,
            omissions: [omission])
        XCTAssertNoThrow(try declared.validate())
    }

    func testOmissionSubjectRejectsAbsoluteOrOversizedValues() {
        XCTAssertThrowsError(try C07DataOmission(
            scope: "attachmentBytes", subject: "/etc/passwd",
            reason: "missing").validate())
        XCTAssertThrowsError(try C07DataOmission(
            scope: "attachmentBytes",
            subject: String(repeating: "a", count: 2_000),
            reason: "missing").validate())
        XCTAssertNoThrow(try C07DataOmission(
            scope: "attachmentBytes", subject: "AB/CD",
            reason: "missing").validate())
    }
}
