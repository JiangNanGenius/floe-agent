// FloeAgentRuntimeTests — Workspace grounding briefing (H5/G5).

import Foundation
import Testing
@testable import FloeAgentRuntime

@Suite("Workspace context briefing")
struct WorkspaceContextBriefingTests {
    private func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-briefing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func listingIsBoundedAndDirectoriesFirst() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<40 { try Data().write(to: root.appendingPathComponent("file\(i).txt")) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".hidden"))

        let listing = try #require(WorkspaceContextBriefing.topLevelListing(rootURL: root, maxEntries: 10))
        #expect(listing.contains("Sources/"))
        #expect(listing.contains("and 31 more entries"))
        #expect(!listing.contains(".hidden"))
        #expect(listing.range(of: "Sources/")!.lowerBound < listing.range(of: "file0.txt")!.lowerBound)
    }

    @Test func emptyOrMissingWorkspaceIsGraceful() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkspaceContextBriefing.topLevelListing(rootURL: root) == "(empty workspace)")
        #expect(WorkspaceContextBriefing.topLevelListing(rootURL: nil) == nil)
        #expect(WorkspaceContextBriefing.projectInstructions(rootURL: root) == nil)
    }

    @Test func projectInstructionsCarryProvenanceAndBudget() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Always run tests before shipping.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = try #require(WorkspaceContextBriefing.projectInstructions(rootURL: root))
        #expect(loaded.contains("<!-- From: AGENTS.md -->"))
        #expect(loaded.contains("Always run tests before shipping."))

        // FLOE.md outranks AGENTS.md and the total budget holds.
        let huge = String(repeating: "x", count: WorkspaceContextBriefing.maxInstructionBytes + 4_096)
        try huge.write(to: root.appendingPathComponent("FLOE.md"), atomically: true, encoding: .utf8)
        let bounded = try #require(WorkspaceContextBriefing.projectInstructions(rootURL: root))
        #expect(bounded.contains("<!-- From: FLOE.md -->"))
        #expect(bounded.contains("[truncated"))
        #expect(bounded.utf8.count < WorkspaceContextBriefing.maxInstructionBytes + 1_024)
    }
}
