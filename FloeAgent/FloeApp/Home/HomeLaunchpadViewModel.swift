// FloeApp — Home launchpad view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the Home launchpad: the centered start-task
// composer, the second-column overview (active runs / pending approvals /
// recent threads), and the single-flight task creation. Home never shows
// the conversation-history list — that is Chat's job.
//
// Task-creation guarantees:
// - A send creates exactly one conversation, even on a double tap
//   (single-flight flag + cleared draft).
// - A failed send keeps the draft, creates no conversation, and surfaces
//   the error — no empty, forever-"running" thread is ever left behind.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// The task-creation seam behind Home's send button. The live
/// implementation delegates to ConversationCenter; tests substitute a
/// fake to pin the single-creation and failure-cleanup guarantees without
/// standing up the whole app environment.
protocol HomeTaskStarting: Sendable {
    /// Creates a conversation for `goal` and starts its run.
    /// Implementations MUST throw (and leave no empty thread behind) when
    /// the run fails to start.
    func startTask(goal: String, modelID: UUID?) async throws -> UUID
    /// Design launch: freeze the typed target + work mode inside the launch
    /// transaction, before provider I/O. The default ignores the binding so
    /// test fakes keep compiling; the live path always provides it.
    func startTask(goal: String, modelID: UUID?, designLaunchBinding: DesignLaunchBinding?) async throws -> UUID
}

extension HomeTaskStarting {
    func startTask(goal: String, modelID: UUID?, designLaunchBinding: DesignLaunchBinding?) async throws -> UUID {
        try await startTask(goal: goal, modelID: modelID)
    }
}

@MainActor
final class HomeLaunchpadViewModel: ObservableObject {

    // MARK: - Shortcuts draft inbox

    /// True only for the canonical Home launchpad composer (the ordinary
    /// Home / New Task / Workspace start surfaces). Creative design entry and
    /// any other draft identity NEVER consume the Shortcuts queue, so an
    /// unrelated editor cannot take over the handoff.
    let acceptsShortcutInbox: Bool
    /// Durable-slot count currently waiting to be reviewed (pending entries).
    /// The banner is honest: 0 means nothing is queued for this surface.
    @Published private(set) var shortcutInboxCount = 0
    /// Publishes handoff completion so submission controls refresh even when
    /// the pending count stays zero (for example a single migrated draft).
    @Published private(set) var shortcutHandoffInProgress = false
    /// One handoff per destination at a time across ALL live windows: the
    /// claim/ack protocol is atomic, and serializing the delivery side keeps
    /// two windows from continuing the same claim against each other.
    @MainActor private static var destinationsInHandoff: Set<String> = []

    /// Test seam: an injected durable store (production resolves the
    /// app-owned database store; no parallel runtime is ever created).
    private let shortcutInboxOverride: (any ShortcutDraftInboxStore)?
    /// Test seam for the durable commit (see `commitDurableOverride`): tests
    /// inject a slow commit to prove the late-callback guard deterministically.
    typealias ShortcutDurableCommit = @MainActor (
        _ text: String,
        _ expectedRevision: Int?,
        _ receipt: ComposerDraftStore.ShortcutHandoffReceipt
    ) async -> Bool
    private let commitDurableOverride: ShortcutDurableCommit?
    /// The launchpad's durable draft slot, injectable for isolated tests.
    let draftStore: ComposerDraftStore
    private let isShortcutInboxEnabled: () -> Bool
    /// Legacy single-slot defaults for the one-time migration. nil uses the
    /// production App Group suite; isolated tests MUST inject a private
    /// suite so no real app defaults are ever touched.
    private let shortcutLegacyDefaults: UserDefaults?

    private func resolveShortcutInbox() -> any ShortcutDraftInboxStore {
        shortcutInboxOverride
            ?? (SQLiteShortcutDraftInboxStore(database: environment.database) as any ShortcutDraftInboxStore)
    }

    /// The composer is actually free to receive a draft: no human text
    /// (whitespace does not count), no staged attachments, no send in
    /// flight, and no other window is mid-handoff for this destination.
    var canAcceptShortcutDraft: Bool {
        isShortcutComposerFree
            && !Self.destinationsInHandoff.contains(draftStorageID.uuidString)
    }

