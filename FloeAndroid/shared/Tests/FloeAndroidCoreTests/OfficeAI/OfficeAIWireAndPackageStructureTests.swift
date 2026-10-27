// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused regression for the Office AI wire contract and the
// independent OOXML package-structure verifier (job-1db1a7a8d5da457a). NOT
// executed by this lane (Main's grouped batch). The descriptor builder must
// refuse out-of-allowlist keys and non-ASCII/control/oversize values BEFORE
// anything reaches the wire (fail closed); replies/failure codes are bounded
// and total (unknown tokens NEVER decode into success). Package-structure
// parsing is a bounded central-directory reader over synthetic ZIP fixtures:
// it proves container shape and required-part presence, never content — the
// semantic layer is separate by design.

import XCTest
import Foundation
import FloeCore
import FloeTools
import FloeAndroidJobTools
@testable import FloeAndroidCore

private struct DeadOfficeTransport: OfficeAIHostTransport, Sendable {
    func isBound(to epoch: UInt64) -> Bool { false }
    func submit(operation: OfficeAIHostOperation, descriptor: [String: String],
                staged: Data, cancellation: CancellationToken) async throws -> Data {
        throw OfficeAIHostTransportError.hostUnbound
    }
}

final class OfficeAIWireContractTests: XCTestCase {

    func testDescriptorAllowlistsAreClosedPerOperation() throws {
        let epoch: UInt64 = 7
        // a key outside an operation's closed set must be impossible to ship
        XCTAssertThrowsError(try OfficeAIHostDescriptor.build(
            operation: .lookup, epoch: epoch,
            fields: [OfficeAIHostField.taskID: UUID().uuidString,
                     OfficeAIHostField.workspaceID: UUID().uuidString,
                     OfficeAIHostField.nativeEpoch: "7",
                     "path": "/tmp/should-never-cross-lookup"]))
        // valid lookup + staged-free command keys are accepted
        let built = try OfficeAIHostDescriptor.build(
            operation: .command, epoch: epoch,
            fields: [OfficeAIHostField.sessionToken: "sess-1",
                     OfficeAIHostField.generation: "9",
                     OfficeAIHostField.opId: "oa-apply-1",
                     OfficeAIHostField.action: "applyText",
                     OfficeAIHostField.targetHandle: String(repeating: "a", count: 32)])
        XCTAssertEqual(built[OfficeAIHostField.operation], "office.command")
        XCTAssertEqual(built[OfficeAIHostField.epoch], "7")
        XCTAssertEqual(Set(built.keys), Set(["operation", "epoch", "sessionToken", "generation",
                                             "opId", "action", "targetHandle"]))
        // absent optional fields are simply not present
        let lookup = try OfficeAIHostDescriptor.build(
            operation: .lookup, epoch: epoch,
            fields: [OfficeAIHostField.taskID: UUID().uuidString,
                     OfficeAIHostField.workspacePresent: "absent",
                     OfficeAIHostField.nativeEpoch: "7",
                     OfficeAIHostField.workspaceID: nil])
        XCTAssertNil(lookup[OfficeAIHostField.workspaceID])
    }

    func testDescriptorRejectsControlCharactersOversizeAndPathShapedTokens() {
        XCTAssertThrowsError(try OfficeAIHostDescriptor.build(
            operation: .command, epoch: 1,
            fields: [OfficeAIHostField.sessionToken: "sess\u{0000}-1",
                     OfficeAIHostField.generation: "1",
                     OfficeAIHostField.opId: "oa-x",
                     OfficeAIHostField.action: "captureTarget"]))
        XCTAssertThrowsError(try OfficeAIHostDescriptor.build(
            operation: .command, epoch: 1,
            fields: [OfficeAIHostField.action: String(repeating: "x", count: 600)]))
        // newline-injection inside a value could split wire framing upstream:
        XCTAssertThrowsError(try OfficeAIHostDescriptor.build(
            operation: .command, epoch: 1,
            fields: [OfficeAIHostField.action: "applyText\nstatus"]))
    }

