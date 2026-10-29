import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeNotes
import FloePersistence
import FloeProviders
@testable import FloeAndroidCore

// MARK: - Shared fixtures

struct OCRBoundNote {
    let epoch: UInt64
    let root: URL
    let documentID: UUID
    let pageID: UUID
    let sourceKey: String
    let revision: Int

    var stagingRoot: URL {
        root.appendingPathComponent("OCRStaging", isDirectory: true)
    }
}

enum OCRTestSupport {
    static let png: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func callData(_ epoch: UInt64, _ action: String,
                         _ payload: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys])
        let value = try JSONDecoder().decode(NotesJSONValue.self, from: data)
        return try await NotesDomainService.shared.handle(
            epoch: epoch,
            requestID: "notes-ocr-test-" + UUID().uuidString,
            action: action,
            payload: value)
    }

    static func call(_ epoch: UInt64, _ action: String,
                     _ payload: [String: Any]) async throws -> [String: Any] {
        let data = try await callData(epoch, action, payload)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any], object["ok"] as? Bool == true else {
            throw NSError(domain: "OCRTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "action failed: \(action)"])
        }
        return object
    }

    static func document(_ epoch: UInt64, _ documentID: UUID) async throws
        -> NoteDocument {
        struct Reply: Decodable { let document: NoteDocument }
        let data = try await callData(epoch, "document.get",
                                      ["documentID": documentID.uuidString])
        return try NotesWire.decode(Reply.self, from: data).document
    }

    static func bindNote() async throws -> OCRBoundNote {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-ocr-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let epoch = DispatchTime.now().uptimeNanoseconds
        NotesDomainService.shared.bindForTesting(epoch: epoch, root: root)
        let documentID = UUID()
        _ = try await call(epoch, "document.create", [
            "documentID": documentID.uuidString,
            "kind": "notebook",
            "title": "OCR note",
        ])
        let document = try await Self.document(epoch, documentID)
        guard let page = document.pages.first else {
            throw NSError(domain: "OCRTests", code: 2)
        }
        let snapshot = try await NotesOCRServiceSource(epoch: epoch).pageSnapshot(
            documentID: documentID, pageID: page.id)
        return OCRBoundNote(epoch: epoch, root: root,
                            documentID: documentID, pageID: page.id,
                            sourceKey: snapshot.visualIndexKey,
                            revision: snapshot.revision)
    }

    static func retire(_ note: OCRBoundNote) async {
        await NotesDomainService.shared.retire(epoch: note.epoch)
        try? FileManager.default.removeItem(at: note.root)
    }

    static func stageInput(_ note: OCRBoundNote, image: Data = png,
                           sha256: String? = nil,
                           pixels: (Int, Int) = (1, 1),
                           byteCount: Int? = nil) -> NotesOCRStageBegin {
        NotesOCRStageBegin(
            documentID: note.documentID, pageID: note.pageID,
            sourceKey: note.sourceKey, revision: note.revision,
            pageNumber: 1, widthPt: 768, heightPt: 1024,
            byteCount: byteCount ?? image.count,
            sha256: sha256 ?? NotesOCRImage.sha256Hex(image),
            pixelWidth: pixels.0, pixelHeight: pixels.1)
    }

    static func stage(_ domain: NotesOCRDomain, _ input: NotesOCRStageBegin,
                      image: Data) async throws -> String {
        let descriptor = try await domain.beginStage(input)
        let received = try await domain.append(stageID: descriptor.stageID,
                                               offset: 0, data: image)
        XCTAssertEqual(received, image.count)
        return descriptor.stageID
    }

    static func waitUntil(_ label: String, timeout: TimeInterval = 3,
                          _ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for \(label)")
                throw NSError(domain: "OCRTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: label])
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

struct FixedOCRRouting: NotesOCRVisionRouting {
    let outcome: NotesOCRVisionRouteOutcome
    func route() async -> NotesOCRVisionRouteOutcome { outcome }
}

final class OCRRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderStreamRequest] = []
    func record(_ request: ProviderStreamRequest) {
        lock.lock(); values.append(request); lock.unlock()
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func first() -> ProviderStreamRequest? { lock.lock(); defer { lock.unlock() }; return values.first }
}

final class ProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

final class ScriptedOCRAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    let recorder: OCRRequestRecorder
    private let handler: @Sendable (ProviderStreamRequest) async throws -> [AgentEvent]

    init(recorder: OCRRequestRecorder = OCRRequestRecorder(),
         handler: @escaping @Sendable (ProviderStreamRequest) async throws
            -> [AgentEvent]) {
        self.recorder = recorder
        self.handler = handler
    }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                recorder.record(request)
                do {
                    let events = try await handler(request)
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

enum OCRRouteFixture {
    static func route(adapter: any ProviderAdapter,
                      label: String = "Fixture · Vision") -> NotesOCRVisionRoute {
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixture.invalid/v1")!)
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "fixture-vision",
            displayName: "Vision",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .vision])
        return NotesOCRVisionRoute(
            provider: provider, model: model,
            credentials: ProviderCredentials(apiKey: "fixture"),
            adapter: adapter, providerLabel: label)
    }

    static func domain(_ note: OCRBoundNote, routing: any NotesOCRVisionRouting,
                       port: AlwaysAttachOwnedWorkPort = AlwaysAttachOwnedWorkPort())
        throws -> NotesOCRDomain {
        try NotesOCRDomain(
            epoch: note.epoch,
            source: NotesOCRServiceSource(epoch: note.epoch),
            routing: routing,
            ownedWork: ConfigOwnedWorkLifecycle(
                registry: port, epochProvider: FixedEpochProvider(epoch: note.epoch)),
            stagingRoot: note.stagingRoot)
    }
}

