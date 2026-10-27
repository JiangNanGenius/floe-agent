// FloeApp — Skill Hub direct-download job service (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// The explicit human "Get / 获取" inside the native Skill Hub for an OFFICIAL
// signed audited catalog entry runs the EXISTING verified staging + install
// transaction as a SERVICE-owned job: the center, not any view or sheet,
// owns the task, so closing the download panel never interrupts it and a
// repeated tap reuses the same job.
//
// Consent model (user direction 2026-10-27):
// - A fresh human Get on a signed reviewed catalog entry IS the install
//   consent for that package's declared INTERNAL capability ceiling. It
//   installs directly through the same trusted official path that already
//   registers `installationGrants(declared:)` — no generic full inspector
//   detour. Real task/file/account/system permissions are unchanged: every
//   side effect still passes the normal per-run approval gates.
// - An UPDATE that adds scope is never silently bypassed: the job parks at a
//   focused added-access confirmation inside the native panel/detail, listing
//   ONLY the added capabilities/tools/packages. Decline or cancel stops
//   before the verified commit; nothing half-lands.
// - The model tool path (`installHubSkill` with ToolContext + approval grant)
//   and external URL/GitHub/folder/creator installs keep their EXISTING
//   review flows untouched.
//
// Progress honesty: no fabricated byte percentage anywhere. Live work shows
// an indeterminate spinner at the ACTUAL current stage; the stage list marks
// completed steps from what really ran.
//
// Pure decisions (consent flow, shelf row composition, compatibility
// verdict, detail-section presence) live in this file so focused regression
// tests pin them without booting the UI or network.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSkills

// MARK: - Bilingual copy helper (shared catalog first, inline fallback)

/// Mirrors the proven `SkillBatchCopy` pattern: prefer the shared bilingual
/// localization catalog, fall back to inline en/zh copy until the catalog
/// keys are registered (registration is handed to the integration owner).
enum SkillHubCopy {
    static func localized(_ key: String, en: String, zh: String) -> String {
        let value = FloeL10n.l(key)
        if value != key { return value }
        return FloeL10n.isChinese ? zh : en
    }

    static var downloadingTitle: String { localized("skills.hub.download.downloading", en: "Download", zh: "下载") }

    static func stageTitle(_ phase: SkillHubInstallPhase) -> String {
        switch phase {
        case .queued: localized("skills.hub.download.stage.queued", en: "Waiting", zh: "等待中")
        case .preparing: localized("skills.hub.download.stage.preparing", en: "Preparing", zh: "准备中")
        case .downloading: localized("skills.hub.download.stage.downloading", en: "Downloading", zh: "正在下载")
        case .checking: localized("skills.hub.download.stage.checking", en: "Checking", zh: "正在检查")
        case .installing: localized("skills.hub.download.stage.installing", en: "Installing", zh: "正在安装")
        case .awaitingScopeApproval: localized("skills.hub.scope.title", en: "Needs new access", zh: "需要新增访问权限")
        case .installed: localized("skills.hub.download.installed", en: "Installed", zh: "已安装")
        case .failed: localized("skills.hub.download.failed", en: "Install failed", zh: "安装失败")
        case .cancelled: localized("skills.hub.download.cancelled", en: "Cancelled", zh: "已取消")
        }
    }

    static var cancel: String { localized("action.cancel", en: "Cancel", zh: "取消") }
    static var retry: String { localized("action.retry", en: "Retry", zh: "重试") }
    static var close: String { localized("action.close", en: "Close", zh: "关闭") }
    static var viewProgress: String { localized("skills.hub.download.open", en: "Show progress", zh: "查看进度") }

    static var scopeAllow: String { localized("skills.hub.scope.allow", en: "Allow", zh: "允许") }
    static var scopeDecline: String { localized("skills.hub.scope.decline", en: "Not now", zh: "暂不") }
    static var scopePrompt: String {
        localized("skills.hub.scope.prompt",
                  en: "This update requests new access for this skill.",
                  zh: "此更新为该技能申请新增访问权限。")
    }

