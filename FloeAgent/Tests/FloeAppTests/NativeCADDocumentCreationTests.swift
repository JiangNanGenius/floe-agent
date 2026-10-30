// FloeAppTests — production native CAD document creation workflow.
//
// Before this round, `FloeCADDocument.create` was reachable ONLY from the
// DEBUG fixture harness: no production path created a `.floecad` package or
// imported STEP/IGES into a new native document. The file tree's
// "New CAD Document" flow (FileTreeViewModel.createNativeCADDocument) and the
// agent `cad.document` create action now share the same production factory
// (`NativeCADPackageCreation`); this test drives the SAME public production
// APIs end to end — tool-level create → open through the shared bridge (the
// FilePreview path) → edit with the typed vocabulary → save → close → reopen
// from the saved bytes → verify, plus the agent create → native propose →
// preview → UI grant → apply → save → reopen loop and a REAL import of the
// kernel's own STEP export. No fixture arguments, no manufactured package
// JSON, no mocks of the kernel path.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
import FloeWorkbench
import FloeTools
import FloeCore
import FloeWorkspace
import FloeAgentRuntime
import FloeModels
import FloeProviders
import FloeSecurity
@testable import FloeApp

@MainActor
final class NativeCADDocumentCreationTests: XCTestCase {

    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in ["Bracket.floecad", "Bracket 2.floecad", "Part.floecad", "Imported.floecad"] {
            let url = workspace.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                await FloeCAD3DBridge.shared.releaseDocument(at: url)
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    /// What the file-tree creation flow runs: guard-resolved path,
    /// `FloeCADDocument.create` (production, non-DEBUG), immediate reopen
    /// through the same bridge the preview uses.
    private func createDocument(named name: String) async throws -> URL {
        let relative = "\(name).floecad"
        let url = try WorkspacePathGuard(rootURL: workspace).resolve(relative)
        _ = try await FloeCADDocument.create(at: url, name: name)
        return url
    }

    private func access(owner: UUID = UUID()) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-1", workspacePath: workspace.path,
                          ownerKind: "chat", ownerID: owner)
    }

    func testCreateEditSaveReopenThroughProductionPath() async throws {
        // 1. Create (production path — the same call the file tree makes).
        let url = try await createDocument(named: "Bracket")
        let manifest = url.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "creation must write a real versioned package")

        // 2. Open through the shared bridge (exactly what FilePreviewView
        //    does), then edit through the typed command vocabulary.
        let document = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertFalse(sketchID.isEmpty)
        XCTAssertTrue(document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[80,40]}]}}
        """.utf8)).isOK)
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[40,20],"distance":10}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let baseRevision = document.revision

        // 3. Save and release (the preview's close path).
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        XCTAssertGreaterThan(save.revision, baseRevision)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)

        // 4. Reopen from the SAVED bytes and verify the geometry survived.
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let summary = reopened.summary()
        XCTAssertEqual(summary.bodyCount, 1)
        XCTAssertEqual(summary.sketchCount, 1)
        XCTAssertGreaterThanOrEqual(summary.revision, save.revision)
        let verified = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(reopened.contentSHA256, verified?.contentSHA256,
                       "reopen must see the verified committed identity")
        let measure = reopened.measureJSON(["kind": "body",
                                            "bodyID": reopened.snapshotJSONBodyID()])
        XCTAssertTrue(measure.isOK, measure.message ?? "")
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
    }

    /// Creation never overwrites: a second document with the same stem gets
    /// its own package (the view model unique-ifies; the store itself refuses
    /// to replace without `overwrite`).
    func testCreateRefusesToReplaceExistingPackage() async throws {
        let url = try await createDocument(named: "Bracket")
        do {
            _ = try await FloeCADDocument.create(at: url, name: "Bracket")
            XCTFail("create without overwrite must refuse an existing package")
        } catch {
            // expected: the store's `exists` refusal, evidence preserved
        }
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(identity, "the original package must be untouched")
    }

    // MARK: - R2: shared factory via the cad.document tool

    /// The agent create action runs the SAME production factory the file
    /// tree uses, through `CadDocumentTool` → `CadDocumentCenter` →
    /// `NativeCADPackageCreation`. It creates a real verified empty package,
    /// never a fake body.
    func testToolCreateBuildsARealVerifiedPackage() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
        let tool = CadDocumentTool(host: center)
        let context = ToolContext(runID: UUID(), toolCallID: "call-create-1", scope: .local,
                                  workspaceRootURL: workspace, cancellation: CancellationToken(),
                                  environmentID: "env-1", conversationID: UUID())

        // 1. Create through the TOOL (the exact model surface).
        let created = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"Part.floecad","name":"Part"}"#)), context: context)
        XCTAssertTrue(created.summary.contains("cad.document created"))
        XCTAssertTrue(created.summary.contains("Part.floecad"))
        let url = workspace.appendingPathComponent("Part.floecad")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manifest.json").path),
                      "create must produce a real versioned package")

        // 2. Read-back through the tool against the SAME real package: the
        //    identity is verified by the versioned store, not a fixture.
        let read = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"read","path":"Part.floecad"}"#)), context: context)
        XCTAssertTrue(read.summary.contains("\"revision\""), read.summary)
        let verified = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(verified, "created package must verify through the store")

        // 3. The SAME tool create call does not overwrite (factory unique-ifies).
        let again = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"Part.floecad","name":"Part"}"#)), context: context)
        XCTAssertTrue(again.summary.contains("Part 2.floecad"),
                      "second create must unique-ify, not overwrite: \(again.summary)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the original package must remain")
    }

    /// The shared factory rejects traversal / outside-root / virtual roots
    /// with a fast structured failure and leaves NO package or directory
    /// behind.
    func testFactoryRejectsUnsafePathsWithoutSideEffects() async throws {
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: workspace))
        let cases = ["../escape.floecad", "/etc/escape.floecad", "Cloud/shared/x.floecad",
                     "Network/remote/x.floecad"]
        for relative in cases {
            do {
                _ = try await NativeCADPackageCreation.create(
                    service: service, desiredRelativePath: relative, explicitName: "x")
                XCTFail("\(relative) must be refused")
            } catch {
                XCTAssertTrue(error is FloeError, "structured failure for \(relative): \(error)")
            }
        }
        // No directory/package was created anywhere for any refusal.
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".floecad") },
                       "no package may be created for a refused path")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.deletingLastPathComponent().appendingPathComponent("escape.floecad").path),
            "nothing may be created outside the workspace root")
    }

    // MARK: - R2: import with REAL kernel geometry

    /// Real import: a STEP file produced by the kernel's own export (the
    /// production OCCT writer) is imported through the shared authority
    /// (`nativeImportData`) into a second native package, which is then
    /// verified by reopening from the committed bytes. This is REAL kernel
    /// geometry, not a mock.
    func testImportRealSTEPGeometryThroughProductionPath() async throws {
        // 1. Create + build a real solid in the source package.
        let source = try await createDocument(named: "Bracket")
        let sourceDocument = try await FloeCAD3DBridge.shared.openDocument(at: source)
        let sketch = sourceDocument.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertTrue(sourceDocument.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,25]}]}}
        """.utf8)).isOK)
        let extrude = sourceDocument.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,12],"distance":8}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        _ = await sourceDocument.save()

        // 2. Export REAL STEP bytes from the kernel and write them as a
        //    workspace source file (the production `nativeExportData` path).
        var stepData: Data?
        if case .success(let result) = sourceDocument.nativeExportData(format: "step", pageID: nil) {
            stepData = result.data
        }
        let bytes = try XCTUnwrap(stepData, "the kernel must export real STEP bytes")
        XCTAssertFalse(bytes.isEmpty)
        await FloeCAD3DBridge.shared.releaseDocument(at: source)
        let sourceFile = workspace.appendingPathComponent("bracket.step")
        try bytes.write(to: sourceFile)

        // 3. Import those REAL bytes into a second package through the shared
        //    authority — the same `nativeImportData` the UI/bridge reuse.
        let target = try await createDocument(named: "Imported")
        let targetDocument = try await FloeCAD3DBridge.shared.openDocument(at: target)
        let outcome = targetDocument.nativeImportData(bytes, format: "step",
                                                      fileName: "bracket.step", unitScale: nil)
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        _ = await targetDocument.save()

        // 4. Reopen from the committed package and verify the imported body
        //    survived: a REAL kernel round-trip, not a mock.
        await FloeCAD3DBridge.shared.releaseDocument(at: target)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: target)
        XCTAssertGreaterThan(reopened.summary().bodyCount, 0,
                             "the imported STEP solid must be present after save/reopen")
        await FloeCAD3DBridge.shared.releaseDocument(at: target)
    }
}

private extension FloeCADDocument {
    /// First body id from the snapshot payload (test helper).
    func snapshotJSONBodyID() -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: snapshotJSON())) as? [String: Any],
              let bodies = object["bodies"] as? [[String: Any]] else { return "" }
        return bodies.first?["id"] as? String ?? ""
    }
}
// J (CAD runtime-authorized edit closure) — App-level source fragment appended
// to NativeCADDocumentCreationTests.swift.
//
// Verifies, on the REAL runtime + production ToolRunnerRegistry/host:
//   * a scripted provider driving cad.document create → propose → apply →
//     read → extrude → measure → export, where apply runs on the runtime-issued
//     authority with NO UI grant and NO approval popup (the production
//     AutomaticApprovalPolicy decides it deterministically);
//   * the exported STEP/STL/GLB files carry REAL geometry that reparses;
//   * idempotent replay after a restart, and denials for stale/foreign/
//     replayed/forged requests;
//   * Chinese/mixed display names work and unsafe names are refused with an
//     actionable bilingual message.

// MARK: - J scripted runtime plumbing

private final class CADScriptedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let lock = NSLock()
    private var turns: [[AgentEvent]]
    private(set) var requestCount = 0

    init(turns: [[AgentEvent]]) { self.turns = turns }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let turn: [AgentEvent]? = lock.withLock {
            requestCount += 1
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            if let turn {
                for event in turn { continuation.yield(event) }
            } else {
                continuation.yield(.textDelta(.init(text: "scripted CAD answer")))
            }
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

private actor CADToolResultRecorder: AgentEventSink {
    private var results: [ToolResult] = []
    private var transitions: [String] = []

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        transitions.append(state.name)
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event { results.append(result) }
    }

    func snapshot() -> [ToolResult] { results }
    func stateNames() -> [String] { transitions }
}

