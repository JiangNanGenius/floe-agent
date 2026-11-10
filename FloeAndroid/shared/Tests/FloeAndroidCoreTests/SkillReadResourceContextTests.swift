// SPDX-License-Identifier: MPL-2.0
//
// N07 skill.read resource-context seam — REAL contract tests (authored, NOT
// executed by this lane; no compiler or XCTest run is claimed). Verifies the
// trusted ToolContext slice reaches the manager ONLY on exact reads, that
// discovery/list/search never stage (the 2-arg seam), that the default
// protocol implementation preserves historical reads (source compatibility),
// and that discovery rows never expose resource availability.
import XCTest
import Foundation
import FloeCore
import FloeSkills
import FloeTools

final class SkillReadResourceContextTests: XCTestCase {

    /// Records which seam each call arrived on, plus the exact context slice.
    private actor RecordingManager: SkillManaging {
        enum Seam: Equatable, Sendable { case plain, run, resource }
        struct Call: Equatable, Sendable {
            let seam: Seam
            let id: String?
            let runID: UUID?
            let temporary: Bool?
            let workspaceProvided: Bool?
        }
        private(set) var calls: [Call] = []
        private let row: ManagedSkill

        init() {
            row = ManagedSkill(
                id: "floe-pdf", name: "PDF Workbench", version: "1.0.0",
                enabled: true, digest: String(repeating: "a", count: 64),
                markdown: "guide body", requiredToolNames: ["exec.shell"])
        }

        func read(id: String?) async throws -> [ManagedSkill] {
            calls.append(.init(seam: .plain, id: id, runID: nil,
                               temporary: nil, workspaceProvided: nil))
            return id == nil ? [row] : [row].filter { $0.id == id }
        }
        func read(id: String?, runID: UUID) async throws -> [ManagedSkill] {
            calls.append(.init(seam: .run, id: id, runID: runID,
                               temporary: nil, workspaceProvided: nil))
            return id == nil ? [row] : [row].filter { $0.id == id }
        }
        func read(id: String?, runID: UUID, resourceContext: SkillResourceContext?) async throws -> [ManagedSkill] {
            calls.append(.init(
                seam: .resource, id: id, runID: runID,
                temporary: resourceContext?.temporaryReadOnly,
                workspaceProvided: resourceContext?.workspaceRootURL != nil))
            return id == nil ? [row] : [row].filter { $0.id == id }
        }
        func manage(_ request: SkillManageTool.Arguments) async throws -> String { "applied" }
    }

    private func context(temporary: Bool = false, workspace: Bool = true) -> ToolContext {
        ToolContext(
            runID: UUID(),
            environmentID: "env-1",
            conversationID: UUID(),
            workspaceRootURL: workspace
                ? FileManager.default.temporaryDirectory.appendingPathComponent("floe-ctx-\(UUID().uuidString)")
                : nil,
            cancellation: CancellationToken(),
            temporaryReadOnly: temporary)
    }

    func testExactReadCarriesTrustedResourceContextSlice() async throws {
        let manager = RecordingManager()
        let tool = SkillReadTool(manager: manager)
        let context = context()
        let output = try await tool.execute(
            .init(id: "floe-pdf"), context: context)
        XCTAssertTrue(output.summary.contains("guide body"))
        let calls = await manager.calls
        XCTAssertEqual(calls, [
            .init(seam: .resource, id: "floe-pdf", runID: context.runID,
                  temporary: false, workspaceProvided: true)
        ])
    }

    func testExactReadPropagatesTemporaryAndMissingWorkspaceHonestly() async throws {
        let manager = RecordingManager()
        let tool = SkillReadTool(manager: manager)
        let temporary = context(temporary: true, workspace: false)
        _ = try await tool.execute(.init(id: "floe-pdf"), context: temporary)
        let calls = await manager.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].seam, .resource)
        XCTAssertEqual(calls[0].temporary, true)
        XCTAssertEqual(calls[0].workspaceProvided, false)
    }

    func testListAndSearchReadsNeverUseTheResourceSeam() async throws {
        let manager = RecordingManager()
        let list = SkillListTool(manager: manager)
        let search = SkillSearchTool(manager: manager)
        let context = context()
        _ = try await list.execute(.init(), context: context)
        _ = try await search.execute(.init(queries: ["pdf"]), context: context)
        let calls = await manager.calls
        // Only the historical 2-arg seam: staging is never attempted for
        // discovery/list/search.
        XCTAssertEqual(calls, [
            .init(seam: .run, id: nil, runID: context.runID,
                  temporary: nil, workspaceProvided: nil),
            .init(seam: .run, id: nil, runID: context.runID,
                  temporary: nil, workspaceProvided: nil),
        ])
    }

    func testDefaultProtocolImplementationsPreserveHistoricalReads() async throws {
        // A legacy manager conforming with only the original two requirements
        // must keep compiling and serving through the new seam's default.
        struct LegacyManager: SkillManaging {
            func read(id: String?) async throws -> [ManagedSkill] {
                [ManagedSkill(id: "legacy", name: "Legacy", version: "1",
                              enabled: true, digest: String(repeating: "b", count: 64),
                              markdown: "legacy body")]
            }
            func manage(_ request: SkillManageTool.Arguments) async throws -> String { "ok" }
        }
        let manager = LegacyManager()
        let rows = try await manager.read(
            id: "legacy", runID: UUID(),
            resourceContext: SkillResourceContext(
                runID: UUID(), cancellation: CancellationToken()))
        XCTAssertEqual(rows.first?.markdown, "legacy body")
    }

    func testDiscoveryMetadataNeverExposesResources() {
        var row = ManagedSkill(
            id: "floe-pdf", name: "PDF", version: "1.0.0", enabled: true,
            digest: String(repeating: "a", count: 64))
        row.resources = SkillResourceAvailability(
            staged: true, guestRoot: "/workspace/.floe/skills/floe-pdf@\(String(repeating: "a", count: 64))",
            pinnedSHA256: String(repeating: "a", count: 64),
            fileCount: 3, visibleInGuest: true, reason: nil)
        let discovery = row.discoveryMetadata
        XCTAssertNil(discovery.resources)
        XCTAssertNil(discovery.markdown)
    }
}