// MARK: - Recognition / cache boundary

final class NotesOCRTests: XCTestCase {
    private var notes: [OCRBoundNote] = []

    override func tearDown() async throws {
        for note in notes { await OCRTestSupport.retire(note) }
        notes.removeAll()
        try await super.tearDown()
    }

    private func note() async throws -> OCRBoundNote {
        let value = try await OCRTestSupport.bindNote()
        notes.append(value)
        return value
    }

    func testRecognizeUsesOriginalAdapterImageDataAndWritesTheExactCacheAndSearch() async throws {
        let note = try await note()
        let recorder = OCRRequestRecorder()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            [.textDelta(.init(text: "recognized page text")),
             .completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        let result = try await domain.recognize(stageID: stageID, conversationID: nil)

        XCTAssertEqual(result.state, .recognized)
        XCTAssertEqual(result.text, "recognized page text")
        XCTAssertEqual(result.cache.status, .applied)
        XCTAssertEqual(result.providerLabel, "Fixture · Vision")

        let request = try XCTUnwrap(recorder.first())
        XCTAssertTrue(request.toolSchemas.isEmpty)
        XCTAssertEqual(request.reasoningPolicy, .disabled)
        let messages = request.effectiveMessages
        XCTAssertEqual(messages.count, 2)
        let parts = messages[1].content
        guard case .imageData(let mime, let base64) = try XCTUnwrap(parts.last) else {
            return XCTFail("the original adapter must receive imageData")
        }
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(base64, OCRTestSupport.png.base64EncodedString())

        let after = try await OCRTestSupport.document(note.epoch, note.documentID)
        XCTAssertEqual(after.revision, note.revision,
                       "the OCR cache never moves the document revision")
        XCTAssertEqual(after.pages.first?.ocrSourceKey, note.sourceKey)
        XCTAssertEqual(after.pages.first?.ocrText, "recognized page text")

        let search = try await OCRTestSupport.call(note.epoch, "search.query",
                                                    ["query": "recognized", "limit": 20])
        let documents = try XCTUnwrap(search["documents"] as? [[String: Any]])
        XCTAssertTrue(documents.contains {
            ($0["id"] as? String) == note.documentID.uuidString
        }, "the real native search index must contain the OCR text")
    }


    func testConfiguredAuxiliaryVisionRouteUsesEffectiveCapabilitiesAndCredentials() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        var preferences = try await fixture.modelStore.preferences()
        preferences.visionModelID = fixture.modelID
        try await fixture.modelStore.savePreferences(preferences)

        let adapter = ScriptedOCRAdapter { _ in [] }
        let routing = NotesOCRRunModelRouting(
            assembly: RunModelAssembly(
                configurationStore: fixture.modelStore,
                credentials: RunCredentialResolver()),
            store: fixture.modelStore,
            credentials: RunCredentialResolver(),
            transportAdmitted: { true },
            adapterFactory: { _ in adapter })

        switch await routing.route() {
        case .resolved(let route):
            XCTAssertEqual(route.model.id, fixture.modelID)
            XCTAssertEqual(route.provider.id, fixture.providerID)
            XCTAssertTrue(route.providerLabel.contains("Fixture"))
            XCTAssertTrue(route.providerLabel.contains("Fixture Model"))
        default:
            XCTFail("the configured auxiliary vision model must resolve")
        }

        // MODEL-LEVEL EXPLICIT CAPABILITY OVERRIDE IS AUTHORITATIVE.
        guard var model = try await fixture.modelStore.model(id: fixture.modelID) else {
            return XCTFail("the fixture model must exist")
        }
        model.explicitCapabilities = [.text]
        try await fixture.modelStore.saveModel(model)
        switch await routing.route() {
        case .notConfigured(let reason):
            XCTAssertEqual(reason, "visionModelMissing")
        case .unsupported(let reason):
            XCTAssertEqual(reason, "visionCapabilityMissing")
        default:
            XCTFail("an explicit text-only override must not use the vision route")
        }

        // Restore the capability and prove a missing preference is typed.
        guard let restored = try await fixture.modelStore.model(id: fixture.modelID) else {
            return XCTFail("the fixture model must still exist")
        }
        model = restored
        // The store's upsert deliberately preserves a previously explicit
        // decision when the incoming value is nil, so restore the exact
        // capability set explicitly instead of relying on nil-clearing.
        model.explicitCapabilities = [.text, .vision]
        try await fixture.modelStore.saveModel(model)
        preferences.visionModelID = nil
        try await fixture.modelStore.savePreferences(preferences)
        switch await routing.route() {
        case .notConfigured(let reason):
            XCTAssertEqual(reason, "visionModelMissing")
        default:
            XCTFail("no configured auxiliary vision model must be typed")
        }

        // A saved route with no registered gateway/secret is typed, never
        // an anonymous request.
        preferences.visionModelID = fixture.modelID
        try await fixture.modelStore.savePreferences(preferences)
        SecretGatewayRegistry.shared.unregister()
        let finalOutcome = await routing.route()
        switch finalOutcome {
        case .credentialUnavailable(let reason):
            XCTAssertEqual(reason, "gatewayUnregistered")
        default:
            XCTFail("a missing credential gateway must be typed, got \(finalOutcome)")
        }
    }