    func testReplyParsingIsStrictAndFailureTokensAreBounded() {
        let ok = Data(#"{"ok":1,"state":"queryObserved"}"#.utf8)
        XCTAssertEqual(OfficeAIHostDescriptor.parse(ok)?["state"] as? String, "queryObserved")
        XCTAssertNil(OfficeAIHostDescriptor.parse(Data("not json".utf8)))
        let failure = OfficeAIHostDescriptor.failure(from: Data(
            #"{"code":"applyConflict","detail":"\#(String(repeating: "d", count: 900)))"}"#.utf8))
        XCTAssertEqual(failure.code, "applyConflict")
        XCTAssertEqual(failure.detail?.count, 240, "details are bounded, never truncated silently mid-token")
        let empty = OfficeAIHostDescriptor.failure(from: Data(#"{"code":""}"#.utf8))
        XCTAssertEqual(empty.code, "failed", "an empty code totalizes to a failure, never success")
    }

    func testEveryHostOperationHasClosedKeysAndABudget() {
        for operation in [OfficeAIHostOperation.open, .lookup, .command, .save, .verify,
                          .reconcile, .pushOriginal] {
            XCTAssertFalse(OfficeAIHostField.allowedKeys(for: operation).isEmpty)
            XCTAssertGreaterThan(OfficeAIHostLimits.budgetMillis(for: operation), 0)
            XCTAssertTrue(OfficeAIHostField.allowedKeys(for: operation)
                .isDisjoint(with: ["input", "output", "url", "grant"]))
        }
    }

    // MARK: amendment/2 owned-proof wire additions

    func testVerifyDescriptorCarriesOwnedProofKeysAndStillRefusesForeignOnes() throws {
        let epoch: UInt64 = 7
        let built = try OfficeAIHostDescriptor.build(
            operation: .verify, epoch: epoch,
            fields: [OfficeAIHostField.path: "/trusted/snapshot.xlsx",
                     OfficeAIHostField.sha256: String(repeating: "a", count: 64),
                     OfficeAIHostField.format: "xlsx",
                     OfficeAIHostField.expectCommand: "setCellContent",
                     OfficeAIHostField.cellAddress: "B4",
                     OfficeAIHostField.contentKind: "formula",
                     OfficeAIHostField.expectPartIndex: "2",
                     OfficeAIHostField.preEditSha256: String(repeating: "b", count: 64),
                     OfficeAIHostField.taskID: UUID().uuidString,
                     OfficeAIHostField.verificationMode: "liveEffect",
                     OfficeAIHostField.effectOpId: "oa-apply-abcdef0123456789abcd",
                     OfficeAIHostField.exportOpId: "oa-export-abcdef0123456789ab",
                     OfficeAIHostField.sessionToken: "sess-1",
                     OfficeAIHostField.generation: "9",
                     OfficeAIHostField.targetHandle: String(repeating: "c", count: 32)])
        XCTAssertEqual(built[OfficeAIHostField.verificationMode], "liveEffect")
        XCTAssertEqual(built[OfficeAIHostField.effectOpId], "oa-apply-abcdef0123456789abcd")
        XCTAssertEqual(built[OfficeAIHostField.exportOpId], "oa-export-abcdef0123456789ab")
        XCTAssertEqual(built[OfficeAIHostField.expectPartIndex], "2")
        XCTAssertEqual(built[OfficeAIHostField.targetHandle], String(repeating: "c", count: 32))
        // A proof-shaped key OUTSIDE the closed allowlist still cannot ship.
        XCTAssertThrowsError(try OfficeAIHostDescriptor.build(
            operation: .verify, epoch: epoch,
            fields: [OfficeAIHostField.path: "/x",
                     OfficeAIHostField.sha256: String(repeating: "a", count: 64),
                     "foreignProof": "nope"]))
    }

    func testSemanticReplyDecodesOwnedProofFactsAndCapturedPartIndex() {
        let bridge = OfficeAIHostBridge(transport: DeadOfficeTransport(),
                                        store: OfficeAIEditContextStore())
        let semantic = bridge.decodeSemantic([
            "inspected": true, "partName": "xl/worksheets/sheet3.xml",
            "expectedTextFound": true, "expectedContentMatches": true,
            "targetEffectVerified": false, "semanticDeltaVerified": true,
            "proofReused": false, "proofVersion": 2,
            "cellTypeAttribute": "str", "cellHasFormula": true,
            "cellTypeMatchesIntent": true])
        XCTAssertTrue(semantic.inspectedSavedPackage)
        XCTAssertEqual(semantic.proofVersion, 2)
        XCTAssertEqual(semantic.expectedContentMatches, true)
        XCTAssertEqual(semantic.targetEffectVerified, false)
        XCTAssertEqual(semantic.semanticDeltaVerified, true)
        XCTAssertEqual(semantic.cellTypeAttribute, "str")
        // The captured LOGICAL part index rides the command facts (amendment/2
        // partIndex) — never a filename ordinal, never a silent sheet1.
        let command = bridge.decodeCommand(
            ["state": "queryObserved", "targetHandle": String(repeating: "f", count: 32),
             "facts": ["partIndex": 2, "docType": "calc", "slideCount": 4]],
            identity: "seed-1")
        XCTAssertEqual(command.state, .queryObserved)
        XCTAssertEqual(command.facts.partIndex, 2)
        XCTAssertEqual(command.facts.docType, "calc")
        // Absent amendment/2 fields decode nil (the gate refuses absent proof).
        let sparse = bridge.decodeSemantic(["inspected": true, "expectedTextFound": true])
        XCTAssertNil(sparse.expectedContentMatches)
        XCTAssertNil(sparse.targetEffectVerified)
        XCTAssertNil(sparse.semanticDeltaVerified)
        XCTAssertNil(sparse.proofReused)
        XCTAssertEqual(sparse.proofVersion, 2, "default proof generation is v2")
    }

    func testCapturedContextLookupReturnsCapturedPartIndexForOwnerOnly() {
        let store = OfficeAIEditContextStore()
        let conversation = UUID()
        let facts = OfficeEditDocumentFacts(
            sessionToken: "sess-c", nativeGeneration: 3, viewerIncarnation: 1,
            hostGeneration: nil, nativeEpoch: nil, ownerTaskID: conversation,
            workspaceID: nil, sourceLogicalPath: "docs/w.xlsx", sourceID: nil,
            sourceRevision: nil, family: .xlsx, editable: true,
            originalSnapshotSha256: String(repeating: "a", count: 64),
            originalSnapshotBytes: 10, workingCopySha256: String(repeating: "b", count: 64),
            workingCopyBytes: 10, displayName: "w.xlsx", route: .workspace)
        let record = OfficeAIEditContextRecord(
            contextID: "ctx-captured", conversationID: conversation, createdRunID: UUID(),
            targetHandle: String(repeating: "f", count: 32), document: facts,
            capturedContext: OfficeEditQueryFacts(docType: "calc", partIndex: 2),
            capturedAtElapsedMillis: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000))
        XCTAssertTrue(store.insert(record))
        XCTAssertEqual(store.capturedContext(contextID: "ctx-captured",
                                             conversationID: conversation)?.partIndex, 2,
                       "the ACTUAL captured logical part index answers for the owner")
        XCTAssertNil(store.capturedContext(contextID: "ctx-captured", conversationID: UUID()),
                     "a foreign conversation never sees the captured facts")
        XCTAssertNil(store.capturedContext(contextID: "ctx-missing", conversationID: conversation))
    }

    func testFailureTokenMappingIsTotalNeverSuccess() {
        // The mapping is a TOTAL function; each pinned token must classify as
        // an ERROR (this test names the ones whose class is the contract).
        let rejected: Set<String> = ["notOwner", "ownerMismatch", "sessionMismatch", "sessionEnding",
                                     "generationFenced", "laneFenced", "editContextMissing",
                                     "editContextStale", "editContextConsumed"]
        for token in rejected {
            let mapped = OfficeAIHostReply.failureError(code: token, detail: nil)
            guard case .rejected(let code, _) = mapped, code == token else {
                return XCTFail("\(token) must map to a rejected carrying its own token")
            }
        }
        let unknowns: Set<String> = ["flushUnknown", "saveUnknown", "mountEndedWithoutAck",
                                     "timeoutWithoutAck"]
        for token in unknowns {
            let mapped = OfficeAIHostReply.failureError(code: token, detail: nil)
            guard case .unknown(let code, _) = mapped, code == token else {
                return XCTFail("\(token) must map to UNKNOWN (retention), never success")
            }
        }
        let verification: Set<String> = ["verificationFailed", "semanticNotInspected",
                                         "packageUnreadable", "structureInvalid", "digestMismatch",
                                         "sizeMismatch", "ambiguousArtifact"]
        for token in verification {
            if case .verificationFailed = OfficeAIHostReply.failureError(code: token, detail: nil) {
                continue
            }
            return XCTFail("\(token) must map to a verification failure")
        }
        // Unknown tokens totalize to a transport-shaped refusal:
        if case .transport = OfficeAIHostReply.failureError(code: "madeUpToken", detail: nil) {}
        else { XCTFail("unknown tokens must remain failures") }
    }
}

// MARK: - Synthetic ZIP fixtures (stored entries; the parser reads the
// central directory only, so CRC values are placeholders by construction)

final class OfficeAIPackageStructureTests: XCTestCase {

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8(value >> 8)]
    }
    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8(value >> 8), UInt8(value >> 16), UInt8(value >> 24)]
    }