private actor CADAuditRecorder: AuditSink {
    private var entries: [AuditEntry] = []
    func record(_ entry: AuditEntry) async throws { entries.append(entry) }
    func snapshot() -> [AuditEntry] { entries }
}

/// A provider that behaves like a real model: each turn is built from the tool
/// evidence the runtime hands back (this turn's results plus the replayed
/// settled pairs), so a proposal id produced by one turn's `propose` is
/// applied in the NEXT turn of the SAME run — no runtime reset, no human turn,
/// no injected grant.
private final class CADAdaptiveProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private let lock = NSLock()
    private var turnIndex = 0
    private let buildTurn: @Sendable (Int, [(callID: String, output: String)]) -> [AgentEvent]

    init(buildTurn: @escaping @Sendable (Int, [(callID: String, output: String)]) -> [AgentEvent]) {
        self.buildTurn = buildTurn
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let built: ([AgentEvent], Int) = lock.withLock {
            var evidence: [(callID: String, output: String)] = request.toolResults
            evidence.append(contentsOf: request.replayedToolPairs.map {
                (callID: $0.call.id, output: $0.result.outputSummary)
            })
            let index = turnIndex
            turnIndex += 1
            return (buildTurn(index, evidence), index)
        }
        return AsyncThrowingStream { continuation in
            for event in built.0 { continuation.yield(event) }
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

/// The ONE shared one-runtime CAD loop used by both policy variants: one
/// dependent operation per turn (create → propose → apply → query → propose →
/// apply → propose → apply → query → measure + STEP/STL/GLB exports). Never
/// batch a dependent proposal with the create it depends on, and never reset
/// the runtime mid-loop — the proposal ids come from the runtime's own
/// evidence, exactly as a real model would reuse them.
private func cadAutonomousLoopTurn(
    _ turn: Int,
    _ evidence: [(callID: String, output: String)]
) -> [AgentEvent] {
        switch turn {
        case 0:
            return [.toolRequest(try! cadMakeCall("l-create", [
                "action": "create", "path": "Loop.floecad", "name": "Loop"]))]
        case 1:
            return [.toolRequest(try! cadMakeCall("l-propose-1", [
                "action": "propose", "path": "Loop.floecad", "op": "sketch.create",
                "args": #"{"name":"Base"}"#, "summary": "base"]))]
        case 2:
            if cadProposalIDFromEvidence(evidence, "l-propose-1") == nil {
                print("FLOE_LOOP_EVIDENCE turn=2 " + evidence.map {
                    "\($0.callID)|\($0.output.prefix(200))"
                }.joined(separator: " || "))
            }
            guard let id = cadProposalIDFromEvidence(evidence, "l-propose-1") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-apply-1", [
                "action": "apply", "path": "Loop.floecad", "proposal_id": id]))]
        case 3:
            return [.toolRequest(try! cadMakeCall("l-query-sketches", [
                "action": "query", "path": "Loop.floecad", "kind": "sketches"]))]
        case 4:
            guard let sketchID = cadRowIDFromEvidence(evidence, "l-query-sketches") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-propose-2", [
                "action": "propose", "path": "Loop.floecad", "op": "sketch.addEntities",
                "args": #"{"sketchID":"\#(sketchID)","entities":[{"kind":"rect","min":[0,0],"max":[80,40]}]}"#,
                "summary": "profile"]))]
        case 5:
            guard let id = cadProposalIDFromEvidence(evidence, "l-propose-2") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-apply-2", [
                "action": "apply", "path": "Loop.floecad", "proposal_id": id]))]
        case 6:
            guard let sketchID = cadRowIDFromEvidence(evidence, "l-query-sketches") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-propose-3", [
                "action": "propose", "path": "Loop.floecad", "op": "feature.extrude",
                "args": #"{"sketchID":"\#(sketchID)","seedPoint":[40,20],"distance":10}"#,
                "summary": "extrude"]))]
        case 7:
            guard let id = cadProposalIDFromEvidence(evidence, "l-propose-3") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-apply-3", [
                "action": "apply", "path": "Loop.floecad", "proposal_id": id]))]
        case 8:
            return [.toolRequest(try! cadMakeCall("l-query-bodies", [
                "action": "query", "path": "Loop.floecad", "kind": "bodies"]))]
        case 9:
            guard let bodyID = cadRowIDFromEvidence(evidence, "l-query-bodies") else { return [] }
            return [.toolRequest(try! cadMakeCall("l-measure", [
                "action": "measure", "path": "Loop.floecad", "op": "body",
                "handles": ["body:\(bodyID)"]])),
                    .toolRequest(try! cadMakeCall("l-export-step", [
                        "action": "export", "path": "Loop.floecad", "output": "loop.export.step"])),
                    .toolRequest(try! cadMakeCall("l-export-stl", [
                        "action": "export", "path": "Loop.floecad", "output": "loop.export.stl"])),
                    .toolRequest(try! cadMakeCall("l-export-glb", [
                        "action": "export", "path": "Loop.floecad", "output": "loop.export.glb"]))]
        default:
            return [.textDelta(.init(text: "CAD 完成：已创建、拉伸并导出。"))]
        }
    }
// MARK: - J evidence helpers (file-scope: usable from @Sendable turn builders)

private func cadMakeCall(_ id: String, _ arguments: String) throws -> ToolCall {
    try ToolCall(id: id, toolName: CadDocumentTool.name,
                 argumentsJSON: Data(arguments.utf8), scope: .local)
}

/// Builds a tool-call argument payload from a dictionary. New fixtures use
/// this instead of hand-escaped JSON string templates: a template can lose
/// quote escaping (invalid outer JSON) or write `\(…)` inside a raw string
/// (which is NOT interpolation), and both mistakes produced decode failures
/// that looked like product bugs.
private func cadMakeCall(_ id: String, _ arguments: [String: Any]) throws -> ToolCall {
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return try ToolCall(id: id, toolName: CadDocumentTool.name,
                        argumentsJSON: data, scope: .local)
}

/// Encodes one fixture payload dictionary into a canonical JSON string, so
/// the SAME bytes feed `decode(…)` and `mintAuthority(…)`.
private func cadFixtureJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// First balanced JSON object in a tool-output summary (the reply may be
/// followed by a human-readable note).
private func cadFirstJSONObject(in text: String) -> [String: Any]? {
    cadJSONObjects(in: text).first
}

/// Every balanced JSON object in a tool-output summary, in order. The runtime
/// prepends ONE compact provenance envelope (`trustedSourceID`/`toolName`/…)
/// before the tool's own reply, so callers must skip the envelope rather than
/// assume the first object is the answer.
private func cadJSONObjects(in text: String) -> [[String: Any]] {
    var objects: [[String: Any]] = []
    var searchStart = text.startIndex
    while let start = text[searchStart...].firstIndex(of: "{") {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        var end: String.Index?
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
            }
            index = text.index(after: index)
        }
        guard let end else { break }
        if let object = (try? JSONSerialization.jsonObject(
            with: Data(text[start...end].utf8))) as? [String: Any] {
            objects.append(object)
        }
        searchStart = text.index(after: end)
    }
    return objects
}

private func cadEvidenceOutput(_ evidence: [(callID: String, output: String)],
                               _ callID: String) -> String? {
    evidence.last { $0.callID == callID }?.output
}

private func cadProposalIDFromEvidence(_ evidence: [(callID: String, output: String)],
                                       _ callID: String) -> String? {
    guard let output = cadEvidenceOutput(evidence, callID) else { return nil }
    for json in cadJSONObjects(in: output) {
        if let proposal = json["proposal"] as? [String: Any],
           let id = proposal["id"] as? String {
            return id
        }
    }
    return nil
}

private func cadRowIDFromEvidence(_ evidence: [(callID: String, output: String)],
                                  _ callID: String) -> String? {
    guard let output = cadEvidenceOutput(evidence, callID) else { return nil }
    for json in cadJSONObjects(in: output) {
        if let result = json["result"] as? [String: Any],
           let rows = result["rows"] as? [[String: Any]],
           let id = rows.first?["id"] as? String {
            return id
        }
    }
    return nil
}

extension NativeCADDocumentCreationTests {

    // MARK: Helpers

