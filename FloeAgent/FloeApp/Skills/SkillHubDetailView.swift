// FloeApp — unified native Skill Hub detail page (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// One detail page for featured cards, category rows, skill names and
// already-added rows. Every rendered fact comes from the signature-verified
// catalog publication, the digest-verified installed row or the app's own
// bundled data — a section with no verified source data is HIDDEN, never
// placeholdered or invented. The Get action routes to the service-owned
// direct download job (official signed catalog) while installed rows keep
// the existing update/enable and upgrade-detail flows.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloePersistence
import FloeSkills

struct SkillHubDetailView: View {
    @ObservedObject var center: SkillsCenter
    let item: SkillHubDisplayItem
    /// Routed through the hub's existing store-action dispatcher (official
    /// catalog entries start/reopen the service-owned download job; update,
    /// enable and bundled rows keep their current flows).
    let onStoreAction: (String) -> Void
    /// Opens the existing GitHub upgrade detail for the installed row.
    let onOpenUpdateDetails: () -> Void

    private var curatedEntry: CuratedSkillEntry? {
        center.curatedCards.first(where: { $0.entry.id == item.id })?.entry
    }
    private var curatedOffer: CuratedSkillHub.OfferState? {
        center.curatedCards.first(where: { $0.entry.id == item.id })?.offer
    }
    private var installed: PersistedSkill? {
        center.installed.first(where: { $0.id == item.id })
    }
    private var job: SkillHubInstallJob? { center.hubInstallJobs[item.id] }

    /// Live action state: never the frozen list-row snapshot when richer
    /// truth (a live job, the installed row) is available.
    private var action: SkillHubDisplayItem.Action {
        if let installed {
            if center.availableVersion(for: installed) != nil { return .update }
            return installed.status == "enabled" ? .added : .enable
        }
        guard let card = center.curatedCards.first(where: { $0.entry.id == item.id }) else {
            return item.action
        }
        return card.showsInstallAction ? .get : .unavailable
    }

    private var verdict: SkillHubCompatibilityVerdict {
        SkillHubCompatibilityVerdict(offer: curatedOffer)
    }

    private var installStateText: String {
        // Installed STORAGE is the authority. A terminal job snapshot is
        // never a state fallback: after an uninstall the row is gone and the
        // page must honestly say "Not installed" again.
        if let installed, let newer = center.availableVersion(for: installed) {
            return SkillHubCopy.updateAvailable(to: newer)
        }
        if let installed {
            return installed.status == "enabled" ? SkillHubCopy.installedEnabled : SkillHubCopy.installedDisabled
        }
        return SkillHubCopy.notInstalled
    }

