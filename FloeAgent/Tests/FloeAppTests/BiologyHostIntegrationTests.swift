// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyHostAdapter
import FloeEnvironments
@testable import FloeApp

@Suite("Biology original/task/registered-tool host contracts", .serialized)
@MainActor struct BiologyHostIntegrationTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biology-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func reservedPersonalIDIsTheNativeIDAndCollisionNeverOverwrites() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BiologyProjectStore(root: root), id = UUID()
        let original = try await store.createBound(id: id, title: "Original")
        #expect(original.id == id)
        do { _ = try await store.createBound(id: id, title: "Replacement"); Issue.record("Reserved ID overwrote an original") } catch { }
        #expect(try await store.load(id) == original)
        try await store.trash(id, expectedRevision: original.revision)
        do { _ = try await store.createBound(id: id, title: "Reused after delete"); Issue.record("Deleted ID was reused") } catch { }
        let deleted = try #require(try await store.deletedProjects().first { $0.projectID == id })
        let restored = try await store.restoreDeleted(deleted.id, projectID: id)
        #expect(restored.id == id && restored.title == "Original")
    }
    @Test func twoStoreInstancesSerializeTheSameReservedID() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try BiologyProjectStore(root: root), b = try BiologyProjectStore(root: root), id = UUID()
        let first = Task { () -> BiologyProject? in try? await a.createBound(id: id, title: "A") }
        let second = Task { () -> BiologyProject? in try? await b.createBound(id: id, title: "B") }
        let (aResult, bResult) = await (first.value, second.value)
        let results = [aResult, bResult].compactMap { $0 }
        #expect(results.count == 1)
        #expect(try await a.load(id) == results.first)
    }
    @Test func toolCreationIdentityReplayStillUsesItsOriginalDeterministicID() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BiologyProjectStore(root: root)
        var identity = BiologyMutationIdentity(owner: .init(taskID: UUID(), hostRunID: UUID()),
            requestID: "exact-create", argumentDigest: BiologyProjectStore.digest(Data("original".utf8)))
        let original = try await store.create(title: "Original", identity: identity)
        #expect(try await store.create(title: "Ignored on exact replay", identity: identity) == original)
        do { _ = try await store.createBound(id: original.id, title: "Host override"); Issue.record("Host ID replaced a tool-created project") } catch { }
        identity.argumentDigest = BiologyProjectStore.digest(Data("changed".utf8))
        do { _ = try await store.create(title: "Changed", identity: identity); Issue.record("Changed call replay overwrote its original") } catch { }
        #expect(try await store.load(original.id) == original)
    }

    private struct Fixture: Sendable {
        let root: URL
        let database: DatabaseManager
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let authority: StudioDocumentAccess
        let authorityRoot: URL
        let library: PersonalContentLibrary
        let store: BiologyProjectStore
        let access: BiologyHostAccess
        let taskID: UUID
        let runID: UUID
        let projectID: UUID
        let registry: ToolRunnerRegistry
        let service: BiologyService
        @MainActor func context(_ tool: String, call: String = UUID().uuidString) -> ToolContext {
            var context = ToolContext(runID: runID, toolCallID: call,
                allowedToolNames: BiologyHostServices.names, workspaceRootURL: root,
                cancellation: CancellationToken(), conversationID: taskID,
                frozenEffectiveCatalogNames: BiologyHostServices.names)
            context.executionToolName = tool
            return context
        }
    }
    private func fixture() async throws -> Fixture {
        let root = try sandbox()
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database), runs = SQLiteRunStore(database: database)
        let authorityRoot = root.appendingPathComponent("Authority"), authority = try StudioDocumentAccess(root: authorityRoot)
        let libraryRoot = root.appendingPathComponent("Library"), library = PersonalContentLibrary(root: libraryRoot)
        let store = try BiologyProjectStore(root: root.appendingPathComponent("Projects"))
        let taskID = UUID(), runID = UUID(), projectID = UUID(), now = Date()
        try await conversations.saveConversation(.init(id: taskID, title: "Owned synthetic biology task", createdAt: now, updatedAt: now))
        try await runs.saveRun(.init(id: runID, conversationID: taskID, state: "executing", goal: "Contract", startedAt: now))
        _ = try await library.create(kind: .biology, title: "Owned", id: projectID) { directory, id in
            _ = try await store.createBound(id: id, title: "Owned")
            try BiologyOriginalBinding(projectID: id).write(to: directory)
        }
        try await authority.finishCreation(conversationID: taskID, projectID: projectID)
        let access = BiologyHostAccess(runs: runs, conversations: conversations, authority: authority,
            libraryRoot: libraryRoot, library: { library })
        let service = try BiologyService(store: store, authorize: { try await access.permit($0) })
        let bridge = BiologyToolBridge(service: service, contexts: BiologyExecutionContexts(),
            grant: { try await access.grant($0) }, registerCreatedProject: { _, _ in throw BiologyHostError.readOnly })
        let registry = ToolRunnerRegistry(); try await bridge.register(in: registry)
        let hooks = BiologyLibraryHooks(attachCreated: { _, _ in throw BiologyHostError.readOnly },
            lifecycle: { _, _, _ in throw BiologyHostError.readOnly })
        let boundary = BiologyToolCallBoundary(access: access, hooks: hooks, didMutate: { ids, name in
            if name != "biology.deleteProject" { try await access.synchronizeMetadata(ids, store: store) }
        })
        for name in BiologyHostServices.names {
            let original = try #require(registry.runner(named: name))
            // Test only the actual native store/authorization boundary here,
            // without changing the process-wide App/Linux routing instance.
            let isolated = AnyAgentTool(descriptor: original.descriptor, run: original.run,
                validateArguments: original.validateArguments,
                preflightSubmission: original.preflightSubmission, routing: ToolEnvironmentRouting())
            registry.register(boundary.wrap(isolated))
        }
        return Fixture(root: root, database: database, conversations: conversations, runs: runs,
            authority: authority, authorityRoot: authorityRoot, library: library, store: store,
            access: access, taskID: taskID, runID: runID, projectID: projectID, registry: registry, service: service)
    }
    @Test func actualRegisteredFamilyReadsWritesAndRejectsStaleRevision() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(Set(f.registry.allDescriptors.map(\.name)) == BiologyHostServices.names)
        #expect(f.registry.allDescriptors.allSatisfy { $0.executionBoundary == .mainRunOnly })
        let read = try #require(f.registry.runner(named: "biology.read"))
        let before = try await read.execute(argumentsJSON: BiologyCoding.encode(BiologyJSON.object(["projectID": .string(f.projectID.uuidString)])),
            context: f.context("biology.read"))
        #expect(before.exitStatus == 0 && before.capturedOutput?.contains("Owned") == true)
        let edit = try #require(f.registry.runner(named: "biology.edit"))
        let args = try BiologyCoding.encode(BiologyJSON.object(["projectID": .string(f.projectID.uuidString),
            "expectedRevision": .number(1), "notes": .string("persisted through real registered bridge")]))
        _ = try await edit.execute(argumentsJSON: args, context: f.context("biology.edit", call: "edit-a"))
        let saved = try await f.store.load(f.projectID)
        #expect(saved.notes == "persisted through real registered bridge")
        let projected = try await f.library.resolve(f.projectID).record
        #expect(projected.modifiedAt >= saved.modifiedAt)
        do { _ = try await edit.execute(argumentsJSON: args, context: f.context("biology.edit", call: "stale-b")); Issue.record("Stale revision wrote") } catch { }
        #expect(try await f.store.load(f.projectID) == saved)
    }
    @Test func actualBridgeRejectsTemporaryForeignEndedAndCancelledRuns() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let read = try #require(f.registry.runner(named: "biology.read"))
        let args = try BiologyCoding.encode(BiologyJSON.object(["projectID": .string(f.projectID.uuidString)]))
        var contexts = [f.context("biology.read"), f.context("biology.read"), f.context("biology.read")]
        contexts[0].temporaryReadOnly = true; contexts[1].conversationID = UUID(); contexts[2].cancellation.cancel()
        for context in contexts {
            do { _ = try await read.execute(argumentsJSON: args, context: context); Issue.record("Invalid run reached Biology original") } catch { }
        }
        try await f.runs.updateRunState(id: f.runID, state: "completed", endedAt: Date())
        do { _ = try await read.execute(argumentsJSON: args, context: f.context("biology.read")); Issue.record("Ended run read as current") } catch { }
        #expect(try await f.store.load(f.projectID).revision == 1)
    }
    @Test func writableSiblingDoesNotElevateAReadOnlyOriginal() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sibling = UUID()
        _ = try await f.library.create(kind: .biology, title: "Read only", id: sibling) { directory, id in
            _ = try await f.store.createBound(id: id, title: "Read only")
            try BiologyOriginalBinding(projectID: id).write(to: directory)
        }
        let pool = try DatabasePool(path: f.authorityRoot.appendingPathComponent("access.sqlite").path)
        try await pool.write { db in try db.execute(sql: "INSERT INTO document_access(conversation_id,project_id,can_edit) VALUES (?,?,0)",
            arguments: [f.taskID.uuidString, sibling.uuidString]) }
        let grant = try await f.access.grant(f.context("biology.read"))
        #expect(grant.projects == [f.projectID, sibling] && !grant.readOnly)
        let read = try #require(f.registry.runner(named: "biology.read"))
        _ = try await read.execute(argumentsJSON: BiologyCoding.encode(BiologyJSON.object(["projectID": .string(sibling.uuidString)])), context: f.context("biology.read"))
        let edit = try #require(f.registry.runner(named: "biology.edit"))
        let args = try BiologyCoding.encode(BiologyJSON.object(["projectID": .string(sibling.uuidString), "expectedRevision": .number(1), "notes": .string("Must not write")]))
        do { _ = try await edit.execute(argumentsJSON: args, context: f.context("biology.edit")); Issue.record("Writable sibling elevated a read-only grant") } catch { }
        #expect(try await f.store.load(sibling).notes.isEmpty)
    }
    @Test func nativeConsoleSeamForwardsOnlyValidatedCurrentProjectRequests() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        actor Capture {
            var calls: [String] = []
            func record(_ id: String?) throws -> BiologyJSON {
                guard let id else { throw BiologyHostError.changed }; calls.append(id)
                return .object(["realHostCall": .string(id)])
            }
            func count() -> Int { calls.count }
        }
        let capture = Capture(), owner = BiologyExecutionOwner(taskID: f.taskID, hostRunID: f.runID)
        let session = BiologyToolSession(service: f.service, authorizedProjectIDs: [f.projectID], owner: owner,
            hostInvocation: { _, _, id in try await capture.record(id) })
        let args: BiologyJSON = .object(["projectID": .string(f.projectID.uuidString)])
        let result = try await session.invoke(name: "biology.read", arguments: args, requestID: "native-a")
        #expect(result["realHostCall"]?.string == "native-a")
        do { _ = try await session.invoke(name: "biology.read", arguments: .object(["projectID": .string(UUID().uuidString)]), requestID: "foreign"); Issue.record("Foreign target forwarded") } catch { }
        do { _ = try await session.invoke(name: "biology.read", arguments: args); Issue.record("Missing stable request ID forwarded") } catch { }
        do { _ = try await session.invoke(name: "biology.read", arguments: .object(["projectID": .string(f.projectID.uuidString), "invented": .bool(true)]), requestID: "invalid"); Issue.record("Invalid schema forwarded") } catch { }
        let cancelled = BiologyToolSession(service: f.service, authorizedProjectIDs: [f.projectID], owner: owner,
            isCancelled: { true }, hostInvocation: { _, _, id in try await capture.record(id) })
        do { _ = try await cancelled.invoke(name: "biology.read", arguments: args, requestID: "cancelled"); Issue.record("Cancelled console forwarded") } catch { }
        #expect(await capture.count() == 1)
    }

    @Test func coldScientificCandidatesDoNotClaimAnInstalledBackend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sequence = try BiologyImporter.parse(title: "Synthetic", format: "fasta", data: Data(">synthetic\nACGTACGT\n".utf8))
        let candidates = BiologyService.optionalScientificMethods(for: sequence)
        #expect(candidates.contains("seq.stats") && candidates.contains("seq.phylogeny"))
        #expect(!candidates.contains("micro.tile") && !candidates.contains("omics.cluster"))
        let configured = await f.service.capabilities(for: sequence)
        #expect(Set(configured.keys) == ["native.local"])
        #expect(configured["native.local"]?.contains("seq.stats") == false)
        let large = BiologyAsset(title: "Opaque image", payload: .externalDataset("tiff"), originalData: Data(), originalFormat: "tiff")
        #expect(BiologyService.optionalScientificMethods(for: large).contains("micro.tile"))
        #expect(!BiologyService.optionalScientificMethods(for: large).contains("seq.stats"))
    }

    @Test func taskBoundLargeFileKeepsSourceAndExplicitReauthorizationCreatesANewHandle() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let registry = EnvironmentRegistry(roots: .init(rootURL: f.root.appendingPathComponent("Environments")), baseRevision: "fixture-arm64")
        let ownerKey = FloeDigest.sha256Hex(Data(f.root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let selected = try await registry.ensureProjectContainer(workspaceID: ownerKey, workspaceRootPath: f.root.path, executionBackend: .linuxVM)
        var run = try #require(try await f.runs.run(id: f.runID))
        run.executionBinding = .init(conversationID: f.taskID,
            target: .init(environmentID: selected.id, backend: .linuxVM, operatingSystem: "linux", architecture: "arm64"))
        try await f.runs.saveRun(run)
        let access = BiologyHostAccess(runs: f.runs, conversations: f.conversations, authority: f.authority,
            environments: registry, libraryRoot: f.root.appendingPathComponent("Library"), library: { f.library })
        let files = BiologyHostFiles(root: f.root.appendingPathComponent("OriginalFiles"), access: access)
        let owner = BiologyExecutionOwner(taskID: f.taskID, hostRunID: f.runID)
        let source = f.root.appendingPathComponent("opaque-input.tiff")
        let bytes = Data(repeating: 0x37, count: BiologyImporter.maximumInputBytes + 257)
        try bytes.write(to: source)
        let native = try await files.register(trustedSourceURL: source, fileName: source.lastPathComponent,
            context: .init(projectID: f.projectID, owner: nil))
        #expect(native.environmentID == "native.local")
        let originalSHA = BiologyProjectStore.digest(bytes)
        let reference = try await files.reauthorize(native, to: .init(projectID: f.projectID, owner: owner))
        #expect(reference.id != native.id && reference.environmentID == selected.id)
        #expect(reference.sha256 == originalSHA && reference.byteCount == UInt64(bytes.count))
        #expect(try await files.resolve(native.id, context: .init(projectID: f.projectID, owner: nil)) == native)
        #expect(try Data(contentsOf: source) == bytes)
        let service = try BiologyService(store: f.store, fileAccess: files, authorize: { try await access.permit($0) })
        let asset = try await service.importFile(f.projectID, fileID: reference.id, title: "Task-bound opaque input", format: "tiff", owner: owner)
        #expect(asset.originalData.isEmpty && asset.fileReference == reference)
        let tail = try await files.read(reference, offset: reference.byteCount - 257, length: 257,
            context: .init(projectID: f.projectID, owner: owner))
        #expect(tail == Data(repeating: 0x37, count: 257))
        do {
            _ = try await files.read(native, offset: 0, length: 16, context: .init(projectID: f.projectID, owner: owner))
            Issue.record("Native-local reference silently became task-scoped")
        } catch { }
        var foreign = run; foreign.id = UUID(); foreign.conversationID = UUID()
        do {
            _ = try await files.resolve(reference.id, context: .init(projectID: f.projectID, owner: .init(taskID: foreign.conversationID, hostRunID: f.runID)))
            Issue.record("A mismatched task/run resolved the opaque file")
        } catch { }
    }

    #if DEBUG
    @Test func actualAppNativeApprovalTokenAndPersonalTrashRestoreUseTheSameOriginal() async throws {
        let app = try await appQualificationEnvironment()
        let host = try await app.biologyComposition.host()
        let record = try await PersonalContentService.shared.create(kind: .biology, title: "QA-N02-Biology-" + UUID().uuidString.prefix(8))
        let library = try await PersonalContentService.shared.library()
        func retireFixture() async throws {
            await host.closeConsoleOwner(projectID: record.id)
            if let current = try? await library.resolve(record.id) {
                try await PersonalLibraryFileActions.delete(current.record, environment: app)
            }
        }
        do {
            guard let runtime = host.nativeRuntime else { throw BiologyHostError.missingRuntime }
            let owner = try await runtime.consoleOwner(projectID: record.id)
            let initial = try await host.store.load(record.id)
            let args = try BiologyCoding.encode(BiologyJSON.object(["projectID": .string(record.id.uuidString),
                "expectedRevision": .number(Double(initial.revision)), "notes": .string("Synthetic native approval and same-ID restore")]))
            let callID = "native-contract-" + UUID().uuidString.lowercased()
            let authorization = try await runtime.authorizeTool(projectID: record.id, toolName: "biology.edit", arguments: args, requestID: callID)
            let valid = await authorization.context.validatedRuntimeAuthority(binding: authorization.binding) == .valid
            #expect(valid)
            let durable = try #require(try await app.runStore.run(id: owner.hostRunID))
            #expect(durable.endedAt == nil && durable.executionBinding?.target.environmentID == authorization.context.environmentID)
            let grants = try await app.runStore.events(runID: owner.hostRunID).filter { $0.kind == .approval }
            #expect(grants.count == 1)
            let runner = try #require(ToolRunnerRegistry.shared.runner(named: "biology.edit"))
            _ = try await runner.execute(argumentsJSON: args, context: authorization.context)
            let saved = try await host.store.load(record.id)
            #expect(saved.notes == "Synthetic native approval and same-ID restore")
            do {
                _ = try await runtime.authorizeTool(projectID: record.id, toolName: "biology.edit", arguments: args, requestID: callID)
                Issue.record("A native single-use request was approved twice")
            } catch { }
            await authorization.finish()
            let retired = await authorization.context.validatedRuntimeAuthority(binding: authorization.binding) != .valid
            #expect(retired)
            await host.closeConsoleOwner(projectID: record.id)
            #expect(try await app.runStore.run(id: owner.hostRunID)?.endedAt != nil)
            let originalBinding = try await library.resolve(record.id).url.appendingPathComponent("biology-binding.json")
            let bindingBytes = try Data(contentsOf: originalBinding)
            try await PersonalLibraryFileActions.delete(try await library.resolve(record.id).record, environment: app)
            #expect(try await host.store.deletedProjects().contains(where: { $0.projectID == record.id }))
            let entry = try #require(try await library.recentlyDeleted().first { $0.projectID == record.id })
            try await PersonalLibraryFileActions.restore(entry, environment: app)
            let restored = try await library.resolve(record.id)
            try BiologyOriginalBinding.verify(id: record.id, directory: restored.url)
            #expect(try Data(contentsOf: originalBinding) == bindingBytes)
            #expect(try await host.store.load(record.id).notes == saved.notes)
            #expect(restored.record.id == record.id)
            try await retireFixture()
        } catch {
            try? await retireFixture()
            throw error
        }
    }
    #endif
    @Test func actualRegisteredRenameAndSerializedMetadataKeepNativeTitleAndFolderIdentity() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await f.library.resolve(f.projectID)
        let nativeRoot = f.root.appendingPathComponent("Projects")
        let runner = try #require(f.registry.runner(named: "biology.update"))
        let args: BiologyJSON = .object(["projectID": .string(f.projectID.uuidString), "operation": .string("project.rename"),
            "expectedRevision": .number(1), "parameters": .object(["title": .string("Renamed native project")])])
        _ = try await runner.execute(argumentsJSON: BiologyCoding.encode(args), context: f.context("biology.update"))
        let renamed = try await f.store.load(f.projectID)
        let projected = try await f.library.resolve(f.projectID)
        #expect(projected.record.title == renamed.title && renamed.title == "Renamed native project")
        #expect(projected.record.modifiedAt >= renamed.modifiedAt)
        #expect(projected.url == original.url && projected.record.id == f.projectID)
        let reopened = try BiologyProjectStore(root: nativeRoot)
        #expect(try await reopened.load(f.projectID) == renamed)
        // Exercise the same serializer used by native UI and the long-lived
        // job observer, with two queued projection requests after a real commit.
        _ = try await f.store.update(f.projectID, expectedRevision: renamed.revision) { $0.title = "Latest authoritative title" }
        async let a: Void = f.access.synchronizeMetadata([f.projectID], store: f.store)
        async let b: Void = f.access.synchronizeMetadata([f.projectID], store: f.store)
        _ = try await (a, b)
        #expect(try await f.library.resolve(f.projectID).record.title == "Latest authoritative title")
        #expect(try await f.library.resolve(f.projectID).url == original.url)
    }

}
#endif