    private func cadRuntime(root: URL, conversationID: UUID, runID: UUID,
                            turns: [[AgentEvent]], sink: (any AgentEventSink)?,
                            audit: (any AuditSink)?) -> FloeAgentRuntime {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://cad-runtime.example/v1")!,
            displayName: "Scripted CAD Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "scripted-cad-model",
            displayName: "Scripted CAD Model",
            limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.tools])
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: [CadDocumentTool.name],
                workspaceRootURL: root),
            adapter: CADScriptedProviderAdapter(turns: turns),
            // The REAL production policy for an "automatic" task: low-risk
            // document edits are allowed deterministically (no popup, no
            // approval model), and the runtime then mints the single-use task
            // authority the automatic apply consumes.
            policy: AutomaticApprovalPolicy(),
            executor: CatalogToolExecutor(),
            auditSink: audit,
            checkpointStore: nil,
            sink: sink,
            runID: runID)
    }

    private func cadCall(_ id: String, _ arguments: String) throws -> ToolCall {
        try ToolCall(id: id, toolName: CadDocumentTool.name,
                     argumentsJSON: Data(arguments.utf8), scope: .local)
    }

    /// The tool's own JSON reply from a provider-visible tool-output summary
    /// ("cad.document query: {…}"), skipping the runtime's provenance
    /// envelope that is prepended to every provider-visible result.
    private func cadJSON(_ summary: String) throws -> [String: Any] {
        let objects = cadJSONObjects(in: summary)
        if let reply = objects.first(where: { $0["trustedSourceID"] == nil }) {
            return reply
        }
        throw FloeError.validationFailed("no JSON payload in: \(summary.prefix(200))")
    }

    private func toolResult(_ results: [ToolResult], _ callID: String) throws -> ToolResult {
        try XCTUnwrap(results.first { $0.callID == callID },
                      "no tool result recorded for \(callID)")
    }

    /// Mint a runtime-issued authority for the exact approved call the tool is
    /// about to execute (the same derivation the real runtime uses; the
    /// end-to-end test above proves the real issuer path).
    private func mintAuthority(_ arguments: String, context: ToolContext) async throws -> RuntimeTaskAuthority {
        let args = try JSONDecoder().decode(CadDocumentArguments.self, from: Data(arguments.utf8))
        let binding = try CadDocumentTool.runtimeAuthorityBinding(for: args, context: context)
        return await RuntimeAuthorityStore.shared.issue(RuntimeAuthorityEvidence(
            runID: binding.runID,
            taskID: binding.taskID,
            environmentBinding: binding.environmentBinding,
            canonicalTarget: binding.canonicalTarget,
            toolName: binding.toolName,
            operation: binding.operation,
            operationID: binding.operationID,
            idempotencyKey: binding.idempotencyKey,
            baseRevision: binding.baseRevision,
            payloadDigest: binding.payloadDigest,
            approvalGrantID: UUID()))
    }

    private func withAuthority(_ context: ToolContext, _ token: RuntimeTaskAuthority) -> ToolContext {
        var context = context
        context.runtimeAuthority = token
        return context
    }

    /// Registers the CAD tool with THIS test's center on the production
    /// registry and returns a restore closure.
    private func registerProductionCADTool(_ center: CadDocumentCenter) -> () -> Void {
        ToolCatalog.register(CadDocumentTool.self)
        let previous = ToolRunnerRegistry.shared.runner(named: CadDocumentTool.name)
        registerCadDocumentTools(center: center)
        return {
            if let previous { ToolRunnerRegistry.shared.register(previous) }
        }
    }

    // MARK: 1. Real runtime → propose/apply → read/extrude/measure/export

    func testRuntimeIssuedAuthorityAppliesCADEditsWithoutUIGrantAndExportsRealGeometry() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-runtime-\(UUID().uuidString).json"))
        let restore = registerProductionCADTool(center)
        defer { restore() }

        let conversationID = UUID()
        let sink = CADToolResultRecorder()
        let audit = CADAuditRecorder()
        let docURL = workspace.appendingPathComponent("Bracket.floecad")
        let docPath = "Bracket.floecad"

        // ── Run 1: create the package and draft the base sketch. The REAL
        //    runtime executes both calls through the production registry.
        let createJSON = #"{"action":"create","path":"Bracket.floecad","name":"Bracket"}"#
        let sketchCreateJSON = #"{"action":"propose","path":"Bracket.floecad","op":"sketch.create","args":"{\"name\":\"Base\"}","summary":"base sketch"}"#
        let run1 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-create-1", createJSON)),
                                       .toolRequest(try cadCall("cad-propose-1", sketchCreateJSON))]],
                              sink: sink, audit: audit)
        try await run1.start(goal: "创建一个 CAD 支架并草拟基础草图")

        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.appendingPathComponent("manifest.json").path),
                      "the runtime-driven create must produce a real versioned package")
        let createdIdentityValue = await FloeCADDocument.storedIdentity(at: docURL)
        let createdIdentity = try XCTUnwrap(createdIdentityValue)
        let createdResults = await sink.snapshot()
        XCTAssertTrue(try toolResult(createdResults, "cad-create-1").outputSummary.contains("cad.document created"))

        // The propose paused the run for review (existing product contract) and
        // persisted the proposal durably.
        let pending1 = await center.pendingNativeProposals(for: docURL)
        let sketchProposal = try XCTUnwrap(pending1.first, "the sketch proposal must be pending")
        XCTAssertEqual(pending1.count, 1)

        // ── Run 2: apply the sketch proposal (NO grant — runtime authority)
        //    and read the committed document back.
        let applySketchJSON = #"{"action":"apply","path":"Bracket.floecad","proposal_id":"\#(sketchProposal.id.uuidString)"}"#
        let querySketchesJSON = #"{"action":"query","path":"Bracket.floecad","kind":"sketches"}"#
        let run2 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-apply-1", applySketchJSON)),
                                       .toolRequest(try cadCall("cad-query-sketches", querySketchesJSON))],
                                      [.textDelta(.init(text: "base sketch applied"))]],
                              sink: sink, audit: audit)
        try await run2.start(goal: "应用基础草图并读取文档")

        let run2Results = await sink.snapshot()
        let sketchApply = try toolResult(run2Results, "cad-apply-1")
        XCTAssertTrue(sketchApply.outputSummary.contains("\"mode\":\"runtime-authority\""),
                      "the apply must run on the runtime authority: \(sketchApply.outputSummary)")
        XCTAssertFalse(sketchApply.outputSummary.contains("grant_id"),
                       "no UI grant may be involved: \(sketchApply.outputSummary)")
        XCTAssertTrue(sketchApply.outputSummary.contains("\"replay\":false"))

        let sketchQuery = try toolResult(run2Results, "cad-query-sketches")
        let sketchReply = try cadJSON(sketchQuery.outputSummary)
        let sketchResult = try XCTUnwrap(sketchReply["result"] as? [String: Any])
        let sketchRows = try XCTUnwrap(sketchResult["rows"] as? [[String: Any]])
        let sketchID = try XCTUnwrap(sketchRows.first?["id"] as? String)
        XCTAssertFalse(sketchID.isEmpty)

        let appliedIdentityValue = await FloeCADDocument.storedIdentity(at: docURL)
        let appliedIdentity = try XCTUnwrap(appliedIdentityValue)
        XCTAssertGreaterThan(appliedIdentity.revision, createdIdentity.revision,
                             "the automatic apply must commit a new revision")
        let stillPending = await center.pendingNativeProposals(for: docURL)
        XCTAssertTrue(stillPending.isEmpty, "an applied proposal must not stay pending")

        // ── Run 3: draft the profile (rect) on the sketch.
        let addEntitiesJSON = #"{"action":"propose","path":"Bracket.floecad","op":"sketch.addEntities","args":"{\"sketchID\":\"\#(sketchID)\",\"entities\":[{\"kind\":\"rect\",\"min\":[0,0],\"max\":[80,40]}]}","summary":"80x40 profile"}"#
        let run3 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-propose-2", addEntitiesJSON))]],
                              sink: sink, audit: audit)
        try await run3.start(goal: "在草图上绘制 80x40 矩形")
        let pending2 = await center.pendingNativeProposals(for: docURL)
        let profileProposal = try XCTUnwrap(pending2.first)

        // ── Run 4: apply the profile, then draft the extrude in the same run
        //    (the apply commits before the propose reads the package).
        let applyProfileJSON = #"{"action":"apply","path":"Bracket.floecad","proposal_id":"\#(profileProposal.id.uuidString)"}"#
        let extrudeProposalJSON = #"{"action":"propose","path":"Bracket.floecad","op":"feature.extrude","args":"{\"sketchID\":\"\#(sketchID)\",\"seedPoint\":[40,20],\"distance\":10}","summary":"extrude 10mm"}"#
        let run4 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-apply-2", applyProfileJSON)),
                                       .toolRequest(try cadCall("cad-propose-3", extrudeProposalJSON))]],
                              sink: sink, audit: audit)
        try await run4.start(goal: "应用矩形轮廓并草拟 10mm 拉伸")
        let run4Results = await sink.snapshot()
        XCTAssertTrue(try toolResult(run4Results, "cad-apply-2").outputSummary.contains("\"mode\":\"runtime-authority\""))
        let pending3 = await center.pendingNativeProposals(for: docURL)
        let extrudeProposal = try XCTUnwrap(pending3.first)

        // ── Run 5: apply the extrude and read the real body back.
        let applyExtrudeJSON = #"{"action":"apply","path":"Bracket.floecad","proposal_id":"\#(extrudeProposal.id.uuidString)"}"#
        let queryBodiesJSON = #"{"action":"query","path":"Bracket.floecad","kind":"bodies"}"#
        let run5 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-apply-3", applyExtrudeJSON)),
                                       .toolRequest(try cadCall("cad-query-bodies", queryBodiesJSON))]],
                              sink: sink, audit: audit)
        try await run5.start(goal: "应用拉伸并读取实体")
        let run5Results = await sink.snapshot()
        XCTAssertTrue(try toolResult(run5Results, "cad-apply-3").outputSummary.contains("\"mode\":\"runtime-authority\""))
        let bodyReply = try cadJSON(try toolResult(run5Results, "cad-query-bodies").outputSummary)
        let bodyResult = try XCTUnwrap(bodyReply["result"] as? [String: Any])
        let bodyRows = try XCTUnwrap(bodyResult["rows"] as? [[String: Any]])
        let bodyRow = try XCTUnwrap(bodyRows.first)
        let bodyID = try XCTUnwrap(bodyRow["id"] as? String)
        XCTAssertEqual(bodyRow["analyticBRep"] as? Bool, true, "STEP-class extrude must be an analytic B-rep body")
        let volumeAfterExtrude = try XCTUnwrap(bodyRow["volumeMM3"] as? Double)
        XCTAssertGreaterThan(volumeAfterExtrude, 25_000, "80x40x10 mm must carry real volume")
        XCTAssertLessThan(volumeAfterExtrude, 40_000)

        // ── Run 6: measure the body and export STEP/STL/GLB through the tool.
        let measureJSON = #"{"action":"measure","path":"Bracket.floecad","op":"body","handles":["body:\#(bodyID)"]}"#
        let exportStepJSON = #"{"action":"export","path":"Bracket.floecad","output":"bracket.export.step"}"#
        let exportStlJSON = #"{"action":"export","path":"Bracket.floecad","output":"bracket.export.stl"}"#
        let exportGlbJSON = #"{"action":"export","path":"Bracket.floecad","output":"bracket.export.glb"}"#
        let run6 = cadRuntime(root: workspace, conversationID: conversationID, runID: UUID(),
                              turns: [[.toolRequest(try cadCall("cad-measure-1", measureJSON)),
                                       .toolRequest(try cadCall("cad-export-1", exportStepJSON)),
                                       .toolRequest(try cadCall("cad-export-2", exportStlJSON)),
                                       .toolRequest(try cadCall("cad-export-3", exportGlbJSON))]],
                              sink: sink, audit: audit)
        try await run6.start(goal: "测量实体并导出 STEP/STL/GLB")
        let run6Results = await sink.snapshot()

        let measureReply = try cadJSON(try toolResult(run6Results, "cad-measure-1").outputSummary)
        let measured = try XCTUnwrap(measureReply["result"] as? [String: Any])
        XCTAssertEqual(measured["kind"] as? String, "body")
        let measuredVolume = try XCTUnwrap(measured["volumeMM3"] as? Double)
        XCTAssertGreaterThan(measuredVolume, 25_000)
        let measuredBounds = try XCTUnwrap(measured["bounds"] as? [[Double]])
        XCTAssertEqual(measuredBounds.count, 2)
        // The real 80x40x10 extrusion, independent of the sketch plane's axis
        // orientation: the sorted extents must be exactly those three sizes.
        let sizes = (0..<3).map { measuredBounds[1][$0] - measuredBounds[0][$0] }.sorted()
        XCTAssertEqual(sizes[0], 10, accuracy: 1.0)
        XCTAssertEqual(sizes[1], 40, accuracy: 1.0)
        XCTAssertEqual(sizes[2], 80, accuracy: 1.0)

        for call in ["cad-export-1", "cad-export-2", "cad-export-3"] {
            let reply = try cadJSON(try toolResult(run6Results, call).outputSummary)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(call): \(reply)")
            XCTAssertGreaterThan((reply["byte_count"] as? Int) ?? 0, 0)
        }

        // The audit proves the REAL production permission path allowed every
        // call with no human/approval-model review.
        let audited = await audit.snapshot()
        let applies = audited.filter { $0.toolName == CadDocumentTool.name && $0.decision.hasPrefix("allow") }
        XCTAssertGreaterThanOrEqual(applies.count, 6, "every CAD call must be allowed by the automatic policy")
        XCTAssertTrue(applies.allSatisfy { $0.policyUsed == "automatic" }, "policy must be the real automatic one")
        XCTAssertFalse(applies.contains { $0.decision.contains("deny") })

        // ── Independent export readback with REAL geometry reparsing.
        let stepURL = workspace.appendingPathComponent("bracket.export.step")
        let stlURL = workspace.appendingPathComponent("bracket.export.stl")
        let glbURL = workspace.appendingPathComponent("bracket.export.glb")
        let stepBytes = try Data(contentsOf: stepURL)
        let stlBytes = try Data(contentsOf: stlURL)
        let glbBytes = try Data(contentsOf: glbURL)

        // STEP: a real ISO-10303 exchange file, re-imported as an exact solid.
        XCTAssertEqual(String(decoding: stepBytes.prefix(12), as: UTF8.self), "ISO-10303-21")
        let stepImport = try await createDocument(named: "Step Import")
        let stepDocument = try await FloeCAD3DBridge.shared.openDocument(at: stepImport)
        let stepOutcome = stepDocument.nativeImportData(stepBytes, format: "step",
                                                        fileName: "bracket.step", unitScale: nil)
        XCTAssertTrue(stepOutcome.isOK, stepOutcome.message ?? "STEP must reparse")
        _ = await stepDocument.save()
        await FloeCAD3DBridge.shared.releaseDocument(at: stepImport)
        let stepReopened = try await FloeCAD3DBridge.shared.openDocument(at: stepImport)
        XCTAssertGreaterThan(stepReopened.summary().bodyCount, 0, "the STEP must carry real solids")
        let stepBodyID = stepReopened.snapshotJSONBodyID()
        if !stepBodyID.isEmpty {
            let stepMeasure = stepReopened.measureJSON(["kind": "body", "bodyID": stepBodyID])
            XCTAssertTrue(stepMeasure.isOK, stepMeasure.message ?? "")
        }
        await FloeCAD3DBridge.shared.releaseDocument(at: stepImport)

        // STL: binary tessellation with a real triangle count.
        XCTAssertGreaterThan(stlBytes.count, 84, "binary STL must carry a header and triangles")
        let triangleCount = stlBytes.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertGreaterThan(triangleCount, 0, "the STL must carry real triangles")
        XCTAssertEqual(stlBytes.count, 84 + Int(triangleCount) * 50, "binary STL layout must be exact")
        let stlImport = try await createDocument(named: "Stl Import")
        let stlDocument = try await FloeCAD3DBridge.shared.openDocument(at: stlImport)
        let stlOutcome = stlDocument.nativeImportData(stlBytes, format: "stl",
                                                      fileName: "bracket.stl", unitScale: nil)
        XCTAssertTrue(stlOutcome.isOK, stlOutcome.message ?? "STL must reparse")
        _ = await stlDocument.save()
        await FloeCAD3DBridge.shared.releaseDocument(at: stlImport)
        let stlReopened = try await FloeCAD3DBridge.shared.openDocument(at: stlImport)
        XCTAssertGreaterThan(stlReopened.summary().bodyCount, 0, "the STL must carry real mesh geometry")
        await FloeCAD3DBridge.shared.releaseDocument(at: stlImport)

        // GLB: real container (magic/version/length + JSON chunk), then a REAL
        // import through the production tool import proposal + automatic apply.
        XCTAssertEqual(String(decoding: glbBytes.prefix(4), as: UTF8.self), "glTF")
        let glbVersion = glbBytes.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(glbVersion, 2)
        let glbDeclaredLength = glbBytes.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        XCTAssertEqual(Int(glbDeclaredLength), glbBytes.count, "the GLB length field must match the file")
        let glbJSONChunkLength = glbBytes.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let glbChunkType = glbBytes.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        XCTAssertEqual(glbChunkType, 0x4E4F534A, "the first GLB chunk must be JSON")
        let glbJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: glbBytes.subdata(in: 20..<(20 + Int(glbJSONChunkLength)))) as? [String: Any])
        let glbMeshes = try XCTUnwrap(glbJSON["meshes"] as? [[String: Any]])
        XCTAssertFalse(glbMeshes.isEmpty, "the GLB must carry real meshes")

        let glbPackage = try await createDocument(named: "Glb Import")
        let glbContext = ToolContext(runID: UUID(), toolCallID: "cad-glb-propose", scope: .local,
                                     workspaceRootURL: workspace, cancellation: CancellationToken(),
                                     environmentID: "env-glb", conversationID: conversationID)
        let glbTool = CadDocumentTool(host: center)
        let importJSON = #"{"action":"import","path":"Glb Import.floecad","source_path":"bracket.export.glb"}"#
        let importArgs = try JSONDecoder().decode(CadDocumentArguments.self, from: Data(importJSON.utf8))
        try glbTool.validate(importArgs)
        let importOutput = try await glbTool.execute(importArgs, context: glbContext)
        XCTAssertTrue(importOutput.summary.contains("cad.document import proposal"))
        let glbPending = await center.pendingNativeProposals(for: glbPackage)
        let glbProposal = try XCTUnwrap(glbPending.first, "the GLB import must draft a durable proposal")

        let glbApplyJSON = #"{"action":"apply","path":"Glb Import.floecad","proposal_id":"\#(glbProposal.id.uuidString)"}"#
        let glbArgs = try JSONDecoder().decode(CadDocumentArguments.self, from: Data(glbApplyJSON.utf8))
        try glbTool.validate(glbArgs)
        let glbToken = try await mintAuthority(glbApplyJSON, context: glbContext)
        let glbApplyOutput = try await glbTool.execute(glbArgs, context: withAuthority(glbContext, glbToken))
        XCTAssertTrue(glbApplyOutput.summary.contains("runtime-authority"), glbApplyOutput.summary)
        XCTAssertTrue(glbApplyOutput.summary.contains("\"replay\":false"))
        await FloeCAD3DBridge.shared.releaseDocument(at: glbPackage)
        let glbReopened = try await FloeCAD3DBridge.shared.openDocument(at: glbPackage)
        XCTAssertGreaterThan(glbReopened.summary().bodyCount, 0,
                             "the exported GLB must import as real geometry")
        await FloeCAD3DBridge.shared.releaseDocument(at: glbPackage)

        // The source document was never touched by the exports/imports.
        let finalIdentityValue = await FloeCADDocument.storedIdentity(at: docURL)
        let finalIdentity = try XCTUnwrap(finalIdentityValue)
        XCTAssertEqual(finalIdentity.revision, appliedIdentity.revision + 2,
                       "exactly the profile and extrude applies committed new revisions")
        XCTAssertEqual(finalIdentity.revision, createdIdentity.revision + 3,
                       "create + sketch + profile + extrude = three commits after creation")
    }

    // MARK: 2. Idempotent replay after a restart + foreign/stale/UI-grant paths

    func testAutomaticNativeApplyReplaysAfterRestartAndDeniesForeignRequests() async throws {
        let storeURL = workspace.appendingPathComponent("proposals-replay-\(UUID().uuidString).json")
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeURL)
        let conversationID = UUID()
        let context = ToolContext(runID: UUID(), toolCallID: "call-replay-apply", scope: .local,
                                  workspaceRootURL: workspace, cancellation: CancellationToken(),
                                  environmentID: "env-1", conversationID: conversationID)
        let tool = CadDocumentTool(host: center)
        let docURL = workspace.appendingPathComponent("Replay.floecad")

        _ = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"Replay.floecad","name":"Replay"}"#)), context: context)
        _ = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"propose","path":"Replay.floecad","op":"sketch.create","args":"{\"name\":\"Base\"}","summary":"base"}"#)),
            context: context)
        let proposed = await center.pendingNativeProposals(for: docURL)
        let proposal = try XCTUnwrap(proposed.first)

        let applyJSON = #"{"action":"apply","path":"Replay.floecad","proposal_id":"\#(proposal.id.uuidString)"}"#
        let applyArgs = try XCTUnwrap(decode(applyJSON))
        let token = try await mintAuthority(applyJSON, context: context)
        let applied = try await tool.execute(applyArgs, context: withAuthority(context, token))
        XCTAssertTrue(applied.summary.contains("\"replay\":false"), applied.summary)
        XCTAssertTrue(applied.summary.contains("runtime-authority"), applied.summary)
        let revisionAfterApplyValue = await FloeCADDocument.storedIdentity(at: docURL)
        let revisionAfterApply = try XCTUnwrap(revisionAfterApplyValue).revision

        // ── Restart: a NEW center instance with the same durable store; the
        //    shared bridge has already dropped the applied proposal, so the
        //    replay MUST come from the durable receipt (not a live binding).
        let restartedCenter = CadDocumentCenter(nativeProposalStoreFileURL: storeURL)
        let restartedTool = CadDocumentTool(host: restartedCenter)
        let replayToken = try await mintAuthority(applyJSON, context: context)
        let replay = try await restartedTool.execute(applyArgs, context: withAuthority(context, replayToken))
        XCTAssertTrue(replay.summary.contains("\"replay\":true"),
                      "a post-restart retry must replay the durable receipt: \(replay.summary)")
        let revisionAfterReplayValue = await FloeCADDocument.storedIdentity(at: docURL)
        XCTAssertEqual(try XCTUnwrap(revisionAfterReplayValue).revision,
                       revisionAfterApply, "a replay must never mutate again")
        let pendingAfterReplay = await restartedCenter.pendingNativeProposals(for: docURL)
        XCTAssertTrue(pendingAfterReplay.isEmpty)

        // ── The SAME token twice is refused (single-use authority).
        do {
            _ = try await restartedTool.execute(applyArgs, context: withAuthority(context, replayToken))
            XCTFail("a consumed runtime authority must not authorize a second apply")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected replay refusal: \(error)")
            }
            XCTAssertTrue(message.contains("already consumed"), message)
        }

        // ── A DIFFERENT request id on the applied proposal is a new operation
        //    and is refused without mutation.
        let otherRequestJSON = #"{"action":"apply","path":"Replay.floecad","proposal_id":"\#(proposal.id.uuidString)","request_id":"different-request"}"#
        let otherRequestArgs = try XCTUnwrap(decode(otherRequestJSON))
        let otherRequestToken = try await mintAuthority(otherRequestJSON, context: context)
        do {
            _ = try await restartedTool.execute(otherRequestArgs, context: withAuthority(context, otherRequestToken))
            XCTFail("a different request id must not re-run an applied proposal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected refusal: \(error)")
            }
            XCTAssertTrue(message.contains("already applied with a different request"), message)
        }

        // ── A foreign owner (different task) is refused with the same denial
        //    as an unknown proposal.
        let foreignContext = ToolContext(runID: UUID(), toolCallID: "call-replay-apply", scope: .local,
                                         workspaceRootURL: workspace, cancellation: CancellationToken(),
                                         environmentID: "env-1", conversationID: UUID())
        let foreignToken = try await mintAuthority(applyJSON, context: foreignContext)
        do {
            _ = try await restartedTool.execute(applyArgs, context: withAuthority(foreignContext, foreignToken))
            XCTFail("a foreign owner must not apply this proposal")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }

        // ── A token bound to a DIFFERENT target cannot authorize this apply.
        let otherTargetJSON = #"{"action":"apply","path":"Other.floecad","proposal_id":"\#(proposal.id.uuidString)"}"#
        let otherTargetArgs = try XCTUnwrap(decode(otherTargetJSON))
        let otherTargetToken = try await mintAuthority(otherTargetJSON, context: context)
        do {
            _ = try await restartedTool.execute(otherTargetArgs, context: withAuthority(context, otherTargetToken))
            XCTFail("a token bound to another target must not authorize this document")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let revisionAfterDenialsValue = await FloeCADDocument.storedIdentity(at: docURL)
        XCTAssertEqual(try XCTUnwrap(revisionAfterDenialsValue).revision,
                       revisionAfterApply, "no denied path may have mutated the document")

        // ── A stale proposal (the document advanced after it was drafted)
        //    refuses through the kernel revision/SHA re-check.
        _ = try await restartedTool.execute(try XCTUnwrap(decode(
            #"{"action":"propose","path":"Replay.floecad","op":"sketch.create","args":"{\"name\":\"First\"}","summary":"first"}"#)),
            context: context)
        let pendingBeforeSecond = await restartedCenter.pendingNativeProposals(for: docURL)
        let staleProposal = try XCTUnwrap(pendingBeforeSecond.first)
        _ = try await restartedTool.execute(try XCTUnwrap(decode(
            #"{"action":"propose","path":"Replay.floecad","op":"sketch.create","args":"{\"name\":\"Second\"}","summary":"second"}"#)),
            context: context)
        let freshProposals = await restartedCenter.pendingNativeProposals(for: docURL)
        let secondProposal = try XCTUnwrap(freshProposals.first { $0.id != staleProposal.id })
        let applySecondJSON = #"{"action":"apply","path":"Replay.floecad","proposal_id":"\#(secondProposal.id.uuidString)"}"#
        let secondToken = try await mintAuthority(applySecondJSON, context: context)
        _ = try await restartedTool.execute(try XCTUnwrap(decode(applySecondJSON)),
                                            context: withAuthority(context, secondToken))
        let revisionAfterSecondValue = await FloeCADDocument.storedIdentity(at: docURL)
        let revisionAfterSecond = try XCTUnwrap(revisionAfterSecondValue).revision
        let applyStaleJSON = #"{"action":"apply","path":"Replay.floecad","proposal_id":"\#(staleProposal.id.uuidString)"}"#
        let staleToken = try await mintAuthority(applyStaleJSON, context: context)
        do {
            _ = try await restartedTool.execute(try XCTUnwrap(decode(applyStaleJSON)),
                                                context: withAuthority(context, staleToken))
            XCTFail("a proposal drafted against an older revision must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected stale refusal: \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("changed"), message)
        }
        let revisionAfterStaleValue = await FloeCADDocument.storedIdentity(at: docURL)
        XCTAssertEqual(try XCTUnwrap(revisionAfterStaleValue).revision,
                       revisionAfterSecond, "the stale refusal must not mutate the document")

        // ── The interactive UI grant path is unchanged: the human confirmation
        //    still applies (mode=interactive-grant).
        let reviewedOutput = try await restartedTool.execute(try XCTUnwrap(decode(
            #"{"action":"propose","path":"Replay.floecad","op":"sketch.create","args":"{\"name\":\"Reviewed\"}","summary":"reviewed"}"#)),
            context: context)
        // The confirmed proposal is resolved from THIS propose's own reply, not
        // from the first entry of the pending list: an older, now-stale proposal
        // may still be listed there (the user-visible order is newest first, and
        // a stale proposal is superseded only when the banner next refreshes).
        let reviewedID = try XCTUnwrap(cadProposalIDFromEvidence(
            [(callID: "reviewed", output: reviewedOutput.summary)], "reviewed"))
        XCTAssertNotEqual(reviewedID, staleProposal.id.uuidString)
        let pendingForUI = await restartedCenter.pendingNativeProposals(for: docURL)
        let uiProposal = try XCTUnwrap(pendingForUI.first { $0.id.uuidString == reviewedID },
                                       "the just-reviewed proposal must be pending")
        XCTAssertFalse(pendingForUI.contains { $0.id == staleProposal.id },
                       "a superseded proposal must not remain confirmable in the CAD UI")
        let grant = try await restartedCenter.issueNativeCADGrant(proposalID: uiProposal.id)
        let applyGrantJSON = #"{"action":"apply","path":"Replay.floecad","proposal_id":"\#(uiProposal.id.uuidString)","grant_id":"\#(grant)"}"#
        let grantOutput = try await restartedTool.execute(try XCTUnwrap(decode(applyGrantJSON)), context: context)
        XCTAssertTrue(grantOutput.summary.contains("\"mode\":\"interactive-grant\""), grantOutput.summary)
        XCTAssertTrue(grantOutput.summary.contains("\"replay\":false"))
    }

    // MARK: 3. Unicode / mixed document names through the production tool

    func testUnicodeCADNamesCreateAndUnsafeNamesAreRefusedBilingually() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-unicode-\(UUID().uuidString).json"))
        let tool = CadDocumentTool(host: center)
        let context = ToolContext(runID: UUID(), toolCallID: "call-unicode", scope: .local,
                                  workspaceRootURL: workspace, cancellation: CancellationToken(),
                                  environmentID: "env-1", conversationID: UUID())

        // A Chinese/mixed DISPLAY name is stored verbatim; the FILE keeps the
        // requested path stem (display name and file name are separate).
        let mixed = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"mixed-part.floecad","name":"混合 Mixed 支架"}"#)),
            context: context)
        XCTAssertTrue(mixed.summary.contains("\"name\":\"混合 Mixed 支架\""), mixed.summary)
        XCTAssertTrue(mixed.summary.contains("\"fileName\":\"mixed-part\""), mixed.summary)
        XCTAssertTrue(mixed.summary.contains("mixed-part.floecad"), mixed.summary)
        let mixedURL = workspace.appendingPathComponent("mixed-part.floecad")
        let mixedDocument = try await FloeCAD3DBridge.shared.openDocument(at: mixedURL)
        XCTAssertEqual(mixedDocument.summary().name, "混合 Mixed 支架",
                       "the package must store the requested display name")
        await FloeCAD3DBridge.shared.releaseDocument(at: mixedURL)

        // A Chinese FILE name (path stem only) works end to end.
        let chinese = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"中文 支架.floecad"}"#)), context: context)
        XCTAssertTrue(chinese.summary.contains("中文 支架.floecad"), chinese.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace
            .appendingPathComponent("中文 支架.floecad/manifest.json").path))
        XCTAssertTrue(chinese.summary.contains("\"name\":\"中文 支架\""), chinese.summary)

        // Unsafe names are refused with an actionable bilingual message and no
        // package is created.
        let before = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        let rejected: [(String, String)] = [
            (#"{"action":"create","path":"bad1.floecad","name":"bad\u0007name"}"#, "控制字符"),
            (#"{"action":"create","path":"bad2.floecad","name":"two\nlines"}"#, "控制字符"),
            (#"{"action":"create","path":"bad3.floecad","name":"folder/name"}"#, "路径分隔符"),
            (#"{"action":"create","path":"bad4.floecad","name":".."}"#, "路径分隔符"),
            (#"{"action":"create","path":"bad5.floecad","name":"   "}"#, "名称"),
        ]
        for (json, fragment) in rejected {
            do {
                _ = try await tool.execute(try XCTUnwrap(decode(json)), context: context)
                XCTFail("\(json) must be refused")
            } catch let error as FloeError {
                guard case .validationFailed(let message) = error else {
                    return XCTFail("unexpected refusal for \(json): \(error)")
                }
                XCTAssertTrue(message.contains(fragment), "\(json) -> \(message)")
                XCTAssertTrue(message.contains("CAD 文档名称"), "the refusal must be bilingual: \(message)")
            }
        }
        // An over-long name (121 characters) is refused, not truncated.
        let longName = String(repeating: "长", count: 121)
        let longJSON = #"{"action":"create","path":"bad6.floecad","name":"\#(longName)"}"#
        do {
            _ = try await tool.execute(try XCTUnwrap(decode(longJSON)), context: context)
            XCTFail("a 121-character name must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected refusal: \(error)")
            }
            XCTAssertTrue(message.contains("121") && message.contains("120"), message)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertEqual(Set(after).subtracting(before), [],
                       "no refused create may leave a package behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("bad1.floecad").path))
    }
}

// The remaining J CAD cases live in an INTERNAL extension on purpose: a
// `private extension` hides its members from the Objective-C runtime, so
// XCTest never discovers test methods declared there (they silently did not
// run). Helpers stay `private` inside this extension.
extension NativeCADDocumentCreationTests {
    private func decode(_ json: String) -> CadDocumentArguments? {
        try? JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    // MARK: 4. ONE runtime, one task: autonomous closure across model turns

    func testSingleRuntimeClosesCADEditAutonomouslyAcrossModelTurns() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-loop-\(UUID().uuidString).json"))
        let restore = registerProductionCADTool(center)
        defer { restore() }

        let conversationID = UUID()
        let runID = UUID()
        let sink = CADToolResultRecorder()
        let audit = CADAuditRecorder()

        // A provider that behaves like a real model: each turn is built from
        // the tool evidence the runtime hands back (this turn's results plus
        // the replayed settled pairs), so a proposal id produced by one turn's
        // `propose` is applied in the NEXT turn of the SAME run — no runtime
        // reset, no human turn, no injected grant.
        let adapter = CADAdaptiveProviderAdapter(buildTurn: cadAutonomousLoopTurn)

        // ONE runtime instance, ONE task/run: the whole chain runs inside it.
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://cad-loop.example/v1")!,
            displayName: "Adaptive CAD Provider")
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "adaptive-cad",
            displayName: "Adaptive CAD",
            limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.tools])
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID, provider: provider, model: model,
                allowedToolNames: [CadDocumentTool.name], workspaceRootURL: workspace),
            adapter: adapter,
            policy: AutomaticApprovalPolicy(),
            executor: CatalogToolExecutor(),
            auditSink: audit,
            checkpointStore: nil,
            sink: sink,
            runID: runID)
        try await runtime.start(goal: "创建支架、拉伸 10mm、测量并导出 STEP/STL/GLB")

        // No human pause, no grant, no reset: the same run applied all three
        // proposals and produced the geometry + exports.
        let results = await sink.snapshot()
        var receiptRevisions: [Int] = []
        for callID in ["l-apply-1", "l-apply-2", "l-apply-3"] {
            let apply = try toolResult(results, callID)
            XCTAssertTrue(apply.outputSummary.contains("\"mode\":\"runtime-authority\""), apply.outputSummary)
            XCTAssertTrue(apply.outputSummary.contains("\"replay\":false"), apply.outputSummary)
            let reply = try cadJSON(apply.outputSummary)
            let receipt = try XCTUnwrap(reply["receipt"] as? [String: Any])
            receiptRevisions.append(try XCTUnwrap(receipt["revision"] as? Int))
        }
        // Exactly one commit per apply, strictly ordered.
        XCTAssertEqual(receiptRevisions.count, 3)
        XCTAssertEqual(receiptRevisions[1], receiptRevisions[0] + 1)
        XCTAssertEqual(receiptRevisions[2], receiptRevisions[1] + 1)
        let identityValue = await FloeCADDocument.storedIdentity(at: workspace.appendingPathComponent("Loop.floecad"))
        XCTAssertEqual(try XCTUnwrap(identityValue).revision, receiptRevisions[2],
                       "the committed package must report the last applied revision")

        let measureJSON = try cadJSON(try toolResult(results, "l-measure").outputSummary)
        let measured = try XCTUnwrap(measureJSON["result"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(measured["volumeMM3"] as? Double), 25_000)
        for callID in ["l-export-step", "l-export-stl", "l-export-glb"] {
            let reply = try cadJSON(try toolResult(results, callID).outputSummary)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(callID): \(reply)")
        }
        for name in ["loop.export.step", "loop.export.stl", "loop.export.glb"] {
            let url = workspace.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) must exist")
            XCTAssertGreaterThan((try Data(contentsOf: url)).count, 0)
        }

        // Every CAD call was allowed by the real automatic policy: no human
        // review, no approval model, no per-edit popup, and no checkpoint that
        // asks the user to continue.
        let audited = await audit.snapshot()
        let cadEntries = audited.filter { $0.toolName == CadDocumentTool.name }
        XCTAssertGreaterThanOrEqual(cadEntries.count, 11)
        XCTAssertTrue(cadEntries.allSatisfy { $0.decision.hasPrefix("allow") }, "\(cadEntries.map(\.decision))")
        XCTAssertTrue(cadEntries.allSatisfy { $0.policyUsed == "automatic" })
        let states = await sink.stateNames()
        XCTAssertFalse(states.contains("checkpointed"),
                       "an ordinary authorized CAD edit must not checkpoint for a human: \(states)")
    }

    // MARK: 6. Real 2D engine: automatic apply commits and reopens

    func testTwoDimensionalAutomaticApplyCommitsThroughTheRealEngine() async throws {
        // The engine fixture the existing CadWebEngineSessionTests use.
        let sampleRoot = try XCTUnwrap(
            Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
            "the EngineeringViewers bundle resource must be present")
        let plateURL = workspace.appendingPathComponent("plate.dxf")
        try FileManager.default.copyItem(at: sampleRoot.appendingPathComponent("sample-plate.dxf"),
                                         to: plateURL)

        let storeURL = workspace.appendingPathComponent("proposals-2d-\(UUID().uuidString).json")
        let center = CadDocumentCenter(nativeProposalStoreFileURL: storeURL)
        let tool = CadDocumentTool(host: center)
        let conversationID = UUID()
        let context = ToolContext(runID: UUID(), toolCallID: "2d-apply", scope: .local,
                                  workspaceRootURL: workspace, cancellation: CancellationToken(),
                                  environmentID: "env-1", conversationID: conversationID)
        let access = CadDocumentTool.access(for: context)

        // Baseline through the REAL engine session (WKWebView + wasm).
        let before = try await center.snapshot(documentID: "plate.dxf", access: access)
        XCTAssertGreaterThan(before.entityCount, 0, "the sample drawing must parse with entities")
        XCTAssertTrue(before.editable)

        // Propose a real 2D edit through the tool (no write yet).
        let proposeJSON = try cadFixtureJSON([
            "action": "propose", "path": "plate.dxf", "summary": "automatic line",
            "operations": [["operation": "addLine", "start": [0, 0, 0],
                            "end": [25, 0, 0], "layer": "0"]],
        ])
        let proposeArgs = try XCTUnwrap(decode(proposeJSON))
        try tool.validate(proposeArgs)
        let proposalOutput = try await tool.execute(proposeArgs, context: context)
        XCTAssertTrue(proposalOutput.summary.contains("cad.document proposal"), proposalOutput.summary)
        XCTAssertFalse(proposalOutput.requiresUserAction)
        let untouched = try await center.snapshot(documentID: "plate.dxf", access: access)
        XCTAssertEqual(untouched.sha256, before.sha256, "propose must not write")

        let pending = try await center.pendingProposals(documentID: "plate.dxf", access: access)
        let proposal = try XCTUnwrap(pending.first, "the 2D proposal must be pending")

        // Without any authority the apply refuses and the drawing is unchanged.
        let applyJSON = try cadFixtureJSON([
            "action": "apply", "path": "plate.dxf", "proposal_id": proposal.id.uuidString,
        ])
        let applyArgs = try XCTUnwrap(decode(applyJSON))
        try tool.validate(applyArgs)
        do {
            _ = try await tool.execute(applyArgs, context: context)
            XCTFail("an apply with no grant and no runtime authority must refuse")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("unexpected refusal: \(error)")
            }
            XCTAssertTrue(message.contains("runtime-approved call authority"), message)
        }
        let stillUntouched = try await center.snapshot(documentID: "plate.dxf", access: access)
        XCTAssertEqual(stillUntouched.sha256, before.sha256)

        // The runtime-approved call authority applies it through the SAME
        // serialized transaction the UI grant uses.
        let token = try await mintAuthority(applyJSON, context: context)
        let output = try await tool.execute(applyArgs, context: withAuthority(context, token))
        XCTAssertTrue(output.summary.contains("\"saved\":true"), output.summary)

        let after = try await center.snapshot(documentID: "plate.dxf", access: access)
        XCTAssertEqual(after.entityCount, before.entityCount + 1,
                       "the committed drawing must carry the new line")
        XCTAssertNotEqual(after.sha256, before.sha256)

        // Reopen from the committed bytes with a FRESH center (new engine
        // session) and verify persistence is real. (The 2D center's `revision`
        // is an engine-session counter, so the durable proof is the entity
        // count plus the content SHA.)
        let reopenedCenter = CadDocumentCenter(nativeProposalStoreFileURL: storeURL)
        let reopened = try await reopenedCenter.snapshot(documentID: "plate.dxf", access: access)
        XCTAssertEqual(reopened.entityCount, before.entityCount + 1)
        XCTAssertEqual(reopened.sha256, after.sha256)
    }

    // MARK: 5. Canvas staged CAD scope (exact authorized document only)

    func testCanvasStagedCADScopeAuthorizesOnlyTheStagedDocument() async throws {
        // A real Canvas-shaped staged draft: its OWN draft root, outside the
        // task workspace, exactly like `CanvasDrawingNodePlanner.canonicalDraftRoot()`.
        let draftRoot = workspace.appendingPathComponent("CanvasDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let canvasID = UUID()
        let stagedRelative = "canvas-\(canvasID.uuidString)/staged.floecad"
        let stagedURL = draftRoot.appendingPathComponent(stagedRelative)
        try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        _ = try await FloeCADDocument.create(at: stagedURL, name: "Staged Part")

        // A second, FOREIGN package beside it (inside the same draft root).
        let foreignURL = draftRoot.appendingPathComponent("foreign.floecad")
        _ = try await FloeCADDocument.create(at: foreignURL, name: "Foreign")

        let staged = CanvasStagedDocumentAccess(canvasID: canvasID,
                                                draftRootPath: draftRoot.path,
                                                stagedRelativePath: stagedRelative)
        let conversationID = UUID()
        let context = ToolContext(runID: UUID(), toolCallID: "canvas-call", scope: .local,
                                  workspaceRootURL: workspace,   // the RUN root ≠ draft root
                                  canvasStagedDocument: staged,
                                  cancellation: CancellationToken(),
                                  environmentID: "env-canvas", conversationID: conversationID)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-canvas-\(UUID().uuidString).json"))
        let tool = CadDocumentTool(host: center)

        // The tool derives the canvas-owned access from the verified binding.
        let access = CadDocumentTool.access(for: context)
        XCTAssertEqual(access.ownerKind, "canvas")
        XCTAssertEqual(access.ownerID, canvasID)
        XCTAssertEqual(access.workspacePath, draftRoot.path)

        // The canonical absolute staged path is the accepted addressing form
        // (the draft root is visible in the assistant context).
        let stagedAbsolute = stagedURL.path
        let proposeJSON = try cadFixtureJSON([
            "action": "propose", "path": stagedAbsolute, "op": "sketch.create",
            "args": #"{"name":"Base"}"#, "summary": "staged base",
        ])
        let proposeArgs = try XCTUnwrap(decode(proposeJSON))
        try tool.validate(proposeArgs)
        let proposalOutput = try await tool.execute(proposeArgs, context: context)
        XCTAssertTrue(proposalOutput.summary.contains("cad.document propose"), proposalOutput.summary)
        XCTAssertFalse(proposalOutput.requiresUserAction)

        let pending = await center.pendingNativeProposals(for: stagedURL)
        let proposal = try XCTUnwrap(pending.first, "the staged proposal must be pending")
        let applyJSON = try cadFixtureJSON([
            "action": "apply", "path": stagedAbsolute, "proposal_id": proposal.id.uuidString,
        ])
        let applyArgs = try XCTUnwrap(decode(applyJSON))
        try tool.validate(applyArgs)
        let token = try await mintAuthority(applyJSON, context: context)
        let applied = try await tool.execute(applyArgs, context: withAuthority(context, token))
        XCTAssertTrue(applied.summary.contains("\"mode\":\"runtime-authority\""), applied.summary)
        XCTAssertTrue(applied.summary.contains("\"replay\":false"))
        let revisionAfterValue = await FloeCADDocument.storedIdentity(at: stagedURL)
        XCTAssertGreaterThan(try XCTUnwrap(revisionAfterValue).revision, 0)

        // NEGATIVE: any foreign document (even inside the same draft root) is
        // refused before any authority is consulted.
        let foreignProposeJSON = try cadFixtureJSON([
            "action": "propose", "path": foreignURL.path, "op": "sketch.create",
            "args": #"{"name":"Nope"}"#, "summary": "foreign",
        ])
        do {
            _ = try await tool.execute(try XCTUnwrap(decode(foreignProposeJSON)), context: context)
            XCTFail("a foreign document must not be reachable through the staged grant")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }

        // NEGATIVE: a token minted for the FOREIGN document cannot apply the
        // staged proposal (target/payload mismatch at consumption).
        let foreignApplyJSON = try cadFixtureJSON([
            "action": "apply", "path": foreignURL.path, "proposal_id": proposal.id.uuidString,
        ])
        let foreignToken = try await mintAuthority(foreignApplyJSON, context: context)
        do {
            _ = try await tool.execute(try XCTUnwrap(decode(foreignApplyJSON)),
                                       context: withAuthority(context, foreignToken))
            XCTFail("a token for another document must not authorize the staged doc")
        } catch let error as FloeError {
            XCTAssertTrue(error == .unauthorized || "\(error)".contains("canonical target"), "\(error)")
        }

        // NEGATIVE: a proposal owned by a DIFFERENT canvas is not visible/appliable
        // through this canvas's context.
        let foreignCanvas = CanvasStagedDocumentAccess(canvasID: UUID(),
                                                       draftRootPath: draftRoot.path,
                                                       stagedRelativePath: stagedRelative)
        let foreignCanvasContext = ToolContext(runID: UUID(), toolCallID: "canvas-call", scope: .local,
                                               workspaceRootURL: workspace,
                                               canvasStagedDocument: foreignCanvas,
                                               cancellation: CancellationToken(),
                                               environmentID: "env-canvas", conversationID: conversationID)
        let secondProposeJSON = try cadFixtureJSON([
            "action": "propose", "path": stagedAbsolute, "op": "sketch.create",
            "args": #"{"name":"Other"}"#, "summary": "other",
        ])
        let secondPropose = try XCTUnwrap(decode(secondProposeJSON))
        _ = try await tool.execute(secondPropose, context: foreignCanvasContext)
        let otherPending = await center.pendingNativeProposals(for: stagedURL)
        let otherProposal = try XCTUnwrap(otherPending.first { $0.id != proposal.id })
        let otherApplyJSON = try cadFixtureJSON([
            "action": "apply", "path": stagedAbsolute, "proposal_id": otherProposal.id.uuidString,
        ])
        let otherToken = try await mintAuthority(otherApplyJSON, context: context)
        do {
            _ = try await tool.execute(try XCTUnwrap(decode(otherApplyJSON)),
                                       context: withAuthority(context, otherToken))
            XCTFail("a proposal owned by another canvas must not apply through this canvas's context")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: 7. Default-ask (Human) policy: the same one-runtime loop, no cards

    func testSingleRuntimeClosesCADEditUnderDefaultAskHumanPolicy() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-human-\(UUID().uuidString).json"))
        let restore = registerProductionCADTool(center)
        defer { restore() }

        let conversationID = UUID()
        let runID = UUID()
        let sink = CADToolResultRecorder()
        let audit = CADAuditRecorder()
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://cad-human.example/v1")!,
            displayName: "Adaptive CAD Provider")
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "adaptive-cad",
            displayName: "Adaptive CAD",
            limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.tools])
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID, provider: provider, model: model,
                allowedToolNames: [CadDocumentTool.name], workspaceRootURL: workspace),
            adapter: CADAdaptiveProviderAdapter(buildTurn: cadAutonomousLoopTurn),
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(),
            auditSink: audit,
            checkpointStore: nil,
            sink: sink,
            runID: runID)
        try await runtime.start(goal: "支架：创建、拉伸 10mm、测量并导出 STEP/STL/GLB（默认询问策略）")

        let results = await sink.snapshot()
        let states = await sink.stateNames()
        XCTAssertFalse(states.contains("waitingApproval"),
                       "ordinary non-repository CAD work must not raise a card under default Ask: \(states)")
        XCTAssertFalse(states.contains("checkpointed"),
                       "no human-continuation checkpoint may interrupt the run: \(states)")

        var receiptRevisions: [Int] = []
        for callID in ["l-apply-1", "l-apply-2", "l-apply-3"] {
            let apply = try toolResult(results, callID)
            XCTAssertTrue(apply.outputSummary.contains("\"mode\":\"runtime-authority\""), apply.outputSummary)
            XCTAssertFalse(apply.outputSummary.contains("grant_id"),
                           "no UI grant may be involved: \(apply.outputSummary)")
            let reply = try cadJSON(apply.outputSummary)
            let receipt = try XCTUnwrap(reply["receipt"] as? [String: Any])
            receiptRevisions.append(try XCTUnwrap(receipt["revision"] as? Int))
        }
        XCTAssertEqual(receiptRevisions.count, 3)
        XCTAssertEqual(receiptRevisions[1], receiptRevisions[0] + 1)
        XCTAssertEqual(receiptRevisions[2], receiptRevisions[1] + 1)

        let measureJSON = try cadJSON(try toolResult(results, "l-measure").outputSummary)
        let measured = try XCTUnwrap(measureJSON["result"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(measured["volumeMM3"] as? Double), 25_000)
        for callID in ["l-export-step", "l-export-stl", "l-export-glb"] {
            let reply = try cadJSON(try toolResult(results, callID).outputSummary)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(callID): \(reply)")
        }

        let audited = await audit.snapshot()
        let cadEntries = audited.filter { $0.toolName == CadDocumentTool.name }
        XCTAssertGreaterThanOrEqual(cadEntries.count, 11)
        XCTAssertTrue(cadEntries.allSatisfy { $0.decision.hasPrefix("allow") }, "\(cadEntries.map(\.decision))")
        XCTAssertTrue(cadEntries.allSatisfy { $0.policyUsed == "human" }, "\(cadEntries.map(\.policyUsed))")

        // A delegated read must belong to a live parent. The completed CAD
        // loop above cannot authorize late child work. Hold a real parent in
        // its normal provider stream, then exercise the same policy path.
        let childParentID = UUID()
        let childParent = FloeAgentRuntime(
            configuration: .init(conversationID: conversationID, provider: provider, model: model,
                allowedToolNames: [CadDocumentTool.name], workspaceRootURL: workspace),
            adapter: ActiveParentTestAdapter(), policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(), auditSink: audit, runID: childParentID)
        let childIdentity = ChildExecutionIdentity(
            parentRunID: childParentID, rootTaskID: conversationID, delegateCallID: "delegate-human-read")
        let childCall = try cadMakeCall("child-read", ["action": "read", "path": "Loop.floecad"])
        let childContext = ToolContext(
            runID: childParentID, toolCallID: "child-read", scope: .local,
            allowedToolNames: [CadDocumentTool.name], workspaceRootURL: workspace,
            cancellation: CancellationToken(), conversationID: conversationID)
        try await ActiveParentTestScope.withScope { @Sendable in
            try await ActiveParentTestScope.activate(childParent)
            let childResult = await childParent.dispatchChildTool(
                childCall, identity: childIdentity, childContext: childContext)
            XCTAssertEqual(childResult.status, .ok,
                           "a delegated child read must execute: \(childResult.outputSummary)")
        }

    }

    // MARK: 8. Canvas staged scope through the runtime: REL path + foreign

    func testCanvasStagedCADRelativePathClosesThroughRuntimeAndForeignTargetsRefuse() async throws {
        let draftRoot = workspace.appendingPathComponent("CanvasDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let canvasID = UUID()
        let stagedRelative = "canvas-\(canvasID.uuidString)/staged.floecad"
        let stagedURL = draftRoot.appendingPathComponent(stagedRelative)
        try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        _ = try await FloeCADDocument.create(at: stagedURL, name: "Staged Part")
        let foreignURL = draftRoot.appendingPathComponent("foreign.floecad")
        _ = try await FloeCADDocument.create(at: foreignURL, name: "Foreign")
        let stagedIdentityBeforeValue = await FloeCADDocument.storedIdentity(at: stagedURL)
        let stagedRevisionBefore = try XCTUnwrap(stagedIdentityBeforeValue).revision
        let foreignIdentityBeforeValue = await FloeCADDocument.storedIdentity(at: foreignURL)
        let foreignRevisionBefore = try XCTUnwrap(foreignIdentityBeforeValue).revision

        let staged = CanvasStagedDocumentAccess(canvasID: canvasID,
                                                draftRootPath: draftRoot.path,
                                                stagedRelativePath: stagedRelative)
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-canvas-runtime-\(UUID().uuidString).json"))
        let restore = registerProductionCADTool(center)
        defer { restore() }

        let conversationID = UUID()
        let runID = UUID()
        let sink = CADToolResultRecorder()
        let audit = CADAuditRecorder()
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://cad-staged.example/v1")!,
            displayName: "Staged CAD Provider")
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "staged-cad",
            displayName: "Staged CAD",
            limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.tools])
        let adapter = CADAdaptiveProviderAdapter { turn, evidence in
            // ONE dependent operation per turn, addressed with the RELATIVE
            // staged path (the assistant-context form the K3 hook resolves):
            // sketch.create → addEntities → feature.extrude → measure+export.
            switch turn {
            case 0:
                return [.toolRequest(try! cadMakeCall("staged-propose", [
                    "action": "propose", "path": stagedRelative, "op": "sketch.create",
                    "args": #"{"name":"Base"}"#, "summary": "staged base"]))]
            case 1:
                guard let id = cadProposalIDFromEvidence(evidence, "staged-propose") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-apply", [
                    "action": "apply", "path": stagedRelative, "proposal_id": id]))]
            case 2:
                return [.toolRequest(try! cadMakeCall("staged-query-sketches", [
                    "action": "query", "path": stagedRelative, "kind": "sketches"]))]
            case 3:
                guard let sketchID = cadRowIDFromEvidence(evidence, "staged-query-sketches") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-propose-profile", [
                    "action": "propose", "path": stagedRelative, "op": "sketch.addEntities",
                    "args": #"{"sketchID":"\#(sketchID)","entities":[{"kind":"rect","min":[0,0],"max":[80,40]}]}"#,
                    "summary": "profile"]))]
            case 4:
                guard let id = cadProposalIDFromEvidence(evidence, "staged-propose-profile") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-apply-profile", [
                    "action": "apply", "path": stagedRelative, "proposal_id": id]))]
            case 5:
                guard let sketchID = cadRowIDFromEvidence(evidence, "staged-query-sketches") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-propose-extrude", [
                    "action": "propose", "path": stagedRelative, "op": "feature.extrude",
                    "args": #"{"sketchID":"\#(sketchID)","seedPoint":[40,20],"distance":10}"#,
                    "summary": "extrude"]))]
            case 6:
                guard let id = cadProposalIDFromEvidence(evidence, "staged-propose-extrude") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-apply-extrude", [
                    "action": "apply", "path": stagedRelative, "proposal_id": id]))]
            case 7:
                return [.toolRequest(try! cadMakeCall("staged-query-bodies", [
                    "action": "query", "path": stagedRelative, "kind": "bodies"]))]
            case 8:
                guard let bodyID = cadRowIDFromEvidence(evidence, "staged-query-bodies") else { return [] }
                return [.toolRequest(try! cadMakeCall("staged-measure", [
                    "action": "measure", "path": stagedRelative, "op": "body",
                    "handles": ["body:\(bodyID)"]])),
                        .toolRequest(try! cadMakeCall("staged-export", [
                            "action": "export", "path": stagedRelative, "output": "staged.export.step"]))]
            case 9:
                // A foreign package beside the staged one (same draft root)
                // must not be reachable through this canvas's binding.
                return [.toolRequest(try! cadMakeCall("foreign-propose", [
                    "action": "propose", "path": foreignURL.path, "op": "sketch.create",
                    "args": #"{"name":"Nope"}"#, "summary": "foreign"]))]
            default:
                return [.textDelta(.init(text: "staged canvas CAD 完成"))]
            }
        }
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID, provider: provider, model: model,
                allowedToolNames: [CadDocumentTool.name],
                workspaceRootURL: workspace,
                canvasStagedDocument: staged),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(),
            auditSink: audit,
            checkpointStore: nil,
            sink: sink,
            runID: runID)
        try await runtime.start(goal: "画布暂存 CAD：提案、应用、导出；外部文档必须被拒绝")

        let results = await sink.snapshot()
        // RELATIVE staged path: propose → apply → sketch profile → extrude →
        // measure → export all close through the runtime's own authority.
        let stagedApply = try toolResult(results, "staged-apply")
        let stagedReply = try cadJSON(stagedApply.outputSummary)
        XCTAssertEqual(stagedReply["mode"] as? String, "runtime-authority",
                       "the staged apply must run on the runtime authority: \(stagedApply.outputSummary)")
        XCTAssertEqual(try toolResult(results, "staged-query-sketches").status, .ok)
        let profileApply = try toolResult(results, "staged-apply-profile")
        XCTAssertEqual(try cadJSON(profileApply.outputSummary)["mode"] as? String, "runtime-authority")
        let extrudeApply = try toolResult(results, "staged-apply-extrude")
        XCTAssertEqual(try cadJSON(extrudeApply.outputSummary)["mode"] as? String, "runtime-authority")

        let measureReply = try cadJSON(try toolResult(results, "staged-measure").outputSummary)
        let measured = try XCTUnwrap(measureReply["result"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(measured["volumeMM3"] as? Double), 25_000)
        let exportReply = try cadJSON(try toolResult(results, "staged-export").outputSummary)
        XCTAssertEqual(exportReply["ok"] as? Bool, true, "\(exportReply)")

        let stagedIdentityValue = await FloeCADDocument.storedIdentity(at: stagedURL)
        let stagedIdentity = try XCTUnwrap(stagedIdentityValue)
        XCTAssertEqual(stagedIdentity.revision, stagedRevisionBefore + 3,
                       "three applied proposals must commit exactly three revisions")

        // Foreign document: refused at the tool/host boundary, nothing stored
        // and the package keeps its exact pre-run revision.
        let foreignResult = try toolResult(results, "foreign-propose")
        XCTAssertNotEqual(foreignResult.status, .ok,
                          "a foreign document must be refused: \(foreignResult.outputSummary)")
        let foreignPending = await center.pendingNativeProposals(for: foreignURL)
        XCTAssertTrue(foreignPending.isEmpty, "no proposal may be stored for a foreign document")
        let foreignIdentityValue = await FloeCADDocument.storedIdentity(at: foreignURL)
        let foreignIdentity = try XCTUnwrap(foreignIdentityValue)
        XCTAssertEqual(foreignIdentity.revision, foreignRevisionBefore,
                       "a foreign package must be untouched")

        // No card for the staged non-repository work, and the whole run used
        // the real human policy through the canonical path.
        let states = await sink.stateNames()
        XCTAssertFalse(states.contains("waitingApproval"), "\(states)")
        let audited = await audit.snapshot()
        let cadEntries = audited.filter { $0.toolName == CadDocumentTool.name }
        XCTAssertGreaterThanOrEqual(cadEntries.count, 4)
        XCTAssertTrue(cadEntries.allSatisfy { $0.policyUsed == "human" }, "\(cadEntries.map(\.policyUsed))")
    }

    // MARK: - Catalog ↔ engine mutation classification

    /// The `cad.document` catalog and the engine's `CADServiceOperations`
    /// classifier are compiled from different modules but must describe ONE
    /// document-effect model. Every catalogued action has to agree with the
    /// engine, and every engine mutation has to be discoverable. The new
    /// assembly exploded-view and drawing assembly/BOM/annotation routes are
    /// named explicitly so a rename on either side fails here instead of
    /// surfacing as a runtime refusal or an unclassified direct write.
    func testWorkbenchCatalogMutationClassificationMatchesEngine() {
        for operation in CadServiceOperationCatalog.operations {
            XCTAssertEqual(
                operation.mutating,
                CADServiceOperations.isMutating(kind: operation.kind, action: operation.action),
                "\(operation.op) mutate classification drifted from CADServiceOperations")
        }
        for action in CADServiceOperations.mutatingAssemblyActions {
            XCTAssertNotNil(CadServiceOperationCatalog.operation(kind: "assembly", action: action),
                            "assembly.\(action) mutates in the engine but is missing from the catalog")
        }
        for action in CADServiceOperations.mutatingDrawingActions {
            XCTAssertNotNil(CadServiceOperationCatalog.operation(kind: "drawing", action: action),
                            "drawing.\(action) mutates in the engine but is missing from the catalog")
        }

        // Transient previews and reference queries are direct reads: they must
        // never require propose → apply.
        for action in ["reference", "referenceCandidates", "explodedViews",
                       "previewExplodedView", "resetExplodedView"] {
            XCTAssertNotNil(CadServiceOperationCatalog.operation(kind: "assembly", action: action))
            XCTAssertFalse(CADServiceOperations.isMutating(kind: "assembly", action: action),
                           "assembly.\(action) is a direct read/transient")
            XCTAssertFalse(CadServiceOperationCatalog.isMutating(kind: "assembly", action: action))
        }
        for action in ["addExplodedView", "updateExplodedView", "removeExplodedView"] {
            XCTAssertTrue(CADServiceOperations.mutatingAssemblyActions.contains(action))
            XCTAssertTrue(CadServiceOperationCatalog.isMutating(kind: "assembly", action: action))
        }
        for action in ["assemblySheet", "setBOM",
                       "addBalloon", "updateBalloon", "removeBalloon",
                       "addDimension", "updateDimension", "removeDimension",
                       "addAnnotation", "updateAnnotation", "removeAnnotation"] {
            XCTAssertTrue(CADServiceOperations.mutatingDrawingActions.contains(action))
            XCTAssertTrue(CadServiceOperationCatalog.isMutating(kind: "drawing", action: action))
        }
    }
}

#endif
