// FloeAppTests — Creative destination routing + canvas→ordinary-task
// handoff: REAL call chains through the real services (capability matrix,
// Linux image probe, run/provider resolution, workspace + task creation,
// durable idempotent route records, verified material snapshots, run→canvas
// binding authority, launch-fact reconciliation).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp
@testable import FloeTools

private actor RouteFakeCanvasRepository: CanvasDocumentRepository {
    private var projects: [UUID: CanvasProject]
    init(project: CanvasProject) { self.projects = [project.id: project] }
    func project(canvasID: UUID) async throws -> CanvasProject {
        guard let project = projects[canvasID] else {
            throw FloeError.validationFailed("missing canvas")
        }
        return project
    }
    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        projects[project.id] = project
    }
}

@Suite("FloeApp.CreativeDestination")
@MainActor
struct CreativeDestinationRouteTests {
    private struct World {
        let environment: AppEnvironment
        let provider: ProviderProfile
        let model: ModelProfile
        let runID: UUID
        let conversationID: UUID
        let routeDirectory: URL
    }

    private func makeWorld() async throws -> World {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let routeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-routes-\(UUID().uuidString)", isDirectory: true)
        CreativeRouteStore.storageDirectoryOverride = routeDirectory
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://creative-route.example/v1")!,
            displayName: "Creative Route Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "creative-route-model",
            displayName: "Creative Route Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.tools])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "来源任务", createdAt: Date(), updatedAt: Date()))
        let runID = UUID()
        try await environment.runStore.saveRun(.init(
            id: runID, conversationID: conversationID, state: "running", goal: "做一份网页工程",
            startedAt: Date(), providerID: provider.id, modelID: model.id))
        return World(environment: environment, provider: provider, model: model,
                     runID: runID, conversationID: conversationID, routeDirectory: routeDirectory)
    }

    private func context(_ world: World) -> ToolContext {
        ToolContext(runID: world.runID, cancellation: CancellationToken())
    }

    /// One real canvas: an image asset node (real ingested bytes) + a text
    /// node, plus the durable run→canvas binding the model tool requires.
    private struct CanvasFixture {
        let canvasID: UUID
        let documentID: UUID
        let assetNode: CanvasNode
        let textNode: CanvasNode
        let repository: RouteFakeCanvasRepository
    }