    static var compatibilitySection: String { localized("skills.hub.compat.title", en: "Compatibility", zh: "兼容性") }
    static var compatibleReady: String { localized("skills.hub.compat.ready", en: "Compatible with this device", zh: "与当前设备兼容") }
    static func needsNewerApp(minimum: String) -> String {
        localized("skills.hub.compat.needs_newer", en: "Needs Floe %@ or newer", zh: "需要 Floe %@ 或更新版本")
            .replacingOccurrences(of: "%@", with: minimum)
    }
    static var unavailable: String { localized("skills.hub.unavailable", en: "Unavailable", zh: "暂不可用") }

    static var dependenciesSection: String { localized("skills.hub.dependencies", en: "Dependencies", zh: "依赖") }
    static var permissionsSection: String { localized("skills.review.permissions", en: "Access", zh: "访问权限") }
    static var toolsSection: String { localized("skills.review.tools", en: "Tools", zh: "工具") }
    static var changelogSection: String { localized("skills.hub.changelog", en: "Release notes", zh: "版本说明") }
    static var verificationSection: String { localized("skills.hub.verify", en: "Verification", zh: "签名验证") }
    static var dependencyPreparedNote: String {
        localized("skills.hub.dependencies.first_use",
                  en: "Dependencies are prepared on first use.",
                  zh: "依赖将在首次使用时准备。")
    }
    static var notInstalled: String { localized("skills.hub.state.not_installed", en: "Not installed", zh: "尚未安装") }
    static var installedEnabled: String { localized("skills.hub.state.installed_enabled", en: "Installed and enabled", zh: "已安装并启用") }
    static var installedDisabled: String { localized("skills.hub.state.installed_disabled", en: "Installed and disabled", zh: "已安装但已停用") }
    static func updateAvailable(to version: String) -> String {
        localized("skills.hub.state.update_to", en: "Update available: %@", zh: "可更新到：%@")
            .replacingOccurrences(of: "%@", with: version)
    }
    static var alreadyInstalled: String { localized("skills.hub.added", en: "Added", zh: "已添加") }
    static var existingOtherSource: String {
        localized("skills.hub.state.existing_other_source",
                  en: "This skill was installed from another source. Use its own update flow.",
                  zh: "该技能来自其他安装来源，请使用其自身的更新流程。")
    }
}

// MARK: - Job model

enum SkillHubInstallPhase: String, CaseIterable, Equatable, Sendable {
    case queued
    case preparing
    case downloading
    case checking
    case installing
    /// Parked for the focused added-scope decision inside the native panel.
    /// NOT terminal, NOT success, and the install stage has not run.
    case awaitingScopeApproval
    case installed
    case failed
    case cancelled

    /// The four real work stages shown in order by the panel. Each maps to
    /// code that actually runs between the reports: preparing = pinned
    /// publication re-check, downloading = the signed
    /// `CuratedSkillHub.stage` fetch+verify chain, checking = compatibility
    /// + dependency-declaration gate, installing = the existing single-writer
    /// commit transaction.
    static let orderedStages: [SkillHubInstallPhase] = [.preparing, .downloading, .checking, .installing]

    var isTerminal: Bool {
        switch self {
        case .installed, .failed, .cancelled: true
        default: false
        }
    }

    var isLive: Bool { !isTerminal }
}

enum SkillHubInstallOutcome: Equatable, Sendable {
    case installed
    /// The live row already carries the pinned publication content digest and
    /// the signed catalog offers nothing newer: honest no-op, no re-download.
    case alreadyInstalled
}

/// One service-owned hub download job. Identity is the catalog entry id:
/// a repeated tap while live (or parked at the scope decision) REUSES the
/// same job; a retry after failure keeps the same identity while bumping
/// `attempt` and the fencing `generation`, so stale callbacks from a
/// superseded run can never mutate published state.
struct SkillHubInstallJob: Equatable, Identifiable {
    let skillID: String
    let displayName: String
    var id: String { skillID }
    var attempt: Int
    var generation: Int
    var phase: SkillHubInstallPhase
    var detail: String?
    var cancelRequested: Bool
    var startedAt: Date
    /// Index of the furthest real work stage the pipeline actually reported
    /// in this attempt (nil until the first stage report). Stage rows render
    /// from this, never from a guess.
    var lastReportedStageIndex: Int?
    /// Added-scope facts shown by the focused confirmation while parked at
    /// `.awaitingScopeApproval`; empty in every other phase.
    var addedCapabilities: [String] = []
    var addedTools: [String] = []
    var addedPackages: [String] = []

