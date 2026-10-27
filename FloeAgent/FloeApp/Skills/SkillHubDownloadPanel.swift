// FloeApp — Skill Hub download panel + persistent status chip (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation of the service-owned hub download job (see
// `SkillHubInstallService`). The job lives on `SkillsCenter`, so closing this
// sheet, scrolling the hub or popping the detail page never touches the
// running task; a repeated Get tap reopens the SAME job.
//
// Progress honesty: live stages show an INDETERMINATE spinner on the actual
// current stage; the list marks only stages that really completed. No
// fabricated byte percentage. The one human gate this panel owns is the
// FOCUSED added-scope confirmation for updates that expand the skill's
// declared access — it lists only the added items and offers Allow / Not
// now. Product copy stays short; signature/digest explanations live in the
// detail page's explicit Verification disclosure, never here.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// Sheet route so `SkillsView` can present the panel for one skill id.
struct SkillHubPanelRoute: Identifiable, Equatable {
    let skillID: String
    var id: String { skillID }
}

// MARK: - Persistent compact chip

/// Shown while a hub job is live or ended failed/cancelled: proof that the
/// download is service-owned and survives closing the panel.
struct SkillHubDownloadChip: View {
    @ObservedObject var center: SkillsCenter
    let skillID: String
    let open: () -> Void

    var body: some View {
        if let job = center.hubInstallJobs[skillID], job.isLive || job.canRetry {
            Button(action: open) {
                HStack(spacing: 10) {
                    if job.isLive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: job.phase == .cancelled ? "xmark.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(job.phase == .cancelled ? Color.secondary : Color.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(SkillHubCopy.stageTitle(job.phase))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skills.download.chip.\(skillID)")
        }
    }
}

// MARK: - Full panel

struct SkillHubInstallPanel: View {
    @ObservedObject var center: SkillsCenter
    let skillID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let job = center.hubInstallJobs[skillID] {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.displayName).font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                if job.isLive { ProgressView().controlSize(.small) }
                                Text(SkillHubCopy.stageTitle(job.phase))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("skills.download.panel.\(skillID)")
                    } header: {
                        Text(SkillHubCopy.downloadingTitle)
                    }
                    Section {
                        ForEach(Array(SkillHubInstallPhase.orderedStages.enumerated()), id: \.element) { index, stage in
                            SkillHubStageRow(stage: stage, state: job.stageStates()[index])
                                .accessibilityIdentifier("skills.download.stage.\(stage.rawValue)")
                        }
                        if job.phase == .failed, let detail = job.detail {
                            Text(detail).font(.footnote).foregroundStyle(.red)
                                .accessibilityIdentifier("skills.download.error.\(skillID)")
                        }
                    } header: {
                        Text(SkillHubCopy.localized("skills.hub.download.stages",
                              en: "Progress", zh: "进度"))
                    }
                    if job.phase == .awaitingScopeApproval {
                        SkillHubScopeApprovalSection(center: center, job: job)
                    }
                    Section {
                        if job.isLive && job.phase != .awaitingScopeApproval {
                            Button(role: .cancel) {
                                center.cancelHubInstall(id: skillID)
                            } label: {
                                Text(SkillHubCopy.cancel)
                            }
                            .accessibilityIdentifier("skills.download.cancel.\(skillID)")
                        } else if job.canRetry {
                            Button {
                                center.requestHubInstall(id: skillID)
                            } label: {
                                Text(SkillHubCopy.retry)
                            }
                            .accessibilityIdentifier("skills.download.retry.\(skillID)")
                        } else if job.phase == .installed {
                            Label(SkillHubCopy.stageTitle(.installed), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityIdentifier("skills.download.installed.\(skillID)")
                        }
                    }
                } else {
                    // No job for this id (never started or cleared): keep the
                    // sheet honest instead of showing a stale progress state.
                    ContentUnavailableView(SkillHubCopy.unavailable,
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(SkillHubCopy.close))
                }
            }
            .navigationTitle(SkillHubCopy.downloadingTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SkillHubCopy.close) { dismiss() }
                        .accessibilityIdentifier("skills.download.close.\(skillID)")
                }
            }
        }
    }
}

/// The ONE human gate inside the download flow: added access only, concise.
struct SkillHubScopeApprovalSection: View {
    @ObservedObject var center: SkillsCenter
    let job: SkillHubInstallJob

    var body: some View {
        Section {
            Text(SkillHubCopy.scopePrompt).font(.callout)
            ForEach(job.addedCapabilities, id: \.self) { item in
                Label(item, systemImage: "hand.raised").font(.callout)
            }
            ForEach(job.addedTools, id: \.self) { item in
                Label(item, systemImage: "wrench.and.screwdriver").font(.callout)
            }
            ForEach(job.addedPackages, id: \.self) { item in
                Label(item, systemImage: "shippingbox").font(.callout)
            }
            HStack {
                Button(SkillHubCopy.scopeAllow) {
                    center.resolveHubScopeApproval(id: job.skillID, generation: job.generation, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("skills.download.scope.allow.\(job.skillID)")
                Spacer()
                Button(SkillHubCopy.scopeDecline, role: .cancel) {
                    center.resolveHubScopeApproval(id: job.skillID, generation: job.generation, approved: false)
                }
                .accessibilityIdentifier("skills.download.scope.decline.\(job.skillID)")
            }
        } header: {
            Text(SkillHubCopy.stageTitle(.awaitingScopeApproval))
        }
        .accessibilityIdentifier("skills.download.scope.\(job.skillID)")
    }
}

/// One real stage row: checkmark when finished, indeterminate spinner while
/// the stage actually runs, hollow circle when pending or left unrun.
struct SkillHubStageRow: View {
    let stage: SkillHubInstallPhase
    let state: SkillHubStageRowState

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .active: ProgressView().controlSize(.small)
            case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
            }
            Text(SkillHubCopy.stageTitle(stage))
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
    }
}
#endif
