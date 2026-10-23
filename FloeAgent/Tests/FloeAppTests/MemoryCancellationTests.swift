// FloeAppTests — Memory cancellation / publication-scope regressions.
//
// Covers the MemoryView lane of job-35d7c4aa11ea4fb7: personalization loads
// must fence stale and cancelled results, keep the last-good data, scope the
// error banner to the operation that raised it, and never present a normal
// GRDB/Task cancellation as a user-visible failure. Publication rules are
// verified deterministically on `MemoryPublicationState`; the real
// cooperative-cancellation path is verified against the live GRDB store in
// the app-hosted center (read-only — no personalization write here, the
// shared app lane belongs to other suites).

import Foundation
import Testing
@testable import FloeApp
import FloeCore
import FloeAgentRuntime

@Suite("FloeApp.MemoryCancellation")
struct MemoryCancellationTests {
    @Test("only the newest operation on the same channel may publish")
    func staleTokensAreFenced() {
        var state = MemoryPublicationState()
        let first = state.begin()
        let second = state.begin()
        #expect(!state.isCurrent(first))
        #expect(state.isCurrent(second))
        let third = state.begin()
        #expect(!state.isCurrent(second))
        #expect(state.isCurrent(third))
    }

    @Test("independent channels never fence each other; newest wins per channel")
    func channelIndependence() {
        var state = MemoryPublicationState()
        let search = state.begin(.search)
        let memories = state.begin(.memories)
        // A personalization refresh starts after both reads…
        let personalization = state.begin(.personalization)
        // …and must not invalidate the in-flight search or memory read.
        #expect(state.isCurrent(search, in: .search))
        #expect(state.isCurrent(memories, in: .memories))
        #expect(state.isCurrent(personalization, in: .personalization))
        // Same-channel newer operation still fences the older one.
        let newerPersonalization = state.begin(.personalization)
        #expect(!state.isCurrent(personalization, in: .personalization))
        #expect(state.isCurrent(newerPersonalization, in: .personalization))
        #expect(state.isCurrent(search, in: .search))
        // Cross-channel lookups never see another channel's token.
        #expect(!state.isCurrent(search, in: .personalization))
        #expect(!state.isCurrent(newerPersonalization, in: .search))
    }

    @Test("an error clears only for the scope that raised it")
    func errorScopeClearsSameScopeOnly() {
        var state = MemoryPublicationState()
        // A failed manual save shows a banner; an unrelated successful
        // background reload must not silently erase it.
        state.recordError(scope: .save)
        let loadClearedSaveError = state.clearError(onSuccessFor: .load)
        #expect(!loadClearedSaveError)
        #expect(state.errorScope == .save)
        // A retry of the same operation succeeding clears its own error.
        let saveClearedOwnError = state.clearError(onSuccessFor: .save)
        #expect(saveClearedOwnError)
        #expect(state.errorScope == nil)
        // Load errors survive an unrelated successful write.
        state.recordError(scope: .load)
        let retentionClearedLoadError = state.clearError(onSuccessFor: .retention)
        #expect(!retentionClearedLoadError)
        #expect(state.errorScope == .load)
        let loadClearedOwnError = state.clearError(onSuccessFor: .load)
        #expect(loadClearedOwnError)
    }

    @Test("lifecycle failures surface as product copy, not debug text")
    @MainActor
    func userMessageMapsFailures() {
        #expect(MemoryCenter.userMessage(
            for: PersonalizationLifecycleFailure.revisionConflict(currentRevision: 4))
            == FloeL10n.l("memory.memory_view.content_updated_elsewhere"))
        #expect(MemoryCenter.userMessage(for: PersonalizationLifecycleFailure.noPrevious)
            == FloeL10n.l("memory.memory_view.no_previous_version"))
        #expect(MemoryCenter.userMessage(
            for: PersonalizationLifecycleFailure.contentTooLong(
                characterLimit: PersonalizationDocument.maxContentCharacters))
            == FloeL10n.l("memory.memory_view.content_too_long",
                PersonalizationDocument.maxContentCharacters))
        let generic = FloeError.validationFailed("sentinel-failure")
        #expect(MemoryCenter.userMessage(for: generic) == generic.localizedDescription)
    }

    @Test("a cancelled personalization reload publishes nothing and reports nothing",
          arguments: [CancelledOperation.loadPersonalization, CancelledOperation.search])
    @MainActor
    func cancelledReadsStaySilent(_ kind: CancelledOperation) async throws {
        let environment = try await appQualificationEnvironment()
        let center = environment.memoryCenter
        // The hosted center is shared across suites; start from a clean
        // banner so a previous suite's failure cannot colour this fence.
        center.errorMessage = nil
        // Establish the last-good snapshot with a completed read.
        await center.loadPersonalization()
        let baselineProfileID = center.profile?.id
        let baselineSoulID = center.soul?.id
        #expect(center.errorMessage == nil)

        let task = Task {
            switch kind {
            case .loadPersonalization: await center.loadPersonalization()
            case .search: await center.search("memory cancellation regression query")
            }
        }
        task.cancel()
        await task.value

        // Whichever interleaving won (completion before the cancel landed, or
        // the GRDB fence throwing CancellationError), a normal cancellation
        // must never leave a visible error or replace data with a partial.
        #expect(center.errorMessage == nil)
        #expect(center.profile?.id == baselineProfileID)
        #expect(center.soul?.id == baselineSoulID)

        // The center remains usable after the fenced operation.
        await center.loadPersonalization()
        #expect(center.errorMessage == nil)
    }

    enum CancelledOperation { case loadPersonalization, search }
}
