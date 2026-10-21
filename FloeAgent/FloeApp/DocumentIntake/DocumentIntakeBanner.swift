// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — compact system document-open status (S5 P3).
//
// One unobtrusive banner covers staging/import progress, a committed receipt,
// an explicit failure, and an interrupted import that needs a user decision.
// Copy names only what happened; queue identities and paths never appear.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct DocumentIntakeBanner: View {
    @ObservedObject var center: DocumentIntakeCenter
    var sceneID: String? = nil

    var body: some View {
        Group {
            if let activity = center.activity {
                activityCard(activity)
            } else if let notice = center.notice {
                noticeCard(notice)
            } else if let record = center.attentionRecords.first {
                attentionCard(record)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .animation(.snappy, value: center.activity)
        .animation(.snappy, value: center.notice)
        .accessibilityIdentifier("document.intake.banner")
    }

    private func activityCard(_ activity: DocumentIntakeActivity) -> some View {
        card {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(FloeL10n.l("document.intake.opening"))
                    .font(.subheadline.weight(.semibold))
                Text(activity.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(FloeL10n.l("share.intake.cancel")) {
                Task { await center.cancel(activity.id) }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityIdentifier("document.intake.cancel")
        }
    }

    private func noticeCard(_ notice: DocumentIntakeNotice) -> some View {
        card {
            Image(systemName: icon(for: notice.kind))
                .foregroundStyle(color(for: notice.kind))
            Text(notice.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if notice.canOpen {
                Button(FloeL10n.l("document.intake.open_result")) {
                    center.openCommittedResult(sceneID: sceneID)
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityIdentifier("document.intake.open")
            }
            if let eventID = notice.eventID, notice.canRetry {
                Button(FloeL10n.l("action.retry")) {
                    Task { await center.retry(eventID) }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityIdentifier("document.intake.retry")
            }
            Button {
                center.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(FloeL10n.l("common.close"))
            .accessibilityIdentifier("document.intake.close")
        }
    }

    private func attentionCard(_ record: DocumentIntakeRecord) -> some View {
        card {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(attentionMessage(for: record))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(FloeL10n.l("action.retry")) {
                Task { await center.retry(record.id) }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityIdentifier("document.intake.retry")
            Button(FloeL10n.l("share.intake.discard"), role: .destructive) {
                Task { await center.discard(record.id) }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityIdentifier("document.intake.discard")
        }
    }

    /// `.failed` keeps the specific importer reason; `.needsReview` is the
    /// ambiguous post-commit case and says so.
    private func attentionMessage(for record: DocumentIntakeRecord) -> String {
        switch record.state {
        case .failed:
            return record.failureDetail ?? record.failure?.message ?? DocumentIntakeFailure.importFailed.message
        case .cancelled:
            return DocumentIntakeFailure.cancelled.message
        default:
            return DocumentIntakeFailure.interrupted.message
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.25))
            )
    }

    private func icon(for kind: DocumentIntakeNotice.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(for kind: DocumentIntakeNotice.Kind) -> Color {
        switch kind {
        case .success: .green
        case .failure: .orange
        case .info: .secondary
        }
    }
}
#endif
