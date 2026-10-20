// FloeAppTests — S3.1 durable Shortcuts draft inbox: FIFO composer handoff,
// human-content protection, claim/ack crash recovery, legacy migration.
//
// Delivery identity is the entry-bound durable handoff receipt — (destination,
// inbox entry id, claim token) — serialized in the SAME snapshot as the placed
// text and verified ON DISK, and the receipt is staged only in the synchronous
// turn in which the composer ACCEPTS the draft (render-before-persist): a
// disk-verified receipt can only ever prove a placement that visibly reached
// the composer, so no crash window can acknowledge an entry the user never
// saw, and no late callback can overwrite newer human work. The critical
// interleavings below pin: identical payloads stay distinct, human prose that
// contains the draft phrase never settles anything, slow durable commits never
// let a late callback overwrite typed text/staged attachments/sends
// (A → B → A included), a failed write rolls its own (already rolled-back)
// placement back leaving the slot retryable, failed commit + failed release
// keeps the claim recoverable on restart without any false ack, human-edit
// then crash-before-ack settles only the visibly accepted entry, clear/send
// after delivery keeps unsettled evidence, crash-after-write-before-ack
// settles idempotently from disk bytes, and failed-write + restart preserves
// every entry with full recovery once the disk works again.
//
// The consumer under test is the ACTUAL launched App: the view model runs
// against `AppEnvironment.qualificationLaunchEnvironment.conversationCenter`
// (the real process service graph, never a second environment and never a
// bootstrapped preview). Every mutable input is still ISOLATED: the durable
// inbox owns a private in-memory database, the draft file lives under a
// private temp directory, and the legacy suite is a throwaway UserDefaults
// domain. Nothing touches real app defaults, the real Home draft slot, the
// launched database or the live composer.

#if canImport(UIKit) && DEBUG
import AppIntents
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.ShortcutInboxHandoff", .serialized)
@MainActor
struct ShortcutInboxHandoffTests {

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let center: ConversationCenter
        let inbox: SQLiteShortcutDraftInboxStore
        let drafts: ComposerDraftStore
        let legacySuite: UserDefaults
        let legacySuiteName: String
        let draftFile: URL
        /// Keeps the isolated inbox database alive for the fixture's lifetime.
        private let inboxDatabase: DatabaseManager
        private let rootDirectory: URL

        init() async throws {
            // Actual launched center: the same ConversationCenter the visible
            // app uses. It is only read for the init dependency; no send,
            // provider or model work runs in this suite.
            let launchEnvironment = try await appQualificationEnvironment()
            center = launchEnvironment.conversationCenter
            // Isolated FIFO queue: private in-memory schema (never the
            // launched database).
            let isolatedDatabase = try DatabaseManager.inMemory()
            try await isolatedDatabase.migrate()
            inboxDatabase = isolatedDatabase
            inbox = SQLiteShortcutDraftInboxStore(database: isolatedDatabase)
            rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-s3-inbox-\(UUID().uuidString)", isDirectory: true)
            draftFile = rootDirectory.appendingPathComponent("drafts.json")
            drafts = ComposerDraftStore(fileURL: draftFile)
            let suiteName = "floe-test-legacy-\(UUID().uuidString)"
            legacySuiteName = suiteName
            legacySuite = UserDefaults(suiteName: suiteName)!
        }

