// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused regression for the manual workspace original save
// (OFC-SAVE-REOPEN, job-4c314431dd8348d4). NOT executed by this lane (Main's
// grouped batch compiles and runs it).
//
// The manual save-original lane (G04WorkspaceSourceHost.saveOriginal)
// classifies a post-commit error by inspecting the ACTUAL original bytes
// under the SAME owned lease, reusing OfficeAIHostBridge.classifyOriginalReadback
// — never "throw means untouched". These tests pin that reused contract
// against the REAL production classifier and a REAL temporary
// WorkspaceFileService: saved (replacement landed), untouched (original
// byte-intact), drifted (neither candidate matches — a cooperating writer
// may have changed it) and unreadable (missing/oversize target). The same
// classification drives the Core model path's saveOriginal, so both lanes
// decide post-commit errors byte-identically.

import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

@Suite("Manual original save readback classification")
struct OfficeSaveOriginalReadbackTests {

    private func fixture(
        _ body: (URL, WorkspaceFileService) throws -> Void
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-save-original-" + UUID().uuidString)
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
    }

    private func originalBytes(seed: UInt8, length: Int) -> Data {
        Data((0..<length).map { UInt8((Int(seed) + $0 * 31) & 0xff) })
    }

    @Test func savedWhenActualBytesAreTheVerifiedReplacement() throws {
        try fixture { root, service in
            let original = originalBytes(seed: 3, length: 2048)
            let saved = originalBytes(seed: 11, length: 4096)
            _ = try service.createBinaryFile("report.docx", data: original, overwrite: false)
            try saved.write(to: root.appendingPathComponent("saved.bin"))
            _ = try service.replaceBinaryFile(
                "report.docx", from: root.appendingPathComponent("saved.bin"),
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(saved),
                expectedSourceBytes: saved.count)
            let verdict = OfficeAIHostBridge.classifyOriginalReadback(
                service: service, logicalPath: "report.docx",
                expectedOriginal: FloeDigest.sha256Hex(original),
                expectedSaved: FloeDigest.sha256Hex(saved),
                expectedBytes: Int64(saved.count))
            guard case .saved = verdict else {
                Issue.record("expected .saved, got \(verdict)")
                return
            }
        }
    }

    @Test func untouchedWhenOriginalStillCarriesTheBaseline() throws {
        try fixture { root, service in
            let original = originalBytes(seed: 5, length: 1024)
            _ = try service.createBinaryFile("report.docx", data: original, overwrite: false)
            let saved = originalBytes(seed: 9, length: 2048)
            // The replacement bytes never landed (a pre-write refusal would
            // leave exactly this state); the readback must prove UNTOUCHED,
            // never drifted and never a silent "saved".
            let verdict = OfficeAIHostBridge.classifyOriginalReadback(
                service: service, logicalPath: "report.docx",
                expectedOriginal: FloeDigest.sha256Hex(original),
                expectedSaved: FloeDigest.sha256Hex(saved),
                expectedBytes: Int64(saved.count))
            guard case .untouched = verdict else {
                Issue.record("expected .untouched, got \(verdict)")
                return
            }
        }
    }

    @Test func driftedWhenNeitherCandidateMatchesTheActualBytes() throws {
        try fixture { root, service in
            let original = originalBytes(seed: 7, length: 1024)
            let foreign = originalBytes(seed: 13, length: 1024)
            _ = try service.createBinaryFile("report.docx", data: original, overwrite: false)
            // A cooperating writer (another lane/process) adopted the file:
            // its bytes now match NEITHER the open-time baseline nor the
            // verified replacement we attempted afterwards.
            try foreign.write(to: root.appendingPathComponent("foreign.bin"))
            _ = try service.replaceBinaryFile(
                "report.docx", from: root.appendingPathComponent("foreign.bin"),
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(foreign),
                expectedSourceBytes: foreign.count)
            let saved = originalBytes(seed: 21, length: 512)
            let verdict = OfficeAIHostBridge.classifyOriginalReadback(
                service: service, logicalPath: "report.docx",
                expectedOriginal: FloeDigest.sha256Hex(original),
                expectedSaved: FloeDigest.sha256Hex(saved),
                expectedBytes: Int64(saved.count))
            guard case .drifted = verdict else {
                Issue.record("expected .drifted, got \(verdict)")
                return
            }
        }
    }

    @Test func unreadableWhenTheTargetCannotBeReProved() throws {
        try fixture { _, service in
            // The original never existed: resolve fails / no plain regular
            // file exists to classify against either identity.
            let verdict = OfficeAIHostBridge.classifyOriginalReadback(
                service: service, logicalPath: "missing.docx",
                expectedOriginal: FloeDigest.sha256Hex(originalBytes(seed: 1, length: 8)),
                expectedSaved: FloeDigest.sha256Hex(originalBytes(seed: 2, length: 8)),
                expectedBytes: 8)
            guard case .unreadable = verdict else {
                Issue.record("expected .unreadable, got \(verdict)")
                return
            }
        }
    }

    @Test func byteExactSavedRequiresMatchingSizeToo() throws {
        try fixture { root, service in
            let original = originalBytes(seed: 17, length: 1024)
            let saved = originalBytes(seed: 19, length: 1024)
            _ = try service.createBinaryFile("report.docx", data: original, overwrite: false)
            try saved.write(to: root.appendingPathComponent("saved.bin"))
            _ = try service.replaceBinaryFile(
                "report.docx", from: root.appendingPathComponent("saved.bin"),
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(saved),
                expectedSourceBytes: saved.count)
            // Same digest but a WRONG expected size must not classify as
            // saved: the file size is part of the landed-proof identity, so
            // the classifier honestly lands on .drifted (neither candidate
            // matches the full identity) — never a "saved" claim.
            let wrongSize = OfficeAIHostBridge.classifyOriginalReadback(
                service: service, logicalPath: "report.docx",
                expectedOriginal: FloeDigest.sha256Hex(original),
                expectedSaved: FloeDigest.sha256Hex(saved),
                expectedBytes: Int64(saved.count + 1))
            guard case .drifted = wrongSize else {
                Issue.record("a size mismatch must not read as saved: \(wrongSize)")
                return
            }
        }
    }
}
