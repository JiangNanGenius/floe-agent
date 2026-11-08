// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools

@Suite("Native synthesized-audio reference boundary")
struct ChatInlineAudioCatalogTests {
    @Test func onlyTheActualAudioProducerContractIsAdvertised() throws {
        let run = UUID(), file = UUID(uuidString: "A1234567-89AB-4CDE-8FAB-123456789ABC")!, id = UUID(), task = UUID()
        let ref = ToolArtifactReference(id: id, relativePath: "ChangeArtifacts/\(run)/\(file.uuidString.lowercased()).html",
            mimeType: "text/html", byteCount: 800, sha256: FloeDigest.sha256Hex(Data("native audio factory".utf8)))
        let result = ToolResult(callID: "speech", status: .ok, outputSummary: "generated", outputDigest: ref.sha256, artifacts: [ref],
            provenance: .init(sourceID: "runtime", toolName: "audio.synthesize", runID: run, taskID: task))
        let saved = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
        let item = try #require(ChatInlineContentCatalog.descriptors(saved).first)
        #expect(item.title == "Audio preview" && item.reference.ownerID == run && item.reference.contentID == id.uuidString)
        #expect(item.inlineMarkdown.contains("floe-content://artifact/"))
        for tool in ["mcp.example.audio.synthesize", "exec.shell", "document.presentation.createInline"] {
            #expect(!ChatInlineContentCatalog.accepts(ref, runID: run, tool: tool))
        }
        #expect(!ChatInlineContentCatalog.accepts(ref, runID: UUID(), tool: "audio.synthesize"))
        for path in ["ChangeArtifacts/\(run)/\(file).html", "ChangeArtifacts/\(run)/player.html",
                     "PresentationArtifacts/\(run)/\(file.uuidString.lowercased()).html", "ChangeArtifacts/\(run)/../player.html"] {
            var changed = ref; changed.relativePath = path
            #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, tool: "audio.synthesize"))
        }
        var changed = ref; changed.byteCount = 1_000_001
        #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, tool: "audio.synthesize"))
        changed = ref; changed.mimeType = "audio/wav"
        #expect(!ChatInlineContentCatalog.accepts(changed, runID: run, tool: "audio.synthesize"))
    }
}
