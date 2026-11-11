// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloeTools

/// Trusted control surface for inline assistant-body timer cards. The real
/// implementation is `SystemAlarmService`; the AppEnvironment accessor patch
/// (primary-owned) vends it through the environment. A nil controller fails
/// closed — the card renders no controls.
protocol SystemAlarmControlling: Sendable {
    func timerStatus(owner: SystemAlarmOwner, alarmID: UUID) async throws -> SystemAlarmTimerStatus
    func controlTimer(
        owner: SystemAlarmOwner,
        alarmID: UUID,
        action: SystemAlarmTimerAction,
        expectedRevision: UInt64,
        cancellation: CancellationToken?
    ) async throws -> SystemAlarmTimerStatus
    /// Emits whenever the native alarm set may have changed (pause/resume/
    /// fire/stop, including Live Activity controls made elsewhere). Bounded
    /// and event-driven — never a per-second stream — so a card refresh is
    /// one authoritative status read per real native change.
    var timerUpdates: AsyncStream<Void> { get async }
}

extension SystemAlarmService: SystemAlarmControlling {}

private struct SystemAlarmControllerKey: EnvironmentKey {
    static let defaultValue: (any SystemAlarmControlling)? = nil
}

extension EnvironmentValues {
    /// Trusted native timer controller for inline cards (AppEnvironment
    /// accessor patch is root-owned; nil until integrated, then fail-closed).
    var systemAlarmController: (any SystemAlarmControlling)? {
        get { self[SystemAlarmControllerKey.self] }
        set { self[SystemAlarmControllerKey.self] = newValue }
    }
}

/// The live native countdown card shown inside an assistant answer. Backed by
/// the exact successful `apple.alarm.schedule` tool receipt and the actual
/// owned native alarm — never by model text or a timestamp-only countdown.
/// Per-second ticking is scoped to this card's own label (no chat rerender),
/// and external native changes (Live Activity pause/resume/fire, reopen)
/// refresh the card through the event-driven `timerUpdates` stream.
struct InlineTimerCard: View {
    let source: InlineTimerCardSource

    @Environment(\.chatInlineContentScope) private var scope
    @Environment(\.systemAlarmController) private var controller
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var phase: Phase = .loading
    @State private var status: SystemAlarmTimerStatus?
    @State private var binding: NativeTimerBinding?
    @State private var changedElsewhere = false
    @State private var busyElsewhere = false
    @State private var confirmCancel = false
    @State private var refreshToken = 0
    @State private var resolutionGeneration = UUID()
    @State private var controlID: UUID?
    @State private var controlCancellation: CancellationToken?

    private enum Phase: Equatable {
        case loading
        case ready(CardPhase)
        case unavailable
        case busy
    }

    private typealias CardPhase = InlineTimerCardPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("chat.timer.syncing")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            case .unavailable:
                Label("chat.timer.unavailable", systemImage: "timer.slash")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            case .busy:
                HStack(spacing: 8) {
                    Text("chat.timer.syncing").font(.callout).foregroundStyle(.secondary)
                    Button(IDELanguageRunText.t("重试", "Retry")) { refreshToken &+= 1 }
                        .frame(minWidth: 44, minHeight: 44)
                }
            case .ready(let cardPhase):
                cardBody(cardPhase)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.inlineTimer")
        .confirmationDialog(
            "chat.timer.cancel_title",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("chat.timer.cancel", role: .destructive) {
                Task { await control(.cancel) }
            }
        } message: {
            Text("chat.timer.cancel_message")
        }
        .task(id: taskID(refresh: refreshToken)) {
            await resolve()
        }
        .task(id: taskID(refresh: 0)) {
            // Refresh on REAL native changes only (Live Activity controls,
            // fire/stop, reconcile): one authoritative status read per
            // change, never a polling loop.
            guard let controller else { return }
            for await _ in await controller.timerUpdates {
                guard !Task.isCancelled else { return }
                await resolve()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            // Re-read after backgrounding: external native changes that
            // happened while away are reflected on return.
            guard newValue == .active else { return }
            refreshToken &+= 1
        }
        .onChange(of: source.creationID) { _, _ in invalidateControl() }
        .onChange(of: scope) { _, _ in invalidateControl() }
        .onDisappear { invalidatePendingWork() }
    }

