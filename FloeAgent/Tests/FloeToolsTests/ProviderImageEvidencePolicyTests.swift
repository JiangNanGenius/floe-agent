import Foundation
import Testing
@testable import FloeCore
@testable import FloeTools

// FloeToolsTests — Shared provider image-evidence policy + MCP image
// extraction. Real tiny images (decodable 2x1 PNG/JPEG/WebP/GIF generated
// with an image encoder) exercise the actual MIME/byte path; spoofed,
// over-limit and duplicate payloads are covered explicitly.

@Suite("Provider image evidence policy + MCP images")
struct ProviderImageEvidencePolicyTests {
    // Real, decodable 2x1 images.
    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DAwPAfAAcAAf9+CLHQAAAAAElFTkSuQmCC"
    static let jpegBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5q1b/AJCt3/13f/0I0UUV/XWT/wDIvof4I/8ApKPMzX/fq3+KX5s//9k="
    static let webpBase64 = "UklGRh4AAABXRUJQVlA4TBEAAAAvAQAAAA8Q87//8x8OMqL/AQA="
    static let gifBase64 = "R0lGODdhAgABAIEAAP8AAAAA/wAAAAAAACwAAAAAAgABAAAIBQABBAgIADs="

    @Test func canonicalMIMEAndExtensionMapping() {
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("IMAGE/PNG") == "image/png")
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("image/jpg") == "image/jpeg")
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("image/webp") == "image/webp")
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("image/gif") == "image/gif")
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("image/heic") == nil)
        #expect(ProviderImageEvidencePolicy.canonicalMIMEType("video/mp4") == nil)
        #expect(ProviderImageEvidencePolicy.fileExtension(forMIME: "image/jpeg") == "jpg")
    }

    @Test func eachSupportedFormatValidatesWithRealBytes() {
        let cases: [(String, String)] = [
            ("image/png", Self.pngBase64),
            ("image/jpeg", Self.jpegBase64),
            ("image/webp", Self.webpBase64),
            ("image/gif", Self.gifBase64)
        ]
        for (mime, base64) in cases {
            guard case .valid(let canonical, let data) = ProviderImageEvidencePolicy.validate(
                declaredMIME: mime, base64: base64
            ) else {
                Issue.record("expected \(mime) to validate")
                continue
            }
            #expect(canonical == mime)
            #expect(data.count > 0)
            #expect(ProviderImageEvidencePolicy.sniffedMIME(data) == mime)
        }
    }

    @Test func mimeSpoofIsRejectedFromTheActualBytes() {
        // GIF bytes declared as PNG must never pass.
        let validation = ProviderImageEvidencePolicy.validate(
            declaredMIME: "image/png", base64: Self.gifBase64
        )
        #expect(validation == .mimeMismatch(declared: "image/png", actual: "image/gif"))
        #expect(ProviderImageEvidencePolicy.rejectionReason(validation)?.contains("image/gif") == true)
        // WebP bytes declared as JPEG.
        let second = ProviderImageEvidencePolicy.validate(
            declaredMIME: "image/jpeg", base64: Self.webpBase64
        )
        #expect(second == .mimeMismatch(declared: "image/jpeg", actual: "image/webp"))
    }

    @Test func unsupportedAndMalformedPayloadsHaveExplicitReasons() {
        #expect(ProviderImageEvidencePolicy.validate(
            declaredMIME: "image/heic", base64: Self.pngBase64
        ) == .unsupportedType("image/heic"))
        // "hello" decodes but is not an image.
        #expect(ProviderImageEvidencePolicy.validate(
            declaredMIME: "image/png", base64: "aGVsbG8="
        ) == .unrecognizedBytes)
        #expect(ProviderImageEvidencePolicy.rejectionReason(.unrecognizedBytes) != nil)
    }

    @Test func overLimitIsRejectedBeforeDecodingTheWholePayload() {
        // A 4 KiB base64 payload with a 1 KiB decoded limit must fail on the
        // ENCODED length check (no full decode).
        let chunk = String(repeating: "A", count: 4_096)
        let validation = ProviderImageEvidencePolicy.validate(
            declaredMIME: "image/png", base64: chunk, decodedLimit: 1_024
        )
        if case .overLimit = validation {} else {
            Issue.record("expected overLimit, got \(validation)")
        }
        // The boundary math never under-estimates the decoded size.
        let limit = 8 * 1_024 * 1_024
        #expect(ProviderImageEvidencePolicy.maximumEncodedLength(decodedLimit: limit) >= (limit * 4 + 2) / 3)
    }
}

