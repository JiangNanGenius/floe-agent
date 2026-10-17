// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace

@Suite("User-selected workspace imports")
struct WorkspaceUserImportTests {
    @Test func userImportDoesNotRelaxModelPayloadCap() throws {
        try fixture { root, source, service in
            let bytes = Data(repeating: 71, count: 5 * 1024 * 1024)
            try bytes.write(to: source)
            #expect(throws: WorkspaceToolError.tooLarge(limit: 4 * 1024 * 1024)) {
                try service.createBinaryFile("model.bin", data: bytes, overwrite: false)
            }
            let hash = FloeDigest.sha256Hex(bytes)
            let result = try service.importUserFile(from: source, to: "Attachments/large.pptx", expectedSHA256: hash)
            #expect(result.bytesWritten == bytes.count)
            #expect(result.sha256 == hash)
            #expect(try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("Attachments/large.pptx")) == hash)
            #expect(try FloeDigest.sha256Hex(ofFileAt: source) == hash)
            #expect(throws: Error.self) {
                try service.importUserFile(from: source, to: "Attachments/large.pptx", expectedSHA256: hash)
            }
        }
    }

    @Test func cancellationMismatchFreezeAndUnsafePathsLeaveNoImport() throws {
        try fixture { root, source, service in
            try Data("original".utf8).write(to: source)
            let token = CancellationToken(); token.cancel()
            #expect(throws: Error.self) {
                try service.importUserFile(from: source, to: "cancel.bin", expectedSHA256: nil, cancellation: token)
            }
            #expect(throws: Error.self) {
                try service.importUserFile(from: source, to: "mismatch.bin", expectedSHA256: String(repeating: "0", count: 64))
            }
            #expect(throws: Error.self) {
                try service.importUserFile(from: source, to: "../outside.bin", expectedSHA256: nil)
            }
            let frozen = WorkspaceFileService(guard: service.guardResolver, mutationGuard: { _ in
                throw WorkspaceToolError.invalidArguments("frozen")
            })
            #expect(throws: Error.self) { try frozen.importUserFile(from: source, to: "frozen.bin", expectedSHA256: nil) }
            let link = root.appendingPathComponent("link.bin")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            #expect(throws: Error.self) { try service.importUserFile(from: link, to: "symbolic.bin", expectedSHA256: nil) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
            #expect(throws: Error.self) { try service.importUserFile(from: source, to: "alias/new.bin", expectedSHA256: nil) }
            let inventory = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(Set(inventory) == ["link.bin", "real", "alias"])
        }
    }

    private func fixture(_ body: (URL, URL, WorkspaceFileService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("user-import-" + UUID().uuidString)
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, base.appendingPathComponent("source.bin"), WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
    }
}
