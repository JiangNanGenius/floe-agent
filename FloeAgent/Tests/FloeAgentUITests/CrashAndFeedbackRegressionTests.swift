// FloeAppTests — regressions for the two production 1.2.0 crashes and
// redacted feedback request construction.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import PencilKit
import AVFoundation
import BackgroundTasks
import Testing
import FloeAgentRuntime
import FloePersistence
import FloeCore
import FloeNotes
import FloeProviders
import FloeLocalModels
import FloeSecurity
import FloeModels
@testable import FloeApp

extension CrashAndFeedbackRegressionTests {
@Test("The actual App can save, restore and remove a local provider credential")
func localProviderKeychainRoundTrip() throws {
    let store = KeychainStore(service: "org.floeagent.qualification.providers", synchronizable: false)
    let account = UUID().uuidString
    let synthetic = Data("qualification-only-not-an-api-key".utf8)
    defer { try? store.delete(account: account) }
    try store.store(account: account, secret: synthetic)
    #expect(try store.read(account: account) == synthetic)
    try store.delete(account: account)
    #expect(throws: KeychainStoreError.itemNotFound) { try store.read(account: account) }
}

@Test("Reopening a restored provider preserves its local-only credential policy")
@MainActor func restoredProviderKeepsCredentialLocal() async throws {
    let environment = AppEnvironment.preview()
    let profile = ProviderProfile(kind: .custom, wireProtocol: .openAIResponses,
        baseURL: URL(string: "https://api.example.com")!,
        secretRef: .init(keychainAccount: "qualification.\(UUID().uuidString)", synchronizable: false))
    let editor = ProviderEditorViewModel(center: environment.conversationCenter, existing: profile)
    #expect(!editor.syncEnabled)
    await editor.load()
    #expect(!editor.syncEnabled)
    #expect(try editor.buildProfile().secretRef?.synchronizable == false)
}

@Test("Notes ownership survives rename, legacy repair, archives and ordinary chat deletion")
@MainActor func notesAssistantHistoryStaysDedicated() async throws {
    let database = try DatabaseManager.inMemory()
    try await database.migrate()
    let store = SQLiteConversationStore(database: database)
    let now = Date(), ordinary = UUID(), legacy = UUID(), dedicated = UUID()
    for id in [ordinary, legacy, dedicated] {
        try await store.saveConversation(.init(id: id, title: "手记 · Same title", createdAt: now, updatedAt: now,
            purpose: id == dedicated ? .notes : .ordinary))
        try await store.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: "retained", createdAt: now))
    }
    try await NotesRepository.markAssistantOwnership([legacy, UUID()], database: database)
    try await NotesRepository.markAssistantOwnership([legacy], database: database)
    try await store.renameConversation(id: legacy, title: "Renamed")
    try await store.setArchived(id: dedicated, archived: true)
    // A stale ordinary record must never overwrite persisted product ownership.
    try await store.saveConversation(.init(id: legacy, title: "Again", createdAt: now, updatedAt: now))
    #expect(try await store.conversations().map(\.id) == [ordinary])
    #expect(try await store.conversations(includeArchived: true).map(\.id) == [ordinary])
    for record in try await store.conversations(includeArchived: true) {
        try await store.deleteConversation(id: record.id)
    }
    #expect(try await store.conversation(id: legacy)?.purpose == .notes)
    #expect(try await store.conversation(id: dedicated)?.purpose == .notes)
    #expect(try await store.messages(conversationID: legacy).map(\.content) == ["retained"])
    #expect(try await store.messages(conversationID: dedicated).map(\.content) == ["retained"])
}

@Test("Notes bootstrap migration removes only the selected conversation setup and retains dialogue")
@MainActor func notesBootstrapMigrationPreservesDialogue() async throws {
    let database = try DatabaseManager.inMemory()
    try await database.migrate()
    let store = SQLiteConversationStore(database: database)
    let documentID = UUID()
    let selected = UUID(), other = UUID()
    let date = Date()
    let legacy = NotesStore.legacyAssistantBootstrap(documentID: documentID)
    for id in [selected, other] {
        try await store.saveConversation(.init(id: id, title: "test", createdAt: date, updatedAt: date))
        try await store.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: legacy, createdAt: date))
        try await store.appendMessage(.init(id: UUID(), conversationID: id, role: "user", content: "解释这个公式", createdAt: date.addingTimeInterval(1)))
    }
    try await NotesAssistantPanel.removeLegacyBootstrap(documentID: documentID, conversationID: selected, database: database)
    #expect(try await store.messages(conversationID: selected).map(\.content) == ["解释这个公式"])
    #expect(try await store.messages(conversationID: other).count == 2)
    try await NotesAssistantPanel.removeLegacyBootstrap(documentID: documentID, conversationID: selected, database: database)
    #expect(try await store.messages(conversationID: selected).count == 1)
}

@Test("MetricKit summary retains termination metadata and attributed frames before upload truncation")
@MainActor func metricKitCrashSummarySurvivesTruncation() throws {
    let metadata = ["exceptionType": "EXC_BAD_ACCESS", "terminationReason": "test termination"]
    let source: [String: Any] = ["crashDiagnostics": [[
        "diagnosticMetaData": metadata,
        "callStackTree": ["callStacks": [
            ["threadAttributed": false, "callStackRootFrames": [["binaryName": "unrelated", "padding": String(repeating: "x", count: 150_000)]]],
            ["threadAttributed": true, "callStackRootFrames": [["binaryName": "FloeApp", "offsetIntoBinaryTextSegment": 42]]]
        ]]
    ]]]
    let data = try JSONSerialization.data(withJSONObject: source)
    let summary = RuntimeDiagnostics.compactEvidence(data)
    #expect(summary.utf8.count < 12_000)
    let object = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
    let records = try #require(object["diagnostics"] as? [[String: Any]])
    #expect(records.first?["diagnosticMetaData"] as? [String: String] == metadata)
    #expect(records.first?["attributedThreadFound"] as? Bool == true)
    let uploaded = FeedbackUploadService.boundedDiagnostics(summary + "\n" + String(decoding: data, as: UTF8.self))
    #expect(uploaded.hasPrefix(summary))
    #expect(uploaded.contains("EXC_BAD_ACCESS"))
    #expect(summary.contains("FloeApp"))
    #expect(!summary.contains("unrelated"))
}

}

@MainActor
private final class SettingsAppearanceProbe {
    var didAppear = false
}