    @ViewBuilder
    private func cardBody(_ cardPhase: CardPhase) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "timer")
                        .font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.body).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        timerValue(cardPhase)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer(minLength: 0)
                    controls(cardPhase)
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                    timerValue(cardPhase)
                }
                Spacer(minLength: 8)
                controls(cardPhase)
            }
        }
        if changedElsewhere {
            Text("chat.timer.changed_elsewhere")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if busyElsewhere {
            Text(IDELanguageRunText.t("计时器正在更新，请稍后重试。", "The timer is updating. Try again shortly."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The authoritative remaining-time surface. The LIVE form hands the
    /// native fireDate to the label, which computes against the TimelineView
    /// clock per tick — a frozen snapshot interval is never re-rendered as if
    /// it were moving. Missing native timeline renders syncing, never 00:00.
    @ViewBuilder
    private func timerValue(_ cardPhase: CardPhase) -> some View {
        switch cardPhase {
        case .running:
            if let fireDate = status?.snapshot?.fireDate {
                LiveCountdownLabel(fireDate: fireDate)
            } else {
                Text("chat.timer.syncing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .paused:
            if let snapshot = status?.snapshot,
               let remaining = InlineTimerBodyProjection.remainingSeconds(snapshot: snapshot, at: Date()) {
                HStack(spacing: 6) {
                    StaticCountdownLabel(remaining: remaining)
                    Text("chat.timer.paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("chat.timer.syncing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .finished:
            Text("chat.timer.finished")
                .font(.title3)
                .foregroundStyle(.primary)
        case .cancelled:
            Text("chat.timer.cancelled")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .unknown:
            Text("chat.timer.syncing")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(_ cardPhase: CardPhase) -> some View {
        HStack(spacing: 2) {
            if cardPhase == .running {
                Button("apple.alarm.pause", systemImage: "pause.fill") {
                    Task { await control(.pause) }
                }
                .labelStyle(.iconOnly)
                .cardControlButton()
            }
            if cardPhase == .paused {
                Button("apple.alarm.resume", systemImage: "play.fill") {
                    Task { await control(.resume) }
                }
                .labelStyle(.iconOnly)
                .cardControlButton()
            }
            if cardPhase == .running || cardPhase == .paused || cardPhase == .unknown {
                Button("chat.timer.cancel", systemImage: "xmark") {
                    confirmCancel = true
                }
                .labelStyle(.iconOnly)
                .tint(.red)
                .cardControlButton()
            }
        }
        .disabled(controlID != nil)
    }

    private var title: String {
        binding?.label ?? String(localized: "chat.timer.default_title")
    }

    private func cardPhase(for status: SystemAlarmTimerStatus) -> CardPhase {
        InlineTimerBodyProjection.cardPhase(for: status)
    }

    // MARK: - Resolve + verify (fail closed)

    private struct TaskID: Hashable {
        var source: InlineTimerCardSource
        var scope: ChatInlineContentScope?
        var controllerAvailable: Bool
        var refresh: Int
    }

    private func taskID(refresh: Int) -> TaskID {
        .init(source: source, scope: scope, controllerAvailable: controller != nil, refresh: refresh)
    }

    private func invalidatePendingWork() {
        resolutionGeneration = UUID()
        invalidateControl()
    }

    private func invalidateControl() {
        controlCancellation?.cancel()
        controlCancellation = nil
        controlID = nil
    }

    private func unavailable() {
        status = nil
        binding = nil
        phase = .unavailable
    }

    private func resolve() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        resolutionGeneration = generation
        guard let scope, !scope.isTemporary, let controller else {
            unavailable()
            return
        }
        guard let binding = await loadBinding() else {
            if resolutionGeneration == generation, !Task.isCancelled { unavailable() }
            return
        }
        // Owner derived from verified durable facts (the binding was read
        // from digest-checked artifact bytes; the ledger is the authority).
        let owner = SystemAlarmOwner(context: ToolContext(
            runID: source.runID, toolCallID: binding.producerCallID,
            cancellation: CancellationToken(), conversationID: scope.conversationID))
        do {
            let current = try await readStatus(controller: controller, owner: owner, alarmID: binding.timerID)
            guard resolutionGeneration == generation, !Task.isCancelled else { return }
            guard verify(current, binding: binding, conversationID: scope.conversationID) else {
                unavailable()
                return
            }
            self.binding = binding
            busyElsewhere = false
            status = current
            phase = .ready(cardPhase(for: current))
        } catch SystemAlarmError.operationInProgress {
            guard resolutionGeneration == generation, !Task.isCancelled else { return }
            busyElsewhere = true
            if status == nil { phase = .busy }
        } catch {
            if resolutionGeneration == generation, !Task.isCancelled { unavailable() }
        }
    }

    /// One bounded retry covers an overlapping status/control read without
    /// turning a transient service gate into permanent unavailability.
    private func readStatus(controller: any SystemAlarmControlling, owner: SystemAlarmOwner,
                            alarmID: UUID) async throws -> SystemAlarmTimerStatus {
        do { return try await controller.timerStatus(owner: owner, alarmID: alarmID) }
        catch SystemAlarmError.operationInProgress {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            return try await controller.timerStatus(owner: owner, alarmID: alarmID)
        }
    }

    /// Loads the binding bytes with the same digest-checked, no-follow read
    /// as every other inline artifact, then decodes it.
    private func loadBinding() async -> NativeTimerBinding? {
        let currentSource = source
        let worker = Task.detached(priority: .utility) { () -> NativeTimerBinding? in
            guard let root = try? FloeArtifactStore.root(),
                  let verified = try? VerifiedChatInlineArtifact.load(
                    currentSource.artifact, runID: currentSource.runID, tool: currentSource.tool, root: root),
                  verified.data.count <= NativeTimerBinding.maximumBytes else { return nil }
            return try? JSONDecoder().decode(NativeTimerBinding.self, from: verified.data)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Every binding field must match the durable ledger row the service just
    /// returned; any foreign/deleted/run-mismatch/receipt-mismatch/incarnation
    /// drift fails closed.
    private func verify(
        _ status: SystemAlarmTimerStatus,
        binding: NativeTimerBinding,
        conversationID: UUID
    ) -> Bool {
        InlineTimerBodyProjection.verifyBinding(binding, status: status,
            conversationID: conversationID, runID: source.runID, producerCallID: source.producerCallID)
    }

    // MARK: - Controls

    private func control(_ action: SystemAlarmTimerAction) async {
        guard controlID == nil, let status, let binding, let scope, !scope.isTemporary,
              let controller, verify(status, binding: binding, conversationID: scope.conversationID) else { return }
        let operationID = UUID(), cancellation = CancellationToken()
        controlID = operationID
        controlCancellation = cancellation
        defer {
            if controlID == operationID {
                controlID = nil
                controlCancellation = nil
            }
        }
        let owner = SystemAlarmOwner(record: status.record)
        do {
            let updated = try await controller.controlTimer(
                owner: owner, alarmID: status.record.id, action: action,
                expectedRevision: status.revision, cancellation: cancellation)
            guard controlID == operationID, !Task.isCancelled else { return }
            guard verify(updated, binding: binding, conversationID: scope.conversationID) else {
                unavailable()
                return
            }
            changedElsewhere = false
            busyElsewhere = false
            self.status = updated
            phase = .ready(cardPhase(for: updated))
        } catch SystemAlarmError.staleControlRevision {
            // The timer changed after our read (e.g. Live Activity control):
            // refresh once from fresh state; the retry uses the new revision.
            guard controlID == operationID, !Task.isCancelled else { return }
            changedElsewhere = true
            refreshToken &+= 1
        } catch SystemAlarmError.operationInProgress {
            guard controlID == operationID, !Task.isCancelled else { return }
            busyElsewhere = true
            refreshToken &+= 1
        } catch {
            if controlID == operationID, !Task.isCancelled { unavailable() }
        }
    }
}

// MARK: - Control button style (44pt hit targets, iPad first)

private struct CardControlButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private extension View {
    func cardControlButton() -> some View {
        modifier(CardControlButtonStyle())
    }
}

// MARK: - Countdown labels

/// Per-second live countdown scoped to this label: each TimelineView tick
/// recomputes remaining time from the AUTHORITATIVE native fireDate, so the
/// rest of the chat body is never re-rendered and the value never freezes.
private struct LiveCountdownLabel: View {
    let fireDate: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            Text(InlineTimerBodyProjection.clockString(max(0, fireDate.timeIntervalSince(context.date)))
                 ?? String(localized: "chat.timer.syncing"))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

}

/// Paused countdown: a fixed remaining value with no live ticking.
private struct StaticCountdownLabel: View {
    let remaining: TimeInterval

    var body: some View {
        Text(InlineTimerBodyProjection.clockString(remaining) ?? String(localized: "chat.timer.syncing"))
            .font(.title3.monospacedDigit())
            .foregroundStyle(.primary)
    }

}
#endif
