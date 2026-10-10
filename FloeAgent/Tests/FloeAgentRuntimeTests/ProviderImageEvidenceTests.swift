import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeModels
@testable import FloeProviders
@testable import FloeTools
@testable import FloeCore

// FloeAgentRuntimeTests — Retained tool-artifact images reach the provider
// visual request through the SAME shared policy the MCP extraction uses:
// real PNG/JPEG/WebP/GIF bytes attach with their exact MIME; spoofed bytes,
// over-limit artifacts and path escapes never attach.

@Suite("Retained artifact visual evidence")
struct ProviderImageEvidenceTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DAwPAfAAcAAf9+CLHQAAAAAElFTkSuQmCC")!
    private let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5q1b/AJCt3/13f/0I0UUV/XWT/wDIvof4I/8ApKPMzX/fq3+KX5s//9k=")!
    private let webp = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAQAAAA8Q87//8x8OMqL/AQA=")!
    private let gif = Data(base64Encoded: "R0lGODdhAgABAIEAAP8AAAAA/wAAAAAAACwAAAAAAgABAAAIBQABBAgIADs=")!

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("GeneratedImages", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func artifact(_ data: Data, mime: String, name: String, root: URL) throws -> ToolArtifactReference {
        let relative = "GeneratedImages/\(name)"
        try data.write(to: root.appendingPathComponent(relative), options: .atomic)
        return ToolArtifactReference(
            id: UUID(), relativePath: relative, mimeType: mime,
            byteCount: data.count, sha256: FloeDigest.sha256Hex(data)
        )
    }

    @Test func realImagesAttachWithExactMIME() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(Data, String, String)] = [
            (png, "image/png", "a.png"),
            (jpeg, "image/jpeg", "b.jpg"),
            (webp, "image/webp", "c.webp"),
            (gif, "image/gif", "d.gif")
        ]
        for (data, mime, name) in cases {
            let reference = try artifact(data, mime: mime, name: name, root: root)
            let part = FloeAgentRuntime.providerImageEvidence(reference, root: root)
            guard case .imageData(let attachedMIME, let base64)? = part else {
                Issue.record("expected evidence for \(mime)")
                continue
            }
            #expect(attachedMIME == mime)
            #expect(Data(base64Encoded: base64) == data)
        }
    }

    @Test func spoofedBytesAndOverLimitAndPathEscapesDoNotAttach() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // GIF bytes declared as PNG (sha matches the real bytes, MIME lies).
        let spoof = ToolArtifactReference(
            id: UUID(), relativePath: "GeneratedImages/spoof.png",
            mimeType: "image/png", byteCount: gif.count, sha256: FloeDigest.sha256Hex(gif)
        )
        try gif.write(to: root.appendingPathComponent("GeneratedImages/spoof.png"), options: .atomic)
        #expect(FloeAgentRuntime.providerImageEvidence(spoof, root: root) == nil)
        // Over the inline byte budget: rejected before any read.
        let overLimit = ToolArtifactReference(
            id: UUID(), relativePath: "GeneratedImages/huge.png",
            mimeType: "image/png",
            byteCount: ProviderImageEvidencePolicy.maximumImageBytes + 1,
            sha256: FloeDigest.sha256Hex(png)
        )
        #expect(FloeAgentRuntime.providerImageEvidence(overLimit, root: root) == nil)
        // Path escape and foreign namespace never attach.
        let escape = ToolArtifactReference(
            id: UUID(), relativePath: "GeneratedImages/../secret.png",
            mimeType: "image/png", byteCount: png.count, sha256: FloeDigest.sha256Hex(png)
        )
        #expect(FloeAgentRuntime.providerImageEvidence(escape, root: root) == nil)
        let foreign = ToolArtifactReference(
            id: UUID(), relativePath: "OtherDir/img.png",
            mimeType: "image/png", byteCount: png.count, sha256: FloeDigest.sha256Hex(png)
        )
        #expect(FloeAgentRuntime.providerImageEvidence(foreign, root: root) == nil)
        // Digest mismatch: retained bytes no longer match the artifact.
        let tampered = try artifact(png, mime: "image/png", name: "tampered.png", root: root)
        try Data("tampered".utf8).write(to: root.appendingPathComponent(tampered.relativePath), options: .atomic)
        #expect(FloeAgentRuntime.providerImageEvidence(tampered, root: root) == nil)
    }
}
