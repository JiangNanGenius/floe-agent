import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeEnvironments

/// Authored-only tests for the G03-R1 Android environment-authority port and
/// the resolved Linux execution lease descriptor (job-d15dbb99ae374286).
/// This file is NOT executed by the source-authoring job; it is host-runnable
/// later on macOS against the real per-file-linked FloeEnvironments authority
/// (EnvironmentRoots / EnvironmentRegistry / EnvironmentExecutionCoordinator)
/// rooted in synthetic temporary directories — no device, no backend process,
/// no model call, no real registry from any other test.
///
/// These tests target REAL authority behavior, not mirrored implementation:
/// workspace-hash ownership, session conversation ownership (including the
/// nil-conversation gap the Android resolver gate closes, checked both
/// pre-acquire and on the resolved record), explicit-backend selection,
/// stopped/rebuild rejection, writable-layer enforcement, trusted root
/// validation, and lease ownership discipline: `resolveMetadata` hands its
/// lease back (never launch authority), while `acquireHolder` retains the
/// lease until the owned process quiesces — a cancellation request is not
/// termination, which is observable through `stopAndWait` timing out while a
/// holder keeps the environment alive and succeeding after release.
final class EnvironmentOwnershipTests: XCTestCase {
    private var scratch: URL!
    private var environmentRoot: URL!
    private var workspaceRoot: URL!
    private var roots: EnvironmentRoots!
    private var registry: EnvironmentRegistry!
    private var coordinator: EnvironmentExecutionCoordinator!

    private let baseRevision = "g03-r1-test-base"

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeEnvOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        scratch = base
        environmentRoot = base.appendingPathComponent("env-root", isDirectory: true)
        workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        roots = try EnvironmentRoots.makeTrusted(rootURL: environmentRoot)
        registry = EnvironmentRegistry(
            roots: roots,
            baseRevision: baseRevision,
            defaultExecutionBackend: .linuxPRoot
        )
        coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        try await registry.prepare()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    /// The same canonical workspace owner identity the coordinator derives.
    private func workspaceID(for url: URL) -> String {
        FloeDigest.sha256Hex(Data(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
    }

    private func makeContext(
        workspace: URL? = nil,
        environmentID: String? = nil,
        conversationID: UUID? = nil
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            scope: .local,
            workspaceRootURL: workspace,
            cancellation: CancellationToken(),
            environmentID: environmentID,
            conversationID: conversationID
        )
    }

    // MARK: - Trusted root validation

    func testMakeTrustedRejectsNonFileURL() {
        let url = URL(string: "https://example.invalid/environments")!
        XCTAssertThrowsError(try EnvironmentRoots.makeTrusted(rootURL: url)) { error in
            guard case FloeError.validationFailed = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
        }
    }

    func testMakeTrustedRejectsFilesystemRoot() {
        XCTAssertThrowsError(try EnvironmentRoots.makeTrusted(rootURL: URL(fileURLWithPath: "/"))) { error in
            guard case FloeError.validationFailed = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
        }
    }

    func testMakeTrustedRejectsNonNormalizedPath() {
        let url = URL(fileURLWithPath: scratch.path + "/foo/../bar")
        XCTAssertThrowsError(try EnvironmentRoots.makeTrusted(rootURL: url)) { error in
            guard case FloeError.validationFailed = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
        }
    }

    func testMakeTrustedAcceptsExplicitDirectory() throws {
        let roots = try EnvironmentRoots.makeTrusted(rootURL: environmentRoot)
        XCTAssertEqual(roots.rootURL, environmentRoot.standardizedFileURL)
    }

    // MARK: - Happy-path resolution and identity survival

    func testSessionResolutionCarriesAllIdentities() async throws {
        let conversation = UUID()
        let context = makeContext(workspace: workspaceRoot, conversationID: conversation)
        let descriptor = try await LinuxExecutionLeaseResolver.resolveMetadata(
            context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
        )
        let resolved = await registry.record(id: descriptor.environmentID)
        let record = try XCTUnwrap(resolved)
        XCTAssertEqual(record.kind, .session)
        XCTAssertEqual(descriptor.runID, context.runID)
        XCTAssertEqual(descriptor.conversationID, conversation)
        XCTAssertEqual(descriptor.workspaceID, workspaceID(for: workspaceRoot))
        XCTAssertEqual(descriptor.workspaceRootURL, workspaceRoot.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(descriptor.backend, .linuxPRoot)
        XCTAssertEqual(descriptor.projectContainerID, record.parentID)
        XCTAssertFalse(descriptor.orderedLayerURLs.isEmpty)
        XCTAssertEqual(descriptor.writableLayerURL, roots.layerURL(id: record.id, kind: record.kind))
        XCTAssertEqual(descriptor.environmentVariables["FLOE_ENVIRONMENT_ID"], descriptor.environmentID)
        XCTAssertEqual(descriptor.homeURL.path.hasPrefix(descriptor.writableLayerURL.path), true)
        XCTAssertEqual(descriptor.temporaryURL.path.hasPrefix(descriptor.writableLayerURL.path), true)
    }

    func testProjectScopedResolutionWithoutConversation() async throws {
        let context = makeContext(workspace: workspaceRoot)
        let descriptor = try await LinuxExecutionLeaseResolver.resolveMetadata(
            context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
        )
        let resolved = await registry.record(id: descriptor.environmentID)
        let record = try XCTUnwrap(resolved)
        XCTAssertEqual(record.kind, .project)
        XCTAssertNil(descriptor.conversationID)
        XCTAssertEqual(descriptor.projectContainerID, record.id)
    }

    // MARK: - Backend selection

    func testNativeBackendIsRefused() async throws {
        let context = makeContext(workspace: workspaceRoot)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .native
            )
            XCTFail("expected backend refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(error, .backendNotSelectableOnAndroid(.native))
        }
    }

    func testIOSLinuxVMBackendIsRefused() async throws {
        let context = makeContext(workspace: workspaceRoot)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxVM
            )
            XCTFail("expected backend refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(error, .backendNotSelectableOnAndroid(.linuxVM))
        }
    }