    var isLive: Bool { phase.isLive }
    var isAwaitingScopeApproval: Bool { phase == .awaitingScopeApproval }
    var canRetry: Bool { phase == .failed || phase == .cancelled }

    /// The panel stage-list index for the current phase.
    var activeStageIndex: Int? {
        SkillHubInstallPhase.orderedStages.firstIndex(of: phase)
    }

    /// Truthful count of stages that actually completed (used for the
    /// "n / 4" line; never a fabricated byte percentage).
    var completedStageCount: Int {
        switch phase {
        case .installed: return SkillHubInstallPhase.orderedStages.count
        case .queued: return 0
        case .preparing, .downloading, .checking, .installing: return activeStageIndex ?? 0
        case .awaitingScopeApproval:
            // The first three stages ran; installing has NOT.
            return SkillHubInstallPhase.orderedStages.firstIndex(of: .installing) ?? 3
        case .failed, .cancelled:
            guard let reached = lastReportedStageIndex else { return 0 }
            // A stage that stopped part-way never counts as completed.
            return reached
        }
    }
}

enum SkillHubStageRowState: Equatable { case pending, active, done }

extension SkillHubInstallJob {
    /// Deterministic per-stage render states: queued → all pending; live
    /// stage N → 0..N-1 done, N active, rest pending; installed → all done;
    /// parked at the scope decision → the three verified stages done, the
    /// install stage pending (approval is NOT completion); failed/cancelled →
    /// done strictly before the furthest stage actually reached.
    func stageStates() -> [SkillHubStageRowState] {
        SkillHubInstallPhase.orderedStages.indices.map { index in
            switch phase {
            case .installed: return .done
            case .queued: return .pending
            case .preparing, .downloading, .checking, .installing:
                guard let current = activeStageIndex else { return .pending }
                if index < current { return .done }
                if index == current { return .active }
                return .pending
            case .awaitingScopeApproval:
                return index < completedStageCount ? .done : .pending
            case .failed, .cancelled:
                return index < completedStageCount ? .done : .pending
            }
        }
    }
}

// MARK: - Consent decision (pure, the review-bypass boundary of this feature)

/// Pure consent policy for the human hub Get, evaluated on the facts the
/// verified staging already computed. Nothing here can be steered by the
/// catalog alone — the caller must first pass the signature/digest/review
/// chain and the device compatibility check.
enum SkillHubConsentDecision: Equatable {
    /// First install of a signed audited entry: the explicit human Get is
    /// consent to the declared internal capability ceiling; the EXISTING
    /// official path registers `installationGrants(declared:)` and no
    /// generic inspector runs.
    case directFreshInstall
    /// Update with no grant expansion: proceed through the existing
    /// reviewed-transaction code without any inspector.
    case directUpdate
    /// Update that ADDS scope: never silently bypassed — park for the
    /// focused added-access confirmation (only the added lists are shown).
    case requiresScopeApproval(addedCapabilities: [String], addedTools: [String], addedPackages: [String])

    static func decide(existingRow: Bool,
                       permissionDeltaRequiresApproval: Bool,
                       missingCapabilities: [String],
                       missingTools: [String],
                       missingPackages: [String]) -> SkillHubConsentDecision {
        guard existingRow else {
            // Fresh human Get: the declared internal ceiling is covered by
            // the user's explicit tap. A brand-new skill has NO grants yet,
            // so its delta is always "everything declared" — routing that to
            // the full inspector is the exact build-301 complaint.
            return .directFreshInstall
        }
        if permissionDeltaRequiresApproval {
            return .requiresScopeApproval(addedCapabilities: missingCapabilities,
                                          addedTools: missingTools,
                                          addedPackages: missingPackages)
        }
        return .directUpdate
    }