    func testCurrentNativeCacheIsReusedWithoutProviderCall() async throws {
        let note = try await note()
        // Prime the real cache first through the ordinary native action.
        _ = try await OCRTestSupport.call(note.epoch, "document.cachePageOCR", [
            "documentID": note.documentID.uuidString,
            "pageID": note.pageID.uuidString,
            "sourceKey": note.sourceKey,
            "text": "cached text",
            "expectedRevision": note.revision,
        ])
        let recorder = OCRRequestRecorder()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            XCTFail("a current cache must not call the provider")
            return [.completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        let result = try await domain.recognize(stageID: stageID, conversationID: nil)
        XCTAssertEqual(result.state, .cached)
        XCTAssertEqual(result.text, "cached text")
        XCTAssertNil(result.providerLabel)
        XCTAssertEqual(recorder.count(), 0)
    }

    func testStaleRevisionBeforeDispatchMakesNoProviderCallAndWritesNothing() async throws {
        let note = try await note()
        let recorder = OCRRequestRecorder()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            XCTFail("a stale source must not reach the provider")
            return []
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        _ = try await OCRTestSupport.call(note.epoch, "document.apply", [
            "documentID": note.documentID.uuidString,
            "expectedRevision": note.revision,
            "title": "Renamed",
            "requestID": "ocr-stale-" + UUID().uuidString,
            "edits": [[
                "action": "rename",
                "text": "Renamed",
            ]],
        ])
        do {
            _ = try await domain.recognize(stageID: stageID, conversationID: nil)
            XCTFail("a stale stage must not return recognized text")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .stale("revisionMismatch"))
        }
        XCTAssertEqual(recorder.count(), 0)
        let after = try await OCRTestSupport.document(note.epoch, note.documentID)
        XCTAssertNil(after.pages.first?.ocrText)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: note.stagingRoot.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the settled stage file must be removed")
    }