    private func buildZip(entries: [(name: String, method: UInt16, flags: UInt16)],
                          corruptEOCD: Bool = false) -> Data {
        var local = Data()
        var central = Data()
        var offset = 0
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            var header: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
            header += Self.le16(20) + Self.le16(entry.flags) + Self.le16(entry.method)
            header += Self.le16(0) + Self.le16(0)               // time/date
            header += Self.le32(0)                              // crc placeholder
            header += Self.le32(0) + Self.le32(0)               // sizes (empty entries)
            header += Self.le16(UInt16(nameBytes.count)) + Self.le16(0)
            local.append(contentsOf: header)
            local.append(contentsOf: nameBytes)
            var cd: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
            cd += Self.le16(20) + Self.le16(20) + Self.le16(entry.flags) + Self.le16(entry.method)
            cd += Self.le16(0) + Self.le16(0)
            cd += Self.le32(0) + Self.le32(0) + Self.le32(0)
            cd += Self.le16(UInt16(nameBytes.count)) + Self.le16(0) + Self.le16(0)
            cd += Self.le16(0) + Self.le16(0) + Self.le32(0)
            cd += Self.le32(UInt32(offset))
            central.append(contentsOf: cd)
            central.append(contentsOf: nameBytes)
            offset += header.count + nameBytes.count
        }
        var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        eocd += Self.le16(0) + Self.le16(0)
        eocd += Self.le16(UInt16(entries.count)) + Self.le16(UInt16(entries.count))
        eocd += Self.le32(UInt32(central.count))
        eocd += Self.le32(UInt32(offset))
        eocd += Self.le16(0)
        var out = local + central
        if corruptEOCD {
            out.append(Data([0x50, 0x4B, 0x09, 0x06]))   // wrong signature at the tail
            out.append(Data(repeating: 0, count: 18))
        } else {
            out.append(Data(eocd))
        }
        return out
    }

    private func writeTemporary(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-ai-\(UUID().uuidString.prefix(8))-\(name)")
        try data.write(to: url)
        return url
    }

    func testHappyPathsPerFamily() throws {
        let docx = buildZip(entries: [("word/document.xml", 8, 0), ("[Content_Types].xml", 8, 0),
                                       ("_rels/.rels", 8, 0)])
        let xlsx = buildZip(entries: [("xl/workbook.xml", 8, 0), ("xl/worksheets/sheet1.xml", 8, 0),
                                       ("[Content_Types].xml", 8, 0), ("_rels/.rels", 8, 0)])
        let pptx = buildZip(entries: [("ppt/presentation.xml", 8, 0), ("ppt/slides/slide1.xml", 8, 0),
                                       ("[Content_Types].xml", 8, 0), ("_rels/.rels", 8, 0)])
        for (data, family) in [(docx, "docx"), (xlsx, "xlsx"), (pptx, "pptx")] {
            let url = try writeTemporary(data, name: "\(family).zip")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(OfficeAIPackageStructure.hasZipMagic(url))
            XCTAssertNoThrow(try OfficeAIPackageStructure.verifyPackage(url: url, family: family))
        }
    }

    func testStructuralRefusalsAreTyped() throws {
        // missing required part
        let bad = buildZip(entries: [("[Content_Types].xml", 8, 0), ("_rels/.rels", 8, 0)])
        let badURL = try writeTemporary(bad, name: "missing.docx")
        defer { try? FileManager.default.removeItem(at: badURL) }
        XCTAssertThrowsError(try OfficeAIPackageStructure.verifyPackage(url: badURL, family: "docx")) { error in
            guard case OfficeAIPackageStructure.Failure.malformedEntry = error else {
                return XCTFail("\(error)")
            }
        }
        // no EOCD at all
        let none = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 64)
        let noneURL = try writeTemporary(none, name: "noeocd.docx")
        defer { try? FileManager.default.removeItem(at: noneURL) }
        XCTAssertThrowsError(try OfficeAIPackageStructure.verifyPackage(url: noneURL, family: "docx"))
        // encrypted entry
        let encrypted = buildZip(entries: [("word/document.xml", 8, 1), ("[Content_Types].xml", 8, 0),
                                            ("_rels/.rels", 8, 0)])
        let encURL = try writeTemporary(encrypted, name: "enc.docx")
        defer { try? FileManager.default.removeItem(at: encURL) }
        XCTAssertThrowsError(try OfficeAIPackageStructure.verifyPackage(url: encURL, family: "docx")) { error in
            guard case OfficeAIPackageStructure.Failure.encryptedEntries = error else {
                return XCTFail("\(error)")
            }
        }
        // unsupported compression method
        let bz = buildZip(entries: [("word/document.xml", 12, 0), ("[Content_Types].xml", 8, 0),
                                     ("_rels/.rels", 8, 0)])
        let bzURL = try writeTemporary(bz, name: "bz.docx")
        defer { try? FileManager.default.removeItem(at: bzURL) }
        XCTAssertThrowsError(try OfficeAIPackageStructure.verifyPackage(url: bzURL, family: "docx")) { error in
            guard case OfficeAIPackageStructure.Failure.unsupportedCompression = error else {
                return XCTFail("\(error)")
            }
        }
        // unknown family token is a refusal, never a guess
        XCTAssertThrowsError(try OfficeAIPackageStructure.verifyPackage(url: encURL, family: "pdf"))
    }

    func testDirectoryAndOversizeGuards() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-ai-dir-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try OfficeAIPackageStructure.readCentralDirectory(of: dir)) { error in
            guard case OfficeAIPackageStructure.Failure.notRegularFile = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertFalse(OfficeAIPackageStructure.hasZipMagic(dir))
    }

    // MARK: - CAPTURE_BASELINE addendum (Main 2026-10-27)

    func testCaptureBaselineFactsDecodeFromCommandFacts() {
        let bridge = OfficeAIHostBridge(transport: DeadOfficeTransport(),
                                        store: OfficeAIEditContextStore())
        let command = bridge.decodeCommand(
            ["state": "queryObserved", "targetHandle": String(repeating: "f", count: 32),
             "facts": ["docType": "calc", "partIndex": 1,
                       "captureWorkingCopySha256": String(repeating: "b", count: 64),
                       "captureWorkingCopyBytes": 4321]],
            identity: "seed-cap")
        XCTAssertEqual(command.state, .queryObserved)
        XCTAssertEqual(command.facts.captureWorkingCopySha256, String(repeating: "b", count: 64))
        XCTAssertEqual(command.facts.captureWorkingCopyBytes, 4321)
        let sparse = bridge.decodeCommand(
            ["state": "queryObserved", "targetHandle": String(repeating: "f", count: 32),
             "facts": ["docType": "calc"]],
            identity: "seed-sparse")
        XCTAssertNil(sparse.facts.captureWorkingCopySha256)
        XCTAssertNil(sparse.facts.captureWorkingCopyBytes)
    }

    /// A = the immutable ORIGINAL staged snapshot (CAS base). B = the ACTUAL
    /// native captured flushed working copy after a manual edit + capture
    /// flush. The stored/returned context and every later live pre-edit /
    /// durable ownedV2Target baseline MUST bind B; the original CAS base
    /// stays A. A missing capture digest refuses — never a silent A fallback.
    func testCaptureBaselineBindsActualNativeCaptureNotInitialStage() throws {
        let bridge = OfficeAIHostBridge(transport: DeadOfficeTransport(),
                                        store: OfficeAIEditContextStore())
        let initialA = String(repeating: "a", count: 64)
        let capturedB = String(repeating: "b", count: 64)
        let staged = OfficeAIHostBridge.HostDocumentSnapshot(
            facts: OfficeEditDocumentFacts(
                sessionToken: "sess-cap", nativeGeneration: 7, viewerIncarnation: 1,
                hostGeneration: "9", nativeEpoch: "77", ownerTaskID: UUID(), workspaceID: UUID(),
                sourceLogicalPath: "docs/book.xlsx", sourceID: "src-1", sourceRevision: "rev-9",
                family: .xlsx, editable: true,
                originalSnapshotSha256: initialA, originalSnapshotBytes: 100,
                workingCopySha256: initialA, workingCopyBytes: 100,
                displayName: "book.xlsx", route: .workspace),
            editStateName: nil, editPermissionEstablished: false, openedNow: false)
        // The engine attests the CURRENT captured flushed bytes (B ≠ A).
        let capture = OfficeEditCommandResult(
            state: .queryObserved, attestation: "capture",
            targetHandle: String(repeating: "f", count: 32),
            facts: OfficeEditQueryFacts(docType: "calc", partIndex: 1,
                                        captureWorkingCopySha256: capturedB,
                                        captureWorkingCopyBytes: 120))
        let derived = try bridge.captureBaselineDocument(snapshot: staged, capture: capture)
        XCTAssertEqual(derived.workingCopySha256, capturedB,
                       "the CURRENT baseline is the ACTUAL native capture (B)")
        XCTAssertEqual(derived.workingCopyBytes, 120)
        XCTAssertEqual(derived.originalSnapshotSha256, initialA,
                       "the ORIGINAL CAS base stays the immutable staged snapshot (A)")
        XCTAssertEqual(derived.sourceRevision, "rev-9", "opaque source revision unchanged")
        XCTAssertEqual(derived.sourceID, "src-1", "source identity unchanged")
        XCTAssertEqual(derived.sessionToken, "sess-cap", "captured target identity unchanged")
        XCTAssertEqual(derived.nativeGeneration, 7, "native generation unchanged")
    }

    func testCaptureBaselineRefusesMissingOrUnprovableCaptureDigest() {
        let bridge = OfficeAIHostBridge(transport: DeadOfficeTransport(),
                                        store: OfficeAIEditContextStore())
        let initialA = String(repeating: "a", count: 64)
        func stagedSnapshot() -> OfficeAIHostBridge.HostDocumentSnapshot {
            OfficeAIHostBridge.HostDocumentSnapshot(
                facts: OfficeEditDocumentFacts(
                    sessionToken: "sess-cap", nativeGeneration: 7, viewerIncarnation: 1,
                    hostGeneration: "9", nativeEpoch: "77", ownerTaskID: UUID(), workspaceID: UUID(),
                    sourceLogicalPath: "docs/book.xlsx", sourceID: nil, sourceRevision: nil,
                    family: .xlsx, editable: true,
                    originalSnapshotSha256: initialA, originalSnapshotBytes: 100,
                    workingCopySha256: initialA, workingCopyBytes: 100,
                    displayName: "book.xlsx", route: .workspace),
                editStateName: nil, editPermissionEstablished: false, openedNow: false)
        }
        func expectRefusal(_ facts: OfficeEditQueryFacts, _ label: String) {
            let capture = OfficeEditCommandResult(
                state: .queryObserved, attestation: "capture",
                targetHandle: String(repeating: "f", count: 32), facts: facts)
            XCTAssertThrowsError(try bridge.captureBaselineDocument(snapshot: stagedSnapshot(),
                                                                    capture: capture),
                                 label) { error in
                guard case OfficeEditHostError.unknown(let code, _) = error else {
                    return XCTFail("\(label): expected captureBaselineUnproven, got \(error)")
                }
                XCTAssertEqual(code, "captureBaselineUnproven")
            }
        }
        // Absent capture digest: NO fallback to the initial-stage staged hash.
        expectRefusal(OfficeEditQueryFacts(docType: "calc", partIndex: 1), "missing digest")
        // Malformed digest (not lowercase 64-hex).
        expectRefusal(OfficeEditQueryFacts(docType: "calc", partIndex: 1,
                                           captureWorkingCopySha256: "ZZZ",
                                           captureWorkingCopyBytes: 10), "malformed digest")
        // Missing byte count.
        expectRefusal(OfficeEditQueryFacts(docType: "calc", partIndex: 1,
                                           captureWorkingCopySha256: String(repeating: "b", count: 64)),
                      "missing bytes")
        // Non-positive bytes.
        expectRefusal(OfficeEditQueryFacts(docType: "calc", partIndex: 1,
                                           captureWorkingCopySha256: String(repeating: "b", count: 64),
                                           captureWorkingCopyBytes: 0), "zero bytes")
        // Over the 256 MiB capture bound.
        expectRefusal(OfficeEditQueryFacts(docType: "calc", partIndex: 1,
                                           captureWorkingCopySha256: String(repeating: "b", count: 64),
                                           captureWorkingCopyBytes: 256 * 1024 * 1024 + 1),
                      "oversize bytes")
    }
}
