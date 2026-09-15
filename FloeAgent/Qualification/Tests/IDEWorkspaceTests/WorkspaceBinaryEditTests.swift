// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeWorkspace

@Suite("Managed binary document commits")
struct WorkspaceBinaryEditTests {
    @Test func successfulCommitRetainsExactPreviousBytes() throws {
        try withWorkspace { root, service in
            let original = Data([0x41, 0x43, 0, 255, 13, 10])
            let draft = Data([0x41, 0x43, 1, 255, 13, 10])
            try original.write(to: root.appendingPathComponent("plan.dwg"))
            let sha = try service.metadata("plan.dwg").sha256
            let result = try service.commitBinaryEdit(path: "plan.dwg", data: draft, expectedSHA256: sha)
            #expect(try Data(contentsOf: root.appendingPathComponent("plan.dwg")) == draft)
            #expect(try Data(contentsOf: root.appendingPathComponent(result.previousVersionPath)) == original)
            #expect(result.write.bytesWritten == draft.count)
        }
    }
    @Test func concurrentEditAndDeletedOriginalRetainDraftWithoutOverwrite() throws {
        for remove in [false, true] {
            try withWorkspace { root, service in
                let url = root.appendingPathComponent("plan.dwg")
                try Data("base".utf8).write(to: url)
                let sha = try service.metadata("plan.dwg").sha256
                if remove { try FileManager.default.removeItem(at: url) }
                else { try Data("agent version".utf8).write(to: url) }
                do {
                    _ = try service.commitBinaryEdit(path: "plan.dwg", data: Data("my version".utf8), expectedSHA256: sha)
                    Issue.record("A stale binary editor overwrote a changed document")
                } catch let conflict as WorkspaceBinaryEditConflict {
                    #expect(try Data(contentsOf: root.appendingPathComponent(conflict.recoveryPath)) == Data("my version".utf8))
                    if remove { #expect(!FileManager.default.fileExists(atPath: url.path)) }
                    else { #expect(try String(contentsOf: url, encoding: .utf8) == "agent version") }
                }
            }
        }
    }
    @Test func pathsAndMissingBaselineAreRejected() throws {
        try withWorkspace { root, service in
            #expect(throws: Error.self) { try service.commitBinaryEdit(path: "new.dwg", data: Data(), expectedSHA256: "") }
            #expect(throws: Error.self) { try service.commitBinaryEdit(path: "../outside.dwg", data: Data(), expectedSHA256: String(repeating: "a", count: 64)) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovered Edits").path))
        }
    }
    private func withWorkspace(_ body: (URL, WorkspaceFileService) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
    }
}