    func testRecordCarryingIOSBackendIsRefused() async throws {
        // A record explicitly created with the iOS TinyEMU backend must not be
        // silently retargeted to the Android backend by the resolver.
        let otherWorkspace = scratch.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        let record = try await registry.ensureProjectContainer(
            workspaceID: workspaceID(for: otherWorkspace),
            workspaceRootPath: otherWorkspace.path,
            executionBackend: .linuxVM
        )
        let context = makeContext(workspace: otherWorkspace, environmentID: record.id)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
            )
            XCTFail("expected record backend mismatch refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(
                error,
                .recordBackendMismatch(
                    environmentID: record.id,
                    recorded: EnvironmentExecutionBackend.linuxVM.rawValue,
                    selected: .linuxPRoot
                )
            )
        }
    }

    // MARK: - Ownership: no outside-project/session selection

    func testNilConversationCannotSelectSessionEnvironment() async throws {
        let conversation = UUID()
        let session = try await registry.ensureSessionContainer(
            conversationID: conversation.uuidString,
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        let context = makeContext(workspace: workspaceRoot, environmentID: session.id)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
            )
            XCTFail("expected nil-conversation session refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(error, .sessionRequiresOwningConversation)
        }
    }

    func testForeignConversationCannotSelectSessionEnvironment() async throws {
        let owner = UUID()
        let foreign = UUID()
        let session = try await registry.ensureSessionContainer(
            conversationID: owner.uuidString,
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        let context = makeContext(workspace: workspaceRoot, environmentID: session.id, conversationID: foreign)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
            )
            XCTFail("expected foreign-conversation refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(error, .foreignConversation(owner: owner.uuidString))
        }
    }

    func testForeignWorkspaceCannotSelectEnvironment() async throws {
        // The same environment addressed from a DIFFERENT task workspace must
        // be rejected by the coordinator's workspace-hash owner check.
        let conversation = UUID()
        _ = try await registry.ensureSessionContainer(
            conversationID: conversation.uuidString,
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        let foreignWorkspace = scratch.appendingPathComponent("foreign-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignWorkspace, withIntermediateDirectories: true)
        // Re-resolve the project record created for workspaceRoot; a session
        // fork above already materialized it through the shared authority.
        let owned = await registry.containersOwned(by: workspaceID(for: workspaceRoot))
        let projectRecord = try XCTUnwrap(owned.first)
        let context = makeContext(workspace: foreignWorkspace, environmentID: projectRecord.id)
        do {
            _ = try await coordinator.acquire(context)
            XCTFail("expected foreign-workspace refusal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("another workspace"))
        }
    }

    // MARK: - Writable layer / liveness enforcement through the coordinator

    func testMissingWorkspaceHasNoResolvedEnvironment() async throws {
        let context = makeContext(workspace: nil)
        do {
            _ = try await LinuxExecutionLeaseResolver.resolveMetadata(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
            )
            XCTFail("expected no-resolved-environment refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(error, .noResolvedEnvironment)
        }
    }

    func testStoppedEnvironmentIsRejected() async throws {
        let record = try await registry.ensureProjectContainer(
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        try await registry.transition(id: record.id, state: .stopped)
        let context = makeContext(workspace: workspaceRoot, environmentID: record.id)
        do {
            _ = try await coordinator.acquire(context)
            XCTFail("expected stopped-environment refusal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("stopped") || message.contains("rebuild"))
        }
    }

    func testRebuildRequiredEnvironmentIsRejected() async throws {
        let record = try await registry.ensureProjectContainer(
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        try await registry.markRebuild(id: record.id, reason: "unit-test rebuild flag")
        let context = makeContext(workspace: workspaceRoot, environmentID: record.id)
        do {
            _ = try await coordinator.acquire(context)
            XCTFail("expected rebuild refusal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("rebuild"))
        }
    }

    func testTemplateRecordIsNotExecutable() async throws {
        // Creating a template record must not advertise an executable
        // capability: ownerless template records are refused by the
        // coordinator's workspace-owner gate, so selecting one for execution
        // can never reach the writable-layer check. This is the REAL
        // authority behavior; the resolver's writable-layer restatement is
        // defense-in-depth for records that pass ownership.
        let project = try await registry.ensureProjectContainer(
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxPRoot
        )
        let template = try await registry.createTemplate(from: project.id, name: "ownership-test-template")
        let context = makeContext(workspace: workspaceRoot, environmentID: template.id)
        do {
            _ = try await coordinator.acquire(context)
            XCTFail("expected template execution refusal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("another workspace"))
        }
    }

    // MARK: - Lease retention until process quiescence

    func testHolderRefusesReleaseBeforeQuiescence() async throws {
        let context = makeContext(workspace: workspaceRoot, conversationID: UUID())
        let holder = try await LinuxExecutionLeaseResolver.acquireHolder(
            context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
        )
        let initiallyQuiesced = await holder.hasQuiesced
        let initiallyReleased = await holder.isReleased
        XCTAssertFalse(initiallyQuiesced)
        XCTAssertFalse(initiallyReleased)
        do {
            _ = try await holder.release()
            XCTFail("expected release-before-quiescence refusal")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("quiesced"))
        }
        let releasedBeforeExit = await holder.isReleased
        XCTAssertFalse(releasedBeforeExit)
        // Real process exit acknowledged by the transport: release succeeds
        // exactly once, and a repeat is an idempotent no-op.
        await holder.markProcessQuiesced()
        let quiescedAfterExit = await holder.hasQuiesced
        XCTAssertTrue(quiescedAfterExit)
        let released = try await holder.release()
        XCTAssertTrue(released)
        let releasedAfterExit = await holder.isReleased
        XCTAssertTrue(releasedAfterExit)
        let again = try await holder.release()
        XCTAssertFalse(again)
    }

    // MARK: - Lease ownership discipline vs the coordinator lifecycle

    func testMetadataResolveHandsLeaseBack() async throws {
        // resolveMetadata is metadata-only: it must finish the coordinator
        // lease before returning, so a real lifecycle drain (stopAndWait)
        // observes no pinned work afterwards.
        let context = makeContext(workspace: workspaceRoot, conversationID: UUID())
        let descriptor = try await LinuxExecutionLeaseResolver.resolveMetadata(
            context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
        )
        try await coordinator.stopAndWait(environmentID: descriptor.environmentID, timeout: .seconds(1))
    }

    func testHolderRetainsEnvironmentThroughLifecycleDrainUntilQuiescence() async throws {
        // Cancellation request is not termination: while the holder keeps
        // the lease (process still running), a lifecycle drain times out and
        // retains the data; after the transport confirms real process exit,
        // release hands the lease back and a drain succeeds.
        let context = makeContext(workspace: workspaceRoot, conversationID: UUID())
        let holder = try await LinuxExecutionLeaseResolver.acquireHolder(
            context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
        )
        do {
            try await coordinator.stopAndWait(environmentID: holder.descriptor.environmentID, timeout: .milliseconds(200))
            XCTFail("expected the lifecycle drain to retain the environment while the process runs")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected FloeError.validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("running work") || message.contains("retained"))
        }
        // The drain cancelled the underlying token; the holder must still
        // refuse release before quiescence, then release after it.
        do {
            _ = try await holder.release()
            XCTFail("expected release-before-quiescence refusal")
        } catch {
            // expected
        }
        await holder.markProcessQuiesced()
        let released = try await holder.release()
        XCTAssertTrue(released)
        try await coordinator.stopAndWait(environmentID: holder.descriptor.environmentID, timeout: .seconds(1))
    }

    func testFailedResolutionDoesNotPinLease() async throws {
        // A rejection AFTER acquisition (record backend mismatch) must hand
        // the lease back; a subsequent lifecycle drain sees no pinned work.
        let record = try await registry.ensureProjectContainer(
            workspaceID: workspaceID(for: workspaceRoot),
            workspaceRootPath: workspaceRoot.path,
            executionBackend: .linuxVM
        )
        let context = makeContext(workspace: workspaceRoot, environmentID: record.id)
        do {
            _ = try await LinuxExecutionLeaseResolver.acquireHolder(
                context, coordinator: coordinator, registry: registry, selectedBackend: .linuxPRoot
            )
            XCTFail("expected record backend mismatch refusal")
        } catch let error as LinuxExecutionLeaseResolverError {
            XCTAssertEqual(
                error,
                .recordBackendMismatch(
                    environmentID: record.id,
                    recorded: EnvironmentExecutionBackend.linuxVM.rawValue,
                    selected: .linuxPRoot
                )
            )
        }
        try await coordinator.stopAndWait(environmentID: record.id, timeout: .seconds(1))
    }
}