private actor ContinuedProcessingExpirationTestGate {
    private var persistenceStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendPersistence() async {
        persistenceStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPersistenceStarts() async {
        guard !persistenceStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePersistence() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@Suite("FloeApp crash and feedback regressions")
struct CrashAndFeedbackRegressionTests {
    @Test("Assistant commits refresh the open document without changing its page or viewport") @MainActor
    func notesAssistantCommitRefreshesOpenEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-live-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let saved = try await store.create(NoteDocument(title: "Course"))
        let page = try #require(saved.pages.first)
        let owner = UUID()
        try await store.bindAssistant(conversationID: owner, documentID: saved.id, canEdit: true)
        let session = NotesSession()
        await session.open(using: store)
        #expect(await session.select(saved))
        var state = NoteWorkspaceTabs.EditorState()
        state.pageID = page.id
        state.viewports[page.id] = .init(x: 30, y: 210, zoom: 1.4)
        session.rememberEditor(state, for: saved.id)
        let note = NoteElement(text: "Saved assistant explanation", isAIGenerated: true)
        let updated = try await store.apply(.init(documentID: saved.id, expectedRevision: saved.revision,
            title: "Assistant edit", edits: [.upsertElement(pageID: page.id, element: note)]), authorizedConversationID: owner)
        // No manual reload: exercise the store notification consumed by the real editor session.
        for _ in 0..<200 where session.document?.revision != updated.revision || !session.canUndo {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.document?.pages.first?.elements == [note])
        #expect(session.document?.revision == updated.revision)
        #expect(session.editorState(for: saved.id) == state)
        #expect(session.tabs.selectedID == saved.id)
        #expect(session.canUndo)
    }

    @Test("A failed local ink save does not suppress a later assistant update or discard recovery") @MainActor
    func notesRefreshPreservesFailedLocalInk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-refresh-ink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let saved = try await store.create(NoteDocument(title: "Before"))
        let recovery = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/Notes/InkRecovery/\(saved.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        let session = NotesSession()
        await session.open(using: store)
        #expect(await session.select(saved))
        let missingPage = UUID()
        session.saveDrawing(PKDrawing().dataRepresentation(), pageID: missingPage, base: saved)
        #expect(session.pendingWrites > 0)
        let updated = try await store.apply(.init(documentID: saved.id, expectedRevision: saved.revision,
            title: "Assistant edit", edits: [.rename("After")]))
        for _ in 0..<200 where session.pendingWrites > 0 || session.document?.revision != updated.revision {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.pendingWrites == 0)
        #expect(session.document?.title == "After")
        #expect(session.hasPendingInk(documentID: saved.id, pageID: missingPage))
        #expect(session.unsavedDocumentIDs.contains(saved.id))
        #expect(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("\(missingPage.uuidString).inkdraft").path))
    }

    @Test("Document assistant permissions stay bound to its native document and stop on restart") @MainActor
    func notesAssistantPolicyCannotBroadenItsDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let document = try await store.create(NoteDocument(title: "Document"))
        let other = try await store.create(NoteDocument(title: "Other"))
        let owner = UUID(), replacement = UUID()
        try await store.bindAssistant(conversationID: owner, documentID: document.id, canEdit: true)
        let policy = NotesDocumentApprovalPolicy(conversationID: owner, store: store)
        func action(_ id: UUID, tool: String = "notes.edit") throws -> ProposedAction {
            let call = try ToolCall(id: UUID().uuidString, toolName: tool,
                argumentsJSON: JSONEncoder().encode(["documentID": id.uuidString]), scope: .local)
            return .init(toolCall: call, riskLabels: [], userGoal: "Edit this document", hostAndPathScope: .local)
        }
        #expect(try await policy.decide(action(document.id)).permitsExecution)
        #expect(!(try await policy.decide(action(other.id)).permitsExecution))
        #expect(!(try await policy.decide(action(document.id, tool: "shell.run")).permitsExecution))
        try await store.bindAssistant(conversationID: replacement, documentID: document.id, canEdit: true)
        #expect(!(try await policy.decide(action(document.id)).permitsExecution))
        #expect(try await store.document(document.id) == document)
    }

    @Test @MainActor
    func notesTabCloseWaitsForEditorSaveAndPreservesFailedEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tabs-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let a = try await store.create(NoteDocument(title: "A"))
        let b = try await store.create(NoteDocument(title: "B"))
        let session = NotesSession()
        await session.open(using: store)
        #expect(await session.select(a))
        #expect(await session.select(b))
        session.registerLeaveGuard(for: b.id) { false }
        await session.closeTab(b.id)
        #expect(session.document?.id == b.id)
        #expect(session.tabs.documentIDs == [a.id, b.id])
        #expect(!(await session.select(nil)))
        session.registerLeaveGuard(for: b.id) { true }
        await session.closeTab(b.id)
        #expect(session.document?.id == a.id && session.tabs.documentIDs == [a.id])
        #expect(try await store.document(b.id) == b)
        #expect(try await store.historyState(b.id).canUndo == false)
        session.removeLeaveGuard(for: b.id)
    }

    @Test @MainActor
    func notesTabRestorationKeepsLibraryAsInitialScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tabs-restore-\(UUID())")
        let suite = "notes-tabs-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let a = try await store.create(NoteDocument(title: "A"))
        let first = NotesSession(tabDefaults: defaults)
        await first.open(using: store)
        #expect(await first.select(a))
        var state = NoteWorkspaceTabs.EditorState()
        state.pageID = a.pages.first?.id; state.tool = "套索"
        first.rememberEditor(state, for: a.id)
        #expect(await first.select(nil))
        let restored = NotesSession(tabDefaults: defaults)
        await restored.open(using: store)
        #expect(restored.document == nil)
        #expect(restored.tabs.documentIDs == [a.id])
        #expect(restored.editorState(for: a.id) == state)
    }

    @MainActor
    @Test("Settings renders in a separate regular-width host without an inherited environment object")
    func settingsPresentationOwnsItsEnvironment() async throws {
        let environment = AppEnvironment.preview()
        let appearance = SettingsAppearanceProbe()
        let controller = UIHostingController(rootView:
            SettingsRootView(environment: environment)
                .environment(\.horizontalSizeClass, .regular)
                .onAppear { appearance.didAppear = true })
        // Model the independent sheet host from the full-app crash. Do not
        // inject AppEnvironment on the hosting controller: SettingsRootView
        // must receive and propagate its explicitly supplied dependency.
        // A detached hosting view may defer SwiftUI rendering and legitimately
        // have zero UIKit children. Mount it as a real sheet-like host and
        // observe appearance instead of relying on private subview structure.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while !appearance.didAppear, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(appearance.didAppear)
        #expect(controller.view.window === window)
    }

    @MainActor
    @Test("Auxiliary local LLMs use the device adapter, never a cloud HTTP adapter")
    func auxiliaryAdapterFollowsExecutionLocation() {
        let environment = AppEnvironment.preview()
        let local = ProviderProfile(kind: .local, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://localhost")!)
        let cloud = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.test/v1")!)
        #expect(environment.conversationCenter.providerAdapter(for: local) is LocalProviderAdapter)
        #expect(environment.conversationCenter.providerAdapter(for: cloud) is OpenAIChatCompletionsAdapter)
    }

    @Test("Window scene phases aggregate by stable per-scene identity")
    func windowScenePhaseIdentityContract() {
        var aggregation = AppScenePhaseAggregation()
        #expect(aggregation.effectivePhase == .background)
        #expect(aggregation.report(.active, sceneID: "scene-a") == .active)

        // A second, background window must not suspend app-wide SSH/VNC while
        // the first window remains active.
        #expect(aggregation.report(.background, sceneID: "scene-b") == nil)
        #expect(aggregation.effectivePhase == .active)

        #expect(aggregation.report(.inactive, sceneID: "scene-a") == .inactive)
        #expect(aggregation.effectivePhase == .inactive)

        #expect(aggregation.report(.active, sceneID: "scene-b") == .active)
        let activeRemoval = aggregation.remove(sceneID: "scene-b")
        #expect(activeRemoval?.removedPhase == .active)
        #expect(activeRemoval?.effectivePhaseChange == .inactive)
        #expect(aggregation.phasesBySceneID == ["scene-a": .inactive])
        #expect(aggregation.effectivePhase == .inactive)

        let finalRemoval = aggregation.remove(sceneID: "scene-a")
        #expect(finalRemoval?.removedPhase == .inactive)
        #expect(finalRemoval?.effectivePhaseChange == .background)
        #expect(aggregation.phasesBySceneID.isEmpty)
        #expect(aggregation.effectivePhase == .background)
    }

    @Test("Face ID access has a packaged privacy explanation")
    func faceIDUsageDescriptionExists() throws {
        let explanation = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String
        )
        #expect(!explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Continued processing submits a concrete registered identifier")
    func continuedIdentifierIsConcrete() {
        let identifier = BackgroundTaskKind.continued.submissionIdentifier
        #expect(identifier.hasPrefix("org.floeagent.ios.continued."))
        #expect(!identifier.contains("*"))
        #expect(identifier != BackgroundTaskKind.continued.rawValue)
        #expect(identifier.hasPrefix(
            BackgroundTaskKind.continued.submissionIdentifierPrefix
        ))
    }

    @Test("Continued processing coalesces duplicate outstanding submissions")
    func continuedSubmissionCoalescingContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let beganFirstSubmission = lifecycle.beginSubmission()
        let beganDuplicateSubmission = lifecycle.beginSubmission()
        #expect(beganFirstSubmission)
        #expect(!beganDuplicateSubmission)

        lifecycle.finishSubmission(identifier: "continued.first")
        #expect(lifecycle.pendingRequestIdentifiers == ["continued.first"])
        #expect(lifecycle.outstandingRequestIdentifiers == ["continued.first"])
        #expect(lifecycle.hasOutstandingWork)
        let beganWhileRequestIsPending = lifecycle.beginSubmission()
        #expect(!beganWhileRequestIsPending)

        let cancelled = lifecycle.cancelPendingRequests()
        #expect(cancelled == ["continued.first"])
        #expect(!lifecycle.hasOutstandingWork)
        let beganAfterCancellation = lifecycle.beginSubmission()
        #expect(beganAfterCancellation)
        lifecycle.finishSubmission(identifier: nil)
        #expect(!lifecycle.hasOutstandingWork)
    }

    @Test("Continued processing retains multiple identifiers and de-duplicates handles")
    func continuedMultiHandleContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let beganSubmission = lifecycle.beginSubmission()
        #expect(beganSubmission)
        lifecycle.finishSubmission(identifier: "continued.current")

        let acceptedCurrent = lifecycle.acceptHandle(
            identifier: "continued.current",
            handleID: "current-1"
        )
        let acceptedCurrentDuplicate = lifecycle.acceptHandle(
            identifier: "continued.current",
            handleID: "current-1"
        )
        let acceptedLegacyFirst = lifecycle.acceptHandle(
            identifier: "continued.legacy",
            handleID: "legacy-1"
        )
        let acceptedLegacySecond = lifecycle.acceptHandle(
            identifier: "continued.legacy",
            handleID: "legacy-2"
        )
        #expect(acceptedCurrent)
        #expect(!acceptedCurrentDuplicate)
        #expect(acceptedLegacyFirst)
        #expect(acceptedLegacySecond)

        #expect(lifecycle.pendingRequestIdentifiers.isEmpty)
        #expect(lifecycle.acceptedHandleCount == 3)
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.current"]
            == ["current-1"])
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.legacy"]
            == ["legacy-1", "legacy-2"])
        #expect(lifecycle.outstandingRequestIdentifiers
            == ["continued.current", "continued.legacy"])
        let beganWhileHandlesAreActive = lifecycle.beginSubmission()
        #expect(!beganWhileHandlesAreActive)

        let completedLegacyFirst = lifecycle.completeHandle(
            identifier: "continued.legacy",
            handleID: "legacy-1"
        )
        #expect(completedLegacyFirst)
        #expect(lifecycle.acceptedHandleCount == 2)
        #expect(lifecycle.acceptedHandlesByIdentifier["continued.legacy"]
            == ["legacy-2"])
    }

    @Test("Continued processing expiration drains every accepted sibling")
    func continuedExpirationDrainsSiblingsContract() {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        let acceptedFirst = lifecycle.acceptHandle(
            identifier: "continued.first",
            handleID: "first-1"
        )
        let acceptedSecond = lifecycle.acceptHandle(
            identifier: "continued.second",
            handleID: "second-1"
        )
        let acceptedThird = lifecycle.acceptHandle(
            identifier: "continued.second",
            handleID: "second-2"
        )
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(acceptedThird)

        let completed = lifecycle.completeAllAcceptedHandles()
        #expect(completed["continued.first"] == ["first-1"])
        #expect(completed["continued.second"] == ["second-1", "second-2"])
        #expect(lifecycle.acceptedHandleCount == 0)
        #expect(!lifecycle.hasOutstandingWork)
        let beganAfterExpiration = lifecycle.beginSubmission()
        #expect(beganAfterExpiration)
    }

    @Test("Continued expiration completes siblings before persistence can suspend")
    @MainActor
    func continuedExpirationIsCompletionFirstAndIdempotent() async {
        var lifecycle = ContinuedProcessingLifecycle<String>()
        lifecycle.acceptHandle(
            identifier: "continued.first",
            handleID: "first-1"
        )
        lifecycle.acceptHandle(
            identifier: "continued.sibling",
            handleID: "sibling-1"
        )
        var events: [String] = []
        let gate = ContinuedProcessingExpirationTestGate()

        let firstCallback = Task { @MainActor in
            await ContinuedProcessingExpirationSequence.runIfManaged(
                drainAndCompleteIfManaged: {
                    guard lifecycle.acceptedHandlesByIdentifier["continued.first"]?
                        .contains("first-1") == true else { return false }
                    let drained = lifecycle.completeAllAcceptedHandles()
                    let drainedCount = drained.values.reduce(0) { $0 + $1.count }
                    events.append("completed-\(drainedCount)")
                    return true
                },
                persistRecoveryPoints: {
                    events.append("persist-started")
                    await gate.suspendPersistence()
                    events.append("persist-finished")
                }
            )
        }

        // Persistence is now deliberately suspended. All sibling handles must
        // already be drained, proving there was no await before completion.
        await gate.waitUntilPersistenceStarts()
        #expect(lifecycle.acceptedHandleCount == 0)
        #expect(events == ["completed-2", "persist-started"])

        let duplicateHandled = await ContinuedProcessingExpirationSequence
            .runIfManaged(
                drainAndCompleteIfManaged: {
                    guard lifecycle.acceptedHandlesByIdentifier["continued.first"]?
                        .contains("first-1") == true else { return false }
                    _ = lifecycle.completeAllAcceptedHandles()
                    events.append("duplicate-completed")
                    return true
                },
                persistRecoveryPoints: {
                    events.append("duplicate-persisted")
                }
            )
        #expect(!duplicateHandled)
        #expect(events == ["completed-2", "persist-started"])

        await gate.releasePersistence()
        #expect(await firstCallback.value)
        #expect(events == [
            "completed-2",
            "persist-started",
            "persist-finished"
        ])
    }

    @Test("Empty audio buffers are rejected before Speech Analyzer")
    func emptyAudioBufferIsRejected() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        #expect(empty.frameLength == 0)
        #expect(!VoiceBufferValidator.isUsable(empty))

        empty.frameLength = 1
        #expect(VoiceBufferValidator.isUsable(empty))
    }

    @Test("Feedback request includes the problem and redacts diagnostics")
    func feedbackRequestIsRedacted() throws {
        let secret = ["sk", "live1234567890abcdef"].joined(separator: "-")
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                problem: "Voice button crashes with key \(secret)",
                diagnostics: "authorization: Bearer eyJhbGciOiJ9.payload"
            ),
            boundary: "TestBoundary"
        )

        #expect(request.url == FeedbackUploadService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "multipart/form-data; boundary=TestBoundary")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key")
            == "11111111-2222-3333-4444-555555555555")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("name=\"manifest\""))
        #expect(body.contains("Voice button crashes"))
        #expect(body.contains("diagnostics-11111111-2222-3333-4444-555555555555-0"))
        #expect(body.contains("⟨redacted⟩"))
        #expect(!body.contains(secret))
        #expect(!body.contains("eyJhbGciOiJ9.payload"))
    }

    @Test("Large diagnostics preserve configuration header and latest failure")
    func diagnosticsKeepHeadAndTail() {
        let input = "HEADER provider=DeepSeek\n"
            + String(repeating: "middle\n", count: 30_000)
            + "LATEST providerRequestBuildFailed\n"
        let bounded = FeedbackUploadService.boundedDiagnostics(input)
        #expect(bounded.count <= FeedbackUploadService.maximumDiagnosticsCharacters)
        #expect(bounded.contains("HEADER provider=DeepSeek"))
        #expect(bounded.contains("LATEST providerRequestBuildFailed"))
        #expect(bounded.contains("middle diagnostics omitted"))
    }

    /// Synthetic only. Mirrors the export shape that lost the Build 231
    /// evidence: a large MetricKit full-payload block (kept from build 229)
    /// sits between the current Office stage trace and the runtime log flood,
    /// so a plain head/tail bound deleted the current sections. No device or
    /// user content is used.
    private func syntheticOversizedDiagnosticReport() -> String {
        let oldPayload = "{\"diagnosticMetaData\":{\"appBuildVersion\":\"229\"},\"padding\":\""
            + String(repeating: "m", count: 120_000) + "\"}"
        var officeLines: [String] = (0..<120).map { index in
            "at=2026-09-27T14:00:00Z session=0F1E2D3C generation=7 stage=paint.chunk.\(index)"
                + " detail=\(String(repeating: "s", count: 200))"
        }
        officeLines.append("at=2026-09-27T14:02:00Z session=0F1E2D3C generation=7 stage=hostExit code=1")
        let localLines = [
            "[2026-09-27T14:01:00.000Z] [providers] [info] localInferenceEngineLoadStarted model=qwen3.8-4b-heretic-mlx4",
            "[2026-09-27T14:01:01.000Z] [providers] [info] localInferencePrepareStarted inputTokens=5436 context=8192",
            "[2026-09-27T14:01:59.000Z] [providers] [error] localInferenceFailed lastFailureStage=prefill lastFailureDomain=mlx lastFailureCode=OOM"
        ]
        let logFiller = (0..<4_000).map { index in
            "[2026-09-27T13:55:00.000Z] [app] [info] linuxMetricsSampleDiscarded tick=\(index) 采样原因=未验证"
        }
        let logTail = [
            "[2026-09-27T14:11:39.000Z] [app] [info] processLaunch previousExit=noTerminationCallback; requiresMetricKitOrIPS",
            "[2026-09-27T14:11:40.000Z] [providers] [info] localInferenceStarted trace=BEEF model=qwen3.8-4b-heretic-mlx4"
        ]
        var sections: [String] = []
        sections.append(DiagnosticsSection.reportIdentity.header + "\n"
            + "Floe Agent Diagnostics\nversion: 1.7.0\nbuild: 231\ngenerated_at: 2026-09-27T14:12:00Z")
        sections.append(DiagnosticsSection.systemRuntime.header + "\n"
            + "previous_exit: noTerminationCallback; requiresMetricKitOrIPS")
        sections.append(DiagnosticsSection.officeStageTrace.header + "\n"
            + "events_retained=512 events_exported=\(officeLines.count)\n" + officeLines.joined(separator: "\n"))
        sections.append(DiagnosticsSection.localInference.header + "\n"
            + "events_retained=39 events_exported=\(localLines.count)\n" + localLines.joined(separator: "\n"))
        sections.append(DiagnosticsSection.taskSummaries.header + "\n"
            + "run=A1B2C3D4-0000-4000-8000-000000000232 state=streamingModel")
        sections.append(DiagnosticsSection.metricKitSummaries.header + "\n"
            + "[metrickit build=229 kind=crashDiagnostics] {\"diagnostics\":[{\"kind\":\"crashDiagnostics\","
            + "\"diagnosticMetaData\":{\"appBuildVersion\":\"229\",\"terminationReason\":\"Namespace SIGNAL\"}}],"
            + "\"floeSummaryVersion\":1}")
        sections.append(DiagnosticsSection.metricKitFullPayloads.header + "\n"
            + Array(repeating: oldPayload, count: 8).joined(separator: "\n"))
        sections.append(DiagnosticsSection.recentLog.header + "\n"
            + (logFiller + logTail).joined(separator: "\n"))
        return sections.joined(separator: "\n")
    }

    @Test("Oversized MetricKit and runtime flood keep current Office, local inference and build identity")
    func oversizedDiagnosticsKeepCurrentSections() {
        let bounded = FeedbackUploadService.boundedDiagnostics(syntheticOversizedDiagnosticReport())

        #expect(bounded.utf8.count <= FeedbackUploadService.maximumDiagnosticsBytes)
        #expect(bounded.count <= FeedbackUploadService.maximumDiagnosticsCharacters)

        // Current app/build identity and the current evidence survive.
        #expect(bounded.contains("build: 231"))
        #expect(bounded.contains("stage=hostExit"))
        #expect(bounded.contains("localInferenceFailed lastFailureStage=prefill"))
        #expect(bounded.contains("previous_exit: noTerminationCallback"))
        #expect(bounded.contains("[metrickit build=229 kind=crashDiagnostics]"))

        // The oversized full payloads are dropped explicitly, never silently.
        #expect(bounded.contains("metrickit_full_payloads omitted by client"))
        #expect(bounded.contains("section office_stage_trace truncated by client"))
        #expect(bounded.contains("section recent_log truncated by client"))
        #expect(bounded.contains("omitted="))
        #expect(!bounded.contains(String(repeating: "m", count: 4_096)))

        // Every crucial byte survives the nineteen-chunk UTF-8 transport bound.
        let chunks = FeedbackUploadService.diagnosticsChunks(bounded)
        #expect(chunks.count <= 19)
        #expect(chunks.allSatisfy { $0.utf8.count <= 7_000 })
        #expect(chunks.joined() == bounded)
        let reassembled = chunks.joined()
        #expect(reassembled.contains("build: 231"))
        #expect(reassembled.contains("stage=hostExit"))
        #expect(reassembled.contains("localInferenceFailed"))
        #expect(reassembled.contains("previous_exit: noTerminationCallback"))
    }

    @Test("Oversized diagnostics upload stays inside the multipart event budget")
    func oversizedDiagnosticsUploadIsBounded() throws {
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                problem: "PPT 编辑器打开后崩溃，本地模型没有回复",
                diagnostics: syntheticOversizedDiagnosticReport()
            ),
            boundary: "DiagnosticBoundary"
        )
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let diagnosticsEvents = body.components(separatedBy: "\"client_event_id\":\"diagnostics-").count - 1
        #expect(diagnosticsEvents >= 2)
        #expect(diagnosticsEvents <= 19)
        #expect(body.contains("build: 231"))
        #expect(body.contains("stage=hostExit"))
        #expect(body.contains("localInferenceFailed"))
        #expect(body.contains("metrickit_full_payloads omitted by client"))
    }

    @Test("MetricKit summaries stay version-labelled and split from full payloads")
    @MainActor func metricKitSectionsAreLabelled() {
        let report = "previous_exit: unknown\n== MetricKit summaries ==\n"
            + "{\"diagnostics\":[{\"kind\":\"crashDiagnostics\",\"diagnosticMetaData\":{\"appBuildVersion\":\"231\"}}]}\n"
            + "== MetricKit full payloads ==\n"
            + "{\"callStackTree\":\"synthetic\"}"
        let sections = DiagnosticsExporter.splitRuntimeEvidence(report)
        #expect(sections.runtime == "previous_exit: unknown")
        #expect(sections.fullPayloads == "{\"callStackTree\":\"synthetic\"}")
        let labelled = DiagnosticsExporter.labelledMetricKitSummaries(sections.summaries)
        #expect(labelled.contains("[metrickit build=231 kind=crashDiagnostics]"))
        #expect(labelled.contains("\"appBuildVersion\":\"231\""))
    }

    @Test("Diagnostics render labels every section and keeps build identity first")
    @MainActor func diagnosticsRenderIsSectioned() async throws {
        let center = SettingsCenter(environment: AppEnvironment.preview())
        let rendered = await DiagnosticsExporter.render(center: center)
        for section in DiagnosticsSection.allCases {
            #expect(rendered.contains(section.header))
        }
        let identity = try #require(rendered.range(of: DiagnosticsSection.reportIdentity.header))
        let office = try #require(rendered.range(of: DiagnosticsSection.officeStageTrace.header))
        let log = try #require(rendered.range(of: DiagnosticsSection.recentLog.header))
        #expect(identity.lowerBound < office.lowerBound)
        #expect(office.lowerBound < log.lowerBound)
        #expect(rendered.contains("version: "))
        #expect(rendered.contains("build: "))
    }

    @Test("Feedback images are bounded multipart attachments")
    func feedbackImagesAreMultipartAttachments() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let attachment = FeedbackImageAttachment(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            filename: "screen\r\nshot.jpg",
            data: jpeg
        )
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                problem: "The model request failed",
                diagnostics: "provider error",
                imageAttachments: [attachment]
            ),
            boundary: "ImageBoundary"
        )
        let body = try #require(request.httpBody)
        let headers = String(decoding: body, as: UTF8.self)

        #expect(headers.contains("name=\"screenshots\""))
        #expect(headers.contains("filename=\"screen__shot.jpg\""))
        #expect(headers.contains("Content-Type: image/jpeg"))
        #expect(headers.contains("X-Floe-Attachment-ID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(body.range(of: jpeg) != nil)
        #expect(headers.contains("\"image_attachment_count\":\"1\""))
    }

    @Test("Feedback rejects more than three images")
    func feedbackRejectsTooManyImages() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let attachments = (0..<4).map {
            FeedbackImageAttachment(filename: "image-\($0).jpg", data: jpeg)
        }
        #expect(throws: FeedbackUploadError.tooManyImages) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(
                    problem: "Too many screenshots",
                    diagnostics: nil,
                    imageAttachments: attachments
                ),
                boundary: "ImageBoundary"
            )
        }
    }

    @Test("Feedback requires a user-written problem")
    func feedbackRequiresProblem() {
        #expect(throws: FeedbackUploadError.emptyProblem) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(problem: "   ", diagnostics: nil),
                boundary: "TestBoundary"
            )
        }
    }

    @Test("Feedback success requires a server-issued report ID")
    func feedbackReceiptContract() {
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"report_id":"report-123"}"#.utf8)
        ) == "report-123")
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"accepted":[]}"#.utf8)
        ) == nil)
    }

    @Test("Feedback honors the server retry window after HTTP 429")
    func feedbackRetryAfterContract() throws {
        let response = try #require(HTTPURLResponse(
            url: FeedbackUploadService.endpoint,
            statusCode: 429,
            httpVersion: "HTTP/2",
            headerFields: ["Retry-After": "17"]
        ))
        #expect(FeedbackUploadService.retryAfterSeconds(from: response) == 17)
    }

    @Test("PiP starts and retries only from actionable stable states")
    @MainActor
    func pictureInPictureManualControlStateContract() {
        typealias State = BackgroundVideoService.PiPPreparationState
        #expect(State.prepared.manualAction == .start)
        #expect(State.active.manualAction == .stop)
        #expect(State.failed.manualAction == .retryPreparation)
        #expect(State.starting.manualAction == .none)
        #expect(State.renderingContent.manualAction == .none)
        #expect(State.waitingForMedia.manualAction == .none)
        #expect(State.idle.manualAction == .none)
        #expect(State.prepared.offersManualControl)
        #expect(State.starting.offersManualControl)
        #expect(State.active.offersManualControl)
        #expect(State.failed.offersManualControl)
        #expect(!State.renderingContent.offersManualControl)
        #expect(!State.waitingForMedia.offersManualControl)
        #expect(!State.idle.offersManualControl)

        let service = BackgroundVideoService()
        #expect(!service.shouldOfferManualControl)
        service.setRunContext(
            title: "Active task",
            progress: "Running",
            automaticallyStartsFromInline: true
        )
        #expect(service.shouldOfferManualControl)
        #expect(service.canPerformManualControl)
        // Locale-independent: prepared state maps to the prepare title via the
        // localization catalog (English in CI, Chinese on a zh-Hans device).
        #expect(service.manualControlTitle == FloeL10n.l(
            "platform.background_video_service.preparing_picture_in_picture"
        ))
        service.stop()
        #expect(!service.shouldOfferManualControl)
    }

    @Test("PiP host detach keeps controllers across inactive and background transitions")
    func pictureInPictureHostDetachLifecycleContract() {
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .inactive,
            preparationPhase: .preparing
        ))
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .background,
            preparationPhase: .prepared
        ))
        #expect(BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .active,
            preparationPhase: .starting
        ))
        #expect(!BackgroundPiPLifecyclePolicy.retainsControllerWhenHostDetaches(
            effectivePhase: .active,
            preparationPhase: .prepared
        ))
        #expect(BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .active,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .active,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: false,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.defersAutomaticHostDetach(
            effectivePhase: .background,
            preparationPhase: .prepared,
            automaticallyStartsFromInline: true,
            hasRunContext: true
        ))
        #expect(!BackgroundPiPLifecyclePolicy.shouldCancelDeferredHostDetach(
            hasUsableReplacementHost: false
        ))
        #expect(BackgroundPiPLifecyclePolicy.shouldCancelDeferredHostDetach(
            hasUsableReplacementHost: true
        ))
    }

    @Test("PiP records a background transition missed before media readiness")
    func pictureInPictureMissedAutomaticTransitionContract() {
        var policy = BackgroundPiPLifecyclePolicy()
        policy.setAutomaticStartEnabled(true, sourceReady: false)
        #expect(policy.automaticTransition == .armed)

        policy.transition(
            to: .inactive,
            automaticallyStartsFromInline: true,
            sourceReady: false,
            startPending: false
        )
        #expect(policy.automaticTransition == .missed)
        #expect(!policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .background,
            automaticallyStartsFromInline: true,
            sourceReady: false,
            startPending: false
        )
        policy.preparationDidBecomeReady(automaticallyStartsFromInline: true)
        #expect(policy.automaticTransition == .missed)
        #expect(!policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .active,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        #expect(policy.automaticTransition == .armed)
        #expect(policy.allowsAutomaticStartFromInline)
    }

    @Test("A ready PiP source stays armed for the system-managed background transition")
    func pictureInPictureSystemManagedTransitionContract() {
        var policy = BackgroundPiPLifecyclePolicy()
        policy.setAutomaticStartEnabled(true, sourceReady: true)
        #expect(policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .inactive,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        #expect(policy.allowsAutomaticStartFromInline)

        policy.transition(
            to: .background,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        #expect(policy.allowsAutomaticStartFromInline)
        policy.willStart(manualRequestPending: false)
        #expect(policy.startOrigin == .automaticInline)
        #expect(!policy.didStartRequiresImmediateStop())
    }

    @Test("PiP retracts an automatic start that completes after foreground return")
    func pictureInPictureLateStartContract() {
        var policy = BackgroundPiPLifecyclePolicy()
        policy.setAutomaticStartEnabled(true, sourceReady: true)
        policy.transition(
            to: .inactive,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: false
        )
        policy.willStart(manualRequestPending: false)
        #expect(policy.startOrigin == .automaticInline)
        policy.transition(
            to: .active,
            automaticallyStartsFromInline: true,
            sourceReady: true,
            startPending: true
        )
        #expect(policy.stopWhenStartCompletes)
        #expect(policy.didStartRequiresImmediateStop())

        var manualPolicy = BackgroundPiPLifecyclePolicy()
        manualPolicy.manualStartRequested()
        manualPolicy.willStart(manualRequestPending: true)
        #expect(manualPolicy.startOrigin == .manualControl)
        #expect(!manualPolicy.didStartRequiresImmediateStop())
        manualPolicy.requestForegroundRetraction(startPending: true)
        #expect(manualPolicy.didStartRequiresImmediateStop())
    }

    @Test("PiP manual retry prepares first and starts only from a prepared tap")
    func pictureInPictureManualRetryContract() {
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .failed,
            hasRunContext: true
        ) == .prepareOnly)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .idle,
            hasRunContext: true
        ) == .prepareOnly)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .prepared,
            hasRunContext: true
        ) == .startSynchronously)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .active,
            hasRunContext: true
        ) == .stop)
        #expect(BackgroundPiPLifecyclePolicy.manualTapDecision(
            preparationPhase: .prepared,
            hasRunContext: false
        ) == .none)
    }

    @Test("A failed or timed-out manual PiP request cannot classify a late callback as manual")
    func pictureInPictureManualStartTrackerClearsPendingOrigin() {
        var tracker = BackgroundPiPManualStartTracker()
        #expect(tracker.begin() == 1)
        #expect(tracker.isPending)

        // Both the timeout and failed-to-start delegate paths use settle().
        tracker.settle()
        #expect(!tracker.isPending)
        #expect(tracker.attemptSerial == 1)

        #expect(tracker.begin() == 2)
        #expect(tracker.isPending)
        tracker.reset()
        #expect(!tracker.isPending)
        #expect(tracker.attemptSerial == 0)

        #expect(BackgroundPiPStopOrigin.manualControl.suppressesCurrentBatch)
        #expect(!BackgroundPiPStopOrigin.foregroundRetraction.suppressesCurrentBatch)
        #expect(BackgroundPiPStopOrigin.foregroundRetraction
            .allowsAutomaticRepreparation)
        #expect(!BackgroundPiPStopOrigin.manualControl
            .allowsAutomaticRepreparation)
    }

    @Test("Only standard mode requests a continued-processing Live Activity")
    func backgroundExecutionLiveActivityPolicy() {
        #expect(BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .standard))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(
            for: .pictureInPicture
        ))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .screenShare))
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: false
        ))
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true
        ))
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .pictureInPicture,
            launchPreferencesLoaded: true
        ))
    }

    @Test("Continued processing requires explicit user origin and aggregate foreground")
    func continuedProcessingSubmissionOriginPolicy() {
        #expect(BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: false
        ))

        let automaticOrigins: [ContinuedProcessingStartOrigin] = [
            .foregroundRecovery,
            .scheduledTask,
            .goalContinuation,
            .queuedInput,
            .externalAutomation,
            .automaticTool
        ]
        for origin in automaticOrigins {
            #expect(!origin.allowsContinuedSubmission)
            #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
                for: .standard,
                launchPreferencesLoaded: true,
                origin: origin,
                hasAggregateForegroundScene: true
            ))
        }
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: false,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))
    }

    @Test("Eligibility keeps first run origin and drains when explicit work ends")
    func continuedProcessingEligibilityLifetime() {
        var state = ContinuedProcessingEligibilityState<UUID>()
        let recoveredRun = UUID()
        let registeredRecoveredRun = state.registerRun(
            recoveredRun,
            origin: .foregroundRecovery
        )
        let upgradedRecoveredRun = state.registerRun(
            recoveredRun,
            origin: .explicitUserAction
        )
        #expect(registeredRecoveredRun)
        #expect(!upgradedRecoveredRun)
        #expect(state.origin(forRun: recoveredRun) == .foregroundRecovery)
        #expect(!state.hasEligibleWork)

        let explicitRun = UUID()
        let scheduledRun = UUID()
        let registeredExplicitRun = state.registerRun(
            explicitRun,
            origin: .explicitUserAction
        )
        let registeredScheduledRun = state.registerRun(
            scheduledRun,
            origin: .scheduledTask
        )
        #expect(registeredExplicitRun)
        #expect(registeredScheduledRun)
        #expect(state.hasEligibleWork)
        state.finishRun(explicitRun)
        #expect(!state.hasEligibleWork)
    }

    @Test("Continued-processing requests fail instead of queueing stale Live Activities")
    func continuedProcessingRequestStrategy() {
        if #available(iOS 26.0, *) {
            let request = ContinuedProcessingRequestFactory.make(
                identifier: "org.floeagent.ios.continued.test",
                title: "Test",
                subtitle: "Test"
            )
            #expect(request.strategy == .fail)
        }
    }

    @Test("Media generation never creates continued processing for any origin")
    func mediaGenerationNeverCreatesContinuedProcessing() {
        for origin in ContinuedProcessingStartOrigin.allCases {
            #expect(!BackgroundRunCoordinator
                .shouldSubmitContinuedProcessingForMediaGeneration(origin: origin))
        }
    }

    @Test("Run recovery mode is immutable and legacy evidence fails closed")
    func runConversationModeResolutionContract() throws {
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: "plan",
            checkpointMode: nil
        ) == .plan)
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: "goal",
            checkpointMode: nil,
            checkpointWasUnreadable: true
        ) == .goal)
        #expect(try RunConversationModeResolver.resolve(
            persistedRunMode: nil,
            checkpointMode: .chat
        ) == .chat)

        #expect(throws: RunConversationModeResolutionError.missingLegacyEvidence(
            checkpointWasUnreadable: false
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: nil,
                checkpointMode: nil
            )
        }
        #expect(throws: RunConversationModeResolutionError.missingLegacyEvidence(
            checkpointWasUnreadable: true
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: nil,
                checkpointMode: nil,
                checkpointWasUnreadable: true
            )
        }
        #expect(throws: RunConversationModeResolutionError.invalidPersistedRunMode("agent")) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: "agent",
                checkpointMode: nil
            )
        }
        #expect(throws: RunConversationModeResolutionError.conflictingEvidence(
            run: .plan,
            checkpoint: .chat
        )) {
            try RunConversationModeResolver.resolve(
                persistedRunMode: "plan",
                checkpointMode: .chat
            )
        }
    }

    @Test("Live background mode changes reconcile surfaces without requesting consent")
    func backgroundExecutionLiveSurfaceTransitionPolicy() {
        #expect(!BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false,
            hasRetainedPausedRun: false
        ))
        #expect(BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: true,
            hasRetainedPausedRun: false
        ))
        #expect(BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false,
            hasRetainedPausedRun: true
        ))

        let standard = BackgroundRunCoordinator.visualSurfaceTransition(for: .standard)
        #expect(standard.stopsPictureInPicture)
        #expect(standard.stopsScreenShare)
        #expect(!standard.preparesPictureInPicture)
        #expect(!standard.requestsScreenShareAuthorization)

        let pictureInPicture = BackgroundRunCoordinator.visualSurfaceTransition(
            for: .pictureInPicture
        )
        #expect(!pictureInPicture.stopsPictureInPicture)
        #expect(pictureInPicture.stopsScreenShare)
        #expect(pictureInPicture.preparesPictureInPicture)
        #expect(!pictureInPicture.requestsScreenShareAuthorization)

        let screenShare = BackgroundRunCoordinator.visualSurfaceTransition(for: .screenShare)
        #expect(screenShare.stopsPictureInPicture)
        #expect(!screenShare.stopsScreenShare)
        #expect(!screenShare.preparesPictureInPicture)
        #expect(!screenShare.requestsScreenShareAuthorization)
    }

    @Test("Ordinary conversation retains its PiP source while checkpointed")
    func ordinaryConversationRetainedPiPSourceOwnership() {
        let conversationID = UUID()
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [],
            retainedConversationID: conversationID
        ))
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [nil, conversationID],
            retainedConversationID: nil
        ))
        #expect(!BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [UUID(), nil],
            retainedConversationID: UUID()
        ))
    }

    @MainActor
    @Test("The scene PiP source mounts without any conditional toolbar button")
    func scenePiPSourceMountsIndependently() async throws {
        let service = BackgroundVideoService()
        let controller = UIHostingController(rootView:
            Color.clear.background(alignment: .bottomTrailing) {
                BackgroundPiPSceneSource(videoService: service)
            })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func sources(_ view: UIView) -> [UIView] {
            (view.layer is AVSampleBufferDisplayLayer ? [view] : []) + view.subviews.flatMap(sources)
        }
        let source = try #require(sources(controller.view).first)
        #expect(source.window === window)
        #expect(!source.isHidden && source.alpha == 1)
        #expect(source.bounds.width > 0 && source.bounds.height > 0)
        #expect(!service.isPiPActive)
    }

    @Test("Explicit SSH to VNC route excludes unrelated execution runtimes")
    func explicitRemoteRouteToolRestriction() {
        let available: Set<String> = [
            "ssh.listHosts", "ssh.execute", "ssh.updateHost",
            "vnc.status", "vnc.connect", "vnc.observe",
            "network.ping", "network.traceroute", "network.tcpProbe",
            "exec.javascript", "exec.localPython", "memory.organizePreview"
        ]
        let selected = ConversationCenter.toolsForExplicitRemoteRoute(
            request: "先用 SSH 配置主机，再测试 VNC 点击",
            from: available
        )
        #expect(selected == [
            "ssh.listHosts", "ssh.execute", "ssh.updateHost",
            "vnc.status", "vnc.connect", "vnc.observe",
            "network.ping", "network.traceroute", "network.tcpProbe"
        ])
        #expect(ConversationCenter.toolsForExplicitRemoteRoute(
            request: "用 VNC 看一下屏幕",
            from: available
        ) == selected)
        #expect(!selected!.contains("memory.organizePreview"))
    }

    @Test("Agent memory tools require current-turn memory intent")
    func agentMemoryToolIntentGate() {
        #expect(!ConversationCenter.requestsAgentMemoryTools(
            "测试 VNC，连接失败就用 SSH 修复"
        ))
        #expect(ConversationCenter.requestsAgentMemoryTools(
            "记住这台主机的新版本，并检查以前的记忆是否冲突"
        ))
        #expect(ConversationCenter.requestsAgentMemoryTools(
            "Please remember this version and replace the old memory"
        ))
    }

    @Test("Memory dream compares new facts with prior versions")
    @MainActor
    func memoryDreamPromptIncludesPriorMemoryAudit() {
        let conversationID = UUID()
        let oldMemory = MemoryEntry(
            scope: .agentGlobal,
            status: .active,
            content: "Floe version is 1.4.82",
            confidence: 1,
            importance: 0.8,
            sourceKind: .explicitUserRequest
        )
        let prompt = MemoryDreamService.buildPrompt([
            PersistedMessage(
                id: UUID(),
                conversationID: conversationID,
                role: "user",
                content: "Floe has upgraded to 1.4.83",
                createdAt: Date()
            )
        ], existing: [oldMemory])

        #expect(prompt.contains(oldMemory.id.uuidString))
        #expect(prompt.contains("Floe version is 1.4.82"))
        #expect(prompt.contains("conflictsWithEntryIDs"))
        #expect(prompt.contains("Never assume an older value is still current"))
    }

    @Test("Semantic organizer never duplicates deterministic review suggestions")
    func semanticMemorySuggestionMergeIsStable() {
        let first = UUID()
        let second = UUID()
        let deterministic = MemoryOrganizationSuggestion(
            kind: .possibleDuplicate,
            memoryIDs: [first, second],
            reason: "deterministic",
            canApplyAutomatically: false
        )
        let semantic = MemoryOrganizationSuggestion(
            kind: .possibleDuplicate,
            memoryIDs: [second, first],
            reason: "semantic",
            canApplyAutomatically: false
        )

        let merged = MemorySemanticOrganizer.merging([deterministic], [semantic])
        #expect(merged.count == 1)
        #expect(!merged[0].canApplyAutomatically)
    }

    @Test("Model-managed semantic decisions can upgrade the same bounded suggestion")
    func modelManagedMemorySuggestionUpgrade() {
        let first = UUID()
        let second = UUID()
        let deterministic = MemoryOrganizationSuggestion(
            kind: .sameFactReplacement,
            memoryIDs: [first, second],
            preferredMemoryID: first,
            reason: "review",
            canApplyAutomatically: false
        )
        let semantic = MemoryOrganizationSuggestion(
            kind: .sameFactReplacement,
            memoryIDs: [second, first],
            preferredMemoryID: second,
            reason: "model-managed",
            canApplyAutomatically: true
        )

        let merged = MemorySemanticOrganizer.merging([deterministic], [semantic])

        #expect(merged.count == 1)
        #expect(merged[0].canApplyAutomatically)
        #expect(merged[0].preferredMemoryID == second)
    }

    @Test("Model-managed memory only applies bounded safe deletion suggestions")
    @MainActor
    func modelManagedMemoryDeletionIsBounded() {
        let keep = UUID()
        let stale = UUID()
        let expired = UUID()
        let needsOwner = UUID()
        let suggestions = [
            MemoryOrganizationSuggestion(
                kind: .sameFactReplacement,
                memoryIDs: [keep, stale],
                preferredMemoryID: keep,
                reason: "new version",
                canApplyAutomatically: true
            ),
            MemoryOrganizationSuggestion(
                kind: .expired,
                memoryIDs: [expired],
                reason: "temporary state",
                canApplyAutomatically: true
            ),
            MemoryOrganizationSuggestion(
                kind: .missingOwnership,
                memoryIDs: [needsOwner],
                reason: "review",
                canApplyAutomatically: true
            )
        ]

        #expect(MemoryCenter.automaticDeleteIDs(in: suggestions) == [stale, expired])
    }
}
extension CrashAndFeedbackRegressionTests {
    @Test("An Agent update during a Pencil gesture cannot replace the gesture baseline")
    @MainActor func pencilGestureRetainsOpenedRevision() throws {
        let base = NoteDocument(title: "Stroke baseline")
        var changed = base; changed.revision += 1
        let data = PKDrawing().dataRepresentation()
        var received: NoteDocument?
        let view = NotePencilView(page: base.pages[0], drawing: nil, background: nil, fingerDrawing: false,
            tool: PKInkingTool(.pen, color: .black, width: 3), onDrawing: { _ in }, drawingBaseline: base,
            onVersionedDrawing: { _, snapshot in received = snapshot })
        let coordinator = view.makeCoordinator()
        coordinator.loadedBaseline = base
        let canvas = PKCanvasView()
        coordinator.canvasViewDidBeginUsingTool(canvas)
        var updated = view; updated.drawingBaseline = changed
        coordinator.parent = updated
        coordinator.pendingDrawing = data
        coordinator.canvasViewDidEndUsingTool(canvas)
        #expect(received == base)
    }