    /// A parked scope decision is a human action; anything stale (a
    /// superseded generation, an unknown skill, a job that already moved on)
    /// resolves to "not approved" so the job stops BEFORE the commit.
    static func approvalAllowed(pending: Bool, approved: Bool) -> Bool {
        pending && approved
    }
}

// MARK: - Coordinator (service-owned engine, injected pipeline keeps it testable)

@MainActor
final class SkillHubInstallCoordinator {
    struct PipelineContext {
        let skillID: String
        let generation: Int
        /// Phase reports are generation-fenced by the coordinator; a stale
        /// run's callbacks are dropped, not applied.
        let report: (SkillHubInstallPhase, String?) -> Void
        /// Cooperative ABANDONMENT check for this exact attempt: true when
        /// the user requested cancel, when a newer attempt/terminal state has
        /// replaced this generation, or when the job is no longer live. Every
        /// production pipeline MUST consult it before beginning pre-commit
        /// side effects and at every stage boundary; once the verified commit
        /// transaction has started, the honest result stands even if a cancel
        /// arrived after entry.
        let isCancelRequested: () -> Bool
    }

    typealias Pipeline = (PipelineContext) async throws -> SkillHubInstallOutcome

    enum Decision: Equatable {
        case started
        /// Repeated tap on the same live (or successfully terminal) job.
        case reused
        /// Another catalog entry currently owns the single-writer service.
        case busyWithOther(String)
    }

    private(set) var jobs: [String: SkillHubInstallJob] = [:]
    var onChange: (([String: SkillHubInstallJob]) -> Void)?

    private var generations: [String: Int] = [:]
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var scopeContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

    init(onChange: (([String: SkillHubInstallJob]) -> Void)? = nil) {
        self.onChange = onChange
    }

    func job(for skillID: String) -> SkillHubInstallJob? { jobs[skillID] }

    @discardableResult
    func request(skillID: String, displayName: String, pipeline: @escaping Pipeline) -> Decision {
        if let existing = jobs[skillID] {
            switch existing.phase {
            case .queued, .preparing, .downloading, .checking, .installing, .awaitingScopeApproval:
                // Coalesce only LIVE attempts into the same job.
                return .reused
            case .installed, .failed, .cancelled:
                // TERMINAL jobs never suppress a fresh request. Installed
                // STORAGE and the CURRENT publication are the authority:
                // after an uninstall in the same session, or when the signed
                // catalog publishes a newer version, the next Get must be
                // able to start a new attempt of the same identity. The
                // pipeline's pre-download alreadyInstalled guard (live row
                // + matching pinned digest + nothing newer) is what prevents
                // a needless re-download, not a stale published job.
                break
            }
        }
        if let live = jobs.values.first(where: { $0.isLive }), live.skillID != skillID {
            return .busyWithOther(live.skillID)
        }
        let attempt = (jobs[skillID]?.attempt ?? 0) + 1
        let generation = (generations[skillID] ?? 0) + 1
        generations[skillID] = generation
        let job = SkillHubInstallJob(skillID: skillID, displayName: displayName,
                                     attempt: attempt, generation: generation,
                                     phase: .queued, detail: nil,
                                     cancelRequested: false, startedAt: Date(),
                                     lastReportedStageIndex: nil)
        publish(job)
        // A scheduled-but-not-yet-started previous run must never be dropped
        // unjoined (e.g. an attempt cancelled while still `.queued`): the new
        // task first awaits the retired execution, then runs its own stages.
        let retired: [Task<Void, Never>] = runningTasks[skillID].map { [$0] } ?? []
        let task = Task { [weak self] in
            for old in retired { await old.value }
            let outcome: SkillHubInstallPhase
            let detail: String?
            do {
                guard let self else { return }
                let result = try await pipeline(PipelineContext(
                    skillID: skillID,
                    generation: generation,
                    report: { [weak self] phase, note in
                        self?.applyReport(skillID: skillID, generation: generation, phase: phase, note: note)
                    },
                    isCancelRequested: { [weak self] in
                        // The attempt is abandoned the moment the stored job
                        // is no longer exactly THIS live, uncancelled attempt:
                        // a cancel (even published before the task started),
                        // a superseded generation, or a terminal state all
                        // refuse pre-commit side effects.
                        guard let current = self?.jobs[skillID] else { return true }
                        return current.generation != generation || !current.isLive || current.cancelRequested
                    }
                ))
                switch result {
                case .installed:
                    outcome = .installed; detail = nil
                case .alreadyInstalled:
                    outcome = .installed
                    detail = SkillHubCopy.alreadyInstalled
                }
            } catch is CancellationError {
                outcome = .cancelled; detail = nil
            } catch {
                if Task.isCancelled { outcome = .cancelled; detail = nil }
                else { outcome = .failed; detail = error.localizedDescription }
            }
            self?.finish(skillID: skillID, generation: generation, phase: outcome, detail: detail)
            // Keep a cancelled/parked task joinable until execution really
            // exits; a superseded attempt must not clear the newer handle.
            if self?.generations[skillID] == generation {
                self?.runningTasks[skillID] = nil
            }
        }
        runningTasks[skillID] = task
        return .started
    }