@Suite("MCP image extraction")
struct MCPImageArtifactTests {
    private func makeResult(_ items: [[String: Any]]) -> [String: Any] {
        ["content": items]
    }

    @Test func supportsAllProviderFormatsAndRejectsSpoofAndOverLimitWithReasons() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = makeResult([
            ["type": "image", "mimeType": "image/png", "data": ProviderImageEvidencePolicyTests.pngBase64],
            ["type": "image", "mimeType": "image/webp", "data": ProviderImageEvidencePolicyTests.webpBase64],
            ["type": "image", "mimeType": "image/gif", "data": ProviderImageEvidencePolicyTests.gifBase64],
            ["type": "image", "mimeType": "image/jpeg", "data": ProviderImageEvidencePolicyTests.jpegBase64],
            // Spoofed MIME: GIF bytes declared PNG.
            ["type": "image", "mimeType": "image/png", "data": ProviderImageEvidencePolicyTests.gifBase64],
            // Unsupported MIME.
            ["type": "image", "mimeType": "image/tiff", "data": ProviderImageEvidencePolicyTests.pngBase64]
        ])
        let (artifacts, rejections) = MCPRemoteClient.imageArtifacts(from: result, root: root)
        #expect(artifacts.map(\.mimeType).sorted() == ["image/gif", "image/jpeg", "image/png", "image/webp"])
        #expect(rejections.count == 2)
        #expect(rejections.contains { $0.contains("image/gif") })
        #expect(rejections.contains { $0.contains("unsupported image type image/tiff") })
        // The retained bytes re-verify against the artifact digest.
        for artifact in artifacts {
            let data = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
            #expect(FloeDigest.sha256Hex(data) == artifact.sha256)
            #expect(ProviderImageEvidencePolicy.sniffedMIME(data) == artifact.mimeType)
        }
    }

    @Test func duplicateImagesAttachOnceAndTwoResultsBothAttach() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // One result with the same image twice attaches once.
        let duplicateResult = makeResult([
            ["type": "image", "mimeType": "image/png", "data": ProviderImageEvidencePolicyTests.pngBase64],
            ["type": "image", "mimeType": "image/png", "data": ProviderImageEvidencePolicyTests.pngBase64]
        ])
        let (duplicates, rejections) = MCPRemoteClient.imageArtifacts(from: duplicateResult, root: root)
        #expect(duplicates.count == 1)
        #expect(rejections.isEmpty)
        // TWO tool results each carrying one image both attach (attribution):
        // distinct digests/destinations, verified independently.
        let first = makeResult([["type": "image", "mimeType": "image/png", "data": ProviderImageEvidencePolicyTests.pngBase64]])
        let second = makeResult([["type": "image", "mimeType": "image/jpeg", "data": ProviderImageEvidencePolicyTests.jpegBase64]])
        let (firstArtifacts, _) = MCPRemoteClient.imageArtifacts(from: first, root: root)
        let (secondArtifacts, _) = MCPRemoteClient.imageArtifacts(from: second, root: root)
        #expect(firstArtifacts.count == 1)
        #expect(secondArtifacts.count == 1)
        #expect(firstArtifacts[0].sha256 != secondArtifacts[0].sha256)
        #expect(firstArtifacts[0].relativePath != secondArtifacts[0].relativePath)
    }
}
