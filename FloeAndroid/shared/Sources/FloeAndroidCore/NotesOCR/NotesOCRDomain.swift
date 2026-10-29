// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes cloud OCR — one epoch-bound domain over the accepted generation.
//
// The domain owns ONLY:
//   * a bounded App-private transient image stage (begin/append/recognize/
//     abort), never a Notes resource import or long-lived CAS entry;
//   * the one configured auxiliary-vision provider request (original
//     ProviderAdapter, original credentials, original owned-work lease);
//   * the exact source-key cache receipt through `NotesDomainService`.
//
// It never creates a NotesStore, a provider client, a model/config store or a
// second run/runtime. Stale epochs cannot read or commit a newer stage, and
// cancellation/root-stop does not report drained until the awaited terminal
// has really settled and the owned-work token is released.
import Foundation
import FloeCore
import FloeModels
import FloeNotes
import FloeProviders

actor NotesOCRDomain {
    static let shared = NotesOCRDomain()

    private struct Binding {
        let epoch: UInt64
        let source: any NotesOCRSourceReading
        let routing: any NotesOCRVisionRouting
        let ownedWork: ConfigOwnedWorkLifecycle
        let stagingRoot: URL
    }

    private struct Stage {
        let id: String
        let epoch: UInt64
        let documentID: UUID
        let pageID: UUID
        let sourceKey: String
        let revision: Int
        let pageNumber: Int
        let widthPt: Double
        let heightPt: Double
        let byteCount: Int
        let expectedSHA256: String
        let pixelWidth: Int
        let pixelHeight: Int
        let url: URL
        var handle: FileHandle?
        var receivedBytes: Int
        let createdAt: Date
    }

    private struct ActiveRecognition {
        let stageID: String
        let task: Task<NotesOCRRecognition, Error>
    }

    private var binding: Binding?
    private var stages: [String: Stage] = [:]
    private var stageOrder: [String] = []
    private var active: [UUID: ActiveRecognition] = [:]
    /// Root-stop admission fence. Set by `prepareForRootStop`, cleared ONLY by
    /// the same-epoch abort/resume. No new OCR starts while fenced.
    private var fenced = false
    private var fencedEpoch: UInt64?
    private var stopGeneration: UInt64 = 0

    private init() {}

    /// Test/qualification seam: bind a fresh domain to the SAME injected
    /// source/routing/lifecycle without the live bootstrap. Production uses
    /// `NotesOCRComposition.attach(epoch:)`.
    init(epoch: UInt64,
         source: any NotesOCRSourceReading,
         routing: any NotesOCRVisionRouting,
         ownedWork: ConfigOwnedWorkLifecycle,
         stagingRoot: URL) throws {
        let standardized = stagingRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized,
                                                withIntermediateDirectories: true)
        Self.removeStagingFiles(standardized)
        self.binding = Binding(epoch: epoch, source: source, routing: routing,
                               ownedWork: ownedWork, stagingRoot: standardized)
    }

    var boundEpoch: UInt64? { binding?.epoch }

    // MARK: - Binding / retirement

    func bind(epoch: UInt64,
              source: any NotesOCRSourceReading,
              routing: any NotesOCRVisionRouting,
              ownedWork: ConfigOwnedWorkLifecycle,
              stagingRoot: URL) async throws {
        if let binding, binding.epoch == epoch { return }
        fenced = true
        await cancelAndWaitAll()
        clearAllStages()
        let standardized = stagingRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized,
                                                withIntermediateDirectories: true)
        Self.removeStagingFiles(standardized)
        binding = Binding(epoch: epoch, source: source, routing: routing,
                          ownedWork: ownedWork, stagingRoot: standardized)
        fenced = false
        fencedEpoch = nil
        stopGeneration &+= 1
    }

    func retire(epoch: UInt64) async {
        guard let binding, binding.epoch == epoch else { return }
        fenced = true
        fencedEpoch = epoch
        await cancelAndWaitAll()
        clearAllStages()
        self.binding = nil
        fenced = false
        fencedEpoch = nil
        stopGeneration &+= 1
    }

    // MARK: - Status

    func status() async -> NotesOCRStatus {
        guard let binding else {
            return NotesOCRStatus(availability: .notConfigured, providerLabel: nil,
                                  modelLabel: nil, reason: "runtimeUnavailable")
        }
        switch await binding.routing.route() {
        case .resolved(let route):
            return NotesOCRStatus(availability: .ready,
                                  providerLabel: route.providerLabel,
                                  modelLabel: route.model.displayName,
                                  reason: nil)
        case .notConfigured(let reason):
            return NotesOCRStatus(availability: .notConfigured, providerLabel: nil,
                                  modelLabel: nil, reason: reason)
        case .unsupported(let reason):
            return NotesOCRStatus(availability: .unsupported, providerLabel: nil,
                                  modelLabel: nil, reason: reason)
        case .credentialUnavailable(let reason):
            return NotesOCRStatus(availability: .notConfigured, providerLabel: nil,
                                  modelLabel: nil, reason: reason)
        case .transportUnavailable:
            return NotesOCRStatus(availability: .unsupported, providerLabel: nil,
                                  modelLabel: nil, reason: "transportUnavailable")
        }
    }

    // MARK: - Stage lifecycle

    func beginStage(_ input: NotesOCRStageBegin) async throws -> NotesOCRStageDescriptor {
        guard !fenced else { throw NotesOCRRefusal.fenced }
        guard let binding else { throw NotesOCRRefusal.notBound }
        guard input.revision >= 0 else {
            throw NotesOCRRefusal.invalidPayload("invalidRevision")
        }
        guard (1...NotesOCRPolicy.maximumPageNumber).contains(input.pageNumber) else {
            throw NotesOCRRefusal.invalidPayload("invalidPageNumber")
        }
        guard input.widthPt.isFinite, input.heightPt.isFinite,
              input.widthPt > 0, input.heightPt > 0,
              input.widthPt <= 16_384, input.heightPt <= 16_384 else {
            throw NotesOCRRefusal.invalidPayload("invalidPageSize")
        }
        guard input.byteCount > 0,
              input.byteCount <= NotesOCRPolicy.maximumImageBytes else {
            throw NotesOCRRefusal.stageTooLarge
        }
        guard input.pixelWidth > 0, input.pixelHeight > 0,
              input.pixelWidth <= NotesOCRPolicy.maximumDimension,
              input.pixelHeight <= NotesOCRPolicy.maximumDimension,
              input.pixelWidth * input.pixelHeight <= NotesOCRPolicy.maximumPixelCount else {
            throw NotesOCRRefusal.invalidPayload("invalidPixelSize")
        }
        guard !input.sourceKey.isEmpty,
              input.sourceKey.utf8.count <= NotesOCRPolicy.maximumSourceKeyBytes,
              !input.sourceKey.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw NotesOCRRefusal.invalidPayload("invalidSourceKey")
        }
        guard NotesOCRImage.isHexDigest(input.sha256) else {
            throw NotesOCRRefusal.invalidPayload("invalidSHA256")
        }
        let sourceKey = input.sourceKey.lowercased()
        let digest = input.sha256.lowercased()

        pruneExpiredStages()
        guard stages.count < NotesOCRPolicy.maximumStages else {
            throw NotesOCRRefusal.busy("stageLimit")
        }

        // Re-read the REAL current document/page before a byte is accepted.
        let snapshot = try await binding.source.pageSnapshot(
            documentID: input.documentID, pageID: input.pageID)
        try Self.verify(snapshot: snapshot, documentID: input.documentID,
                        pageID: input.pageID, sourceKey: sourceKey,
                        revision: input.revision)

        let stageID = UUID().uuidString
        let url = binding.stagingRoot.appendingPathComponent(".ocr-\(stageID).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NotesOCRRefusal.storageUnavailable
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            stages[stageID] = Stage(
                id: stageID, epoch: binding.epoch,
                documentID: input.documentID, pageID: input.pageID,
                sourceKey: sourceKey, revision: snapshot.revision,
                pageNumber: input.pageNumber,
                widthPt: input.widthPt, heightPt: input.heightPt,
                byteCount: input.byteCount, expectedSHA256: digest,
                pixelWidth: input.pixelWidth, pixelHeight: input.pixelHeight,
                url: url, handle: handle, receivedBytes: 0,
                createdAt: Date())
            stageOrder.append(stageID)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw NotesOCRRefusal.storageUnavailable
        }
        return NotesOCRStageDescriptor(
            stageID: stageID,
            chunkBytes: NotesOCRPolicy.maximumChunkBytes,
            totalBytes: input.byteCount,
            maxStages: NotesOCRPolicy.maximumStages,
            expiresInSeconds: Int(NotesOCRPolicy.stageLifetime))
    }

    func append(stageID: String, offset: Int, data: Data) async throws -> Int {
        guard !fenced else { throw NotesOCRRefusal.fenced }
        guard !stageID.isEmpty, stageID.utf8.count <= 128 else {
            throw NotesOCRRefusal.invalidPayload("invalidStageID")
        }
        guard var stage = stages[stageID], stage.handle != nil else {
            throw NotesOCRRefusal.stageNotFound
        }
        guard stage.receivedBytes == offset else {
            throw NotesOCRRefusal.invalidPayload("stageOffset")
        }
        guard !data.isEmpty, data.count <= NotesOCRPolicy.maximumChunkBytes else {
            throw NotesOCRRefusal.invalidPayload("chunkSize")
        }
        guard stage.receivedBytes + data.count <= stage.byteCount else {
            throw NotesOCRRefusal.stageTooLarge
        }
        do {
            try stage.handle?.write(contentsOf: data)
        } catch {
            removeStage(stageID)
            throw NotesOCRRefusal.storageUnavailable
        }
        stage.receivedBytes += data.count
        stages[stageID] = stage
        return stage.receivedBytes
    }

    func abort(stageID: String) async {
        guard stages[stageID] != nil else { return }
        let matches = active.filter { $0.value.stageID == stageID }
        for (_, entry) in matches { entry.task.cancel() }
        removeStage(stageID)
    }

    func cancelActive(stageID: String?) async -> Int {
        var count = 0
        for (_, entry) in active where stageID == nil || entry.stageID == stageID {
            entry.task.cancel()
            count += 1
        }
        return count
    }

    // MARK: - Recognise

    func recognize(stageID: String, conversationID: UUID?) async throws
        -> NotesOCRRecognition {
        guard !fenced else { throw NotesOCRRefusal.fenced }
        guard let stage = stages[stageID] else { throw NotesOCRRefusal.stageNotFound }
        guard stage.receivedBytes == stage.byteCount else {
            throw NotesOCRRefusal.stageIncomplete
        }
        let workID = UUID()
        let task = Task<NotesOCRRecognition, Error> { [self] in
            defer { self.finishActive(workID) }
            return try await self.performRecognition(stageID: stageID,
                                                     conversationID: conversationID)
        }
        active[workID] = ActiveRecognition(stageID: stageID, task: task)
        return try await task.value
    }

    private func performRecognition(stageID: String,
                                    conversationID: UUID?) async throws
        -> NotesOCRRecognition {
        guard let binding, !fenced else { throw NotesOCRRefusal.fenced }
        guard let stage = stages[stageID] else { throw NotesOCRRefusal.stageNotFound }
        defer { removeStage(stageID) }

        // The page image is validated completely BEFORE any provider route
        // is resolved or any byte leaves the device.
        let image = try readStageBytes(stage)
        guard !Task.isCancelled else { throw NotesOCRRefusal.cancelled }

        let before = try await binding.source.pageSnapshot(
            documentID: stage.documentID, pageID: stage.pageID)
        try Self.verify(snapshot: before, documentID: stage.documentID,
                        pageID: stage.pageID, sourceKey: stage.sourceKey,
                        revision: stage.revision)
        if before.current, let text = before.cachedText {
            let receipt = NoteIndexCacheReceipt(
                status: .unchanged,
                documentID: stage.documentID,
                documentRevision: before.revision,
                sourceKey: stage.sourceKey,
                currentKey: before.visualIndexKey,
                storedKey: before.visualIndexKey,
                indexed: true,
                textLength: text.count,
                error: nil,
                retryable: false,
                reason: nil)
            return NotesOCRRecognition(
                state: .cached, text: text, providerLabel: nil,
                sourceKey: stage.sourceKey, documentID: stage.documentID,
                pageID: stage.pageID, documentRevision: before.revision,
                cache: receipt)
        }

        let route = try await resolveRoute(binding)
        guard !fenced, !Task.isCancelled, stages[stageID] != nil else {
            throw Task.isCancelled ? NotesOCRRefusal.cancelled : NotesOCRRefusal.fenced
        }

        let lease: ConfigOwnedWorkLease
        switch binding.ownedWork.begin(kind: .tool,
                                       ownerID: "notes-ocr:" + stage.id) {
        case .success(let value):
            lease = value
        case .failure(.noAdmittedEpoch):
            throw NotesOCRRefusal.notConfigured("ownedWorkEpoch")
        case .failure(.invalidOwnerIdentity):
            throw NotesOCRRefusal.unsupported("ownedWorkIdentity")
        case .failure(.rejected(let code)):
            throw NotesOCRRefusal.busy("ownedWorkRejected:" + code)
        }
        defer { binding.ownedWork.settle(lease) }

        let text: String
        do {
            text = try await streamRecognition(image: image, stage: stage,
                                                route: route)
        } catch let refusal as NotesOCRRefusal {
            if case .providerFailure(let reason) = refusal {
                await cacheProviderError(reason: reason, stage: stage,
                                         binding: binding,
                                         conversationID: conversationID)
            }
            throw refusal
        } catch is CancellationError {
            throw NotesOCRRefusal.cancelled
        }

        guard !Task.isCancelled else { throw NotesOCRRefusal.cancelled }
        guard text.utf8.count <= NotesOCRPolicy.maximumOutputBytes else {
            throw NotesOCRRefusal.providerFailure("outputTooLarge")
        }

        // Recheck the EXACT revision/source identity at the cache boundary.
        let after = try await binding.source.pageSnapshot(
            documentID: stage.documentID, pageID: stage.pageID)
        try Self.verify(snapshot: after, documentID: stage.documentID,
                        pageID: stage.pageID, sourceKey: stage.sourceKey,
                        revision: stage.revision)
        let receipt: NoteIndexCacheReceipt
        do {
            receipt = try await binding.source.cachePageOCR(
                documentID: stage.documentID, pageID: stage.pageID,
                sourceKey: stage.sourceKey, text: text, error: nil,
                expectedRevision: stage.revision, conversationID: conversationID)
        } catch let refusal as NotesOCRRefusal {
            throw refusal
        }
        switch receipt.status {
        case .applied, .unchanged:
            return NotesOCRRecognition(
                state: .recognized, text: text,
                providerLabel: route.providerLabel,
                sourceKey: stage.sourceKey, documentID: stage.documentID,
                pageID: stage.pageID, documentRevision: receipt.documentRevision,
                cache: receipt)
        case .stale:
            throw NotesOCRRefusal.stale(receipt.reason ?? "cacheSourceChanged")
        case .failed:
            throw NotesOCRRefusal.sourceUnavailable(receipt.reason ?? "cacheFailed")
        }
    }

    private func streamRecognition(image: Data, stage: Stage,
                                   route: NotesOCRVisionRoute) async throws -> String {
        let request = ProviderStreamRequest(
            provider: route.provider,
            model: route.model,
            contentMessages: [
                ProviderMessage(role: "system", content: [.text(NotesOCRPrompt.system)]),
                ProviderMessage(role: "user", content: [
                    .text(NotesOCRPrompt.user(pageNumber: stage.pageNumber,
                                              widthPt: stage.widthPt,
                                              heightPt: stage.heightPt)),
                    .imageData(mimeType: "image/png",
                               base64: image.base64EncodedString()),
                ]),
            ],
            toolSchemas: [],
            reasoningPolicy: .disabled)
        var output = ""
        for try await event in route.adapter.stream(request: request,
                                                    credentials: route.credentials) {
            if Task.isCancelled { throw CancellationError() }
            switch event {
            case .textDelta(let delta):
                guard output.utf8.count + delta.text.utf8.count
                    <= NotesOCRPolicy.maximumOutputBytes else {
                    throw NotesOCRRefusal.providerFailure("outputTooLarge")
                }
                output += delta.text
            case .error(let error):
                if error.kind == .cancelled {
                    throw CancellationError()
                }
                throw NotesOCRRefusal.providerFailure(
                    Self.providerFailureReason(error.kind))
            case .completed:
                break
            default:
                break
            }
        }
        if Task.isCancelled { throw CancellationError() }
        return output
    }

    private func resolveRoute(_ binding: Binding) async throws -> NotesOCRVisionRoute {
        switch await binding.routing.route() {
        case .resolved(let route):
            return route
        case .notConfigured(let reason):
            throw NotesOCRRefusal.notConfigured(reason)
        case .unsupported(let reason):
            throw NotesOCRRefusal.unsupported(reason)
        case .credentialUnavailable(let reason):
            throw NotesOCRRefusal.credentialUnavailable(reason)
        case .transportUnavailable:
            throw NotesOCRRefusal.transportUnavailable
        }
    }

    private func cacheProviderError(reason: String, stage: Stage,
                                    binding: Binding,
                                    conversationID: UUID?) async {
        guard !Task.isCancelled, !fenced else { return }
        guard let current = try? await binding.source.pageSnapshot(
            documentID: stage.documentID, pageID: stage.pageID) else { return }
        guard current.documentID == stage.documentID,
              current.pageID == stage.pageID,
              current.revision == stage.revision,
              current.visualIndexKey == stage.sourceKey else { return }
        _ = try? await binding.source.cachePageOCR(
            documentID: stage.documentID, pageID: stage.pageID,
            sourceKey: stage.sourceKey, text: nil, error: reason,
            expectedRevision: stage.revision, conversationID: conversationID)
    }

    // MARK: - Drain / root stop

    func drain(epoch: UInt64) async throws -> NotesOCRDrainReport {
        guard let binding, binding.epoch == epoch else { throw NotesOCRRefusal.notBound }
        while !active.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        clearAllStages()
        return NotesOCRDrainReport(epoch: epoch, drained: true, pendingCount: 0,
                                   retainedStageCount: 0)
    }

    func prepareForRootStop(epoch: UInt64, deadlineMillis: Int = 10_000) async
        -> NotesOCRStopReport {
        guard let binding, binding.epoch == epoch else {
            return NotesOCRStopReport(epoch: epoch, cancelRequestedCount: 0,
                                      pendingCount: 0, canRetire: true,
                                      retainedStageCount: stages.count)
        }
        fenced = true
        fencedEpoch = epoch
        stopGeneration &+= 1
        let tasks = Array(active.values)
        for entry in tasks { entry.task.cancel() }
        let deadline = Date().addingTimeInterval(
            Double(max(0, deadlineMillis)) / 1_000)
        while !active.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = active.count
        if pending == 0 {
            clearAllStages()
        }
        return NotesOCRStopReport(
            epoch: epoch,
            cancelRequestedCount: tasks.count,
            pendingCount: pending,
            canRetire: pending == 0,
            retainedStageCount: stages.count)
    }

    func abortRootStop(epoch: UInt64) {
        guard fencedEpoch == epoch else { return }
        fenced = false
        fencedEpoch = nil
        stopGeneration &+= 1
    }

    func resumeAfterRootChange(epoch: UInt64) async throws {
        guard let binding, binding.epoch == epoch else {
            throw NotesOCRRefusal.notBound
        }
        fenced = false
        fencedEpoch = nil
    }

    // MARK: - Stage file helpers

    private func readStageBytes(_ stage: Stage) throws -> Data {
        guard stage.receivedBytes == stage.byteCount else {
            throw NotesOCRRefusal.stageIncomplete
        }
        do {
            try stage.handle?.synchronize()
            try stage.handle?.close()
        } catch {
            throw NotesOCRRefusal.storageUnavailable
        }
        let data: Data
        do {
            data = try Data(contentsOf: stage.url)
        } catch {
            throw NotesOCRRefusal.sourceUnavailable("stageRead")
        }
        guard data.count == stage.byteCount else {
            throw NotesOCRRefusal.stageIncomplete
        }
        guard NotesOCRImage.sha256Hex(data).lowercased()
                == stage.expectedSHA256.lowercased() else {
            throw NotesOCRRefusal.invalidPayload("imageHash")
        }
        guard let dimensions = NotesOCRImage.pngDimensions(data),
              dimensions.width == stage.pixelWidth,
              dimensions.height == stage.pixelHeight else {
            throw NotesOCRRefusal.invalidPayload("imageFormat")
        }
        return data
    }

    private func pruneExpiredStages() {
        let cutoff = Date().addingTimeInterval(-NotesOCRPolicy.stageLifetime)
        let expired = stages.compactMap { id, stage in
            stage.createdAt < cutoff ? id : nil
        }
        for id in expired { removeStage(id) }
    }

    private func removeStage(_ stageID: String) {
        guard let stage = stages.removeValue(forKey: stageID) else { return }
        stageOrder.removeAll { $0 == stageID }
        try? stage.handle?.close()
        try? FileManager.default.removeItem(at: stage.url)
    }

    private func clearAllStages() {
        for id in Array(stages.keys) { removeStage(id) }
        stages.removeAll()
        stageOrder.removeAll()
    }

    private func cancelAndWaitAll() async {
        let tasks = Array(active.values)
        for entry in tasks { entry.task.cancel() }
        while !active.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func finishActive(_ workID: UUID) {
        active.removeValue(forKey: workID)
    }

    private static func removeStagingFiles(_ root: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        // The staging files are intentionally dot-prefixed (`.ocr-*.part`);
        // do NOT use `.skipsHiddenFiles` here or stale stages never clean up.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: []) else { return }
        for entry in entries.prefix(64) {
            guard entry.lastPathComponent.hasPrefix(".ocr-"),
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func verify(snapshot: NotesOCRPageSnapshot,
                               documentID: UUID, pageID: UUID,
                               sourceKey: String, revision: Int) throws {
        guard snapshot.documentID == documentID, snapshot.pageID == pageID else {
            throw NotesOCRRefusal.sourceUnavailable("pageChanged")
        }
        guard snapshot.revision == revision else {
            throw NotesOCRRefusal.stale("revisionMismatch")
        }
        guard snapshot.visualIndexKey.lowercased() == sourceKey.lowercased() else {
            throw NotesOCRRefusal.stale("sourceChanged")
        }
    }

    private static func providerFailureReason(
        _ kind: AgentEvent.NormalizedError.Kind) -> String {
        switch kind {
        case .rateLimited: return "rateLimited"
        case .auth: return "auth"
        case .contextOverflow: return "contextOverflow"
        case .network: return "network"
        case .malformed: return "malformed"
        case .malformedToolArguments: return "malformedToolArguments"
        case .server: return "server"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: - BridgeV4 action surface

    func handle(epoch: UInt64, requestID: String, action: String,
                payload: NotesJSONValue?) async throws -> Data {
        guard NotesOCRActions.handles(action) else {
            throw NotesDomainError.unsupportedAction(
                NotesWire.bounded(action, limit: 80))
        }
        do {
            if binding?.epoch != epoch {
                if action == NotesOCRActions.status {
                    let attached = await NotesOCRComposition.attach(epoch: epoch)
                    if !attached {
                        return statusData(NotesOCRStatus(
                            availability: .notConfigured, providerLabel: nil,
                            modelLabel: nil, reason: "runtimeUnavailable"))
                    }
                } else if NotesOCRActions.isLifecycle(action) {
                    if action == NotesOCRActions.abortRootStop {
                        return success(["epoch": Int(epoch), "aborted": true])
                    }
                    if action == NotesOCRActions.drain {
                        return success(["epoch": Int(epoch), "drained": true,
                                        "pendingCount": 0,
                                        "retainedStageCount": 0])
                    }
                    if action == NotesOCRActions.prepareRootStop {
                        return success(["epoch": Int(epoch),
                                        "cancelRequestedCount": 0,
                                        "pendingCount": 0,
                                        "canRetire": true,
                                        "retainedStageCount": 0])
                    }
                    if action == NotesOCRActions.resumeAfterRootChange {
                        let attached = await NotesOCRComposition.attach(epoch: epoch)
                        guard attached else {
                            throw NotesOCRRefusal.notBound
                        }
                    }
                } else {
                    let attached = await NotesOCRComposition.attach(epoch: epoch)
                    guard attached else {
                        throw NotesOCRRefusal.notConfigured("runtimeUnavailable")
                    }
                }
            }
            guard binding?.epoch == epoch else {
                throw NotesOCRRefusal.notBound
            }
            switch action {
            case NotesOCRActions.status:
                return statusData(await status())
            case NotesOCRActions.stageBegin:
                let payload = try NotesPayload(payload)
                let input = NotesOCRStageBegin(
                    documentID: try payload.uuid("documentID"),
                    pageID: try payload.uuid("pageID"),
                    sourceKey: try payload.string("sourceKey"),
                    revision: try payload.int("revision"),
                    pageNumber: try payload.int("pageNumber"),
                    widthPt: try payload.double("widthPt"),
                    heightPt: try payload.double("heightPt"),
                    byteCount: try payload.int("byteCount"),
                    sha256: try payload.string("sha256"),
                    pixelWidth: try payload.int("pixelWidth"),
                    pixelHeight: try payload.int("pixelHeight"))
                let descriptor = try await beginStage(input)
                return success([
                    "stageID": descriptor.stageID,
                    "chunkBytes": descriptor.chunkBytes,
                    "totalBytes": descriptor.totalBytes,
                    "maxStages": descriptor.maxStages,
                    "expiresInSeconds": descriptor.expiresInSeconds,
                ])
            case NotesOCRActions.stageAppend:
                let payload = try NotesPayload(payload)
                let stageID = try payload.string("stageID")
                let offset = try payload.int("offset")
                let encoded = try payload.string("dataBase64")
                guard let data = NotesOCRImage.decodeBase64(encoded) else {
                    throw NotesOCRRefusal.invalidPayload("chunkBase64")
                }
                let received = try await append(stageID: stageID, offset: offset,
                                                data: data)
                return success(["stageID": stageID, "receivedBytes": received])
            case NotesOCRActions.recognize:
                let payload = try NotesPayload(payload)
                let stageID = try payload.string("stageID")
                let conversationID = try payload.uuidOrNil("conversationID")
                let result = try await recognize(stageID: stageID,
                                                 conversationID: conversationID)
                return try recognitionData(result)
            case NotesOCRActions.stageAbort:
                let payload = try NotesPayload(payload)
                let stageID = try payload.string("stageID")
                await abort(stageID: stageID)
                return success(["stageID": stageID, "aborted": true])
            case NotesOCRActions.cancel:
                let payload = try NotesPayload(payload)
                let stageID = try payload.stringOrNil("stageID")
                let count = await cancelActive(stageID: stageID)
                return success(["cancelRequested": true, "activeCount": count])
            case NotesOCRActions.drain:
                let payload = try NotesPayload(payload)
                let requested = try payload.intOrNil("epoch").map { UInt64(max(0, $0)) }
                let report = try await drain(epoch: requested ?? epoch)
                return success([
                    "epoch": Int(report.epoch), "drained": report.drained,
                    "pendingCount": report.pendingCount,
                    "retainedStageCount": report.retainedStageCount,
                ])
            case NotesOCRActions.prepareRootStop:
                let payload = try NotesPayload(payload)
                let deadline = try payload.intOrNil("deadlineMillis") ?? 10_000
                let report = await prepareForRootStop(
                    epoch: epoch, deadlineMillis: deadline)
                return success([
                    "epoch": Int(report.epoch),
                    "cancelRequestedCount": report.cancelRequestedCount,
                    "pendingCount": report.pendingCount,
                    "canRetire": report.canRetire,
                    "retainedStageCount": report.retainedStageCount,
                ])
            case NotesOCRActions.abortRootStop:
                abortRootStop(epoch: epoch)
                return success(["epoch": Int(epoch), "aborted": true])
            case NotesOCRActions.resumeAfterRootChange:
                try await resumeAfterRootChange(epoch: epoch)
                return success(["epoch": Int(epoch), "resumed": true])
            default:
                throw NotesOCRRefusal.invalidPayload("unknownAction")
            }
        } catch let refusal as NotesOCRRefusal {
            let wire = refusal.wire
            return NotesWire.errorData(code: wire.code, reason: wire.reason,
                                       retryable: wire.retryable)
        } catch let error as NotesDomainError {
            let mapped = NotesWire.mappedError(error)
            return NotesWire.errorData(code: mapped.code, reason: mapped.reason,
                                       retryable: mapped.retryable)
        } catch let error as NoteError {
            let mapped = NotesWire.mappedError(error)
            return NotesWire.errorData(code: mapped.code, reason: mapped.reason,
                                       retryable: mapped.retryable)
        } catch is CancellationError {
            return NotesWire.errorData(code: "ocrCancelled", reason: nil,
                                       retryable: true)
        } catch {
            return NotesWire.errorData(code: "ocrInternal", reason: nil,
                                       retryable: false)
        }
    }

    private func statusData(_ status: NotesOCRStatus) -> Data {
        var fields: [String: Any] = ["availability": status.availability.rawValue]
        if let providerLabel = status.providerLabel {
            fields["providerLabel"] = providerLabel
        }
        if let modelLabel = status.modelLabel { fields["modelLabel"] = modelLabel }
        if let reason = status.reason { fields["reason"] = reason }
        return success(fields)
    }

    private func recognitionData(_ result: NotesOCRRecognition) throws -> Data {
        var value: [String: Any] = [
            "state": result.state.rawValue,
            "text": result.text,
            "sourceKey": result.sourceKey,
            "documentID": result.documentID.uuidString,
            "pageID": result.pageID.uuidString,
            "documentRevision": result.documentRevision,
        ]
        if let providerLabel = result.providerLabel {
            value["providerLabel"] = providerLabel
        }
        let cacheData = try NotesWire.encode(result.cache)
        if let cache = try JSONSerialization.jsonObject(with: cacheData)
            as? [String: Any] {
            value["cache"] = cache
        }
        return success(["result": value])
    }

    private func success(_ fields: [String: Any]) -> Data {
        var object = fields
        object["ok"] = true
        return NotesWire.data(from: object)
    }
}
