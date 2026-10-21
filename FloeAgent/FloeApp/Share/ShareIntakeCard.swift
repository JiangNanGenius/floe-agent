// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — compact reviewed-share card (S5 P1).
//
// Appears only while a durable share envelope is pending for this Home
// window. Adding is explicit and non-destructive: the existing draft is
// preserved, attachments are appended, and nothing is sent or run. The
// card has no deep-link, launch or task-creation action.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels

@MainActor
struct ShareIntakeCard: View {
    @ObservedObject var center: ShareIntakeCenter
    let destination: any ShareIntakeDestination

    @State private var showsDiscardConfirmation = false
    @State private var destinationHasText = false

    var body: some View {
        Group {
            if let envelope = center.pending.first {
                card(for: envelope)
            }
        }
        .onAppear { refreshDestinationState() }
        .onChange(of: center.pending.count) { _, _ in
            refreshDestinationState()
        }
    }

    // MARK: Card

    private func card(for envelope: ShareEnvelope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: envelope)
            if let preview = preview(for: envelope) {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .accessibilityIdentifier("home.share.intake.preview")
            }
            actions(for: envelope)
            status(for: envelope)
        }
        .padding(12)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(FloeTheme.primary.opacity(0.16))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.share.intake.card")
        .confirmationDialog(
            "share.intake.discard_confirm_title",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await center.discard(envelope) }
            } label: {
                Text("share.intake.discard_confirm")
            }
            Button(role: .cancel) {} label: {
                Text("share.intake.cancel")
            }
        } message: {
            Text("share.intake.discard_confirm_message")
        }
    }

    private func header(for envelope: ShareEnvelope) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title3)
                .foregroundStyle(FloeTheme.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("share.intake.pending_title")
                    .font(.subheadline.weight(.semibold))
                Text(FloeL10n.plural(
                    "share.intake.pending_count",
                    count: envelope.items.count
                ))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if center.pending.count > 1 {
                Text(verbatim: "+\(center.pending.count - 1)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(FloeL10n.l("share.intake.more_waiting", center.pending.count - 1))
            }
        }
    }

    private func actions(for envelope: ShareEnvelope) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await center.apply(envelope, to: destination)
                    refreshDestinationState()
                }
            } label: {
                Text(destinationHasText
                     ? FloeL10n.l("share.intake.add_to_draft")
                     : FloeL10n.l("share.intake.use"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(center.isWorking)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("home.share.intake.use")

            Button(role: .destructive) {
                showsDiscardConfirmation = true
            } label: {
                Text("share.intake.discard")
            }
            .buttonStyle(.bordered)
            .disabled(center.isWorking)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("home.share.intake.discard")

            Spacer(minLength: 0)

            if center.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("share.intake.working"))
            }
        }
    }

    @ViewBuilder
    private func status(for envelope: ShareEnvelope) -> some View {
        if outcomeApplies(to: envelope), let message = center.lastErrorMessage {
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.share.intake.status")
        } else if outcomeApplies(to: envelope), let message = outcomeMessage {
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("share.intake.pending_hint")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A status from the previous envelope must never describe a newly
    /// arrived share. `.empty` has no envelope and never matches.
    private func outcomeApplies(to envelope: ShareEnvelope) -> Bool {
        switch center.lastOutcome {
        case .applied(let id), .alreadyApplied(let id), .discarded(let id),
             .deferred(let id, _), .failed(let id, _):
            return id == envelope.id
        case .empty, nil:
            return false
        }
    }

    private var outcomeMessage: String? {
        guard let outcome = center.lastOutcome else { return nil }
        switch outcome {
        case .applied:
            return FloeL10n.l("share.intake.applied")
        case .alreadyApplied:
            return FloeL10n.l("share.intake.already_applied")
        case .discarded, .empty:
            return nil
        case .deferred(_, let reason):
            switch reason {
            case .composerBusy, .anotherShareInProgress:
                return FloeL10n.l("share.intake.deferred_busy")
            case .cancelled:
                return FloeL10n.l("share.intake.cancelled")
            case .unavailable:
                return FloeL10n.l("share.intake.unavailable")
            }
        case .failed(_, let message):
            return message
        }
    }

    private func preview(for envelope: ShareEnvelope) -> String? {
        let summary = ShareIntakeCenter.summary(for: envelope)
        if let textPreview = summary.textPreview {
            return textPreview
        }
        if !summary.fileNames.isEmpty {
            return summary.fileNames.prefix(2).joined(separator: " · ")
        }
        if summary.attachmentCount > 0 {
            return FloeL10n.l("share.intake.default_file_name")
        }
        return nil
    }

    private func refreshDestinationState() {
        destinationHasText = destination.shareIntakeSnapshot().hasText
    }
}
#endif