    /// Request cancellation at the next stage boundary. A queued job finalizes
    /// immediately and a parked scope decision resolves as "not approved";
    /// once the verified commit transaction has started, the job honestly
    /// runs to `installed`. Cancellation is boundary-only ON PURPOSE: the
    /// Task is never force-cancelled, so a half-written commit cannot be
    /// interrupted mid-transaction. The flag is PUBLISHED to the stored job
    /// before any terminal transition, so a run scheduled but not yet started
    /// (or a superseded attempt) observes abandonment at its first check and
    /// refuses pre-commit side effects. A cancellation arriving after the
    /// commit actually ran keeps the honest installed result.
    func cancel(skillID: String) {
        guard var job = jobs[skillID], job.isLive else { return }
        job.cancelRequested = true
        publish(job)
        if job.phase == .awaitingScopeApproval {
            resolveScopeApproval(skillID: skillID, generation: job.generation, approved: false)
        }
        if job.phase == .queued || job.phase == .awaitingScopeApproval {
            finish(skillID: skillID, generation: job.generation, phase: .cancelled, detail: nil)
        }
    }

    /// Park the current attempt at the focused added-scope confirmation and
    /// wait for the human decision. Returns the decision; a superseded or
    /// unknown generation is honestly "not approved".
    func requestScopeApproval(context: PipelineContext,
                              addedCapabilities: [String],
                              addedTools: [String],
                              addedPackages: [String]) async -> Bool {
        guard var job = jobs[context.skillID], job.generation == context.generation, job.isLive,
              !job.cancelRequested else {
            return false
        }
        job.phase = .awaitingScopeApproval
        job.addedCapabilities = addedCapabilities
        job.addedTools = addedTools
        job.addedPackages = addedPackages
        publish(job)
        let key = "\(context.skillID):\(context.generation)"
        return await withCheckedContinuation { continuation in
            scopeContinuations[key] = continuation
        }
    }

    /// The panel's Allow / Not-now buttons. Only the CURRENT parked
    /// generation resolves; anything stale is a no-op (stale callback fence).
    func resolveScopeApproval(skillID: String, generation: Int, approved: Bool) {
        let key = "\(skillID):\(generation)"
        guard let continuation = scopeContinuations.removeValue(forKey: key) else { return }
        continuation.resume(returning: SkillHubConsentDecision.approvalAllowed(pending: true, approved: approved))
    }

    /// Wait for the in-flight pipeline of one skill (test seam; also safe in
    /// the UI when a sheet wants the settled state).
    func settle(skillID: String) async {
        let task = runningTasks[skillID]
        await task?.value
    }

    private func applyReport(skillID: String, generation: Int, phase: SkillHubInstallPhase, note: String?) {
        guard var job = jobs[skillID], job.generation == generation, job.isLive else { return }
        // A pending cancel request is kept as-is: the pipeline observes the
        // flag and throws at its next stage boundary.
        job.phase = phase
        job.lastReportedStageIndex = SkillHubInstallPhase.orderedStages.firstIndex(of: phase)
            ?? job.lastReportedStageIndex
        job.detail = note
        publish(job)
    }