    private func makeCanvasFixture(_ world: World, bindSelection: Bool) async throws -> CanvasFixture {
        let canvasID = UUID()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString).png")
        try png.write(to: assetURL)
        let asset = try await CreativeAssetIngestionService(
            assetStore: world.environment.creativeAssetStore).importLocalFile(assetURL)
        try? FileManager.default.removeItem(at: assetURL)
        var assetNode = CanvasNode.placeholder(kind: .image, position: .init(x: 0, y: 0), zIndex: 0)
        assetNode.id = UUID()
        assetNode.title = "主视觉"
        assetNode.asset = .init(contentHash: asset.contentHash)
        var textNode = CanvasNode.placeholder(kind: .text, position: .init(x: 10, y: 10), zIndex: 1)
        textNode.id = UUID()
        textNode.title = "文案"
        textNode.text = "标题与说明"
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [assetNode, textNode])
        var project = CanvasProject(
            id: canvasID, name: "画布", documents: [document], selectedDocumentID: document.id)
        project.revision = 7
        // The durable run→canvas binding: the tool may ONLY hand off from
        // this canvas/document, restricted to the user's selection.
        try await CanvasRunContextStore(database: world.environment.database).save(
            CanvasRunContext(
                runID: world.runID,
                conversationID: world.conversationID,
                canvasID: canvasID,
                documentID: document.id,
                selectedNodeIDs: bindSelection ? [assetNode.id] : [],
                projectRevision: project.revision))
        return CanvasFixture(
            canvasID: canvasID, documentID: document.id, assetNode: assetNode,
            textNode: textNode, repository: RouteFakeCanvasRepository(project: project))
    }

    private func handoffTool(_ world: World, fixture: CanvasFixture) -> CanvasStartOrdinaryTaskTool {
        CanvasStartOrdinaryTaskTool(
            environment: world.environment,
            canvasRepository: fixture.repository,
            runContexts: CanvasRunContextStore(database: world.environment.database))
    }

    @Test("destination decision: visual family → canvas; linux-needed or web family → project; office+canvas hint refused; canvas hint never accepts Linux")
    func destinationDecision() async throws {
        let world = try await makeWorld()
        let canvas = CreativeDestinationRouter.assessDestination(
            family: .image, needsLinux: false, hint: nil, environment: world.environment)
        #expect(canvas.destination == "canvas")
        let web = CreativeDestinationRouter.assessDestination(
            family: .webpage, needsLinux: false, hint: nil, environment: world.environment)
        #expect(web.destination == "project")
        let linux = CreativeDestinationRouter.assessDestination(
            family: .webpage, needsLinux: true, hint: nil, environment: world.environment)
        #expect(linux.destination == "project")
        let refused = CreativeDestinationRouter.assessDestination(
            family: .officeDocument, needsLinux: false, hint: "canvas", environment: world.environment)
        #expect(refused.destination == "refused")
        // A canvas hint must NOT swallow a Linux need (canvas+Linux is
        // impossible); native CAD visual composition stays on the canvas.
        let canvasLinux = CreativeDestinationRouter.assessDestination(
            family: .image, needsLinux: true, hint: "canvas", environment: world.environment)
        #expect(canvasLinux.destination == "project")
        #expect(canvasLinux.reasons.contains(where: { $0.contains("cannot run on the canvas") }))
        let cad = CreativeDestinationRouter.assessDestination(
            family: .cad, needsLinux: false, hint: "canvas", environment: world.environment)
        #expect(cad.destination == "canvas")
        // The model's EXPLICIT destination intent is honored even when it
        // overrides the family default: visual family + project hint, and a
        // refusal for a non-visual family + canvas hint both stay
        // distinguishable — family alone never silently re-routes an
        // explicit choice.
        let explicitProject = CreativeDestinationRouter.assessDestination(
            family: .image, needsLinux: false, hint: "project", environment: world.environment)
        #expect(explicitProject.destination == "project")
        let webCanvas = CreativeDestinationRouter.assessDestination(
            family: .webpage, needsLinux: false, hint: "canvas", environment: world.environment)
        #expect(webCanvas.destination == "refused")
        #expect(webCanvas.reasons.contains(where: { $0.contains("not a visual composition") }))
    }

    @Test("chooseDestination (notes, native capability) creates ONE task; replay returns it without recreating")
    func chooseDestinationCreatesAndReplays() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "写一份双语文档", family: "notes", needsLinux: false,
            hint: nil, operationID: "route-\(UUID().uuidString)")
        let first = try await tool.execute(args, context: context(world))
        #expect(first.exitStatus == 0)
        #expect(first.summary.contains("destination=project"))
        #expect(first.summary.contains("created=true"))
        // The initiating run is not in the foreground list → navigation
        // honestly suppressed (no focus stealing from tests/late calls).
        #expect(first.summary.contains("navigated=false"))
        let recordCount = try CreativeRouteStore.load().count
        #expect(recordCount == 1)
        let replay = try await tool.execute(args, context: context(world))
        #expect(replay.summary.contains("created=false"))
        #expect(try CreativeRouteStore.load().count == 1, "replays must not duplicate the destination")
    }

    @Test("chooseDestination with Linux required refuses honestly when the image is not installed")
    func linuxRequiredRefusesWithoutImage() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "起一个有依赖的网页服务", family: "webpage", needsLinux: true,
            hint: nil, operationID: "route-linux-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(args, context: context(world))
        }
        // The reservation exists with an honest failed state (recoverable);
        // no workspace or task was created.
        let records = try CreativeRouteStore.load()
        #expect(records.count == 1)
        #expect(records.first?.status == .failed)
    }

    @Test("canvas handoff snapshots explicit materials; replay never duplicates; errors are readable")
    func canvasHandoffMaterialsAndIdempotency() async throws {
        let world = try await makeWorld()
        let fixture = try await makeCanvasFixture(world, bindSelection: false)
        let tool = handoffTool(world, fixture: fixture)
        let args = CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: fixture.canvasID.uuidString,
            nodeIDs: [fixture.assetNode.id.uuidString, fixture.textNode.id.uuidString],
            goal: "用这些素材做落地页",
            family: nil, projectWorkspaceID: nil, createProject: true,
            operationID: "handoff-\(UUID().uuidString)")
        let first = try await tool.execute(args, context: context(world))
        #expect(first.exitStatus == 0)
        #expect(first.summary.contains("materials=2"))
        #expect(try CreativeRouteStore.load().count == 1)
        // The source canvas is untouched.
        let after = try await fixture.repository.project(canvasID: fixture.canvasID)
        #expect(after.documents.first?.nodes.count == 2)

        // Replay: same operationID → nothing recreated.
        let replay = try await tool.execute(args, context: context(world))
        #expect(replay.summary.contains("created=false"))
        #expect(replay.summary.contains("replayed operationID"))
        #expect(try CreativeRouteStore.load().count == 1)

        // Missing node: readable error, no route recorded.
        let missing = CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: fixture.canvasID.uuidString,
            nodeIDs: [UUID().uuidString],
            goal: "用这些素材做落地页",
            family: nil, projectWorkspaceID: nil, createProject: true,
            operationID: "handoff-missing-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(missing, context: context(world))
        }
        #expect(try CreativeRouteStore.load().count == 1)

        // Validation: empty node list refused before any I/O.
        await #expect(throws: (any Error).self) {
            try tool.validate(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: fixture.canvasID.uuidString, nodeIDs: [],
                goal: "x", family: nil, projectWorkspaceID: nil, createProject: nil,
                operationID: "handoff-empty-\(UUID().uuidString)"))
        }
    }

    @Test("handoff authority: no run binding, cross-canvas and outside-selection references fail before routing")
    func handoffAuthorityRejectsForgedReferences() async throws {
        let world = try await makeWorld()
        // No binding at all → the tool refuses before any route record.
        let emptyDocumentID = UUID()
        let unbound = CanvasStartOrdinaryTaskTool(
            environment: world.environment,
            canvasRepository: RouteFakeCanvasRepository(project: CanvasProject(
                id: UUID(), name: "?",
                documents: [CanvasDocument(id: emptyDocumentID, name: "d", nodes: [])],
                selectedDocumentID: emptyDocumentID)),
            runContexts: CanvasRunContextStore(database: world.environment.database))
        await #expect(throws: (any Error).self) {
            _ = try await unbound.execute(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: UUID().uuidString, nodeIDs: [UUID().uuidString],
                goal: "x", family: nil, projectWorkspaceID: nil, createProject: true,
                operationID: "handoff-unbound-\(UUID().uuidString)"), context: context(world))
        }
        #expect(try CreativeRouteStore.load().isEmpty)

        // A bound run naming a DIFFERENT canvas → cross-canvas refusal.
        let fixture = try await makeCanvasFixture(world, bindSelection: false)
        let tool = handoffTool(world, fixture: fixture)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: UUID().uuidString,
                nodeIDs: [fixture.assetNode.id.uuidString],
                goal: "x", family: nil, projectWorkspaceID: nil, createProject: true,
                operationID: "handoff-cross-\(UUID().uuidString)"), context: context(world))
        }
        #expect(try CreativeRouteStore.load().isEmpty)

        // The user's selection is [assetNode]; naming the OTHER (unselected)
        // node is refused — no guessing beyond the selection.
        let selectedWorld = try await makeWorld()
        let selectedFixture = try await makeCanvasFixture(selectedWorld, bindSelection: true)
        let selectedTool = handoffTool(selectedWorld, fixture: selectedFixture)
        await #expect(throws: (any Error).self) {
            _ = try await selectedTool.execute(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: selectedFixture.canvasID.uuidString,
                nodeIDs: [selectedFixture.textNode.id.uuidString],
                goal: "x", family: nil, projectWorkspaceID: nil, createProject: true,
                operationID: "handoff-outside-\(UUID().uuidString)"), context: context(selectedWorld))
        }
        #expect(try CreativeRouteStore.load().isEmpty)
        // …while the selected node itself hands off fine.
        let ok = try await selectedTool.execute(CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: selectedFixture.canvasID.uuidString,
            nodeIDs: [selectedFixture.assetNode.id.uuidString],
            goal: "用选中素材做落地页", family: nil, projectWorkspaceID: nil, createProject: true,
            operationID: "handoff-selected-\(UUID().uuidString)"), context: context(selectedWorld))
        #expect(ok.exitStatus == 0)
        #expect(ok.summary.contains("materials=1"))
    }

    @Test("destination choice is explicit: neither/both choices and unknown projects are refused")
    func destinationChoiceMustBeExplicitAndReal() async throws {
        let world = try await makeWorld()
        let fixture = try await makeCanvasFixture(world, bindSelection: false)
        let tool = handoffTool(world, fixture: fixture)
        let base = CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: fixture.canvasID.uuidString,
            nodeIDs: [fixture.textNode.id.uuidString],
            goal: "x", family: nil,
            projectWorkspaceID: nil, createProject: nil,
            operationID: "handoff-ambiguous-\(UUID().uuidString)")
        // Neither choice → refused at validation.
        await #expect(throws: (any Error).self) { try tool.validate(base) }
        // Both choices → refused at validation.
        await #expect(throws: (any Error).self) {
            try tool.validate(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: base.canvasID, nodeIDs: base.nodeIDs, goal: base.goal,
                family: nil, projectWorkspaceID: UUID().uuidString, createProject: true,
                operationID: base.operationID))
        }
        // An unknown existing project → refused at routing (AFTER the
        // deterministic identity reservation, which stays prepared and
        // resumable — never a duplicate project).
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(CanvasStartOrdinaryTaskTool.Arguments(
                canvasID: base.canvasID, nodeIDs: base.nodeIDs, goal: base.goal,
                family: nil, projectWorkspaceID: UUID().uuidString, createProject: nil,
                operationID: "handoff-ghost-\(UUID().uuidString)"), context: context(world))
        }
        let records = try CreativeRouteStore.load()
        #expect(records.count == 1)
        #expect(records.first?.status == .prepared)
        #expect(records.first?.destinationWorkspaceID != nil)
    }

    @Test("same operationID with a DIFFERENT payload is a conflict, never silently merged")
    func payloadConflictRejected() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let operationID = "conflict-\(UUID().uuidString)"
        let first = CreativeChooseDestinationTool.Arguments(
            goal: "写一份双语文档", family: "notes", needsLinux: false,
            hint: nil, operationID: operationID)
        _ = try await tool.execute(first, context: context(world))
        let changed = CreativeChooseDestinationTool.Arguments(
            goal: "改成三语", family: "notes", needsLinux: false,
            hint: nil, operationID: operationID)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(changed, context: context(world))
        }
        #expect(try CreativeRouteStore.load().count == 1)
    }

    @Test("the first provider turn sees staged materials and the frozen manifest (document, revision, UTF-8 names)")
    func firstProviderSeesMaterialsAndManifest() async throws {
        let world = try await makeWorld()
        let fixture = try await makeCanvasFixture(world, bindSelection: false)
        let tool = handoffTool(world, fixture: fixture)
        let operationID = "manifest-\(UUID().uuidString)"
        let result = try await tool.execute(CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: fixture.canvasID.uuidString,
            nodeIDs: [fixture.assetNode.id.uuidString],
            goal: "用素材做落地页", family: nil, projectWorkspaceID: nil, createProject: true,
            operationID: operationID), context: context(world))
        // The tool reports the frozen source document + revision.
        #expect(result.summary.contains("sourceDocumentID=\(fixture.documentID.uuidString)"))
        #expect(result.summary.contains("sourceRevision=7"))
        let record = try #require(try CreativeRouteStore.existing(
            operationID: operationID, sourceRunID: world.runID))
        #expect(record.status == .started)
        #expect(record.sourceDocumentID == fixture.documentID)
        #expect(record.sourceProjectRevision == 7)
        #expect(record.materials.count == 1)
        #expect(record.materials.first?.sha256 == FloeDigest.sha256Hex(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!))
        #expect(record.materials.first?.nodeID == fixture.assetNode.id)
        // The UTF-8 original name survives (no ASCII mangling).
        #expect(record.materials.first?.name.contains("主视觉") == true)
        // The destination workspace really contains the verified bytes.
        let workspace = try #require(try await SQLiteWorkspaceStore(
            database: world.environment.database).workspace(id: record.destinationWorkspaceID))
        var isStale = false
        let root = try #require(try URL(
            resolvingBookmarkData: workspace.rootBookmark, options: [],
            relativeTo: nil, bookmarkDataIsStale: &isStale))
        let staged = root.appendingPathComponent("HandoffMaterials/\(record.materials[0].name)")
        #expect(try Data(contentsOf: staged) == Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!)
    }

    @Test("a stale prepared record converges against the real launch facts — never re-sends, never duplicates")
    func stalePreparedRecordConvergesWithoutResend() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let operationID = "stale-\(UUID().uuidString)"
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "写一份恢复文档", family: "notes", needsLinux: false,
            hint: nil, operationID: operationID)
        _ = try await tool.execute(args, context: context(world))
        let record = try #require(try CreativeRouteStore.existing(
            operationID: operationID, sourceRunID: world.runID))
        #expect(record.status == .started)
        let destinationID = try #require(record.destinationConversationID)

        // Simulate the crash window: revert the record to `prepared` (as if
        // the association save never happened after the launch committed).
        var stale = record
        stale.status = .prepared
        stale.error = "simulated crash"
        try CreativeRouteStore.upsert(stale)

        // The destination conversation + its launch run really exist.
        let runs = try await world.environment.runStore.runs(conversationID: destinationID)
        #expect(!runs.isEmpty)

        // Replay: the router queries the launch facts, marks started and
        // returns WITHOUT re-sending the launch (no second run/message).
        let replay = try await tool.execute(args, context: context(world))
        #expect(replay.summary.contains("created=false"))
        let after = try #require(try CreativeRouteStore.existing(
            operationID: operationID, sourceRunID: world.runID))
        #expect(after.status == .started)
        let runsAfter = try await world.environment.runStore.runs(conversationID: destinationID)
        #expect(runsAfter.count == runs.count, "the launch must never be re-sent")
    }

    @Test("concurrent identical routes coalesce into ONE destination")
    func concurrentIdenticalRoutesCoalesce() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "并发同一份文档", family: "notes", needsLinux: false,
            hint: nil, operationID: "concurrent-\(UUID().uuidString)")
        async let first = tool.execute(args, context: context(world))
        async let second = tool.execute(args, context: context(world))
        let outcomes = try await [first, second]
        #expect(try CreativeRouteStore.load().count == 1)
        // Exactly one call may report creation; the coalesced/replayed twin
        // returns the SAME destination without recreating or re-navigating.
        #expect(outcomes.filter { $0.summary.contains("created=true") }.count == 1)
        let records = try CreativeRouteStore.load()
        #expect(records.first?.status == .started)
    }

    @Test("a destination conversation cannot recursively spawn another destination")
    func recursiveDestinationIsRefused() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "写第一份文档", family: "notes", needsLinux: false,
            hint: nil, operationID: "recursive-\(UUID().uuidString)")
        _ = try await tool.execute(args, context: context(world))
        let record = try #require(try CreativeRouteStore.existing(
            operationID: args.operationID, sourceRunID: world.runID))
        let destinationID = try #require(record.destinationConversationID)
        // A run launched inside the destination conversation tries to route
        // again → refused (no route tool-loops, no destination chains).
        let destinationRun = try #require(
            try await world.environment.runStore.runs(conversationID: destinationID).first)
        let nested = ToolContext(runID: destinationRun.id, cancellation: CancellationToken())
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(CreativeChooseDestinationTool.Arguments(
                goal: "再开一个目的地", family: "notes", needsLinux: false,
                hint: nil, operationID: "recursive-2-\(UUID().uuidString)"), context: nested)
        }
        #expect(try CreativeRouteStore.load().count == 1)
    }

    @Test("navigation is delivered ONLY for the real foreground run with the seam installed")
    func foregroundGating() async throws {
        let world = try await makeWorld()
        var navigated: [UUID] = []
        CreativeDestinationRouter.navigator = { id in navigated.append(id) }
        defer { CreativeDestinationRouter.navigator = nil }
        // No probe installed → background → suppressed.
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "写文档", family: "notes", needsLinux: false,
            hint: nil, operationID: "nav-\(UUID().uuidString)")
        let background = try await tool.execute(args, context: context(world))
        #expect(background.summary.contains("navigated=false"))
        #expect(navigated.isEmpty)
    }

    @Test("the foreground canvas-cover run is eligible for navigation delivery")
    func canvasCoverForegroundRunNavigates() async throws {
        let world = try await makeWorld()
        let fixture = try await makeCanvasFixture(world, bindSelection: false)
        var navigated: [UUID] = []
        CreativeDestinationRouter.navigator = { id in navigated.append(id) }
        defer { CreativeDestinationRouter.navigator = nil }
        // The user is looking at the canvas through the root canvas cover:
        // the run's durable canvas binding is the presented canvas.
        CreativeDestinationRouter.foregroundRunProbe = { runID in
            let context = try? await CanvasRunContextStore(
                database: world.environment.database).context(runID: runID)
            return context?.canvasID == fixture.canvasID
        }
        defer { CreativeDestinationRouter.foregroundRunProbe = nil }
        let tool = handoffTool(world, fixture: fixture)
        let result = try await tool.execute(CanvasStartOrdinaryTaskTool.Arguments(
            canvasID: fixture.canvasID.uuidString,
            nodeIDs: [fixture.textNode.id.uuidString],
            goal: "用文案做落地页", family: nil, projectWorkspaceID: nil, createProject: true,
            operationID: "nav-canvas-\(UUID().uuidString)"), context: context(world))
        #expect(result.summary.contains("navigated=true"))
        #expect(navigated.count == 1)
    }

    @Test("routed destination delivery dismisses the root-owned covers so the destination is visible")
    func routedDestinationDismissesOwnedModals() {
        let router = AppRouter()
        let destination = UUID()
        let canvas = UUID()
        router.presentedCanvasID = canvas
        router.presentsCanvas = true
        router.presentedDesignPage = DesignPageRequest(
            target: DesignTarget(
                kind: .fileDocument, ownerID: UUID().uuidString,
                sourceID: "site/index.html"),
            conversationID: UUID())
        router.presentRoutedDestination(destination)
        #expect(router.presentsCanvas == false)
        #expect(router.presentedCanvasID == nil)
        #expect(router.presentedDesignPage == nil)
        #expect(router.workbenchSelection == .conversation(destination))

        // A routed canvas presents through the cover and never stacks on the
        // design page cover.
        router.presentedDesignPage = DesignPageRequest(
            target: DesignTarget(
                kind: .fileDocument, ownerID: UUID().uuidString,
                sourceID: "site/index.html"),
            conversationID: UUID())
        router.presentRoutedCanvas(canvas)
        #expect(router.presentedDesignPage == nil)
        #expect(router.presentsCanvas == true)
        #expect(router.presentedCanvasID == canvas)
    }

    @Test("canvas destination creates a REAL durable canvas; replay returns it without recreating")
    func canvasDestinationIsRealAndIdempotent() async throws {
        let world = try await makeWorld()
        let tool = CreativeChooseDestinationTool(environment: world.environment)
        let args = CreativeChooseDestinationTool.Arguments(
            goal: "做视觉海报", family: "image", needsLinux: false,
            hint: nil, operationID: "canvas-\(UUID().uuidString)")
        let first = try await tool.execute(args, context: context(world))
        #expect(first.summary.contains("destination=canvas"))
        guard let range = first.summary.range(of: "canvasID=") else {
            Issue.record("canvasID missing"); return
        }
        let canvasIDString = first.summary[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        let canvasID = try #require(UUID(uuidString: canvasIDString))
        // Durable canvas document + workspace record exist.
        #expect(WorkspaceCanvasRegistry.exists(canvasID: canvasID))
        #expect(try await SQLiteWorkspaceStore(
            database: world.environment.database).workspace(id: canvasID) != nil)
        // Replay returns the SAME canvas without recreating.
        let replay = try await tool.execute(args, context: context(world))
        #expect(replay.summary.contains("canvasID=\(canvasID.uuidString)"))
        #expect(replay.summary.contains("navigated=false"))
        #expect(try CreativeRouteStore.load().count == 1)
    }

    @Test("tools are discoverable in the shared catalog/registry AND inside the real canvas ceiling")
    func toolsAreRegistered() {
        #expect(ToolCatalog.descriptor(named: "creative.chooseDestination") != nil)
        #expect(ToolCatalog.descriptor(named: "canvas.startOrdinaryTask") != nil)
        #expect(ToolRunnerRegistry.shared.runner(named: "creative.chooseDestination") != nil)
        #expect(ToolRunnerRegistry.shared.runner(named: "canvas.startOrdinaryTask") != nil)
        // The canvas model can ACTUALLY discover/call the bounded handoff:
        // it is part of the native ceiling used to build a canvas run's
        // allowed tool names.
        #expect(CanvasAgentToolPolicy.nativeToolNames.contains("canvas.startOrdinaryTask"))
        let ceiling = CanvasAgentToolPolicy.allowedToolNames(servers: [], discoveredTools: [:])
        #expect(ceiling.contains("canvas.startOrdinaryTask"))
        // …and the ceiling stays visual-only: no execution surface entered
        // the canvas through the handoff (no Linux/shell/workspace write).
        #expect(!ceiling.contains(where: { $0.hasPrefix("linux.") }))
        #expect(!ceiling.contains(where: { $0.hasPrefix("shell.") }))
        #expect(!ceiling.contains(where: { $0.hasPrefix("workspace.") }))
    }

    @Test("a corrupt route store fails loudly, never silently empty")
    func corruptStoreFailsLoudly() async throws {
        let world = try await makeWorld()
        let url = try CreativeRouteStore.fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) {
            _ = try CreativeRouteStore.load()
        }
    }

    @Test("a route store read error fails closed — never mistaken for an empty store")
    func storeReadErrorFailsClosed() async throws {
        let world = try await makeWorld()
        let url = try CreativeRouteStore.fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A valid record on disk…
        try String(data: JSONEncoder().encode([
            CreativeRouteRecord(
                operationID: "existing", payloadDigest: "d", status: .started,
                sourceConversationID: UUID(), sourceRunID: UUID(), sourceCanvasID: nil,
                sourceDocumentID: nil, sourceProjectRevision: nil, sourceNodeIDs: [],
                materials: [], destinationConversationID: UUID(),
                destinationWorkspaceID: UUID(), destinationEnvironmentID: nil,
                destinationCanvasID: nil, family: "notes", goal: "g", error: nil,
                createdAt: Date())
        ]), encoding: .utf8)!.write(to: url, atomically: true, encoding: .utf8)
        // …made unreadable: load must THROW (fail closed), not return [].
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        await #expect(throws: (any Error).self) {
            _ = try CreativeRouteStore.load()
        }
    }
}
#endif