    func testStaleAfterReplyDoesNotWriteCacheOrReturnText() async throws {
        let note = try await note()
        let recorder = OCRRequestRecorder()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            _ = try await OCRTestSupport.call(note.epoch, "document.apply", [
                "documentID": note.documentID.uuidString,
                "expectedRevision": note.revision,
                "title": "Changed while thinking",
                "requestID": "ocr-late-" + UUID().uuidString,
                "edits": [[
                    "action": "rename",
                    "text": "Changed while thinking",
                ]],
            ])
            return [.textDelta(.init(text: "late result")),
                    .completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        do {
            _ = try await domain.recognize(stageID: stageID, conversationID: nil)
            XCTFail("a late result for a newer revision must be stale")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .stale("revisionMismatch"))
        }
        XCTAssertEqual(recorder.count(), 1)
        let after = try await OCRTestSupport.document(note.epoch, note.documentID)
        XCTAssertNil(after.pages.first?.ocrText, "stale text must never label newer content")
    }

    func testNoConfiguredVisionRouteIsTypedAndMakesNoProviderCall() async throws {
        let note = try await note()
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .notConfigured("visionModelMissing")))
        let status = await domain.status()
        XCTAssertEqual(status.availability, .notConfigured)
        XCTAssertEqual(status.reason, "visionModelMissing")
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        do {
            _ = try await domain.recognize(stageID: stageID, conversationID: nil)
            XCTFail("an unconfigured route must not recognize")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .notConfigured("visionModelMissing"))
        }
        let after = try await OCRTestSupport.document(note.epoch, note.documentID)
        XCTAssertNil(after.pages.first?.ocrText)
    }

    func testInvalidStageContentIsRejectedBeforeAnyProviderRequest() async throws {
        let note = try await note()
        let recorder = OCRRequestRecorder()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            XCTFail("invalid image bytes must never be dispatched")
            return []
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))

        // Wrong declared digest.
        let wrongHash = try await OCRTestSupport.stage(
            domain,
            OCRTestSupport.stageInput(note, sha256: String(repeating: "0", count: 64)),
            image: OCRTestSupport.png)
        do {
            _ = try await domain.recognize(stageID: wrongHash, conversationID: nil)
            XCTFail("digest mismatch must be refused")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .invalidPayload("imageHash"))
        }

        // Wrong image signature.
        let junk = Data(repeating: 0x42, count: 64)
        let wrongSignature = try await OCRTestSupport.stage(
            domain,
            OCRTestSupport.stageInput(note, image: junk),
            image: junk)
        do {
            _ = try await domain.recognize(stageID: wrongSignature, conversationID: nil)
            XCTFail("non-PNG bytes must be refused")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .invalidPayload("imageFormat"))
        }

        // Incomplete stage.
        let descriptor = try await domain.beginStage(OCRTestSupport.stageInput(note))
        _ = try await domain.append(stageID: descriptor.stageID, offset: 0,
                                    data: Data(OCRTestSupport.png.prefix(10)))
        do {
            _ = try await domain.recognize(stageID: descriptor.stageID, conversationID: nil)
            XCTFail("an incomplete stage must be refused")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .stageIncomplete)
        }

        // Offset mismatch.
        let offsetStage = try await domain.beginStage(OCRTestSupport.stageInput(note))
        do {
            _ = try await domain.append(stageID: offsetStage.stageID, offset: 1,
                                        data: OCRTestSupport.png)
            XCTFail("an offset mismatch must be refused")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .invalidPayload("stageOffset"))
        }

        XCTAssertEqual(recorder.count(), 0)
    }

    func testImageByteCapIsRefusedBeforeAStageFileExists() async throws {
        let note = try await note()
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .credentialUnavailable("secretMissing")))
        var input = OCRTestSupport.stageInput(note)
        input = NotesOCRStageBegin(
            documentID: input.documentID, pageID: input.pageID,
            sourceKey: input.sourceKey, revision: input.revision,
            pageNumber: input.pageNumber, widthPt: input.widthPt,
            heightPt: input.heightPt,
            byteCount: NotesOCRPolicy.maximumImageBytes + 1,
            sha256: input.sha256, pixelWidth: input.pixelWidth,
            pixelHeight: input.pixelHeight)
        do {
            _ = try await domain.beginStage(input)
            XCTFail("an over-cap image must not create a stage")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .stageTooLarge)
        }
    }
}