    private func finish(skillID: String, generation: Int, phase: SkillHubInstallPhase, detail: String?) {
        // Stale callbacks (superseded generation) AND transitions onto a
        // job that already reached a terminal state are dropped: a late
        // pipeline result can never rewrite a user-visible cancelled or
        // failed outcome, exactly like the published-snapshot fence.
        guard var job = jobs[skillID], job.generation == generation, job.isLive else { return }
        // The verified commit, once entered, always completes honestly:
        // a cancel requested mid-transaction is reported as superseded by
        // the committed outcome (installed), never as a fake rollback.
        job.phase = phase
        job.detail = detail
        // Clear any leftover scope-approval presentation on terminal moves.
        job.addedCapabilities = []
        job.addedTools = []
        job.addedPackages = []
        publish(job)
    }

    private func publish(_ job: SkillHubInstallJob) {
        jobs[job.skillID] = job
        onChange?(jobs)
    }
}

// MARK: - Shelf row composition policy (one decision per shelf, never per item)

/// The build-301 feedback: a per-item `ViewThatFits` flipped some rows in the
/// SAME shelf (Office got the stacked CTA, PDF stayed inline), producing
/// inconsistent heights and misaligned actions. The composition is therefore
/// decided ONCE from the shelf's effective column width and applied to every
/// row of that shelf.
enum SkillHubRowLayout {
    /// Minimum real column width (points, excluding card padding) at which
    /// icon + text + trailing CTA fit inline without stealing the whole line
    /// from the title. Below it — or at accessibility text sizes — EVERY row
    /// of the shelf uses the stacked composition.
    static let minimumInlineColumnWidth: CGFloat = 300

    static func prefersInlineCTA(columnWidth: CGFloat, isAccessibilityText: Bool) -> Bool {
        !isAccessibilityText && columnWidth >= minimumInlineColumnWidth
    }

    /// Effective per-column width for a shelf: available grid width minus the
    /// inter-column gutters, divided by the column count.
    static func columnWidth(gridWidth: CGFloat, columns: Int, gutter: CGFloat) -> CGFloat {
        let count = max(1, columns)
        return max(0, (gridWidth - gutter * CGFloat(count - 1)) / CGFloat(count))
    }
}

// MARK: - Compatibility verdict (from the signed card offer only)

enum SkillHubCompatibilityVerdict: Equatable {
    case compatible
    case needsNewerApp(minimum: String)
    case unavailable(reason: String)
    /// No signed offer data for this row (e.g. a bundled guide or an
    /// external install): the page must not render any compatibility claim.
    case unknown

    init(offer: CuratedSkillHub.OfferState?) {
        guard let offer else { self = .unknown; return }
        switch offer {
        case .installable: self = .compatible
        case .simulatedFixture: self = .unavailable(reason: SkillHubCopy.unavailable)
        case .incompatibleApp(let minimum): self = .needsNewerApp(minimum: minimum)
        case .unavailable(let reason): self = .unavailable(reason: reason)
        }
    }
}

// MARK: - Detail section policy (verified metadata only, never invented)

enum SkillHubDetailSection: String, CaseIterable {
    case dependencies
    case permissions
    case tools
    case changelog
    case verification
}

/// Pure presence decision: a section exists exactly when the signed feed /
/// verified catalog carries the data. Missing values hide the section; the
/// page never renders a placeholder or an inferred fact.
enum SkillHubDetailSections {
    static func present(hasPythonPlanOrDependencies: Bool,
                        hasReviewedCapabilities: Bool,
                        hasReviewedTools: Bool,
                        hasReleaseNoteOrReviewDate: Bool,
                        hasSignedVerificationFacts: Bool) -> [SkillHubDetailSection] {
        var sections: [SkillHubDetailSection] = []
        if hasPythonPlanOrDependencies { sections.append(.dependencies) }
        if hasReviewedCapabilities { sections.append(.permissions) }
        if hasReviewedTools { sections.append(.tools) }
        if hasReleaseNoteOrReviewDate { sections.append(.changelog) }
        if hasSignedVerificationFacts { sections.append(.verification) }
        return sections
    }
}
#endif