        func makeVM(
            enabled: Bool = true,
            accepts: Bool = true,
            inbox overrideStore: (any ShortcutDraftInboxStore)? = nil,
            draftStore overrideDrafts: ComposerDraftStore? = nil,
            shortcutCommit: HomeLaunchpadViewModel.ShortcutDurableCommit? = nil
        ) -> HomeLaunchpadViewModel {
            HomeLaunchpadViewModel(
                center: center,
                acceptsShortcutInbox: accepts,
                shortcutInbox: overrideStore ?? (inbox as any ShortcutDraftInboxStore),
                draftStore: overrideDrafts ?? drafts,
                isShortcutInboxEnabled: { enabled },
                shortcutLegacyDefaults: legacySuite,
                shortcutCommitDurable: shortcutCommit
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootDirectory)
            legacySuite.removePersistentDomain(forName: legacySuiteName)
        }
    }

    /// One-way rendezvous used to interleave a human edit INSIDE the real
    /// durable-commit suspension deterministically — no sleeps: the test
    /// wakes exactly when the commit was requested (the placement job is
    /// enqueued first, so its synchronous CAS/submit has already run when
    /// the woken test body executes), and releases the gated write queue
    /// only after the human action has landed.
    @MainActor
    private final class CommitRendezvous {
        private var startedWaiter: CheckedContinuation<Void, Never>?

        func awaitCommitStarted() async {
            await withCheckedContinuation { startedWaiter = $0 }
        }
        func commitStarted() {
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    /// MainActor box carrying the receipt the injected commit closure saw.
    @MainActor
    private final class ReceiptBox {
        var value: ComposerDraftStore.ShortcutHandoffReceipt?
    }

    /// Wraps the real store and widens the post-claim await window so a
    /// human edit can land between claim and re-check deterministically.

    /// Wraps the real store and widens the post-claim await window so a
    /// human edit can land between claim and re-check deterministically.
    private actor DelayingInbox: ShortcutDraftInboxStore {
        private let base: SQLiteShortcutDraftInboxStore
        private let enqueueDelay: Duration?
        init(base: SQLiteShortcutDraftInboxStore, enqueueDelay: Duration? = nil) {
            self.base = base
            self.enqueueDelay = enqueueDelay
        }

        @discardableResult
        func enqueue(
            text: String, source: ShortcutDraftInboxSource, migrationKey: String?
        ) async throws -> ShortcutDraftInboxEntry {
            if let enqueueDelay { try? await Task.sleep(for: enqueueDelay) }
            return try await base.enqueue(text: text, source: source, migrationKey: migrationKey)
        }
        func pendingCount() async throws -> Int { try await base.pendingCount() }
        func pendingEntries(limit: Int) async throws -> [ShortcutDraftInboxEntry] {
            try await base.pendingEntries(limit: limit)
        }
        func entry(id: UUID) async throws -> ShortcutDraftInboxEntry? {
            try await base.entry(id: id)
        }
        func claimNext(
            destinationID: String, at date: Date, epoch: String
        ) async throws -> ShortcutDraftInboxEntry? {
            let claim = try await base.claimNext(destinationID: destinationID, at: date, epoch: epoch)
            try? await Task.sleep(for: .milliseconds(60))
            return claim
        }
        func claims(destinationID: String, epoch: String) async throws -> [ShortcutDraftInboxEntry] {
            try await base.claims(destinationID: destinationID, epoch: epoch)
        }
        func abandonedClaims(currentEpoch: String) async throws -> [ShortcutDraftInboxEntry] {
            try await base.abandonedClaims(currentEpoch: currentEpoch)
        }
        @discardableResult
        func ack(id: UUID, claimToken: String) async throws -> Bool {
            try await base.ack(id: id, claimToken: claimToken)
        }
        @discardableResult
        func release(id: UUID, claimToken: String) async throws -> Bool {
            try await base.release(id: id, claimToken: claimToken)
        }
    }

    /// The injected faults raised by `FaultyInbox` while the faults are on.
    private struct HandoffAckFault: Error {}
    private struct HandoffReleaseFault: Error {}

    /// Wraps the real store with an injectable ack fault so the
    /// crash-after-durable-write-before-ack window can be produced and
    /// later settled for real, with the receipt as the only bridge.
    private actor FaultyInbox: ShortcutDraftInboxStore {
        private let base: SQLiteShortcutDraftInboxStore
        private var ackFault = false
        private var releaseFault = false
        init(base: SQLiteShortcutDraftInboxStore) { self.base = base }

        func setAckFault(_ value: Bool) { ackFault = value }
        func setReleaseFault(_ value: Bool) { releaseFault = value }

        @discardableResult
        func enqueue(
            text: String, source: ShortcutDraftInboxSource, migrationKey: String?
        ) async throws -> ShortcutDraftInboxEntry {
            try await base.enqueue(text: text, source: source, migrationKey: migrationKey)
        }
        func pendingCount() async throws -> Int { try await base.pendingCount() }
        func pendingEntries(limit: Int) async throws -> [ShortcutDraftInboxEntry] {
            try await base.pendingEntries(limit: limit)
        }
        func entry(id: UUID) async throws -> ShortcutDraftInboxEntry? {
            try await base.entry(id: id)
        }
        func claimNext(
            destinationID: String, at date: Date, epoch: String
        ) async throws -> ShortcutDraftInboxEntry? {
            try await base.claimNext(destinationID: destinationID, at: date, epoch: epoch)
        }
        func claims(destinationID: String, epoch: String) async throws -> [ShortcutDraftInboxEntry] {
            try await base.claims(destinationID: destinationID, epoch: epoch)
        }
        func abandonedClaims(currentEpoch: String) async throws -> [ShortcutDraftInboxEntry] {
            try await base.abandonedClaims(currentEpoch: currentEpoch)
        }
        @discardableResult
        func ack(id: UUID, claimToken: String) async throws -> Bool {
            if ackFault { throw HandoffAckFault() }
            return try await base.ack(id: id, claimToken: claimToken)
        }
        @discardableResult
        func release(id: UUID, claimToken: String) async throws -> Bool {
            if releaseFault { throw HandoffReleaseFault() }
            return try await base.release(id: id, claimToken: claimToken)
        }
    }

    // MARK: - Actual Intent producer (real perform → runtime → isolated queue)

    /// Task-scoped persistence for the ACTUAL legacy intents: an isolated
    /// in-memory inbox, throwaway legacy defaults and a private notification
    /// center. The app-owned inbox, App Group defaults, real Home draft and
    /// default NotificationCenter are never touched.
    @MainActor
    private final class DebugProducerScope {
        let inbox: SQLiteShortcutDraftInboxStore
        let notifications = NotificationCenter()
        let defaults: UserDefaults
        private let defaultsName: String
        private let database: DatabaseManager

        init() async throws {
            let isolatedDatabase = try DatabaseManager.inMemory()
            try await isolatedDatabase.migrate()
            database = isolatedDatabase
            inbox = SQLiteShortcutDraftInboxStore(database: isolatedDatabase)
            let suiteName = "floe-test-intent-\(UUID().uuidString)"
            defaultsName = suiteName
            defaults = UserDefaults(suiteName: suiteName)!
        }

        /// The caller wraps its ACTUAL `perform()` sequence in
        /// `$debugDraftEnqueueContext.withValue`; nothing is installed
        /// process-globally, so an unrelated concurrent intent can never be
        /// routed into this fixture.
        func context(store: (any ShortcutDraftInboxStore)? = nil) -> FloeDraftEnqueueDebugContext {
            FloeDraftEnqueueDebugContext(
                inbox: store ?? inbox,
                legacyDefaults: defaults,
                notifications: notifications,
                shortcutsEnabled: { true }
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    /// Thread-safe count of posted notifications.
    private final class NotificationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Isolated store whose enqueue always fails: proves the actual intent
    /// surfaces an honest failure instead of reporting success.
    private actor ThrowingEnqueueInbox: ShortcutDraftInboxStore {
        struct EnqueueFault: Error {}

        @discardableResult
        func enqueue(
            text: String, source: ShortcutDraftInboxSource, migrationKey: String?
        ) async throws -> ShortcutDraftInboxEntry {
            throw EnqueueFault()
        }
        func pendingCount() async throws -> Int { throw EnqueueFault() }
        func pendingEntries(limit: Int) async throws -> [ShortcutDraftInboxEntry] {
            throw EnqueueFault()
        }
        func entry(id: UUID) async throws -> ShortcutDraftInboxEntry? { throw EnqueueFault() }
        func claimNext(
            destinationID: String, at date: Date, epoch: String
        ) async throws -> ShortcutDraftInboxEntry? { throw EnqueueFault() }
        func claims(destinationID: String, epoch: String) async throws -> [ShortcutDraftInboxEntry] {
            throw EnqueueFault()
        }
        func abandonedClaims(currentEpoch: String) async throws -> [ShortcutDraftInboxEntry] {
            throw EnqueueFault()
        }
        @discardableResult
        func ack(id: UUID, claimToken: String) async throws -> Bool { throw EnqueueFault() }
        @discardableResult
        func release(id: UUID, claimToken: String) async throws -> Bool { throw EnqueueFault() }
    }

    @Test("Actual draft intents append repeated distinct and identical payloads")
    func actualIntentProducerAppendsRepeatedDrafts() async throws {
        let scope = try await DebugProducerScope()
        defer { scope.cleanup() }
        let privatePosts = NotificationCounter()
        let defaultPosts = NotificationCounter()
        let privateToken = scope.notifications.addObserver(
            forName: FloeShortcutInbox.didEnqueue, object: nil, queue: nil
        ) { _ in privatePosts.bump() }
        let defaultToken = NotificationCenter.default.addObserver(
            forName: FloeShortcutInbox.didEnqueue, object: nil, queue: nil
        ) { _ in defaultPosts.bump() }
        defer {
            scope.notifications.removeObserver(privateToken)
            NotificationCenter.default.removeObserver(defaultToken)
        }

        var send = SendToFloeIntent()
        send.prompt = "Summarize this text"
        send.text = "repeated payload"
        var create = CreateFloeTaskIntent()
        create.taskDescription = "repeated payload"
        try await FloeShortcutsRuntime.$debugDraftEnqueueContext.withValue(scope.context()) {
            _ = try await send.perform()
            _ = try await send.perform()
            _ = try await create.perform()
        }

        let queued = try await scope.inbox.pendingEntries(limit: 10)
        #expect(queued.count == 3)
        #expect(queued.map(\.text) == [
            "Summarize this text\n\nrepeated payload",
            "Summarize this text\n\nrepeated payload",
            "repeated payload"
        ])
        #expect(Set(queued.map(\.id)).count == 3)
        #expect(queued.map(\.source) == [.intentSend, .intentSend, .intentCreate])
        #expect(privatePosts.count == 3)
        #expect(defaultPosts.count == 0)
    }

    @Test("An actual intent reports a failed enqueue and posts nothing")
    func actualIntentProducerHonestFailure() async throws {
        let scope = try await DebugProducerScope()
        defer { scope.cleanup() }
        let privatePosts = NotificationCounter()
        let token = scope.notifications.addObserver(
            forName: FloeShortcutInbox.didEnqueue, object: nil, queue: nil
        ) { _ in privatePosts.bump() }
        defer { scope.notifications.removeObserver(token) }

        var create = CreateFloeTaskIntent()
        create.taskDescription = "payload"
        var failure: Error?
        do {
            try await FloeShortcutsRuntime.$debugDraftEnqueueContext.withValue(
                scope.context(store: ThrowingEnqueueInbox())
            ) {
                _ = try await create.perform()
            }
        } catch {
            failure = error
        }
        #expect(failure != nil)
        #expect(privatePosts.count == 0)
        let isolated = try await scope.inbox.pendingCount()
        #expect(isolated == 0)
    }

    @Test("A pre-cancelled actual intent enqueues nothing")
    func actualIntentProducerPreCancelled() async throws {
        let scope = try await DebugProducerScope()
        defer { scope.cleanup() }
        let privatePosts = NotificationCounter()
        let token = scope.notifications.addObserver(
            forName: FloeShortcutInbox.didEnqueue, object: nil, queue: nil
        ) { _ in privatePosts.bump() }
        defer { scope.notifications.removeObserver(token) }

        let failure = await FloeShortcutsRuntime.$debugDraftEnqueueContext.withValue(
            scope.context()
        ) {
            await Task { @MainActor () -> Error? in
                withUnsafeCurrentTask { $0?.cancel() }
                var send = SendToFloeIntent()
                send.prompt = "cancelled"
                send.text = "payload"
                do {
                    _ = try await send.perform()
                    return nil
                } catch {
                    return error
                }
            }.value
        }
        #expect(failure is CancellationError)
        #expect(privatePosts.count == 0)
        #expect(try await scope.inbox.pendingCount() == 0)
    }

    // MARK: - FIFO + composer protection

    @Test("Consecutive drafts deliver FIFO and the queue only advances after a durable ack")
    func fifoDelivery() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "first", source: .intentSend, migrationKey: nil)
        _ = try await f.inbox.enqueue(text: "second", source: .intentCreate, migrationKey: nil)
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "first")
        #expect(vm.shortcutInboxCount == 1)
        // The field now holds content: the next entry must NOT overwrite it.
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "first")
        #expect(vm.shortcutInboxCount == 1)
        // Emptied (as a real send would): the FIFO advances to "second".
        vm.draft = ""
        f.drafts.clear(conversationID: ComposerDraftStore.homeDraftID)
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "second")
        #expect(vm.shortcutInboxCount == 0)
        let counts = try await f.inbox.pendingCount()
        #expect(counts == 0)
    }

    @Test("Human text in the field keeps every queued entry pending")
    func humanTextWins() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let vm = f.makeVM()
        vm.draft = "human typed"
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "human typed")
        #expect(vm.shortcutInboxCount == 1)
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["queued"])
    }

    @Test("Staged attachments keep every queued entry pending")
    func attachmentsWin() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentSend, migrationKey: nil)
        let vm = f.makeVM()
        vm.attachments = [AttachmentRef(kind: .document, displayName: "file.pdf")]
        await vm.acceptShortcutInbox()
        #expect(vm.attachments.count == 1)
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.count == 1)
    }

    @Test("A durable slot holding content is never overwritten even when this field is empty")
    func occupiedSlotNeverOverwritten() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        // Another window (same durable slot) already holds human text.
        f.drafts.save(text: "typed elsewhere", conversationID: ComposerDraftStore.homeDraftID)
        // The launchpad restores that human draft at init — acceptance must
        // leave it exactly as-is.
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "typed elsewhere")
        let slotText = f.drafts.text(for: ComposerDraftStore.homeDraftID)
        #expect(slotText == "typed elsewhere")
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["queued"])
    }

    @Test("An A → B → A human edit landing during the claim window releases the claim")
    func generationGuardRejectsMidClaimEdit() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let delaying = DelayingInbox(base: f.inbox)
        let vm = f.makeVM(inbox: delaying)
        let accept = Task { await vm.acceptShortcutInbox() }
        // The human types and then clears while the claim await is open.
        try await Task.sleep(for: .milliseconds(20))
        vm.draft = "B"
        vm.draft = ""
        await accept.value
        #expect(vm.draft == "")
        // The draft was NOT delivered, and the entry is recoverable, pending.
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["queued"])
    }

    // MARK: - Toggle / route

    @Test("Shortcuts disabled: acceptance rejects, records stay queued, surface stays quiet")
    func toggleOffRetainsRecords() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let vm = f.makeVM(enabled: false)
        await vm.acceptShortcutInbox()
        #expect(vm.shortcutInboxCount == 0)
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.count == 1)
        // Re-enabling makes the retained record visible and deliverable.
        let vm2 = f.makeVM(enabled: true)
        await vm2.acceptShortcutInbox()
        #expect(vm2.draft == "queued")
    }

    @Test("Creative and foreign draft identities never consume the queue")
    func wrongRouteNeverConsumes() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let creative = f.makeVM(accepts: false)
        await creative.acceptShortcutInbox()
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.count == 1)
        #expect(creative.draft == "")
    }

    // MARK: - Legacy migration

    @Test("Legacy single-slot draft migrates once, delivers durably, then the key is gone")
    func legacyMigrationDelivers() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let legacyRaw = "Summarize this text\n\nold payload"
        let identity = FloeShortcutInbox.legacyMigrationIdentity(for: legacyRaw)
        f.legacySuite.set(legacyRaw, forKey: FloeShortcutInbox.legacyPendingDraftKey)
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        #expect(vm.draft.contains("old payload"))
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey) == nil)
        // The migrated row keeps a delivered tombstone for the identity bound
        // to these exact bytes.
        let tombstone = try await f.inbox.entry(
            id: ShortcutDraftInboxEntry.stableID(migrationKey: identity)
        )
        #expect(tombstone?.state == .delivered)
        // A late retry (key reappearing from an unsynchronized removal) of the
        // SAME bytes can never redeliver: the migration hits the tombstone.
        f.legacySuite.set(legacyRaw, forKey: FloeShortcutInbox.legacyPendingDraftKey)
        try await FloeShortcutInbox.migrateLegacyDraft(into: f.inbox, defaults: f.legacySuite)
        let count = try await f.inbox.pendingCount()
        #expect(count == 0)
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey) == nil)
        // A DIFFERENT later value is not swallowed by the old tombstone: it
        // migrates as its own pending entry with a distinct identity.
        let replacement = "Summarize this text\n\nnew payload"
        f.legacySuite.set(replacement, forKey: FloeShortcutInbox.legacyPendingDraftKey)
        try await FloeShortcutInbox.migrateLegacyDraft(into: f.inbox, defaults: f.legacySuite)
        let replacementEntries = try await f.inbox.pendingEntries(limit: 5)
        #expect(replacementEntries.map(\.text) == [replacement])
        #expect(replacementEntries.first?.migrationKey
                == FloeShortcutInbox.legacyMigrationIdentity(for: replacement))
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey) == nil)
    }

    @Test("A legacy value replaced during the awaited migration is preserved")
    func legacyValueReplacedDuringMigrationIsPreserved() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        f.legacySuite.set("old legacy payload", forKey: FloeShortcutInbox.legacyPendingDraftKey)
        let delaying = DelayingInbox(base: f.inbox, enqueueDelay: .milliseconds(150))
        let migrate = Task {
            try await FloeShortcutInbox.migrateLegacyDraft(into: delaying, defaults: f.legacySuite)
        }
        try await Task.sleep(for: .milliseconds(30))
        // A concurrent legacy writer replaces the slot while the migration's
        // durable enqueue is still awaiting.
        f.legacySuite.set("new legacy payload", forKey: FloeShortcutInbox.legacyPendingDraftKey)
        try await migrate.value
        // The migration queued exactly the value it read and did NOT delete
        // the newer one; a later migration call queues it under its OWN
        // identity instead of being swallowed by the earlier entry.
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["old legacy payload"])
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey)
                == "new legacy payload")
        try await FloeShortcutInbox.migrateLegacyDraft(into: f.inbox, defaults: f.legacySuite)
        let afterReplacement = try await f.inbox.pendingEntries(limit: 5)
        #expect(afterReplacement.map(\.text) == ["old legacy payload", "new legacy payload"])
        #expect(afterReplacement.last?.id == ShortcutDraftInboxEntry.stableID(
            migrationKey: FloeShortcutInbox.legacyMigrationIdentity(for: "new legacy payload")
        ))
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey) == nil)
    }

    @Test("A whitespace-only legacy value clears the key without queueing anything")
    func legacyWhitespaceCleared() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        f.legacySuite.set("   ", forKey: FloeShortcutInbox.legacyPendingDraftKey)
        try await FloeShortcutInbox.migrateLegacyDraft(into: f.inbox, defaults: f.legacySuite)
        #expect(f.legacySuite.string(forKey: FloeShortcutInbox.legacyPendingDraftKey) == nil)
        let count = try await f.inbox.pendingCount()
        #expect(count == 0)
    }

    // MARK: - Document format compatibility

    @Test("A v1 bare-map draft document restores drafts and proves no receipt")
    func v1DocumentRestoresDraftsWithoutReceiptProof() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        // v1 format = one bare [uuidString: Entry] JSON object (every build
        // before the receipt protocol). The human draft must still restore,
        // and a document without receipts must prove nothing on disk.
        let entry = ComposerDraftStore.Entry(
            text: "human draft from an older build",
            attachments: [],
            revision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            selectionLocation: 3,
            selectionLength: 2
        )
        try FileManager.default.createDirectory(
            at: f.draftFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v1Data = try JSONEncoder().encode([
            ComposerDraftStore.homeDraftID.uuidString: entry
        ])
        try v1Data.write(to: f.draftFile)
        let store = ComposerDraftStore(fileURL: f.draftFile)
        let restored = try #require(store.entry(for: ComposerDraftStore.homeDraftID))
        #expect(restored.text == "human draft from an older build")
        #expect(restored.revision == 7)
        #expect(restored.selection == NSRange(location: 3, length: 2))
        let anyReceipt = ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: ComposerDraftStore.homeDraftID.uuidString,
            entryID: UUID(), claimToken: "token"
        )
        #expect(!store.handoffReceiptOnDisk(anyReceipt))
        #expect(store.unsettledHandoffReceipts.isEmpty)
        // A normal edit upgrades the SAME file to the v2 document; the v1
        // draft remains readable through the version-2 loader.
        #expect(store.save(
            text: "human draft from an older build, edited",
            conversationID: ComposerDraftStore.homeDraftID,
            expectedRevision: 7
        ) != nil)
        #expect(store.flushAndWait())
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: f.draftFile)
        ) as? [String: Any]
        #expect(raw?["drafts"] != nil)
        #expect(raw?["handoffs"] != nil)
        let upgraded = ComposerDraftStore(fileURL: f.draftFile)
        #expect(upgraded.entry(for: ComposerDraftStore.homeDraftID)?.text
                == "human draft from an older build, edited")
    }

    // MARK: - Crash / recovery

    @Test("A dead process's claim whose durable receipt is on disk is acked, not redelivered")
    func deadClaimAlreadyDelivered() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let claim = try #require(try await f.inbox.claimNext(
            destinationID: ComposerDraftStore.homeDraftID.uuidString,
            at: Date(), epoch: "epoch-dead-process"
        ))
        // The dead process DID complete the verified durable handoff — text
        // and entry-bound receipt in ONE snapshot — then died before the ack.
        let token = try #require(claim.claimToken)
        let receipt = ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: ComposerDraftStore.homeDraftID.uuidString,
            entryID: claim.id, claimToken: token
        )
        let placed = await f.drafts.commitDurable(
            text: "queued", conversationID: ComposerDraftStore.homeDraftID,
            expectedRevision: nil, handoff: receipt
        )
        #expect(placed)
        #expect(f.drafts.handoffReceiptOnDisk(receipt))
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        // Settled idempotently from the disk receipt: the restored single
        // copy stays and the entry is NOT placed a second time (no doubling,
        // no overwrite), and the retired evidence no longer proves anything.
        #expect(vm.draft == "queued")
        #expect(f.drafts.text(for: ComposerDraftStore.homeDraftID) == "queued")
        #expect(vm.shortcutInboxCount == 0)
        // Once the settle housekeeping write lands, even the disk no longer
        // proves the retired receipt (inert token either way).
        #expect(f.drafts.flushAndWait())
        #expect(!f.drafts.handoffReceiptOnDisk(receipt))
        #expect(f.drafts.unsettledHandoffReceipts.isEmpty)
        let gone = try await f.inbox.entry(id: claim.id)
        #expect(gone == nil)
    }

    @Test("A dead process's undelivered claim is recovered and delivered")
    func deadClaimRequeuedAndDelivered() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        _ = try await f.inbox.claimNext(
            destinationID: ComposerDraftStore.homeDraftID.uuidString,
            at: Date(), epoch: "epoch-dead-process"
        )
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "queued")
        #expect(vm.shortcutInboxCount == 0)
    }

    @Test("A failed durable commit keeps the entry pending, the composer untouched and the slot retryable")
    func durableCommitFailureKeepsPending() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        // Durable writes fail: the draft document path sits below a plain file.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-s3-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let brokenStore = ComposerDraftStore(
            fileURL: blocker.appendingPathComponent("nested/drafts.json")
        )
        let vm = HomeLaunchpadViewModel(
            center: f.center,
            acceptsShortcutInbox: true,
            shortcutInbox: f.inbox,
            draftStore: brokenStore,
            isShortcutInboxEnabled: { true },
            shortcutLegacyDefaults: f.legacySuite
        )
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "")
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["queued"])
        // The failed commit rolled back its own placement: the SHARED slot is
        // not left occupied while the VM field is empty (that asymmetry used
        // to make every later delivery fail retry-checks), no unverified
        // receipt is in memory or proven on disk, and a retry can still write.
        let slot = brokenStore.entry(for: ComposerDraftStore.homeDraftID)
        #expect((slot?.text ?? "").isEmpty)
        #expect(brokenStore.unsettledHandoffReceipts.isEmpty)
        let retryRevision = slot?.revision
        #expect(brokenStore.save(text: "retry probe",
                                 conversationID: ComposerDraftStore.homeDraftID,
                                 expectedRevision: retryRevision) != nil)
        brokenStore.clear(conversationID: ComposerDraftStore.homeDraftID)
    }

    @Test("A failed write plus restart preserves every entry and fully recovers when the disk works again")
    func failedWriteThenRestartPreservesEntries() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "alpha", source: .intentSend, migrationKey: nil)
        _ = try await f.inbox.enqueue(text: "beta", source: .intentCreate, migrationKey: nil)
        let brokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-s3-restart-\(UUID().uuidString)", isDirectory: true)
        // Writes fail: the path component that must hold the directory is a file.
        try Data().write(to: brokenURL)
        let brokenFile = brokenURL.appendingPathComponent("nested/drafts.json")
        defer { try? FileManager.default.removeItem(at: brokenURL) }

        // Attempt 1 (broken disk): every accept fails cleanly and releases.
        let store1 = ComposerDraftStore(fileURL: brokenFile)
        let vm1 = f.makeVM(draftStore: store1)
        await vm1.acceptShortcutInbox()
        #expect(vm1.draft == "")
        #expect(vm1.shortcutInboxCount == 2)
        // Process restart, still broken: a fresh store reads nothing (no file
        // landed) and proves nothing; the durable inbox keeps BOTH entries.
        let store2 = ComposerDraftStore(fileURL: brokenFile)
        let vm2 = f.makeVM(draftStore: store2)
        await vm2.acceptShortcutInbox()
        #expect(vm2.draft == "")
        #expect(vm2.shortcutInboxCount == 2)
        let queued = try await f.inbox.pendingEntries(limit: 5)
        #expect(queued.map(\.text) == ["alpha", "beta"])

        // Disk repaired: the entries were never lost and now deliver FIFO.
        try FileManager.default.removeItem(at: brokenURL)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        let store3 = ComposerDraftStore(fileURL: brokenFile)
        let vm3 = f.makeVM(draftStore: store3)
        await vm3.acceptShortcutInbox()
        #expect(vm3.draft == "alpha")
        vm3.draft = ""
        store3.clear(conversationID: ComposerDraftStore.homeDraftID)
        await vm3.acceptShortcutInbox()
        #expect(vm3.draft == "beta")
        #expect(vm3.shortcutInboxCount == 0)
        #expect(try await f.inbox.pendingCount() == 0)
    }

    // MARK: - Receipt identity (no textual inference)

    @Test("Two queue entries with identical payloads stay distinct end to end")
    func identicalPayloadEntriesStayDistinct() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let first = try await f.inbox.enqueue(text: "dup", source: .intentSend, migrationKey: nil)
        let second = try await f.inbox.enqueue(text: "dup", source: .intentCreate, migrationKey: nil)
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "dup")
        #expect(vm.shortcutInboxCount == 1)
        // The settled receipt belongs to the FIRST entry only; the identical
        // second payload is untouched and un-acked.
        #expect(try await f.inbox.entry(id: first.id) == nil)
        let remaining = try #require(try await f.inbox.entry(id: second.id))
        #expect(remaining.state == .pending)
        vm.draft = ""
        f.drafts.clear(conversationID: ComposerDraftStore.homeDraftID)
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "dup")
        #expect(vm.shortcutInboxCount == 0)
        #expect(try await f.inbox.entry(id: second.id) == nil)
    }

    @Test("Human prose containing the draft phrase never settles the claim")
    func containsTrapNeverAcknowledges() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let entry = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        // A previous instance claimed the entry, then vanished mid-handoff
        // without any durable placement (live epoch so settle sees it).
        let claim = try #require(try await f.inbox.claimNext(
            destinationID: ComposerDraftStore.homeDraftID.uuidString, at: Date()
        ))
        #expect(claim.id == entry.id)
        // The durable slot holds ONLY human prose that happens to contain the
        // phrase — plain save, no receipt. Text containment would ack here.
        f.drafts.save(
            text: "my own note that mentions queued in a sentence",
            conversationID: ComposerDraftStore.homeDraftID
        )
        let vm = f.makeVM()
        await vm.acceptShortcutInbox()
        // No receipt → no ack: the claim is left intact for a later settle,
        // and the human text is untouched.
        let row = try #require(try await f.inbox.entry(id: entry.id))
        #expect(row.state == .claimed)
        #expect(row.claimToken == claim.claimToken)
        #expect(vm.draft == "my own note that mentions queued in a sentence")
        #expect(f.drafts.text(for: ComposerDraftStore.homeDraftID)
                == "my own note that mentions queued in a sentence")
        #expect(vm.shortcutInboxCount == 0) // claimed, not pending
    }

    // MARK: - Durable-commit suspension interleavings (deterministic, no sleeps)

    /// Runs one acceptance with the store's serial write queue suspended and
    /// hands the VM to `humanAction` exactly while the REAL durable commit is
    /// inside its verified-write suspension. The synchronous acceptance turn
    /// (pre-check → render → CAS save → receipt stage → must-land submit)
    /// has ALREADY completed when `humanAction` starts: the draft is in the
    /// live field, and everything the human does from here is post-acceptance
    /// work that the flow may never overwrite. The queue resumes only after
    /// the human action returns, so the interleaving is pinned by the queue,
    /// never by timing luck.
    private func interleavedAcceptance(
        f: Fixture,
        store: ComposerDraftStore,
        queue: DispatchQueue,
        faultedInbox: FaultyInbox? = nil,
        humanAction: @MainActor (HomeLaunchpadViewModel) async -> Void
    ) async throws -> (vm: HomeLaunchpadViewModel, receipt: ComposerDraftStore.ShortcutHandoffReceipt) {
        let rendezvous = CommitRendezvous()
        let receiptBox = ReceiptBox()
        let commit: HomeLaunchpadViewModel.ShortcutDurableCommit = { text, revision, receipt in
            receiptBox.value = receipt
            // Starting the real durable commit runs its synchronous prefix
            // (save + receipt stage + submit) as the next main-actor job; it
            // then suspends until the gated queue drains.
            let placement = Task {
                await store.commitDurable(
                    text: text, conversationID: ComposerDraftStore.homeDraftID,
                    expectedRevision: revision, handoff: receipt
                )
            }
            rendezvous.commitStarted()
            return await placement.value
        }
        let vm = f.makeVM(
            inbox: faultedInbox, draftStore: store, shortcutCommit: commit
        )
        let accept = Task { await vm.acceptShortcutInbox() }
        await rendezvous.awaitCommitStarted()
        await humanAction(vm)
        queue.resume()
        await accept.value
        return (vm, try #require(receiptBox.value))
    }

    @Test("An A → B → A edit inside the durable-commit suspension is never overwritten by the handoff")
    func editDuringDurableWriteIsNeverOverwritten() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let queue = DispatchQueue(label: "floe-test-drafts-gated")
        queue.suspend()
        let store = ComposerDraftStore(fileURL: f.draftFile, writeQueue: queue)
        // The draft is accepted into the field synchronously BEFORE the
        // commit suspends; the human then rewrites it (A → B → A). No late
        // callback may re-assign the field after the verified write lands.
        let (vm, receipt) = try await interleavedAcceptance(f: f, store: store, queue: queue) { model in
            // The human saw "queued" and edited it away.
            #expect(model.draft == "queued")
            model.draft = "typed"
            store.save(text: "typed", conversationID: ComposerDraftStore.homeDraftID)
            store.flush()
            model.draft = ""
            store.save(text: "", conversationID: ComposerDraftStore.homeDraftID)
            store.flush()
        }
        // After the commit verifies, the flow ONLY acks — it never touches
        // the field again: the human's final state stands.
        #expect(vm.draft == "")
        #expect(store.text(for: ComposerDraftStore.homeDraftID) == "")
        // The entry was visibly accepted before the durable proof, so the
        // ack is honest and the queue advances; nothing lingers unacked.
        #expect(try await f.inbox.pendingCount() == 0)
        let claims = try await f.inbox.claims(destinationID: ComposerDraftStore.homeDraftID.uuidString)
        #expect(claims.isEmpty)
        // Evidence retired with the ack; the receipt proves nothing further.
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(store.flushAndWait())
        #expect(!store.handoffReceiptOnDisk(receipt))
    }

    @Test("Attachments staged inside the durable-commit suspension are preserved")
    func attachmentsDuringDurableWriteArePreserved() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let queue = DispatchQueue(label: "floe-test-drafts-gated")
        queue.suspend()
        let store = ComposerDraftStore(fileURL: f.draftFile, writeQueue: queue)
        let staged = AttachmentRef(kind: .document, displayName: "human.pdf")
        let (vm, receipt) = try await interleavedAcceptance(f: f, store: store, queue: queue) { model in
            model.attachments = [staged]
            store.save(text: model.draft, attachments: [staged],
                       conversationID: ComposerDraftStore.homeDraftID)
            store.flush()
        }
        // The accepted draft stays, the human's staged file stays, nothing
        // is overwritten by the post-suspension path (there is none).
        #expect(vm.draft == "queued")
        #expect(vm.attachments.map(\.displayName) == ["human.pdf"])
        #expect(store.attachments(for: ComposerDraftStore.homeDraftID).map(\.displayName) == ["human.pdf"])
        #expect(try await f.inbox.pendingCount() == 0)
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(store.flushAndWait())
        #expect(!store.handoffReceiptOnDisk(receipt))
    }

    @Test("Crash after a human edit and before the ack settles only the visibly accepted entry")
    func humanEditThenCrashBeforeAckSettlesAcceptedEntry() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let queue = DispatchQueue(label: "floe-test-drafts-gated")
        queue.suspend()
        let store = ComposerDraftStore(fileURL: f.draftFile, writeQueue: queue)
        let faulty = FaultyInbox(base: f.inbox)
        await faulty.setAckFault(true)
        // Human edits the just-rendered draft, then the ack is lost (crash
        // window) while their newer content is what the composer holds.
        let (vm1, receipt) = try await interleavedAcceptance(
            f: f, store: store, queue: queue, faultedInbox: faulty
        ) { model in
            model.draft = "typed further"
            store.save(text: "typed further", conversationID: ComposerDraftStore.homeDraftID)
            store.flush()
        }
        // Claim stays with its token; the receipt is disk-verified and the
        // draft WAS visibly accepted before the crash — settle from disk
        // acks exactly this accepted entry, never an unrendered one.
        let claim = try #require(try await f.inbox.claims(
            destinationID: ComposerDraftStore.homeDraftID.uuidString
        ).first)
        #expect(claim.state == .claimed)
        await faulty.setAckFault(false)
        let vm2 = f.makeVM(draftStore: store, inbox: faulty)
        await vm2.acceptShortcutInbox()
        // No redelivery, no overwrite: the human's newer text stands, the
        // entry is settled, and the receipt evidence is retired.
        #expect(vm2.draft == "typed further")
        #expect(vm1.draft == "typed further")
        #expect(try await f.inbox.entry(id: claim.id) == nil)
        #expect(store.unsettledHandoffReceipts.isEmpty)
        #expect(store.flushAndWait())
        #expect(!store.handoffReceiptOnDisk(receipt))
    }

    @Test("A failed commit with a failed release keeps the claim recoverable and never false-acks")
    func failedCommitWithFailedReleaseRestartsCleanly() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let brokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-s3-releasefault-\(UUID().uuidString)")
        try Data().write(to: brokenURL)
        let brokenFile = brokenURL.appendingPathComponent("nested/drafts.json")
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let brokenStore = ComposerDraftStore(fileURL: brokenFile)
        let faulty = FaultyInbox(base: f.inbox)
        await faulty.setReleaseFault(true)
        let vm1 = f.makeVM(draftStore: brokenStore, inbox: faulty)
        await vm1.acceptShortcutInbox()
        await faulty.setReleaseFault(false)
        // The unproven render rolled back (human never touched the field);
        // nothing is acknowledged; the release ALSO failed, so the claim
        // stays with its token — but crucially NO receipt ever reached disk.
        #expect(vm1.draft == "")
        let claim = try #require(try await f.inbox.claims(
            destinationID: ComposerDraftStore.homeDraftID.uuidString
        ).first)
        #expect(claim.state == .claimed)
        #expect(brokenStore.unsettledHandoffReceipts.isEmpty)
        #expect(!brokenStore.handoffReceiptOnDisk(ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: ComposerDraftStore.homeDraftID.uuidString,
            entryID: claim.id, claimToken: try #require(claim.claimToken)
        )))
        // "Restart" with the disk repaired: settle sees the live claim,
        // finds no disk receipt, and RE-delivers into the free composer —
        // visible acceptance first, then ack with the SAME token. The
        // payload is recovered exactly once.
        try FileManager.default.removeItem(at: brokenURL)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        let fixedStore = ComposerDraftStore(fileURL: brokenFile)
        let vm2 = f.makeVM(draftStore: fixedStore, inbox: faulty)
        await vm2.acceptShortcutInbox()
        #expect(vm2.draft == "queued")
        #expect(try await f.inbox.entry(id: claim.id) == nil)
        #expect(vm2.shortcutInboxCount == 0)
        #expect(fixedStore.unsettledHandoffReceipts.isEmpty)
    }

    // MARK: - Crash windows around the ack

    @Test("Crash after the durable write but before the ack settles idempotently from disk")
    func durableWriteBeforeAckCrashSettles() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let faulty = FaultyInbox(base: f.inbox)
        await faulty.setAckFault(true)
        // VM1 delivers: the text + entry-bound receipt land on disk, the
        // draft renders, then the ack is lost (simulated crash window).
        let vm1 = f.makeVM(inbox: faulty)
        await vm1.acceptShortcutInbox()
        #expect(vm1.draft == "queued")
        let claim = try #require(try await f.inbox.claims(
            destinationID: ComposerDraftStore.homeDraftID.uuidString
        ).first)
        #expect(claim.state == .claimed)
        // "Restart": a fresh instance settles the abandoned same-epoch claim.
        // The disk receipt — not any text comparison — is the only bridge.
        await faulty.setAckFault(false)
        let vm2 = f.makeVM(inbox: faulty)
        await vm2.acceptShortcutInbox()
        #expect(vm2.draft == "queued")
        // Idempotent: exactly ONE copy, no re-delivery, entry settled.
        #expect(f.drafts.text(for: ComposerDraftStore.homeDraftID) == "queued")
        #expect(try await f.inbox.entry(id: claim.id) == nil)
        #expect(vm2.shortcutInboxCount == 0)
        #expect(f.drafts.unsettledHandoffReceipts.isEmpty)
    }

    @Test("A clear/send after delivery but before the ack keeps the unsettled evidence")
    func clearAfterDeliveryKeepsUnsettledEvidence() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let faulty = FaultyInbox(base: f.inbox)
        await faulty.setAckFault(true)
        let vm = f.makeVM(inbox: faulty)
        await vm.acceptShortcutInbox()
        #expect(vm.draft == "queued")
        // Ordinary clears/sends (and the store's own delete-after-send path)
        // must NOT destroy the unsettled receipt evidence.
        vm.draft = ""
        f.drafts.clear(conversationID: ComposerDraftStore.homeDraftID)
        #expect(f.drafts.unsettledHandoffReceipts.count == 1)
        let claim = try #require(try await f.inbox.claims(
            destinationID: ComposerDraftStore.homeDraftID.uuidString
        ).first)
        await faulty.setAckFault(false)
        let vm2 = f.makeVM(inbox: faulty)
        await vm2.acceptShortcutInbox()
        // The draft WAS rendered and durably placed: the ack is honest, the
        // entry is gone, and the retired evidence proves nothing further.
        #expect(try await f.inbox.entry(id: claim.id) == nil)
        #expect(vm2.draft == "")
        #expect(f.drafts.unsettledHandoffReceipts.isEmpty)
    }

    // MARK: - Claim identity

    @Test("Two windows accepting at once deliver the draft exactly once")
    func concurrentWindowsSingleDelivery() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        _ = try await f.inbox.enqueue(text: "queued", source: .intentCreate, migrationKey: nil)
        let first = f.makeVM()
        let second = f.makeVM()
        // `async let` child tasks inherit the enclosing MainActor isolation,
        // so both windows race on the destination lock as real windows do.
        async let a = first.acceptShortcutInbox()
        async let b = second.acceptShortcutInbox()
        _ = await (a, b)
        let delivered = [first.draft, second.draft].filter { $0 == "queued" }
        #expect(delivered.count == 1)
        let count = try await f.inbox.pendingCount()
        #expect(count == 0)
    }
}

#endif
