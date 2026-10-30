import Foundation
import Testing
import FloeCore
@testable import FloeTools

struct FoundationPrimitivesTests {
    @Test("A short UI summary retains the complete admitted tool response")
    func fullToolResponseSurvivesSummaryProjection() throws {
        let full = String(decoding: try JSONSerialization.data(withJSONObject: [
            "rows": Array(repeating: "完整参数与结果 mixed text", count: 5000),
            "tail": "RESULT-TAIL-MUST-SURVIVE"
        ]), as: UTF8.self)
        let output = ToolExecutionOutput(digesting: full)
        #expect(output.summary.count == 4096)
        #expect(output.summaryTruncated)
        #expect(output.capturedOutput == full)
        #expect(!output.capturedOutputTruncated)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(full.utf8)))
        let restored = try #require(output.capturedOutput)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any])
        #expect(json["tail"] as? String == "RESULT-TAIL-MUST-SURVIVE")
        let explicit = ToolExecutionOutput(digesting: full, capturedOutput: "explicit sanitized body",
                                           capturedOutputTruncated: true)
        #expect(explicit.capturedOutput == "explicit sanitized body")
        #expect(explicit.capturedOutputTruncated)
        #expect(ToolExecutionOutput(digesting: "short").capturedOutput == nil)
    }

    @Test("Digest matches the standard SHA-256 vector")
    func digestVector() {
        #expect(FloeDigest.sha256Hex(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(FloeDigest.shortSHA256(Data("abc".utf8), length: 8) == "ba7816bf")
    }

    @Test("AtomicFileCommitter refuses an existing destination without consent")
    func committerRefusesOverwrite() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.txt")
        try Data("first".utf8).write(to: destination)
        #expect(throws: Error.self) {
            try AtomicFileCommitter.commit(Data("second".utf8), to: destination)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first")
    }

    @Test("AtomicFileCommitter replaces only with explicit consent")
    func committerReplacesWithConsent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.txt")
        try Data("first".utf8).write(to: destination)
        let receipt = try AtomicFileCommitter.commit(
            Data("second".utf8),
            to: destination,
            policy: FileCommitPolicy(conflict: .replaceAtomically(consent: true))
        )
        #expect(receipt.replacedExisting)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "second")
    }

    @Test("A failed pre-commit verification leaves the destination untouched")
    func committerVerifyFailureIsSafe() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.txt")
        try Data("first".utf8).write(to: destination)
        #expect(throws: Error.self) {
            try AtomicFileCommitter.commit(
                Data("second".utf8),
                to: destination,
                policy: FileCommitPolicy(
                    conflict: .replaceAtomically(consent: true),
                    verifyBeforeCommit: { _ in throw CocoaError(.fileReadCorruptFile) }
                )
            )
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".floe-commit-") }
        #expect(leftovers.isEmpty)
    }

    @Test("ArtifactStore enforces namespaces, containment and digests")
    func artifactStorePolicy() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("GeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let file = artifact.appendingPathComponent("cat.png")
        let bytes = Data("png-bytes".utf8)
        try bytes.write(to: file)

        let resolved = try FloeArtifactStore.resolve(
            "GeneratedImages/cat.png",
            allowed: [.generatedImages],
            maxBytes: 1024,
            root: root
        )
        #expect(resolved.lastPathComponent == "cat.png")
        #expect(throws: Error.self) {
            try FloeArtifactStore.resolve("BrowserArtifacts/x.png", allowed: [.generatedImages], maxBytes: 1024, root: root)
        }
        #expect(throws: Error.self) {
            try FloeArtifactStore.resolve("../GeneratedImages/cat.png", allowed: [.generatedImages], maxBytes: 1024, root: root)
        }
        #expect(throws: Error.self) {
            try FloeArtifactStore.resolve(
                "GeneratedImages/cat.png",
                allowed: [.generatedImages],
                maxBytes: 1024,
                expectedSHA256: String(repeating: "0", count: 64),
                root: root
            )
        }
        let data = try FloeArtifactStore.verifiedData(
            "GeneratedImages/cat.png",
            allowed: [.generatedImages],
            maxBytes: 1024,
            expectedSHA256: FloeDigest.sha256Hex(bytes),
            root: root
        )
        #expect(data == bytes)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-primitives-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