    /// Internal checks run after this caller owns the destination lock.
    /// Testing the public locked-state predicate there would reject itself.
    private var isShortcutComposerFree: Bool {
        acceptsShortcutInbox
            && !draft.contains(where: { !$0.isWhitespace })
            && attachments.isEmpty
            && !isSending
            && !isConsumingDraft
    }

    var showsShortcutInboxBanner: Bool {
        acceptsShortcutInbox && shortcutInboxCount > 0
    }

    // MARK: - Composer state

    /// Draft text. Preserved verbatim across a failed send. Every real
    /// change advances `draftGeneration`; a successful send clears the field
    /// only while that generation is unchanged, so editing A → B → A while
    /// the task is being created keeps the new A draft.
    @Published var draft: String = "" {
        didSet {
            guard draft != oldValue else { return }
            draftGeneration &+= 1
        }
    }
    /// Monotonic identity of the live composer text. See `draft`.
    private(set) var draftGeneration = 0
    @Published var selectedModelID: UUID?
    @Published var selectedProjectID: UUID?
    @Published var executionTarget: AgentExecutionTarget = .local
    @Published var agentMode: AgentExecutionMode = .agent
    @Published var attachments: [AttachmentRef] = []
    @Published var draftPolicy = DraftTaskPolicy()
    /// Select Notes before sending without creating a blank conversation.
    @Published private(set) var draftConversationID = UUID()
    /// Single-flight send guard (double-tap safe).
    @Published private(set) var isSending = false
    /// True from the moment `sendNewTask` consumes the draft until the task
    /// exists. The composer keeps the sent content in the draft store while
    /// it is set, so text typed during task creation is never erased.
    @Published private(set) var isConsumingDraft = false
    /// Honest error surface for the last failed send.
    @Published private(set) var actionError: String?

    // MARK: - Overview state (iPad second column)

    /// Conversations with at least one non-terminal run.
    @Published private(set) var activeTasks: [ConversationRecord] = []
    /// Recent conversations for the overview (capped by the view).
    @Published private(set) var recentConversations: [ConversationRecord] = []
    /// Latest run state per conversation (overview status pills).
    @Published private(set) var latestRunStates: [UUID: String] = [:]
    @Published private(set) var isLoading = false
    /// Model actually used by the most recent run, refreshed by `load()`.
    /// Used only as a fallback for the draft picker; running requests keep
    /// their own model and are never re-routed by this value.
    @Published private(set) var recentModelID: UUID?
    /// Prevents duplicate default repairs while a save is in flight (the save
    /// reloads the center, which triggers another reconciliation pass).
    private var isRepairingDefault = false

    let center: ConversationCenter
    let environment: AppEnvironment
    /// Separate start surfaces share the launch service, not their unsent text.
    let draftStorageID: UUID
    /// Injectable task starter (defaults to the live center-backed one).
    private let taskStarter: (any HomeTaskStarting)?
    /// Design entry (Creative continue): builds the frozen launch binding at
    /// send time, evaluated inside `sendNewTask` so the async-loaded owner
    /// envelope state (create vs modify) is known before the launch.
    private let designLaunchBindingProvider: (@MainActor () -> DesignLaunchBinding?)?