    @Test("Concurrent ink saves preserve the Agent page and a durable human copy")
    @MainActor func concurrentInkCreatesReviewInsteadOfOverwriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-concurrency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Shared ink"))
        let recovery = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/Notes/InkRecovery/\(base.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        let session = NotesSession()
        await session.open(using: store)
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let agentBytes = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))]).dataRepresentation()
        let resourceFile = root.appendingPathComponent("agent.drawing")
        try agentBytes.write(to: resourceFile)
        let resource = try await store.importResource(from: resourceFile, mediaType: "application/vnd.apple.pencilkit")
        let agent = try await store.apply(.init(documentID: base.id, expectedRevision: base.revision,
            title: "Agent", edits: [.drawing(pageID: base.pages[0].id, resourceID: resource)]))
        let human = PKDrawing().dataRepresentation()
        session.saveDrawing(human, pageID: base.pages[0].id, base: base)
        let deadline = Date().addingTimeInterval(5)
        while session.pendingWrites > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.pendingWrites == 0)
        #expect(try await store.document(base.id) == agent)
        let review = try #require(try await store.conflictReviews().first)
        #expect(review.current.id == base.id)
        let copy = try await store.document(review.copy.id)
        let inkID = try #require(copy.pages[0].drawingResourceID)
        let url = try await store.resourceURL(inkID)
        #expect(try Data(contentsOf: url) == human)
        #expect(!session.hasPendingInk(documentID: base.id, pageID: base.pages[0].id))
        let restarted = try NotesStore(root: root)
        #expect(try await restarted.conflictReviews().first?.copy.id == copy.id)
    }
}
extension CrashAndFeedbackRegressionTests {
    @Test("A dialog draft uses its opened version even after the session refreshes")
    @MainActor func notesDialogDraftCannotAdoptAgentRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-dialog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        var value = NoteDocument(title: "Element")
        let element = NoteElement(text: "Opened text")
        value.pages[0].elements = [element]
        let base = try await store.create(value)
        let session = NotesSession()
        await session.open(using: store)
        var changed = element; changed.text = "Agent update"
        let agent = try await store.apply(.init(documentID: base.id, expectedRevision: base.revision,
            title: "Agent", edits: [.upsertElement(pageID: base.pages[0].id, element: changed)]))
        try await session.reload()
        var mine = element; mine.text = "Human draft"
        session.apply([.upsertElement(pageID: base.pages[0].id, element: mine)], title: "Dialog", base: base)
        let deadline = Date().addingTimeInterval(5)
        while session.pendingWrites > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.pendingWrites == 0)
        #expect(try await store.document(base.id) == agent)
        let review = try #require(try await store.conflictReviews().first)
        #expect(review.copy.pages[0].elements.first?.text == "Human draft")
    }
}
extension CrashAndFeedbackRegressionTests {
    @Test("Engineering navigation recovery is local, finite and protects edit state")
    func engineeringNavigationRecoveryBoundaries() {
        let local = URL(string: "http://127.0.0.1:8080/session/index.html")!
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        var policy = EngineeringNavigationRecovery()
        let firstAttempt = policy.consume(error: offline, page: local, serverAvailable: true, delivered: false, completed: false, dirty: false, saving: false)
        #expect(firstAttempt)
        let repeatedAttempt = policy.consume(error: offline, page: local, serverAvailable: true, delivered: false, completed: false, dirty: false, saving: false)
        #expect(!repeatedAttempt)
        for flag in 0..<4 {
            var active = EngineeringNavigationRecovery()
            let activeEditorAttempt = active.consume(error: offline, page: local, serverAvailable: true, delivered: flag == 0, completed: flag == 1, dirty: flag == 2, saving: flag == 3)
            #expect(!activeEditorAttempt)
        }
        for url in [nil, URL(string: "https://example.com/index.html"), URL(string: "http://127.0.0.1.example.com/index.html")] {
            var remote = EngineeringNavigationRecovery()
            let nonLocalAttempt = remote.consume(error: offline, page: url, serverAvailable: true, delivered: false, completed: false, dirty: false, saving: false)
            #expect(!nonLocalAttempt)
        }
        var stopped = EngineeringNavigationRecovery()
        let stoppedServerAttempt = stopped.consume(error: offline, page: local, serverAvailable: false, delivered: false, completed: false, dirty: false, saving: false)
        #expect(!stoppedServerAttempt)
        let cancelledAttempt = stopped.consume(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), page: local, serverAvailable: true, delivered: false, completed: false, dirty: false, saving: false)
        #expect(!cancelledAttempt)
    }
}
// MARK: - Notes handwriting acknowledgement lineage (build 283 feedback)
//
// Real NotesStore + real NotesSession. The session may adopt its own last
// acknowledged ink commit for a page only for the canvas lineage and epoch
// that produced it (or one reloaded with those exact bytes), and only while
// the live store page still holds them. Every test below exercises one of
// those boundaries; none mock the store.
extension CrashAndFeedbackRegressionTests {
    /// Build one deterministic stroke. Tests reuse the SAME stroke instances
    /// across drawings (D2 literally contains D1's stroke) and store each
    /// expected Data once — repeated `inkData` rebuilds are never used as
    /// byte-proof.
    private func makeStroke(_ offset: CGFloat) -> PKStroke {
        let date = Date(timeIntervalSince1970: 0)
        let points = [CGPoint(x: 8 + offset, y: 12), CGPoint(x: 36 + offset, y: 44)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: date))
    }

    private func drawingData(_ strokes: [PKStroke]) -> Data {
        PKDrawing(strokes: strokes).dataRepresentation()
    }

    @MainActor private func drainInk(_ session: NotesSession) async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.pendingWrites > 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.pendingWrites == 0)
    }

    private func pageInk(_ store: NotesStore, _ document: NoteDocument) async throws -> Data? {
        guard let resource = document.pages[0].drawingResourceID else { return nil }
        return try Data(contentsOf: await store.resourceURL(resource))
    }

    @Test("Own next stroke after a drained save uses the acknowledged base, not a stale UI base")
    @MainActor func inkSaveReentryUsesOwnAcknowledgedBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-reentry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Continuous writing"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        let first = drawingData([strokeA])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let savedOnce = try await store.document(base.id)
        #expect(savedOnce.revision == base.revision + 1)
        #expect(try await pageInk(store, savedOnce) == first)
        // The editor baseline is still the pre-save snapshot here; the next
        // stroke must not be treated as a concurrent edit of our own commit.
        let second = drawingData([strokeA, makeStroke(300)])
        #expect(try PKDrawing(data: second).strokes.count == 2)
        session.saveDrawing(second, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let savedTwice = try await store.document(base.id)
        #expect(try await store.conflictReviews().isEmpty)
        #expect(savedTwice.revision == base.revision + 2)
        let storedSecond = try #require(try await pageInk(store, savedTwice))
        #expect(storedSecond == second)
        #expect(try PKDrawing(data: storedSecond).strokes.count == 2)
        #expect(try await store.editingSnapshot(base.id, revision: savedOnce.revision) == savedOnce)
    }

    @Test("Two strokes queued back to back coalesce into one commit without duplicates")
    @MainActor func multipleInflightInkSavesCommitOnceWithoutDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-inflight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Rapid strokes"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        let first = drawingData([strokeA])
        let second = drawingData([strokeA, makeStroke(300)])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        session.saveDrawing(second, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let saved = try await store.document(base.id)
        #expect(try await store.conflictReviews().isEmpty)
        #expect(saved.revision == base.revision + 1)
        let stored = try #require(try await pageInk(store, saved))
        #expect(stored == second)
        #expect(try PKDrawing(data: stored).strokes.count == 2)
    }

    @Test("An obsolete older-sequence report cannot overwrite the newer queued stroke")
    @MainActor func olderSequenceCannotReplaceNewerPendingStroke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-sequence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Ordered reports"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        let newer = drawingData([strokeA, makeStroke(300)])
        let obsolete = drawingData([strokeA, makeStroke(600)])
        session.saveDrawing(newer, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        // A stale callback from the same canvas/generation arriving after the
        // newer report must be ignored, not coalesced over it.
        session.saveDrawing(obsolete, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let saved = try await store.document(base.id)
        #expect(try await store.conflictReviews().isEmpty)
        #expect(saved.revision == base.revision + 1)
        let stored = try #require(try await pageInk(store, saved))
        #expect(stored == newer)
        #expect(try PKDrawing(data: stored).strokes.count == 2)
    }

    @Test("A late older report cannot replace a newer stroke after the queue has drained")
    @MainActor func olderSequenceCannotReplaceDrainedStroke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-drained-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Drained report order"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID(), stroke = makeStroke(0)
        let newest = drawingData([stroke, makeStroke(300)])
        session.saveDrawing(newest, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let committed = try await store.document(base.id)
        session.saveDrawing(drawingData([stroke]), pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let afterLateCallback = try await store.document(base.id)
        #expect(afterLateCallback.revision == committed.revision)
        #expect(try await pageInk(store, afterLateCallback) == newest)
        #expect(try await store.conflictReviews().isEmpty)
    }

    @Test("Another producer cannot overwrite a failed producer's durable recovery envelope")
    @MainActor func failedProducerRecoverySurvivesOtherProducerAndRestarts() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ink-producer-recovery-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let store = try NotesStore(root: root)
        // A missing document makes the real store reject AFTER the recovery
        // envelope is durable, without replacing the store with a fake.
        let missing = NoteDocument(title: "Recovered producer")
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/InkRecovery/\(missing.id.uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let session = NotesSession()
        await session.open(using: store)
        let failedInk = drawingData([makeStroke(0)])
        session.saveDrawing(failedInk, pageID: missing.pages[0].id, base: missing,
                            provenance: .init(lineage: UUID(), generation: 1, sequence: 1))
        try await drainInk(session)
        #expect(session.errorMessage != nil)
        let envelopes = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "inkdraft" }
        let failedEnvelope = try #require(envelopes.first)
        #expect(envelopes.count == 1)
        let retainedBytes = try Data(contentsOf: failedEnvelope)
        #expect(try JSONDecoder().decode(NoteInkDraft.self, from: retainedBytes).drawing == failedInk)

        let base = try await store.create(missing)
        let succeedingInk = drawingData([makeStroke(600)])
        session.saveDrawing(succeedingInk, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: UUID(), generation: 1, sequence: 1))
        try await drainInk(session)
        #expect(try Data(contentsOf: failedEnvelope) == retainedBytes)
        let current = try await store.document(base.id)
        #expect(try await pageInk(store, current) == succeedingInk)

        // A fresh session replays the ORIGINAL file independently, preserving
        // both genuinely different drawings and retiring only its own file.
        let restarted = NotesSession()
        await restarted.open(using: store)
        restarted.recoverInk(documentID: base.id)
        try await drainInk(restarted)
        let review = try #require(try await store.conflictReviews().first)
        let copy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, copy) == failedInk)
        #expect(try await pageInk(store, try await store.document(base.id)) == succeedingInk)
        #expect(!fm.fileExists(atPath: failedEnvelope.path))
    }

    @Test("Pencil dispatches once to the captured page and retains legacy fallback")
    @MainActor func pencilReportsOnceToCapturedOriginAndPreservesLegacyFallback() {
        let base = NoteDocument(title: "Callback origin")
        var legacyCalls = 0, provenancedCalls = 0, differentPageCalls = 0
        var view = NotePencilView(page: base.pages[0], drawing: nil, background: nil,
            fingerDrawing: false, tool: PKInkingTool(.pen, color: .black, width: 3),
            onDrawing: { _ in legacyCalls += 1 }, drawingBaseline: base)
        let canvas = PKCanvasView(), coordinator = view.makeCoordinator()
        coordinator.loadedBaseline = base
        canvas.drawing = PKDrawing(strokes: [makeStroke(0)])
        coordinator.canvasViewDrawingDidChange(canvas)
        #expect(legacyCalls == 1)
        view.onVersionedDrawingProvenance = { _, snapshot, _, _ in
            #expect(snapshot.id == base.id)
            provenancedCalls += 1
        }
        coordinator.parent = view
        coordinator.canvasViewDidBeginUsingTool(canvas)
        var other = view
        other.onVersionedDrawingProvenance = { _, _, _, _ in differentPageCalls += 1 }
        coordinator.parent = other
        canvas.drawing = PKDrawing(strokes: [makeStroke(0), makeStroke(300)])
        coordinator.canvasViewDrawingDidChange(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        #expect(legacyCalls == 1)
        #expect(provenancedCalls == 1)
        #expect(differentPageCalls == 0)
    }

    @Test("A stale view snapshot cannot rewind ink and equal-byte loads confirm their actual generation")
    @MainActor func pencilSnapshotCannotRewindNewerLocalInk() async {
        let base = NoteDocument(title: "Snapshot order")
        var adopted: [UInt64] = []
        let view = NotePencilView(page: base.pages[0], drawing: nil,
            onDrawingAdopted: { _, generation in adopted.append(generation) }, background: nil,
            fingerDrawing: false, tool: PKInkingTool(.pen, color: .black, width: 3), onDrawing: { _ in })
        let canvas = PKCanvasView(), coordinator = view.makeCoordinator()
        canvas.drawing = PKDrawing(strokes: [makeStroke(0), makeStroke(300)])
        coordinator.canvasViewDrawingDidChange(canvas)
        let newInk = canvas.drawing.dataRepresentation()
        coordinator.applyDrawingSnapshot(drawingData([makeStroke(600)]), generation: 1,
            baseline: base, mutation: 0, to: canvas)
        #expect(canvas.drawing.dataRepresentation() == newInk)
        coordinator.applyDrawingSnapshot(newInk, generation: 2, baseline: base,
            mutation: coordinator.mutationCounter, to: canvas)
        // The actual adoption proof must be delivered BEFORE a new gesture
        // can retire any deferred notification.
        #expect(adopted == [2])
        coordinator.canvasViewDidBeginUsingTool(canvas)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(adopted == [2])
        #expect(coordinator.adoptedGeneration == 2)
        #expect(canvas.drawing.dataRepresentation() == newInk)
    }

    @Test("A report from a generation retired by reload registration cannot use the ack, the current one can")
    @MainActor func staleGenerationReportRejectedAfterReloadRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-register-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Reload registration"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        let first = drawingData([strokeA])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let acknowledged = try #require(try await store.document(base.id).pages[0].drawingResourceID)
        // The canvas reloads the same bytes; the confirmed adoption registers
        // generation 2 and retires generation 1.
        session.noteInkCanvasSynced(documentID: base.id, pageID: base.pages[0].id,
                                    canvasLineage: lineage, canvasGeneration: 2, drawingResourceID: acknowledged)
        // A stale generation-1 report (captured before the reload) must fail
        // closed even though it matches the ack's producer: the registered
        // generation fence retires it.
        let stale = drawingData([strokeA, makeStroke(600)])
        session.saveDrawing(stale, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let review = try #require(try await store.conflictReviews().first)
        let currentAfterStale = try await store.document(base.id)
        #expect(try await pageInk(store, currentAfterStale) == first)
        let staleCopy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, staleCopy) == stale)
        // The current generation-2 report adopts through the verified reload
        // and continues the line without a second conflict.
        let resumed = drawingData([strokeA, makeStroke(300)])
        session.saveDrawing(resumed, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 2, sequence: 3))
        try await drainInk(session)
        #expect(try await store.conflictReviews().count == 1)
        let saved = try await store.document(base.id)
        #expect(saved.revision == base.revision + 2)
        #expect(try await pageInk(store, saved) == resumed)
    }

    @Test("A canvas reloaded with the acknowledged bytes may continue that line")
    @MainActor func remountedCanvasAdoptsAckAfterSyncedReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-remount-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Remounted canvas"))
        let session = NotesSession()
        await session.open(using: store)
        let firstLineage = UUID()
        let first = drawingData([makeStroke(0)])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: firstLineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let savedOnce = try await store.document(base.id)
        let acknowledged = try #require(savedOnce.pages[0].drawingResourceID)
        // The editor remounts: a new canvas loads the committed bytes through
        // the verified page task and registers that exact resource.
        let secondLineage = UUID()
        session.noteInkCanvasSynced(documentID: base.id, pageID: base.pages[0].id,
                                    canvasLineage: secondLineage, canvasGeneration: 1, drawingResourceID: acknowledged)
        let second = drawingData([makeStroke(0), makeStroke(300)])
        session.saveDrawing(second, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: secondLineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let savedTwice = try await store.document(base.id)
        #expect(try await store.conflictReviews().isEmpty)
        #expect(savedTwice.revision == base.revision + 2)
        #expect(try await pageInk(store, savedTwice) == second)
    }

    @Test("A foreign canvas that never reloaded the acknowledged bytes cannot consume the ack")
    @MainActor func foreignCanvasCannotConsumeAcknowledgedBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-foreign-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Foreign canvas"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let first = drawingData([makeStroke(0)])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        // A different lineage with no synced reload reports from an old base:
        // it must fail closed to the preserved-conflict path, not overwrite.
        let foreign = drawingData([makeStroke(600)])
        session.saveDrawing(foreign, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: UUID(), generation: 1, sequence: 1))
        try await drainInk(session)
        let review = try #require(try await store.conflictReviews().first)
        let current = try await store.document(base.id)
        #expect(try await pageInk(store, current) == first)
        let copy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, copy) == foreign)
        #expect(current.revision == base.revision + 1)
    }

    @Test("A generation retired by a rewind cannot consume the old acknowledgement")
    @MainActor func retiredGenerationCannotConsumeAckAfterRewind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-rewind-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Rewind"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        let first = drawingData([strokeA])
        session.saveDrawing(first, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let savedOnce = try await store.document(base.id)
        #expect(savedOnce.pages[0].drawingResourceID != nil)
        // The user undoes the stroke; the editor's page task reloads the
        // rewound bytes and the canvas adoption advances the generation.
        _ = try await store.undo(base.id, expectedRevision: savedOnce.revision)
        let rewound = try await store.document(base.id)
        #expect(rewound.revision == savedOnce.revision + 1)
        #expect(rewound.pages[0].drawingResourceID == nil)
        session.noteInkCanvasSynced(documentID: base.id, pageID: base.pages[0].id,
                                    canvasLineage: lineage, canvasGeneration: 2, drawingResourceID: nil)
        // A stale closure from before the rewind still carries generation 1
        // (the pre-undo canvas). The live-page guard fences the ack closed:
        // both versions are preserved instead of the old bytes winning.
        let stale = drawingData([strokeA, makeStroke(300)])
        session.saveDrawing(stale, pageID: base.pages[0].id, base: savedOnce,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let review = try #require(try await store.conflictReviews().first)
        let current = try await store.document(base.id)
        #expect(current.pages[0].drawingResourceID == nil)
        #expect(current.revision == rewound.revision)
        let copy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, copy) == stale)
    }

    @Test("Continuing to write after a valid undo saves cleanly with the rewound baseline")
    @MainActor func validUndoThenContinueWritingSavesWithoutConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Undo then write"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        session.saveDrawing(drawingData([makeStroke(0)]), pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let savedOnce = try await store.document(base.id)
        _ = try await store.undo(base.id, expectedRevision: savedOnce.revision)
        let rewound = try await store.document(base.id)
        // The rewound canvas re-registers at a new generation; a fresh stroke
        // is a legitimate new edit on the rewound state and must save
        // directly with the refreshed baseline.
        session.noteInkCanvasSynced(documentID: base.id, pageID: base.pages[0].id,
                                    canvasLineage: lineage, canvasGeneration: 2, drawingResourceID: nil)
        let resumed = drawingData([makeStroke(300)])
        session.saveDrawing(resumed, pageID: base.pages[0].id, base: rewound,
                            provenance: .init(lineage: lineage, generation: 2, sequence: 1))
        try await drainInk(session)
        let saved = try await store.document(base.id)
        #expect(try await store.conflictReviews().isEmpty)
        #expect(saved.revision == rewound.revision + 1)
        #expect(try await pageInk(store, saved) == resumed)
    }

    @Test("External same-page ink still conflicts, keeps both versions, and resolves at the latest revision")
    @MainActor func externalSamePageInkStillConflictsAndPreservesBoth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-external-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "True concurrency"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let strokeA = makeStroke(0)
        session.saveDrawing(drawingData([strokeA]), pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let mine = try await store.document(base.id)
        // Another writer path commits different bytes to the same page.
        let external = drawingData([makeStroke(900)])
        let externalFile = root.appendingPathComponent("external.drawing")
        try external.write(to: externalFile)
        let externalResource = try await store.importResource(from: externalFile, mediaType: "application/vnd.apple.pencilkit")
        let externalSaved = try await store.apply(.init(documentID: base.id, expectedRevision: mine.revision,
            title: "External", edits: [.drawing(pageID: base.pages[0].id, resourceID: externalResource)]))
        let human = drawingData([strokeA, makeStroke(300), makeStroke(600)])
        session.saveDrawing(human, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let review = try #require(try await store.conflictReviews().first)
        let current = try await store.document(base.id)
        #expect(current == externalSaved)
        #expect(try await pageInk(store, current) == external)
        let copy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, copy) == human)
        // Resolving with "use mine" applies at the latest revision and keeps
        // the external text-era document state addressable in history.
        await session.resolveEditConflict(review, useMine: true)
        try await drainInk(session)
        #expect(try await store.conflictReviews().isEmpty)
        let resolved = try await store.document(base.id)
        #expect(resolved.revision == externalSaved.revision + 1)
        #expect(try await pageInk(store, resolved) == human)
        #expect(session.errorMessage == nil)
    }

    @Test("An identical repeated conflict reuses its review and copy instead of duplicating")
    @MainActor func repeatedIdenticalInkConflictDoesNotDuplicateCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-dedup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Repeated conflict"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let human = drawingData([makeStroke(0), makeStroke(300)])
        // Force the first conflict with an external page change.
        let external = drawingData([makeStroke(900)])
        let externalFile = root.appendingPathComponent("external.drawing")
        try external.write(to: externalFile)
        let externalResource = try await store.importResource(from: externalFile, mediaType: "application/vnd.apple.pencilkit")
        let externalSaved = try await store.apply(.init(documentID: base.id, expectedRevision: base.revision,
            title: "External", edits: [.drawing(pageID: base.pages[0].id, resourceID: externalResource)]))
        session.saveDrawing(human, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let firstReview = try #require(try await store.conflictReviews().first)
        let documentCount = try await store.documents(includeTrash: true).count
        // An unrelated edit moves the document on; the same failing bytes
        // must refresh the same review instead of minting a second copy.
        try await store.apply(.init(documentID: base.id, expectedRevision: externalSaved.revision,
            title: "External text", edits: [.textSource(id: UUID(), text: "unrelated")]))
        session.saveDrawing(human, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 2))
        try await drainInk(session)
        let reviews = try await store.conflictReviews()
        #expect(reviews.count == 1)
        let refreshed = try #require(reviews.first)
        #expect(refreshed.id == firstReview.id)
        #expect(refreshed.copy.id == firstReview.copy.id)
        #expect(refreshed.current.revision == externalSaved.revision + 1)
        #expect(refreshed.current.textSources?.values.contains("unrelated") == true)
        #expect(try await store.documents(includeTrash: true).count == documentCount)
        let copy = try await store.document(refreshed.copy.id)
        #expect(try await pageInk(store, copy) == human)
    }

    @Test("Crash recovery replays the true disk baseline and cannot consume a live-canvas ack")
    @MainActor func recoveryReplayCannotAdoptLiveAck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Recovered draft"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let committed = drawingData([makeStroke(0)])
        session.saveDrawing(committed, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        #expect(try await pageInk(store, try await store.document(base.id)) == committed)
        // A crash envelope with different, older bytes survives the restart.
        let recovery = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/Notes/InkRecovery/\(base.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let staleDraft = drawingData([makeStroke(300)])
        let envelope = NoteInkDraft(base: base, pageID: base.pages[0].id, drawing: staleDraft)
        try JSONEncoder().encode(envelope).write(to: recovery.appendingPathComponent("\(base.pages[0].id.uuidString).inkdraft"))
        session.recoverInk(documentID: base.id)
        try await drainInk(session)
        // The recovery kept its real baseline: the newer committed ink wins
        // the page, the older draft is preserved as the recovery copy.
        let review = try #require(try await store.conflictReviews().first)
        let current = try await store.document(base.id)
        #expect(try await pageInk(store, current) == committed)
        let copy = try await store.document(review.copy.id)
        #expect(try await pageInk(store, copy) == staleDraft)
    }

    @Test("Crash recovery of already-applied bytes replays without a conflict or a new revision")
    @MainActor func recoveryReplayOfAppliedBytesIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let base = try await store.create(NoteDocument(title: "Idempotent replay"))
        let session = NotesSession()
        await session.open(using: store)
        let lineage = UUID()
        let committed = drawingData([makeStroke(0)])
        session.saveDrawing(committed, pageID: base.pages[0].id, base: base,
                            provenance: .init(lineage: lineage, generation: 1, sequence: 1))
        try await drainInk(session)
        let saved = try await store.document(base.id)
        // Crash between commit and envelope removal: same bytes replay.
        let recovery = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/Notes/InkRecovery/\(base.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let envelope = NoteInkDraft(base: base, pageID: base.pages[0].id, drawing: committed)
        try JSONEncoder().encode(envelope).write(to: recovery.appendingPathComponent("\(base.pages[0].id.uuidString).inkdraft"))
        session.recoverInk(documentID: base.id)
        try await drainInk(session)
        #expect(try await store.conflictReviews().isEmpty)
        let replayed = try await store.document(base.id)
        #expect(replayed.revision == saved.revision)
        #expect(try await pageInk(store, replayed) == committed)
    }
}

#endif
