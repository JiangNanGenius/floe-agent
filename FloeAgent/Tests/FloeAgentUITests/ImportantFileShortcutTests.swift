#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace
@testable import FloeAgentRuntime
@testable import FloeApp

@Suite("FloeApp important file shortcuts")
struct ImportantFileShortcutTests {
    @Test("workspace paths with spaces survive structured result parsing")
    @MainActor
    func pathsWithSpaces() {
        #expect(ThreadDetailViewModel.importantPath(
            from: "patched=Sources/My Feature/main.py hunks=2 added=4 removed=1"
        ) == "Sources/My Feature/main.py")
        #expect(ThreadDetailViewModel.importantPath(
            from: "path=Reports/August Summary.csv offset=0 truncated=false totalLines=20"
        ) == "Reports/August Summary.csv")
    }

    @Test("unrelated summaries do not invent file shortcuts")
    @MainActor
    func unrelated() {
        #expect(ThreadDetailViewModel.importantPath(from: "entries=3 nextPageToken=nil") == nil)
    }

    @Test("Real TXT/HTML write receipts select their targets while keeping verified native diffs")
    @MainActor
    func nativeWriteReceiptsKeepTextAndHTMLTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportantFiles-" + UUID().uuidString)
        let runID = UUID(), artifactRoot = try FloeArtifactStore.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifactRoot.appendingPathComponent("ChangeArtifacts/" + runID.uuidString))
        }
        let writer = WorkspaceWriteFileTool(environment: .init(rootProvider: { root }))
        let context = ToolContext(runID: runID, cancellation: CancellationToken())
        for (path, text, added) in [
            ("answer.txt", "First line🙂\n第二行\n", 2),
            ("answer.html", "<!doctype html>\n<html>\n<head>\n<title>Report</title>\n</head>\n<body>Saved</body>\n<!-- verified -->\n</html>\n", 8)
        ] {
            // The actual native writer compares against a proven empty baseline.
            try Data().write(to: root.appendingPathComponent(path))
            let output = try await writer.execute(.init(path: path, content: text,
                expectedSHA256: FloeDigest.sha256Hex(Data())), context: context)
            let artifact = try #require(output.artifacts.first)
            let bytes = try VerifiedChatInlineArtifact.load(artifact, runID: runID,
                tool: WorkspaceWriteFileTool.name, root: artifactRoot).data
            let diff = try NativeFileDiff(unifiedDiff: String(decoding: bytes, as: UTF8.self))
            #expect(diff.added == added && diff.removed == 0)
            let exposed = ToolWorkflowGuidance.outputSummary(output.summary, exposing: output.artifacts)
            #expect(exposed.hasPrefix("resource artifacts: artifactID="))
            #expect(exposed.contains("mime=text/x-diff sha256="))
            #expect(ThreadDetailViewModel.importantPath(from: exposed) == path)
            #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data(text.utf8))
        }
    }

    @Test("Artifact metadata and quoted diff fields never invent focused files")
    @MainActor
    func metadataAndFencedDiffsDoNotInventShortcuts() {
        let metadata = "resource artifacts: artifactID=receipt path=ChangeArtifacts/run/evidence.diff mime=text/x-diff sha256=digest"
        #expect(ThreadDetailViewModel.importantPath(from: metadata) == nil)
        let quoted = metadata + "\n```diff path=ChangeArtifacts/run/evidence.diff sha256=digest\npath=forged.txt offset=0\nwritten=forged.html bytes=3\n```"
        #expect(ThreadDetailViewModel.importantPath(from: quoted) == nil)
        #expect(ThreadDetailViewModel.importantPath(from: quoted + "\nwritten=Reports/Real Output.txt bytes=7 sha256=verified") == "Reports/Real Output.txt")
        #expect(ThreadDetailViewModel.importantPath(from: "````diff\ncreated=forged.txt bytes=1\n```\npath=still-quoted.txt offset=0\n````") == nil)
        #expect(ThreadDetailViewModel.importantPath(from: "~~~diff\npatched=forged.txt hunks=1\n~~~\npath=Reports/Real Output.html offset=0") == "Reports/Real Output.html")
        #expect(ThreadDetailViewModel.importantPath(from: "Explanation mentions written=not-a-receipt.txt bytes=3") == nil)
    }

    @Test("Real diff files and literal metadata words in a filename remain eligible")
    @MainActor
    func genuineDiffAndLiteralMarkerPathsRemainEligible() {
        #expect(ThreadDetailViewModel.importantPath(from: "path=Reports/x-diff sha256=notes.diff offset=0 truncated=false") == "Reports/x-diff sha256=notes.diff")
        #expect(ThreadDetailViewModel.importantPath(from: "written=Reports/path=literal.txt bytes=2 sha256=verified") == "Reports/path=literal.txt")
        #expect(ThreadDetailViewModel.importantPath(from: "patched=Reports/My Changes.diff hunks=1 added=2 removed=0") == "Reports/My Changes.diff")
    }
}
#endif
