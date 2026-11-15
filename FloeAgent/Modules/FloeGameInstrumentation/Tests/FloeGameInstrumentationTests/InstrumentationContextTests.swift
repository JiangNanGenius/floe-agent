// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameInstrumentation

private func clean(_ imported: InstrumentationFixture.Imported) {
    try? FileManager.default.removeItem(at: imported.repositoryDirectory)
    try? FileManager.default.removeItem(at: imported.sourceDirectory)
}

private func unrelatedCommit(_ imported: InstrumentationFixture.Imported,
                             revision: String) async throws -> GameStoredProject {
    let path = try GameRelativePath("Docs/extra.txt")
    return try await imported.repository.commit(
        InstrumentationFixture.projectID,
        owner: InstrumentationFixture.owner,
        expectedRevision: revision,
        changes: [.write(path, Data("extra\n".utf8))])
}

@Test func staleRepositoryRevisionIsRejectedAtApply() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let changed = try await unrelatedCommit(imported, revision: imported.context.savedRevision)
    #expect(changed.revision != imported.context.savedRevision)
    do {
        _ = try await instrumenter.apply(plan)
        Issue.record("expected staleContext")
    } catch let error as GameDeveloperInstrumentationError {
        #expect(error == .staleContext)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func changedHostContextIsRejectedAtApply() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let changed = try await unrelatedCommit(imported, revision: imported.context.savedRevision)
    let newContext = try GameProjectContext(
        projectID: imported.context.projectID, owner: imported.context.owner,
        rootURL: imported.context.rootURL, savedRevision: changed.revision,
        environmentID: imported.context.environmentID)
    await imported.contexts.bind(newContext)
    do {
        _ = try await instrumenter.apply(plan)
        Issue.record("expected staleContext")
    } catch let error as GameDeveloperInstrumentationError {
        #expect(error == .staleContext)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func handoffFailureKeepsTheCommittedRevisionDurable() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let historyBefore = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .unity)
    await imported.contexts.setRejectHandoff(true)
    do {
        _ = try await instrumenter.apply(plan)
        Issue.record("expected contextHandoffFailed")
    } catch let error as GameDeveloperInstrumentationError {
        guard case .contextHandoffFailed(_) = error else {
            Issue.record("expected contextHandoffFailed, got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected \(error)")
    }
    let head = try await imported.repository.open(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    #expect(head.revision != imported.context.savedRevision)
    let history = try await imported.repository.history(
        InstrumentationFixture.projectID, owner: InstrumentationFixture.owner)
    #expect(history.count == historyBefore.count + 1)
    #expect(history.first?.revision == head.revision)
    #expect(history.dropFirst().map(\.revision) == historyBefore.map(\.revision))
    for file in plan.files where file.kind == .helperSource {
        #expect(head.files.contains { $0.path == file.path && $0.sha256 == file.outputSHA256 })
    }
}

@Test func idempotentApplyDoesNotNeedAContextHandoff() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let firstPlan = try await instrumenter.plan(context: imported.context, engine: .unity)
    let first = try await instrumenter.apply(firstPlan)
    await imported.contexts.setRejectHandoff(true)
    let secondPlan = try await instrumenter.plan(context: first.context, engine: .unity)
    let second = try await instrumenter.apply(secondPlan)
    #expect(second.revision == first.revision)
    #expect(!second.changed)
}

@Test func wrongOwnerIsRejectedByTheRepository() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.unityProject())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let owner = GameProjectOwner.conversation(
        conversationID: UUID(), workspaceID: UUID())
    let context = try GameProjectContext(
        projectID: InstrumentationFixture.projectID, owner: owner,
        rootURL: imported.sourceDirectory,
        savedRevision: imported.context.savedRevision,
        environmentID: imported.context.environmentID)
    await imported.contexts.bind(context)
    do {
        _ = try await instrumenter.plan(context: context, engine: .unity)
        Issue.record("expected ownershipMismatch")
    } catch let error as GameProjectError {
        #expect(error == .ownershipMismatch)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func receiptRevisionMatchesTheHandedOffContext() async throws {
    let imported = try await InstrumentationFixture.imported(
        files: InstrumentationFixture.godotProjectData())
    defer { clean(imported) }
    let instrumenter = try InstrumentationFixture.instrumenter(imported)
    let plan = try await instrumenter.plan(context: imported.context, engine: .godot)
    let receipt = try await instrumenter.apply(plan)
    #expect(receipt.previousRevision == imported.context.savedRevision)
    #expect(receipt.revision == receipt.project.revision)
    #expect(receipt.context.savedRevision == receipt.revision)
    #expect(receipt.changedFiles == plan.changedFiles)
    #expect(receipt.project.files.contains { $0.path.value == "floe_developer.gd" })
}