    private var sections: [SkillHubDetailSection] {
        let entry = curatedEntry
        let installedReceipt = installed.flatMap { SkillsCenter.curatedReceipt(for: $0) }
        let hasReleaseNote = (entry.map {
            !$0.notes.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.notes.zhHans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false) || installedReceipt != nil
        return SkillHubDetailSections.present(
            hasPythonPlanOrDependencies: (entry?.runtime.pythonPackagesPlan.isEmpty == false),
            hasReviewedCapabilities: (entry.map { !$0.runtime.capabilities.isEmpty } ?? false),
            hasReviewedTools: (entry.map { !$0.runtime.tools.isEmpty } ?? false),
            hasReleaseNoteOrReviewDate: hasReleaseNote,
            hasSignedVerificationFacts: entry?.package != nil || installedReceipt != nil
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.title)
                            .foregroundStyle(item.category.tint)
                            .frame(width: 44, height: 44)
                            .background(item.category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.title2.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.category.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(item.summary).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tags = curatedEntry?.tags, !tags.isEmpty {
                        FlowingTags(tags: tags)
                    }
                }
                .accessibilityIdentifier("skills.detail.\(item.id)")
            }
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))

            Section("skills.hub.about") {
                LabeledContent(SkillHubCopy.localized("skills.hub.install_state",
                                                      en: "Status", zh: "安装状态"),
                               value: installStateText)
                    .accessibilityIdentifier("skills.detail.state.\(item.id)")
                if let version = versionText {
                    LabeledContent("skills.hub.version", value: version)
                }
                if installed != nil {
                    // The existing installed-row facts stay reachable from
                    // the unified page without duplicating that sheet.
                    LabeledContent("skills.update.installed", value: "v\(installed?.version ?? "")")
                        .accessibilityIdentifier("skills.detail.installedVersion.\(item.id)")
                    Button("skills.update.details", action: onOpenUpdateDetails)
                        .buttonStyle(.borderless)
                        .disabled(installed == nil || center.isWorking || center.isBatchRunning)
                        .accessibilityIdentifier("skills.detail.updateDetails.\(item.id)")
                }
                LabeledContent("skills.hub.publisher",
                               value: curatedEntry == nil ? "Floe" : CuratedSkillHub.publisher)
                if let source = sourceText {
                    LabeledContent("skills.hub.source", value: source)
                }
                if let license = curatedEntry?.upstream?.repositoryLicense, !license.isEmpty {
                    LabeledContent("skills.hub.license", value: license)
                }
                if curatedEntry != nil, let publication = center.curatedPublication {
                    LabeledContent("skills.hub.publication",
                                   value: String(publication.publicationCommit.prefix(12)))
                }
                compatibilityRow
            }

            ForEach(sections, id: \.self) { section in
                sectionView(section)
            }

            Section {
                if let job, job.isLive {
                    SkillHubInstallLiveSummary(job: job)
                    if job.phase == .awaitingScopeApproval {
                        SkillHubScopeApprovalSection(center: center, job: job)
                    } else {
                        HStack {
                            Button(SkillHubCopy.viewProgress) { onStoreAction(item.id) }
                                .buttonStyle(.bordered)
                            Button(SkillHubCopy.cancel, role: .cancel) { center.cancelHubInstall(id: item.id) }
                                .accessibilityIdentifier("skills.download.cancel.\(item.id)")
                        }
                    }
                } else if let job, job.canRetry {
                    HStack {
                        Button(SkillHubCopy.retry) { onStoreAction(item.id) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("skills.download.retry.\(item.id)")
                        if let detail = job.detail {
                            Text(detail).font(.footnote).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                } else {
                    Button(action.title) { onStoreAction(item.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!actionEnabledNow)
                        .accessibilityIdentifier("skills.detail.cta.\(item.id)")
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actionEnabledNow: Bool {
        switch action {
        case .unavailable: false
        case .enable: !center.isWorking && !center.isBatchRunning
        case .update: !center.isWorking && !center.updates.isRunning && !center.isBatchRunning
        case .added: false
        case .get:
            guard let card = center.curatedCards.first(where: { $0.entry.id == item.id }) else {
                return !center.isWorking && !center.isBatchRunning
            }
            // While a job is live the CTA stays enabled: tapping it reuses
            // the same job and reopens its panel (product direction).
            return card.showsInstallAction && !center.isWorking
                && !center.updates.isRunning && !center.isBatchRunning
        }
    }

    private var versionText: String? {
        if let entry = curatedEntry { return entry.version }
        return installed?.version ?? center.catalogPackages[item.id]?.version
    }

    private var sourceText: String? {
        if let upstream = curatedEntry?.upstream {
            return "\(upstream.repository) · \(String(upstream.commit.prefix(12)))"
        }
        if let firstParty = curatedEntry?.firstParty {
            return "\(firstParty.repository) · \(String(firstParty.commit.prefix(12)))"
        }
        if installed != nil, let source = installed?.sourceURL, !source.isEmpty {
            return source
        }
        return nil
    }

    @ViewBuilder
    private var compatibilityRow: some View {
        switch verdict {
        case .unknown:
            EmptyView()
        case .compatible:
            Label(SkillHubCopy.compatibleReady, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .needsNewerApp(let minimum):
            Label(SkillHubCopy.needsNewerApp(minimum: minimum), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        case .unavailable(let reason):
            Label(reason.isEmpty ? SkillHubCopy.unavailable : reason, systemImage: "circle.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SkillHubDetailSection) -> some View {
        let entry = curatedEntry
        switch section {
        case .dependencies:
            DisclosureGroup(SkillHubCopy.dependenciesSection) {
                ForEach(entry?.runtime.pythonPackagesPlan ?? [], id: \.self) { spec in
                    Text(spec).font(.callout.monospaced())
                }
                Text(SkillHubCopy.dependencyPreparedNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .permissions:
            DisclosureGroup(SkillHubCopy.permissionsSection) {
                ForEach(entry?.runtime.capabilities ?? [], id: \.self) { capability in
                    Text(capability).font(.callout)
                }
            }
        case .tools:
            DisclosureGroup(SkillHubCopy.toolsSection) {
                ForEach(entry?.runtime.tools ?? [], id: \.self) { tool in
                    Text(tool).font(.callout)
                }
            }
        case .changelog:
            DisclosureGroup(SkillHubCopy.changelogSection) {
                if let entry, !entry.notes.value(preferredLanguages: Locale.preferredLanguages)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.notes.value(preferredLanguages: Locale.preferredLanguages))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reviewedAt = installed.flatMap({ SkillsCenter.curatedReceipt(for: $0) })?.reviewedAt {
                    LabeledContent(SkillHubCopy.localized("skills.hub.review_reviewedAt",
                                                          en: "Reviewed", zh: "审核时间"),
                                   value: reviewedAt)
                }
            }
        case .verification:
            DisclosureGroup(SkillHubCopy.verificationSection) {
                if let package = entry?.package {
                    LabeledContent("sha256", value: String(package.sha256.prefix(16)) + "…")
                    LabeledContent("contentDigest", value: String(package.contentDigest.prefix(16)) + "…")
                    LabeledContent(SkillHubCopy.localized("skills.hub.verify.size", en: "Package size", zh: "包大小"),
                                   value: package.size.formatted(.byteCount(style: .file)))
                }
                if let receipt = installed.flatMap({ SkillsCenter.curatedReceipt(for: $0) }) {
                    LabeledContent(SkillHubCopy.localized("skills.hub.verify.key", en: "Signing key", zh: "签名密钥"),
                                   value: receipt.feedSignatureKeyID)
                    LabeledContent(SkillHubCopy.localized("skills.hub.verify.review", en: "Review record", zh: "审核记录"),
                                   value: String(receipt.reviewSHA256.prefix(16)) + "…")
                }
            }
        }
    }
}

// MARK: - Small pieces

private struct FlowingTags: View {
    let tags: [String]
    var body: some View {
        // Simple wrap without depending on iOS 26-only layout APIs.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .combine)
    }
}

/// Inline live-job summary embedded on the detail page while a download job
/// runs; the full stage list stays on the panel. Indeterminate on purpose —
/// only the ACTUAL current stage is named, never a fake byte percentage.
struct SkillHubInstallLiveSummary: View {
    let job: SkillHubInstallJob
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(SkillHubCopy.stageTitle(job.phase))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("skills.detail.download.\(job.skillID)")
    }
}
#endif
