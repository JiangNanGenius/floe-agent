// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeTools

@Suite("Native inline-content result advertisement")
struct ChatInlineContentCatalogTests {
    @Test("Native CAD image contracts advertise original run identities across saved receipt decoding")
    func nativeCADImagesAdvertiseAfterReceiptRoundTrip() throws {
        let run = UUID(), task = UUID(), digest = FloeDigest.sha256Hex(Data("bounded CAD image contract".utf8))
        for (namespace, mime, ext) in [("CADViewportArtifacts", "image/png", "png"),
            ("EngineeringObservations", "image/png", "png"), ("CADAnimationFrames", "image/png", "png"),
            ("CADAnimationFrames", "image/jpeg", "jpg")] {
            let artifact = ToolArtifactReference(id: UUID(), relativePath: "\(namespace)/\(run)/\(digest).\(ext)",
                mimeType: mime, byteCount: 64, sha256: digest)
            let original = ToolResult(callID: "native-cad-frame", status: .ok, outputSummary: "actual CAD capture contract",
                outputDigest: digest, artifacts: [artifact], provenance: .init(sourceID: "runtime", toolName: "cad.document", runID: run, taskID: task))
            let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(original))
            let descriptor = try #require(ChatInlineContentCatalog.descriptors(restored).first)
            #expect(descriptor.reference.ownerID == run)
            #expect(descriptor.reference.contentID == artifact.id.uuidString)
            #expect(descriptor.mimeType == mime)
            #expect(ChatInlineContentCatalog.wireItems([descriptor])[0]["inlineMarkdown"] == descriptor.inlineMarkdown)
        }
    }

    @Test("CAD admission cannot adopt another producer, run, filename, MIME type or oversized capture")
    func nativeCADImagesKeepProducerAndNamespaceBoundary() {
        let run = UUID(), digest = FloeDigest.sha256Hex(Data("CAD contract".utf8))
        let original = ToolArtifactReference(id: UUID(), relativePath: "CADViewportArtifacts/\(run)/\(digest).png",
            mimeType: "image/png", byteCount: 64, sha256: digest)
        #expect(ChatInlineContentCatalog.accepts(original, runID: run, tool: "cad.document"))
        #expect(!ChatInlineContentCatalog.accepts(original, runID: UUID(), tool: "cad.document"))
        #expect(!ChatInlineContentCatalog.accepts(original, runID: run, tool: "mcp.example.cad.document"))
        for path in ["GeneratedImages/\(run)/\(digest).png", "BrowserArtifacts/\(run)/\(digest).png",
                     "CADViewportArtifacts/\(run)/other.png", "CADViewportArtifacts/\(run)/../\(digest).png",
                     "CADAnimationFrames/\(run)/\(digest).jpg", "EngineeringObservations/\(run)/\(digest).jpg"] {
            var changed = original; changed.relativePath = path
            #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, tool: "cad.document"))
        }
        var oversized = original; oversized.byteCount = 16 * 1_024 * 1_024 + 1
        #expect(!ChatInlineContentCatalog.accepts(oversized, runID: run, tool: "cad.document"))
        var wrongMIME = original; wrongMIME.mimeType = "image/jpeg"
        #expect(!ChatInlineContentCatalog.accepts(wrongMIME, runID: run, tool: "cad.document"))
        var result = ToolResult(callID: "cad", status: .failed, outputSummary: "failed", outputDigest: digest, artifacts: [original],
            provenance: .init(sourceID: "runtime", toolName: "cad.document", runID: run, taskID: UUID()))
        #expect(ChatInlineContentCatalog.descriptors(result).isEmpty)
        result.status = .ok; result.outcomeUnknown = true
        #expect(ChatInlineContentCatalog.descriptors(result).isEmpty)
        result.outcomeUnknown = false; result.ephemeralSensitiveOutput = "transient"
        #expect(ChatInlineContentCatalog.descriptors(result).isEmpty)
    }
    @Test("Native Office, iOS Bridge and post-action screenshots keep their receipt identities")
    func nativeReadAndPostActionImagesAdvertiseAfterReceiptRoundTrip() throws {
        let run = UUID(), task = UUID(), id = UUID()
        let digest = FloeDigest.sha256Hex(Data("native image producer contract".utf8))
        var cases: [(tool: String, path: String, mime: String)] = [
            ("notes.read", "GeneratedImages/office-region-\(id).png", "image/png"),
            ("ios.bridge.observe", "VNCArtifacts/\(id).png", "image/png"),
            ("ios.bridge.observe", "VNCArtifacts/\(id).jpg", "image/jpeg"),
            ("browser.clickPoint", "BrowserArtifacts/\(id).jpg", "image/jpeg"),
            ("browser.clickVisualText", "BrowserArtifacts/\(id).jpg", "image/jpeg")
        ]
        cases += ["vnc.clickElement", "vnc.click", "vnc.typeText", "vnc.scroll", "vnc.drag", "vnc.keyPress"].map {
            (tool: $0, path: "VNCArtifacts/\(id).jpg", mime: "image/jpeg")
        }
        for item in cases {
            let artifact = ToolArtifactReference(id: id, relativePath: item.path, mimeType: item.mime, byteCount: 64, sha256: digest)
            let original = ToolResult(callID: "native-observation", status: .ok, outputSummary: "native observation contract",
                outputDigest: digest, artifacts: [artifact], provenance: .init(sourceID: "runtime", toolName: item.tool, runID: run, taskID: task))
            let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(original))
            let descriptors = ChatInlineContentCatalog.descriptors(restored)
            #expect(descriptors.count == 1)
            let descriptor = try #require(descriptors.first)
            #expect(descriptor.reference.ownerID == run && descriptor.reference.contentID == id.uuidString)
            #expect(descriptor.mimeType == item.mime)
            #expect(ChatInlineContentCatalog.wireItems(descriptors)[0]["inlineMarkdown"] == descriptor.inlineMarkdown)
        }
    }

    @Test("Native observation producers cannot claim another namespace, file identity or credential/control output")
    func nativeObservationImagesKeepTheirActualProducerContracts() {
        let run = UUID(), id = UUID(), other = UUID()
        let digest = FloeDigest.sha256Hex(Data("native image contract".utf8))
        let invalid: [(tool: String, path: String, mime: String)] = [
            ("notes.read", "GeneratedImages/\(id).png", "image/png"),
            ("notes.read", "GeneratedImages/office-region-\(other).png", "image/png"),
            ("notes.read", "GeneratedImages/office-region-\(id).png", "image/jpeg"),
            ("ios.bridge.control", "VNCArtifacts/\(id).png", "image/png"),
            ("mcp.example.ios.bridge.observe", "VNCArtifacts/\(id).png", "image/png"),
            ("ios.bridge.observe", "VNCArtifacts/\(other).png", "image/png"),
            ("ios.bridge.observe", "BrowserArtifacts/\(id).png", "image/png"),
            ("ios.bridge.observe", "VNCArtifacts/\(id).png", "image/jpeg"),
            ("vnc.typeCredential", "VNCArtifacts/\(id).jpg", "image/jpeg"),
            ("vnc.click", "GeneratedImages/\(id).jpg", "image/jpeg"),
            ("vnc.click", "VNCArtifacts/\(other).jpg", "image/jpeg"),
            ("vnc.click", "VNCArtifacts/\(id).png", "image/png"),
            ("browser.click", "BrowserArtifacts/\(id).jpg", "image/jpeg"),
            ("browser.type", "BrowserArtifacts/\(id).jpg", "image/jpeg"),
            ("browser.clickPoint", "VNCArtifacts/\(id).jpg", "image/jpeg"),
            ("browser.clickVisualText", "BrowserArtifacts/\(other).jpg", "image/jpeg"),
            ("browser.clickPoint", "BrowserArtifacts/\(id).png", "image/png")
        ]
        for item in invalid {
            let artifact = ToolArtifactReference(id: id, relativePath: item.path, mimeType: item.mime, byteCount: 64, sha256: digest)
            #expect(!ChatInlineContentCatalog.accepts(artifact, runID: run, tool: item.tool))
        }
        for (tool, path, mime, limit) in [
            ("notes.read", "GeneratedImages/office-region-\(id).png", "image/png", ProviderImageEvidencePolicy.maximumImageBytes),
            ("browser.clickPoint", "BrowserArtifacts/\(id).jpg", "image/jpeg", 8 * 1_024 * 1_024),
            ("vnc.click", "VNCArtifacts/\(id).jpg", "image/jpeg", VerifiedToolImageArtifact.maximumStoredImageBytes),
            ("ios.bridge.observe", "VNCArtifacts/\(id).png", "image/png", VerifiedToolImageArtifact.maximumStoredImageBytes)
        ] {
            let artifact = ToolArtifactReference(id: id, relativePath: path, mimeType: mime, byteCount: limit + 1, sha256: digest)
            #expect(!ChatInlineContentCatalog.accepts(artifact, runID: run, tool: tool))
        }
    }
    @Test func aLargeUnicodeCatalogKeepsCompleteJSONAndItsRetryCursor() throws {
        let descriptors = (0..<128).map { _ in
            ChatContentDescriptor(reference: ChatContentReference(kind: .artifact, ownerID: UUID(), contentID: UUID().uuidString)!,
                mimeType: "application/vnd.floe.chart+json", title: String(repeating: "图表说明", count: 100))
        }
        let pages = [["runID": UUID().uuidString, "startAfterSequence": "40", "nextAfterSequence": "90"]]
        let data = try ChatInlineContentCatalog.listingData(descriptors, pages: pages)
        #expect(data.count <= 60 * 1_024)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(value["contents"] as? [[String: String]])
        #expect(!contents.isEmpty && contents.count < descriptors.count)
        #expect(value["truncated"] as? Bool == true)
        #expect(value["pages"] as? [[String: String]] == pages)
        #expect(contents.allSatisfy { item in descriptors.contains { $0.inlineMarkdown == item["inlineMarkdown"] } })
        let complete = try ChatInlineContentCatalog.listingData(Array(descriptors.prefix(1)), pages: pages)
        let one = try #require(JSONSerialization.jsonObject(with: complete) as? [String: Any])
        #expect(one["truncated"] as? Bool == false)
    }
    @Test func successfulNativeChartAdvertisesCopyableMarkdownAndFailuresDoNot() throws {
        let run = UUID(), task = UUID(), id = UUID()
        let artifact = ToolArtifactReference(id: id,
            relativePath: "PresentationArtifacts/\(run)/\(id).chart.json", mimeType: "application/vnd.floe.chart+json",
            byteCount: 2, sha256: FloeDigest.sha256Hex(Data("{}".utf8)))
        var result = ToolResult(callID: "call", status: .ok, outputSummary: "created", outputDigest: artifact.sha256, artifacts: [artifact],
            provenance: .init(sourceID: "runtime", toolName: "document.presentation.createInline", runID: run, taskID: task))
        let descriptors = ChatInlineContentCatalog.descriptors(result)
        let wire = try #require(ChatInlineContentCatalog.wireItems(descriptors).first)
        #expect(wire["inlineMarkdown"] == "![Chart](floe-content://artifact/\(run)/\(id))")
        #expect(wire["mimeType"] == artifact.mimeType)
        result.status = .failed
        #expect(ChatInlineContentCatalog.descriptors(result).isEmpty)
        result.status = .ok; result.ephemeralSensitiveOutput = "transient"
        #expect(ChatInlineContentCatalog.descriptors(result).isEmpty)
    }
    @Test func externalToolsAndQuotedPathsCannotMintNativeReferences() {
        let run = UUID(), id = UUID()
        var artifact = ToolArtifactReference(id: id, relativePath: "PresentationArtifacts/\(run)/\(id).table.json",
            mimeType: "application/vnd.floe.table+json", byteCount: 2, sha256: FloeDigest.sha256Hex(Data("{}".utf8)))
        #expect(!ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "mcp.example.createInline"))
        #expect(!ChatInlineContentCatalog.accepts(artifact, runID: UUID(), tool: "document.presentation.createInline"))
        artifact.relativePath = "/etc/passwd"
        #expect(!ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "document.presentation.createInline"))
        artifact.relativePath = "PresentationArtifacts/../private.html"
        artifact.mimeType = "text/html"
        #expect(!ChatInlineContentCatalog.accepts(artifact, runID: run, tool: "document.presentation.createInline"))
    }
}
