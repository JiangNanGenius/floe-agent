import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxWorkbenches

private actor ControlledCaptureAnalysis {
    private var pending: [String:CheckedContinuation<SerialAnalysisResult,any Error>] = [:]
    private var waiters: [String:[CheckedContinuation<Void,Never>]] = [:]
    func analyze(_ question:String) async throws -> SerialAnalysisResult {
        try await withCheckedThrowingContinuation { completion in
            pending[question] = completion
            for waiter in waiters.removeValue(forKey:question) ?? [] { waiter.resume() }
        }
    }
    func wait(_ question:String) async {
        if pending[question] != nil { return }
        await withCheckedContinuation { waiters[question,default:[]].append($0) }
    }
    func complete(_ question:String,_ result:Result<SerialAnalysisResult,any Error>) -> Bool {
        guard let pending = pending.removeValue(forKey:question) else { return false }
        pending.resume(with:result); return true
    }
}

@Suite("Toolbox analysis lifecycle", .serialized)
@MainActor struct ToolboxAnalysisLifecycleTests {
    private func makeModel(_ backend:ControlledCaptureAnalysis,timeout:Duration = .seconds(60)) throws -> (CaptureWorkbenchModel,URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-analysis-contract-\(UUID())")
        let journal = try CaptureJournal(ownerID:UUID(),captureID:UUID(),repository:FileCaptureRepository(root:root),limits:CaptureLimits())
        return (CaptureWorkbenchModel(journal:journal,analysisTimeout:timeout,analyze:{ try await backend.analyze($0) }),root)
    }
    @Test(.timeLimit(.minutes(1)))
    func cancellationReturnsImmediatelyAndLateSuccessCannotReplaceANewerResult() async throws {
        let backend = ControlledCaptureAnalysis(), (model,root) = try makeModel(backend)
        defer { try? FileManager.default.removeItem(at:root) }
        model.question = "old"
        let old = Task { await model.analyze() }; await backend.wait("old")
        let lateWorker = try #require(model.analysisOperation)
        #expect(model.analyzing); model.cancelAnalysis(); await old.value
        #expect(!model.analyzing && model.analysisCancelled && !model.failed && model.analysis == nil)
        model.question = "new"
        let current = Task { await model.analyze() }; await backend.wait("new")
        #expect(await backend.complete("old",.success(.init(facts:["stale"],inferences:[]))))
        await lateWorker.value
        #expect(model.analyzing && model.analysis == nil)
        #expect(await backend.complete("new",.success(.init(facts:["current"],inferences:[]))))
        await current.value
        #expect(!model.analyzing && model.analysis?.facts == ["current"] && !model.failed)
    }
    @Test(.timeLimit(.minutes(1)))
    func deadlineReturnsEvenIfTheProviderIgnoresCancellationAndRetainsNoOldResult() async throws {
        let backend = ControlledCaptureAnalysis(), (model,root) = try makeModel(backend,timeout:.seconds(1))
        defer { try? FileManager.default.removeItem(at:root) }
        model.question = "hang"
        let request = Task { await model.analyze() }; await backend.wait("hang")
        let lateWorker = try #require(model.analysisOperation)
        await request.value
        #expect(!model.analyzing && model.analysisTimedOut && model.failed && !model.analysisCancelled)
        #expect(await backend.complete("hang",.success(.init(facts:["too late"],inferences:[]))))
        await lateWorker.value
        #expect(model.analysisTimedOut && model.analysis == nil)
    }
    @Test(.timeLimit(.minutes(1)))
    func callerCancellationReleasesTheBusyStateAndLateFailureIsIgnored() async throws {
        let backend = ControlledCaptureAnalysis(), (model,root) = try makeModel(backend)
        defer { try? FileManager.default.removeItem(at:root) }
        model.question = "cancel"
        let request = Task { await model.analyze() }; await backend.wait("cancel")
        let lateWorker = try #require(model.analysisOperation)
        request.cancel(); await request.value
        #expect(!model.analyzing && model.analysisCancelled && !model.failed)
        #expect(await backend.complete("cancel",.failure(CocoaError(.fileReadUnknown))))
        await lateWorker.value
        #expect(!model.failed && model.analysisCancelled)
    }
    @Test(.timeLimit(.minutes(1)))
    func anEmptyQuestionUsesTheExplicitDefaultAndFreezesThisRequestsInput() async throws {
        let backend = ControlledCaptureAnalysis(), (model,root) = try makeModel(backend)
        defer { try? FileManager.default.removeItem(at:root) }
        let request = Task { await model.analyze(defaultQuestion:"分析本次记录") }
        await backend.wait("分析本次记录")
        model.question = "下一次问题"
        #expect(await backend.complete("分析本次记录",.success(.init(facts:["this request"],inferences:[]))))
        await request.value
        #expect(model.analysis?.facts == ["this request"] && model.question == "下一次问题")
    }
}