    init(
        center: ConversationCenter,
        taskStarter: (any HomeTaskStarting)? = nil,
        selectedProjectID: UUID? = nil,
        draftStorageID: UUID = ComposerDraftStore.homeDraftID,
        initialDraft: String? = nil,
        designLaunchBindingProvider: (@MainActor () -> DesignLaunchBinding?)? = nil,
        acceptsShortcutInbox: Bool = false,
        shortcutInbox: (any ShortcutDraftInboxStore)? = nil,
        draftStore: ComposerDraftStore = .shared,
        isShortcutInboxEnabled: @escaping () -> Bool = { AppleCapabilityPreferences.isEnabled(.shortcuts) },
        shortcutLegacyDefaults: UserDefaults? = nil,
        shortcutCommitDurable: ShortcutDurableCommit? = nil
    ) {
        self.center = center
        self.environment = center.environment
        self.taskStarter = taskStarter
        self.selectedProjectID = selectedProjectID
        self.draftStorageID = draftStorageID
        self.designLaunchBindingProvider = designLaunchBindingProvider
        self.acceptsShortcutInbox = acceptsShortcutInbox
        self.shortcutInboxOverride = shortcutInbox
        self.draftStore = draftStore
        self.isShortcutInboxEnabled = isShortcutInboxEnabled
        self.shortcutLegacyDefaults = shortcutLegacyDefaults
        self.commitDurableOverride = shortcutCommitDurable
        // An unsent Home draft (and staged attachments) survive app restarts
        // under the stable launchpad identity — not the per-launch staging
        // UUID, which rotates after each send.
        let stored = draftStore.entry(for: draftStorageID)
        _draft = Published(initialValue: stored?.text ?? initialDraft ?? "")
        _attachments = Published(initialValue: stored?.attachments ?? [])
        // Default the draft policy to the user's global default agent mode so
        // "自动审批" actually takes effect on new tasks started from Home.
        if environment.settingsCenter.defaultAgentMode == .approvalModel {
            draftPolicy = DraftTaskPolicy(approvalMode: .automatic)
        }
    }

    var pendingApprovals: [PendingApproval] { center.pendingApprovals }
    var hasConfiguredProvider: Bool { center.hasConfiguredProvider }
    var availableModels: [ModelProfile] { center.availableAgentModels }

    var activeModelName: String? {
        center.providerAndModel(modelID: selectedModelID)?.1.displayName
    }

    var usesLocalModel: Bool {
        center.providerAndModel(modelID: selectedModelID)?.0.kind == .local
    }

    var availableProjects: [ComposerProject] {
        environment.workspaceCenter.projectWorkspaces.map(ComposerProject.init(record:))
    }

    var canSend: Bool {
        center.providerAndModel(modelID: selectedModelID) != nil
            && draft.contains(where: { !$0.isWhitespace })
            && !isSending
            && !Self.destinationsInHandoff.contains(draftStorageID.uuidString)
    }

    /// Starting a casual chat and sending a normal task share one creation
    /// gate. Opening the temporary composer never starts a model request.
    var canStartTemporaryChat: Bool {
        !isSending && center.temporarySession == nil
            && !Self.destinationsInHandoff.contains(draftStorageID.uuidString)
    }

    @discardableResult
    func startTemporaryChat() async -> UUID? {
        guard canStartTemporaryChat else { return nil }
        let carriedText = draft
        let commit = ComposerSendCommit(
            draft: carriedText,
            attachments: [],
            editorGeneration: draftGeneration,
            conversationID: draftStorageID
        )
        isSending = true
        isConsumingDraft = true
        defer {
            isSending = false
            isConsumingDraft = false
        }
        do {
            let id = try await center.startTemporarySession(
                initialDraft: carriedText,
                preferredModelID: selectedModelID
            )
            // Move only the text actually carried into the RAM-only chat:
            // leaving a second durable copy defeats the temporary choice.
            // The existing generation-aware commit keeps all attachments
            // and any newer ordinary edits, including an A → B → A edit.
            draft = commit.draftAfterSuccess(
                currentDraft: draft,
                currentGeneration: draftGeneration
            )
            commit.commitStore()
            actionError = nil
            return id
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Loading

    /// Loads the overview data. Cheap and quiet: no empty-card stacks —
    /// empty sections simply render nothing.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        await environment.workspaceCenter.reload()
        // Nil is a deliberate private-chat scope. Never inherit whatever
        // project happens to be open in another task or inspector.

        var states: [UUID: String] = [:]
        var active: [ConversationRecord] = []
        var newestRun: (date: Date, modelID: UUID)?
        for conversation in center.conversations {
            let runs = (try? await environment.runStore.runs(conversationID: conversation.id)) ?? []
            guard let latest = runs.sorted(by: { $0.startedAt > $1.startedAt }).first else { continue }
            states[conversation.id] = latest.state
            if !RunStateLocalizer.isTerminal(latest.state) {
                active.append(conversation)
            }
            if let modelID = latest.modelID,
               newestRun == nil || latest.startedAt > newestRun!.date {
                newestRun = (latest.startedAt, modelID)
            }
        }
        recentModelID = newestRun?.modelID
        latestRunStates = states
        activeTasks = active
        recentConversations = center.conversations
        reconcileModelSelection()
        await refreshShortcutInboxCount()
    }

    // MARK: - Shortcuts draft inbox handoff

    /// Delivers the oldest queued Shortcuts draft into this composer.
    /// Only the canonical Home route accepts (Creative and foreign draft
    /// identities never consume). Existing human text or staged attachments
    /// always win: the entry stays durably queued and the composer is
    /// untouched. Delivery identity is an explicit durable receipt —
    /// (destination, inbox entry id, claim token) — serialized in the SAME
    /// snapshot as the placed text; a claim is acknowledged ONLY while that
    /// exact receipt is verified on disk. No text containment, no equality
    /// inference, no in-memory-only proof: unrelated prose can quote the
    /// same phrase and two queue entries can carry identical payloads, so
    /// only the entry-bound receipt can distinguish them. Rendering happens
    /// as the synchronous acceptance event BEFORE the receipt is staged —
    /// nothing assigns the field after the durable commit — so typing,
    /// staging during the durable-write suspension
    /// (including an A → B → A edit) is newer work that no late callback
    /// ever overwrites — the only assignment happens synchronously BEFORE
    /// the commit suspends, and a failed placement rolls back its render
    /// only while the field is generation-unchanged since. Every
    /// settle/release stays token-guarded, so stale callbacks cannot disturb
    /// a newer handoff, and a restart can only settle a receipt that proves
    /// a VISIBLE acceptance. On success the FIFO queue advances to the next
    /// entry; on any failure the entry remains recoverable.
    func acceptShortcutInbox() async {
        guard acceptsShortcutInbox else { return }
        let destination = draftStorageID.uuidString
        guard !Self.destinationsInHandoff.contains(destination) else {
            await refreshShortcutInboxCount()
            return
        }
        Self.destinationsInHandoff.insert(destination)
        shortcutHandoffInProgress = true
        defer {
            Self.destinationsInHandoff.remove(destination)
            shortcutHandoffInProgress = false
        }
        guard isShortcutInboxEnabled() else {
            // Capability off: queued records stay queued, the surface is quiet.
            if shortcutInboxCount != 0 { shortcutInboxCount = 0 }
            return
        }
        let inbox = resolveShortcutInbox()
        do {
            try await FloeShortcutInbox.migrateLegacyDraft(
                into: inbox, defaults: shortcutLegacyDefaults
            )
            await settleShortcutClaims(inbox, destination: destination)
            guard isShortcutComposerFree else {
                await refreshShortcutInboxCount()
                return
            }
            // Capture the live field identity BEFORE the await: any human
            // edit during the claim — including a retyped A → B → A — is
            // rejected below and the claim is released.
            let capturedGeneration = draftGeneration
            guard let claim = try await inbox.claimNext(destinationID: destination, at: Date()),
                  let claimToken = claim.claimToken else {
                await refreshShortcutInboxCount()
                return
            }
            guard !draft.contains(where: { !$0.isWhitespace }),
                  draftGeneration == capturedGeneration,
                  attachments.isEmpty, !isSending, !isConsumingDraft
            else {
                _ = try? await inbox.release(id: claim.id, claimToken: claimToken)
                await refreshShortcutInboxCount()
                return
            }
            let outcome = await deliverShortcutDraft(
                claim.text, inbox: inbox, id: claim.id, claimToken: claimToken,
                destination: destination
            )
            if case .failed = outcome {
                _ = try? await inbox.release(id: claim.id, claimToken: claimToken)
            }
        } catch {
            // The queue keeps every entry in its durable state; nothing is
            // acknowledged or discarded by this path.
            FloeLogger(category: .app).error(
                "shortcutInboxAcceptFailed error=\(error.localizedDescription)"
            )
        }
        await refreshShortcutInboxCount()
    }

    private enum ShortcutDeliveryOutcome {
        /// The composer synchronously accepted the draft, its entry-bound
        /// receipt was verified durable, and the source was settled (or is
        /// left for an idempotent token-matched settle from the disk bytes —
        /// which is honest because the acceptance already visibly occurred).
        case delivered
        /// Nothing was acknowledged: the commit failed or the slot was
        /// already occupied. Any render is rolled back when the human has
        /// not touched the field since, and the caller releases the claim
        /// back to `pending`; no receipt reached disk, so a restart can only
        /// re-deliver, never falsely ack.
        case failed
    }

    /// Delivers ONE inbox entry with the render-before-persist ownership
    /// invariant: the live composer synchronously accepts the text FIRST,
    /// and only the same main-actor turn stages the entry-bound receipt and
    /// submits its must-land snapshot, so any receipt that can ever be
    /// disk-verified proves a placement that ACTUALLY reached the visible
    /// composer. There is no durable "placed but unrendered" state to
    /// withdraw (the previous design's crash window: a human edit during the
    /// commit could leave a landed receipt whose withdrawal or release then
    /// failed, letting a restart settle an entry the user never saw).
    /// After the commit suspends, any human typing/staging/send is newer
    /// work that no late callback ever overwrites: the render already
    /// happened before the suspension and nothing assigns `draft` after it.
    /// On a failed durable commit the pre-commit render is rolled back only
    /// while the field is generation-unchanged since acceptance — a human
    /// who edited the just-rendered draft keeps their content either way.
    private func deliverShortcutDraft(
        _ text: String,
        inbox: any ShortcutDraftInboxStore,
        id: UUID,
        claimToken: String,
        destination: String
    ) async -> ShortcutDeliveryOutcome {
        // Re-check the SHARED durable slot AND the live composer right up to
        // the render: human text, staged attachments or a send in flight
        // must never be displaced or overwritten.
        let stored = draftStore.entry(for: draftStorageID)
        let slotFree = (stored?.text ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && (stored?.attachments ?? []).isEmpty
        guard slotFree,
              !draft.contains(where: { !$0.isWhitespace }),
              attachments.isEmpty, !isSending, !isConsumingDraft
        else { return .failed }
        let receipt = ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: destination, entryID: id, claimToken: claimToken
        )
        // 1. Logical UI acceptance — synchronous, and the only `draft`
        //    assignment in this flow. `renderedGeneration` is the exact
        //    generation this acceptance creates (the setter's didSet bumps
        //    once; the queue payload is validated non-empty on enqueue, so
        //    the assignment always changes the field).
        let preAcceptanceDraft = draft
        let renderedGeneration = draftGeneration &+ 1
        draft = text
        // 2. Durable placement + receipt. Same main-actor turn through the
        //    store's synchronous CAS prefix, so no human event can slip
        //    between the render above and the receipt staging below.
        let committed: Bool
        if let commitDurableOverride {
            committed = await commitDurableOverride(text, stored?.revision, receipt)
        } else {
            committed = await draftStore.commitDurable(
                text: text, attachments: [],
                conversationID: draftStorageID, expectedRevision: stored?.revision,
                handoff: receipt
            )
        }
        if !committed {
            // Generation-safe rollback of an UNPROVEN placement: restore the
            // field only while the human has not touched it since acceptance;
            // their newer content always wins and is never rolled back.
            if draftGeneration == renderedGeneration {
                draft = preAcceptanceDraft
            }
            return .failed
        }
        // 3. Ack only now: acceptance was visible AND the bytes (text +
        //    receipt) are verified durable. Nothing touches the composer
        //    field after the commit suspension, ever.
        do {
            let acked = try await inbox.ack(id: id, claimToken: claimToken)
            if acked {
                // The source record is settled; retire the receipt evidence.
                draftStore.settleHandoff(entryID: id, claimToken: claimToken)
            } else {
                // Destination holds the text durably (the receipt proves it);
                // the token-guarded ack simply lost a race and the settle
                // path will settle it from the disk-verified receipt.
                FloeLogger(category: .app).error("shortcutInboxAckUnsettled id=\(id.uuidString.prefix(8))")
            }
            return .delivered
        } catch {
            // The draft IS visible and durable; a transient ack failure is
            // recoverable by the settle path against the on-disk receipt,
            // so the handoff itself is not reported as lost. The entry
            // stays claimed until a token-matched settle.
            FloeLogger(category: .app).error(
                "shortcutInboxAckThrew id=\(id.uuidString.prefix(8)) error=\(error.localizedDescription)"
            )
            return .delivered
        }
    }

    /// Settles claims left by dead processes and by a launchpad instance
    /// that was replaced mid-handoff. Delivery identity is the receipt, not
    /// the text: a claim is acknowledged idempotently ONLY while the
    /// destination's draft document verifiably carries its exact
    /// (destination, entry id, claim token) receipt on disk — the
    /// crash-after-durable-write-before-ack case. Anything else is
    /// re-delivered (composer free) or left claimed/released (composer busy
    /// or dead token), never acknowledged on containment or equality.
    private func settleShortcutClaims(
        _ inbox: any ShortcutDraftInboxStore,
        destination: String
    ) async {
        // Same destination, live process: a previous launchpad instance left
        // this claim (closed window after the durable save, or between save
        // and ack). Under the destination handoff lock only one instance can
        // be delivery-active, so settling here is safe.
        let resumable = (try? await inbox.claims(destinationID: destination)) ?? []
        for row in resumable {
            guard let token = row.claimToken else { continue }
            if draftStore.handoffReceiptOnDisk(
                ComposerDraftStore.ShortcutHandoffReceipt(
                    destinationID: destination, entryID: row.id, claimToken: token
                )
            ) {
                let acked = try? await inbox.ack(id: row.id, claimToken: token)
                if acked == true {
                    draftStore.settleHandoff(entryID: row.id, claimToken: token)
                }
            } else if !draft.contains(where: { !$0.isWhitespace }),
                      attachments.isEmpty, !isSending, !isConsumingDraft {
                let outcome = await deliverShortcutDraft(
                    row.text, inbox: inbox, id: row.id, claimToken: token,
                    destination: destination
                )
                if case .failed = outcome {
                    _ = try? await inbox.release(id: row.id, claimToken: token)
                }
            }
        }
        // Claims from dead processes: settle or recover, never continue a
        // delivery on a token whose owner no longer exists.
        let abandoned = (try? await inbox.abandonedClaims()) ?? []
        for row in abandoned where row.destinationID == destination {
            guard let token = row.claimToken else { continue }
            if draftStore.handoffReceiptOnDisk(
                ComposerDraftStore.ShortcutHandoffReceipt(
                    destinationID: destination, entryID: row.id, claimToken: token
                )
            ) {
                let acked = try? await inbox.ack(id: row.id, claimToken: token)
                if acked == true {
                    draftStore.settleHandoff(entryID: row.id, claimToken: token)
                }
            } else {
                _ = try? await inbox.release(id: row.id, claimToken: token)
            }
        }
    }

    private func refreshShortcutInboxCount() async {
        guard acceptsShortcutInbox, isShortcutInboxEnabled() else {
            if shortcutInboxCount != 0 { shortcutInboxCount = 0 }
            return
        }
        let count = ((try? await resolveShortcutInbox().pendingCount()) ?? 0)
        if shortcutInboxCount != count { shortcutInboxCount = count }
    }

    // MARK: - Model validation

    /// Validates the draft selection against the models the picker actually
    /// offers after a Settings change and repairs it in the fixed fallback
    /// order. Only a *broken* persisted default is rewritten; a running
    /// request keeps its provider/model pair untouched.
    func reconcileModelSelection() {
        let candidates = availableModels.map {
            AgentModelCandidate(id: $0.id, isUsable: center.providerAndModel(modelID: $0.id) != nil)
        }
        let resolution = AgentModelSelectionResolver.resolve(
            selected: selectedModelID,
            defaultModel: center.modelPreferences.defaultAgentModelID,
            recent: recentModelID,
            candidates: candidates
        )
        if selectedModelID != resolution.modelID { selectedModelID = resolution.modelID }
        guard let repaired = resolution.modelID else { return }
        let stored = center.modelPreferences.defaultAgentModelID
        let storedIsUsable = candidates.contains { $0.id == stored && $0.isUsable }
        guard !storedIsUsable, !isRepairingDefault else { return }
        // Repair the persisted default so Chat and other surfaces agree with
        // Home. This never mutates an in-flight run's model.
        isRepairingDefault = true
        Task {
            await center.setDefaultAgentModel(repaired)
            isRepairingDefault = false
        }
    }

    // MARK: - Task creation

    /// Creates exactly one conversation for the draft and starts its run.
    /// Returns the new conversation ID so Home can open the thread.
    /// On failure nothing is created: the draft stays, the error shows,
    /// and no blank/eternally-timed thread exists.
    @discardableResult
    func sendNewTask() async -> UUID? {
        guard canSend,
              center.providerAndModel(modelID: selectedModelID) != nil
        else { return nil }
        let goal = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = attachments
        let sentText = draft
        // Identity of this send's claim on the field and the stored draft.
        // Text equality is not identity: the user can edit A → B → A while
        // the task is being created, and the success must keep that draft.
        let commit = ComposerSendCommit(
            draft: sentText,
            attachments: stagedAttachments,
            editorGeneration: draftGeneration,
            conversationID: draftStorageID
        )
        isSending = true
        isConsumingDraft = true
        defer {
            isSending = false
            isConsumingDraft = false
        }
        do {
            let conversationID: UUID
            let designLaunchBinding = designLaunchBindingProvider?()
            if let taskStarter {
                conversationID = try await taskStarter.startTask(
                    goal: goal, modelID: selectedModelID,
                    designLaunchBinding: designLaunchBinding
                )
            } else {
                conversationID = try await startTaskLive(
                    goal: goal, stagedAttachments: stagedAttachments,
                    designLaunchBinding: designLaunchBinding
                )
            }
            // Clear only what this send consumed: text typed while the task
            // was being created (and attachments staged in that window)
            // stays in the launchpad composer.
            draft = commit.draftAfterSuccess(
                currentDraft: draft,
                currentGeneration: draftGeneration
            )
            attachments = commit.attachmentsAfterSuccess(current: attachments)
            draftConversationID = UUID()
            commit.commitStore()
            actionError = nil
            // Build 230 first-message navigation: the durable identity exists
            // now. Refresh the overview (conversation list, run states, model
            // catalog) after returning, so Home can open the thread without
            // waiting on `reload()`/`workspaceCenter.reload()` — the slow
            // local-model catalog reconcile used to sit between the durable
            // commit and the navigation.
            Task { await load() }
            // The send may have been the only thing blocking the Shortcuts
            // FIFO. If the field emptied (newer human text keeps the queue
            // waiting), the next durable draft can now be reviewed.
            Task { await self.acceptShortcutInbox() }
            return conversationID
        } catch {
            // Failure keeps the draft and creates no lingering thread. The
            // store still holds the sent draft (an emptied field during the
            // send did not overwrite it), so text and attachments survive a
            // relaunch too.
            actionError = error.localizedDescription
            return nil
        }
    }

    /// Live path: one persistence transaction creates the conversation, run,
    /// first message, attachments and workspace link before provider I/O.
    /// The design launch binding (when present) is frozen in the SAME window,
    /// before the deferred run task can reach the provider.
    private func startTaskLive(
        goal: String,
        stagedAttachments: [AttachmentRef],
        designLaunchBinding: DesignLaunchBinding? = nil
    ) async throws -> UUID {
        guard let (provider, model) = center.providerAndModel(modelID: selectedModelID) else {
            throw FloeError.invalidConfiguration("No provider and model configured")
        }
        let started = try await center.startTask(
            goal: goal,
            title: Self.title(from: goal),
            provider: provider,
            model: model,
            workspaceID: selectedProjectID,
            attachments: stagedAttachments,
            executionMode: agentMode,
            initialPolicy: draftPolicy,
            newConversationID: draftConversationID,
            designLaunchBinding: designLaunchBinding,
            startOrigin: .explicitUserAction
        )
        return started.conversationID
    }

    /// Derives a conversation title from the goal (first ~40 chars).
    private static func title(from goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)) + "…"
    }
}
#endif
