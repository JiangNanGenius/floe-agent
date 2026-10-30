// FloeApp — Native task execution environment (move task) sheet.
//
// SPDX-License-Identifier: MPL-2.0
//
// One saved ordinary task's ACTUAL execution location, a selectable
// destination, and the read-only dependency/capability preflight before an
// explicit move. The sheet observes the injected center; dismissing it never
// cancels the service-owned migration job. No ETA and no synthetic progress
// percentage is shown: only the persisted phase and real prepared files.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeModels
import FloeEnvironments

/// One task's execution location and recoverable migration flow.
///
/// The primary owns `TaskExecutionEnvironmentCenter` and all persistence /
/// runtime wiring. This view only reads the published snapshot and calls the
/// existing `load`, `check`, `start`, `cancel`, `selectPrevious` entry points.
struct TaskExecutionEnvironmentView: View {
    private let environment: AppEnvironment
    private let conversationID: UUID
    @ObservedObject private var center: TaskExecutionEnvironmentCenter
    @Environment(\.dismiss) private var dismiss

    /// Local destination selection before/while the center checks it.
    @State private var selectionID: String?
    /// The destination whose Check produced the currently displayed preview.
    @State private var checkedChoiceID: String?
    /// Explicit acceptance for optional external Skill capability losses.
    @State private var acceptedLosses = false
    /// A Check is in flight. `load` also flips `checking`; this distinguishes
    /// a user-requested destination probe from initial reading.
    @State private var checkRequested = false
    /// A real Start request is in flight. The center publishes phases for
    /// migrations; this covers the initial binding step that has no persisted
    /// phase yet, so the control never looks idle after a tap.
    @State private var startRequested = false
    /// Migration revision whose fresh Check was requested in this sheet. A
    /// failed/precommit migration must be checked again before Start; a new
    /// failure revision invalidates the previous check.
    @State private var freshCheckRevision: Int64?
    /// Real container names for legacy session targets, when available.
    @State private var legacyNames: [String: String] = [:]

    init(environment: AppEnvironment, conversationID: UUID) {
        self.environment = environment
        self.conversationID = conversationID
        _center = ObservedObject(wrappedValue: environment.taskExecutionEnvironments)
    }

    // MARK: - Snapshot access

    private typealias Snapshot = TaskExecutionEnvironmentCenter.Snapshot
    private typealias Choice = TaskExecutionEnvironmentCenter.Choice

    private var snapshot: Snapshot? {
        center.snapshots[conversationID]
    }

    private var isChecking: Bool {
        checkRequested && (snapshot?.checking ?? false)
    }

    /// A migration that still owns the task. Failed migrations are active
    /// (the center resumes the same record); completed/cancelled are not.
    private var activeMigration: TaskEnvironmentMigration? {
        guard let migration = snapshot?.migration, !migration.phase.isTerminal else { return nil }
        return migration
    }

    /// The preview may only authorize a move for the destination that was
    /// actually checked, after the check finished without an error.
    private var visiblePreview: SkillMigrationPreview? {
        guard let snapshot,
              !snapshot.checking,
              snapshot.failure == nil,
              let selectionID,
              snapshot.choices.contains(where: { $0.id == selectionID }),
              selectionID == checkedChoiceID,
              snapshot.selectedChoiceID == selectionID,
              selectionID != currentChoiceID(in: snapshot) else { return nil }
        return snapshot.preview
    }

    var body: some View {
        NavigationStack {
            checkingObservedForm
        }
    }

    /// The form, its navigation chrome and each small group of snapshot
    /// observations are separate typed sub-expressions. This keeps the sheet
    /// identical on screen while avoiding one oversized `body` expression.
    private var baseForm: some View {
        Form {
            formSections
        }
        .navigationTitle(copy("任务运行位置", "Task Environment"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(copy("完成", "Done")) { dismiss() }
                    .accessibilityIdentifier("task.environment.done")
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var formSections: some View {
        if let snapshot {
            currentSection(snapshot)
            if let migration = activeMigration {
                migrationSection(migration, snapshot: snapshot)
            } else if snapshot.binding == nil {
                if snapshot.legacyChoices.isEmpty {
                    destinationSection(snapshot, initial: true)
                    if let preview = visiblePreview {
                        previewSections(preview, initial: true)
                        startSection(preview, snapshot: snapshot, initial: true)
                    }
                } else {
                    legacySection(snapshot)
                }
            } else {
                destinationSection(snapshot, initial: false)
                if let preview = visiblePreview {
                    previewSections(preview, initial: false)
                    startSection(preview, snapshot: snapshot, initial: false)
                }
            }
            if let failure = snapshot.failure,
               failure != snapshot.migration?.failure {
                failureSection(failure)
            }
        } else {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(copy("正在读取任务运行位置…", "Reading this task's environment…"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionObservedForm: some View {
        baseForm
            .onChange(of: snapshot?.selectedChoiceID) { _, id in
                guard let id else { return }
                selectionID = id
                if snapshot?.preview != nil {
                    checkedChoiceID = id
                }
            }
            .onChange(of: snapshot?.preview) { _, preview in
                // A new preflight replaces any previous acceptance.
                if preview != nil { acceptedLosses = false }
            }
    }

    private var migrationObservedForm: some View {
        selectionObservedForm
            .onChange(of: snapshot?.migration?.revision) { _, _ in
                // A new migration failure/phase invalidates the check that
                // preceded it; retry must inspect the target again.
                freshCheckRevision = nil
                startRequested = false
                let phase = snapshot?.migration?.phase
                if phase == .completed || phase == .cancelled {
                    resetCheckedDestination()
                }
            }
            .onChange(of: snapshot?.migration?.id) { _, id in
                startRequested = false
                if id == nil {
                    // A terminal migration no longer owns a previously checked
                    // destination; never restart from that stale preview.
                    resetCheckedDestination()
                }
            }
    }

    private var environmentObservedForm: some View {
        migrationObservedForm
            .onChange(of: snapshot?.binding?.target.environmentID) { _, _ in
                startRequested = false
            }
            .onChange(of: snapshot?.failure) { _, _ in
                startRequested = false
            }
    }

    private var checkingObservedForm: some View {
        environmentObservedForm
            .onChange(of: snapshot?.checking ?? false) { _, checking in
                // The center ends a start/preparation attempt with a load;
                // clear the pending state even if the operation failed before
                // persisting a migration.
                if !checking, startRequested {
                    startRequested = false
                }
            }
    }

    // MARK: - Current location

    private func currentSection(_ snapshot: Snapshot) -> some View {
        Section {
            if let binding = snapshot.binding {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: binding.target))
                        .foregroundStyle(FloeTheme.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(locationTitle(for: binding.target, choices: snapshot.choices))
                            .font(.headline)
                        Text(locationDetail(for: binding.target))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("task.environment.current")
            } else {
                Text(copy("尚未选择运行位置", "No environment chosen yet"))
                    .font(.headline)
                Text(copy("为此任务选择一个运行位置；之后命令会在那里执行。",
                          "Choose an environment for this task; commands will run there."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Text(fileSummary(snapshot))
            } label: {
                Text(copy("工作文件", "Workspace files"))
            }
            if snapshot.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(copy("正在读取…", "Reading…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(copy("当前运行位置", "Current environment"))
        } footer: {
            Text(copy("浏览、文档与绘图继续在 Floe 中使用；命令在所选运行位置执行。",
                      "Browsing, documents and design stay in Floe. Commands run in the selected environment."))
        }
    }

    // MARK: - Legacy saved locations

    /// Old tasks could accumulate more than one session environment before
    /// bindings were pinned. Only shown when no binding exists yet and the
    /// loaded snapshot actually found such rows.
    private func legacySection(_ snapshot: Snapshot) -> some View {
        Section {
            Text(copy("此任务有之前使用的运行位置。选择一个继续使用。",
                      "This task has previous environments. Choose one to continue."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(snapshot.legacyChoices) { target in
                Button {
                    Task {
                        await center.selectPrevious(
                            conversationID: conversationID,
                            environmentID: target.environmentID)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: target))
                            .foregroundStyle(FloeTheme.primary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(legacyTitle(target, snapshot: snapshot))
                            Text(legacyDetail(target, snapshot: snapshot))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .disabled(snapshot.checking || center.isMigrating(conversationID))
                .accessibilityIdentifier("task.environment.legacy.\(target.environmentID)")
            }
        } header: {
            Text(copy("上次使用的位置", "Previous environments"))
        }
    }

    // MARK: - Destination

    private func destinationSection(_ snapshot: Snapshot, initial: Bool) -> some View {
        let currentID = currentChoiceID(in: snapshot)
        let destinations = snapshot.choices.filter { $0.id != currentID }
        let busy = snapshot.checking || center.isMigrating(conversationID)
        return Section {
            if destinations.isEmpty {
                Text(copy("没有其他可用的运行位置。", "No other environments are available."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(destinations) { choice in
                    Button {
                        selectionID = choice.id
                        checkedChoiceID = nil
                        acceptedLosses = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: choice.symbol)
                                .foregroundStyle(FloeTheme.primary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.name)
                                Text(destinationDetail(choice))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selectionID == choice.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(FloeTheme.primary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(busy)
                    .accessibilityIdentifier("task.environment.choice.\(choice.id)")
                }
                Button {
                    guard let choice = destinations.first(where: { $0.id == selectionID }) else { return }
                    checkedChoiceID = choice.id
                    acceptedLosses = false
                    checkRequested = true
                    Task {
                        await center.check(conversationID: conversationID, choice: choice)
                        checkRequested = false
                    }
                } label: {
                    checkActionLabel(copy("检查此位置", "Check this location"),
                                     systemImage: "magnifyingglass")
                }
                .disabled(selectionID == nil || busy)
                .accessibilityIdentifier("task.environment.check")
            }
        } header: {
            Text(initial
                 ? copy("选择运行位置", "Choose an environment")
                 : copy("移动到", "Move to"))
        } footer: {
            Text(copy("先选择运行位置，再检查。检查只会读取依赖和需要的能力，不会移动文件。",
                      "Select an environment, then check it. Check only reads dependencies and required capabilities; nothing is moved."))
        }
    }

    // MARK: - Preflight preview

    @ViewBuilder
    private func previewSections(_ preview: SkillMigrationPreview, initial: Bool) -> some View {
        Section {
            Label {
                Text(preview.canProceed
                     ? (initial
                        ? copy("可以使用此位置", "Ready to use this location")
                        : copy("可以移动", "Ready to move"))
                     : (initial
                        ? copy("暂时不能使用此位置", "Cannot use this location yet")
                        : copy("暂时不能移动", "Cannot move yet")))
                    .font(.headline)
            } icon: {
                Image(systemName: preview.canProceed
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(preview.canProceed ? FloeTheme.success : FloeTheme.destructive)
            }
            ForEach(preview.blockingIssues) { issue in
                blockingIssueRow(issue)
            }
        } header: {
            Text(copy("检查结果", "Check results"))
        }

        if !preview.dependencies.isEmpty {
            Section {
                ForEach(Array(preview.dependencies.enumerated()), id: \.offset) { _, dependency in
                    dependencyRow(dependency)
                }
                if !preview.modelManagedSkillIDs.isEmpty {
                    Text(modelManagedSummary(count: preview.modelManagedSkillIDs.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(copy("依赖与版本", "Dependencies and versions"))
            }
        }

        if !preview.optionalLosses.isEmpty {
            Section {
                ForEach(preview.optionalLosses) { loss in
                    optionalLossRow(loss)
                }
                if preview.requiresExplicitAcceptance {
                    Toggle(isOn: $acceptedLosses) {
                        Text(copy("我了解并接受这些能力不再可用",
                                  "I understand these capabilities will be unavailable"))
                    }
                    .accessibilityIdentifier("task.environment.acceptLosses")
                }
            } header: {
                Text(copy("迁移后不可用的 Skill 能力",
                          "Skill capabilities unavailable after the move"))
            } footer: {
                Text(copy("这些 Skill 的外部步骤或未验证的安装不会运行；记录会保留，浏览、文档与绘图继续在 Floe 中使用。",
                          "These Skills' external steps or unverified installs will not run. Their records are kept, and browsing, documents and design stay in Floe."))
            }
        }
    }

    private func dependencyRow(_ dependency: SkillMigrationDependency) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: dependency.targetSupported ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(dependency.targetSupported ? FloeTheme.success : FloeTheme.destructive)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(dependencyVersionLabel(dependency))
                Text(dependencyContextLabel(dependency))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = dependency.reason {
                    DisclosureGroup(copy("详情", "Details")) {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A blocking issue uses the product name and an actionable line in the
    /// body; the raw identifier and model-safe diagnostic stay in Details.
    private func blockingIssueRow(_ issue: SkillMigrationBlockingIssue,
                                  compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = issue.name, !name.isEmpty {
                        Text(name)
                            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.medium))
                    }
                    Text(blockingIssueMessage(issue))
                        .font(compact ? .caption : .subheadline)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(FloeTheme.destructive)
            }
            migrationIssueDetails(
                identifier: issue.skillID,
                version: issue.version,
                diagnostic: issue.diagnostic)
        }
    }

    /// An optional loss is the same product-name + actionable copy pattern.
    private func optionalLossRow(_ loss: SkillMigrationOptionalLoss,
                                 compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loss.name)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.medium))
                    Text(optionalLossMessage(loss))
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(FloeTheme.pending)
            }
            migrationIssueDetails(
                identifier: loss.skillID,
                version: loss.version,
                diagnostic: loss.diagnostic)
        }
    }

    /// User-expandable technical details. Raw ids, versions and diagnostics
    /// never lead the ordinary body copy.
    private func migrationIssueDetails(identifier: String?,
                                       version: String?,
                                       diagnostic: String) -> some View {
        DisclosureGroup(copy("详情", "Details")) {
            VStack(alignment: .leading, spacing: 3) {
                if let identifier, !identifier.isEmpty {
                    Text(identifier)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                if let version, !version.isEmpty {
                    Text("v\(version)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(diagnostic)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    private func blockingIssueMessage(_ issue: SkillMigrationBlockingIssue) -> String {
        switch issue.kind {
        case .target:
            if issue.diagnostic == SkillDependencyReason.targetUnavailable {
                return copy("请先选择一个运行位置并完成连接。",
                            "Choose an environment and connect it first.")
            }
            if issue.diagnostic == SkillDependencyReason.targetUnsupported {
                return copy("这个位置不能运行外部命令，请选择其他位置。",
                            "This location cannot run external commands. Choose another location.")
            }
            if issue.diagnostic == SkillDependencyReason.targetDisconnected {
                return copy("这个位置尚未连接，请连接后重新检查。",
                            "This location is not connected. Connect it and check again.")
            }
            return copy("这个位置暂时不可用，请重新连接后再检查。",
                        "This location is unavailable. Reconnect and check again.")
        case .inventory:
            return copy("无法读取已安装的 Skill，请稍后重试。",
                        "Installed Skills could not be read. Try again later.")
        case .unvalidatableRequiredSkill:
            return copy("这是此任务需要的 Skill，但安装内容无法验证，因此暂时不能继续。",
                        "This Skill is required by this task, but its installed contents could not be verified, so the move cannot continue.")
        case .authorization:
            return copy("无法确认这个 Skill 的权限，请重新安装或检查权限后再试。",
                        "This Skill's permissions could not be confirmed. Reinstall or check permissions first.")
        case .requiredDependency:
            return copy("这个 Skill 的必需依赖无法在此位置准备，请选择其他位置或更新依赖。",
                        "This Skill's required dependency cannot be prepared here. Choose another location or update the dependency.")
        }
    }

    private func optionalLossMessage(_ loss: SkillMigrationOptionalLoss) -> String {
        switch loss.kind {
        case .unvalidatableSkill:
            return copy("安装内容无法验证。迁移后会保留记录，但不会运行未经验证的内容；可稍后重新安装。",
                        "Its installed contents could not be verified. The record is kept, but unverified content will not run; reinstall it later.")
        case .externalCapability:
            return copy("外部步骤无法在新位置运行；Floe 内的文档、浏览与绘图仍可使用。",
                        "Its external steps cannot run at the new location; documents, browsing and design in Floe still work.")
        case .optionalDependency:
            return copy("可选依赖无法在新位置准备；其他可用能力不受影响。",
                        "An optional dependency cannot be prepared at the new location; other available capabilities are unaffected.")
        }
    }

    // MARK: - Explicit move

    private func startSection(_ preview: SkillMigrationPreview,
                              snapshot: Snapshot,
                              initial: Bool) -> some View {
        let choice = checkedChoice(in: snapshot)
        let enabled = canStart(preview, snapshot: snapshot, choice: choice)
        return Section {
            Button {
                guard let choice, enabled else { return }
                start(choice: choice, acceptCapabilityLosses: acceptedLosses)
            } label: {
                HStack(spacing: 8) {
                    if startRequested || center.isMigrating(conversationID) {
                        ProgressView().controlSize(.small)
                    }
                    Text(startRequested || center.isMigrating(conversationID)
                         ? (initial
                            ? copy("正在选择…", "Choosing…")
                            : copy("正在准备…", "Preparing…"))
                         : (initial
                            ? copy("选择此位置", "Use This Location")
                            : copy("准备并移动", "Prepare and Move")))
                }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("task.environment.start")
            if !preview.canProceed {
                Text(initial
                     ? copy("请先解决无法使用此位置的问题，再检查一次。",
                            "Resolve the issues blocking this location, then check again.")
                     : copy("请先解决无法移动的问题，再检查一次。",
                            "Resolve the issues blocking this move, then check again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if preview.requiresExplicitAcceptance, !acceptedLosses {
                Text(copy("请先确认上面列出的能力变化。",
                          "Confirm the capability changes listed above first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if initial {
                Text(copy("只为此任务选择运行位置，新任务的默认设置不变；之后命令会在这个位置执行。",
                          "This only sets this task's environment; the default for new tasks does not change. Commands run there afterwards."))
            } else {
                Text(copy("只移动当前任务，新任务的默认运行位置不变。移动前会先准备文件与依赖；在切换运行位置之前都可以取消。",
                          "Only this task moves; the default environment for new tasks does not change. Files and dependencies are prepared first, and you can cancel any time before the environment switches."))
            }
        }
    }

    private func canStart(_ preview: SkillMigrationPreview,
                          snapshot: Snapshot,
                          choice: Choice?) -> Bool {
        guard let choice,
              preview.canProceed,
              preview.requiresExplicitAcceptance == false || acceptedLosses,
              activeMigration == nil,
              !snapshot.checking,
              !startRequested,
              !center.isMigrating(conversationID),
              choice.id != currentChoiceID(in: snapshot) else { return false }
        return true
    }

    private func checkedChoice(in snapshot: Snapshot) -> Choice? {
        guard let selectionID,
              selectionID == checkedChoiceID,
              snapshot.selectedChoiceID == selectionID,
              selectionID != currentChoiceID(in: snapshot) else { return nil }
        return snapshot.choices.first { $0.id == selectionID }
    }

    /// A retry/resume preview only counts after a Check performed for the
    /// CURRENT migration revision. A preview left over from before a failure
    /// or a relaunch never authorizes Start.
    private func migrationPreview(_ migration: TaskEnvironmentMigration,
                                  snapshot: Snapshot) -> SkillMigrationPreview? {
        guard !snapshot.checking,
              freshCheckRevision == migration.revision,
              let choice = migrationChoice(for: migration.target, choices: snapshot.choices),
              snapshot.selectedChoiceID == choice.id else { return nil }
        return snapshot.preview
    }

    private func requiresRetryAcceptance(_ migration: TaskEnvironmentMigration,
                                         _ preview: SkillMigrationPreview) -> Bool {
        guard preview.requiresExplicitAcceptance else { return false }
        let alreadyAccepted = Set(migration.acceptedCapabilityLosses ?? [])
        // A subset (including an unchanged set) was already accepted; only a
        // newly introduced loss needs a fresh explicit acceptance.
        return !Set(preview.optionalCapabilityLosses).isSubset(of: alreadyAccepted)
    }

    private func retryAccepted(_ migration: TaskEnvironmentMigration,
                               _ preview: SkillMigrationPreview) -> Bool {
        !requiresRetryAcceptance(migration, preview) || acceptedLosses
    }

    // MARK: - Migration phase

    private func migrationSection(_ migration: TaskEnvironmentMigration,
                                  snapshot: Snapshot) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                phaseSymbol(migration)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(phaseTitle(migration))
                        .font(.headline)
                    Text((migration.phase == .committed
                          ? copy("现在位于：", "Now at: ")
                          : copy("移动到：", "Moving to: "))
                         + locationTitle(for: migration.target, choices: snapshot.choices))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let progress = migrationProgress(migration) {
                LabeledContent {
                    Text(progress)
                } label: {
                    Text(copy("已准备", "Prepared"))
                }
            }
            if let failure = migration.failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(FloeTheme.destructive)
            }
            if let preview = migrationPreview(migration, snapshot: snapshot) {
                Label {
                    Text(preview.canProceed
                         ? copy("目标位置检查通过", "Destination check passed")
                         : copy("目标位置目前无法继续迁移", "The destination cannot continue yet"))
                        .font(.subheadline)
                } icon: {
                    Image(systemName: preview.canProceed
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(preview.canProceed ? FloeTheme.success : FloeTheme.destructive)
                }
                ForEach(preview.blockingIssues) { issue in
                    blockingIssueRow(issue, compact: true)
                }
                if !preview.dependencies.isEmpty {
                    Text(copy("依赖与版本", "Dependencies and versions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(preview.dependencies.enumerated()), id: \.offset) { _, dependency in
                        dependencyRow(dependency)
                    }
                    if !preview.modelManagedSkillIDs.isEmpty {
                        Text(modelManagedSummary(count: preview.modelManagedSkillIDs.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !preview.optionalLosses.isEmpty {
                    Text(copy("迁移后将不可用的 Skill 能力：", "Skill capabilities unavailable after the move:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(preview.optionalLosses) { loss in
                        optionalLossRow(loss, compact: true)
                    }
                }
                if requiresRetryAcceptance(migration, preview) {
                    Toggle(isOn: $acceptedLosses) {
                        Text(copy("我了解并接受这些能力不再可用",
                                  "I understand these capabilities will be unavailable"))
                    }
                    .accessibilityIdentifier("task.environment.retryAcceptLosses")
                }
            }
            migrationActions(migration, snapshot: snapshot)
        } header: {
            Text(copy("迁移状态", "Move status"))
        } footer: {
            Text(phaseFooter(migration))
        }
    }

    @ViewBuilder
    private func migrationActions(_ migration: TaskEnvironmentMigration,
                                  snapshot: Snapshot) -> some View {
        if !migration.phase.isCommitted, !migration.phase.isTerminal {
            // Durable cancellation: this also works when no job is running
            // (for example after a failure or process death).
            Button(role: .destructive) {
                center.cancel(conversationID)
            } label: {
                Label(copy("取消迁移", "Cancel move"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("task.environment.cancel")
        }
        if migration.phase == .committed {
            // The atomic commit already happened. Reconnect directly; do not
            // re-enter preparation or require an unrelated preview. The center
            // guards duplicate jobs, so retaining the control is safe even if
            // no new phase is published.
            Button {
                center.resumeCommitted(conversationID: conversationID)
            } label: {
                Label(copy("重新连接", "Reconnect"),
                      systemImage: "arrow.clockwise.circle")
            }
            .disabled(snapshot.checking || center.isMigrating(conversationID))
            .accessibilityIdentifier("task.environment.reconnect")
        } else if migration.phase != .completed,
                  !startRequested,
                  !center.isMigrating(conversationID),
                  let choice = migrationChoice(for: migration.target, choices: snapshot.choices) {
            if let preview = migrationPreview(migration, snapshot: snapshot),
               preview.canProceed {
                Button {
                    start(choice: choice,
                          acceptCapabilityLosses: retryAccepted(migration, preview))
                } label: {
                    Label(resumeTitle(migration.phase),
                          systemImage: "arrow.clockwise")
                }
                .disabled(!retryAccepted(migration, preview) || startRequested)
                .accessibilityIdentifier("task.environment.resume")
                Button {
                    freshCheckRevision = migration.revision
                    checkRequested = true
                    Task {
                        await center.check(conversationID: conversationID, choice: choice)
                        checkRequested = false
                    }
                } label: {
                    checkActionLabel(copy("重新检查", "Check again"),
                                     systemImage: "magnifyingglass")
                }
                .disabled(snapshot.checking || startRequested)
                .accessibilityIdentifier("task.environment.recheck")
            } else {
                Button {
                    freshCheckRevision = migration.revision
                    checkRequested = true
                    Task {
                        await center.check(conversationID: conversationID, choice: choice)
                        checkRequested = false
                    }
                } label: {
                    checkActionLabel(copy("检查后继续", "Check to continue"),
                                     systemImage: "magnifyingglass")
                }
                .disabled(snapshot.checking || startRequested)
                .accessibilityIdentifier("task.environment.check")
            }
        }
    }

    // MARK: - Failure

    private func failureSection(_ failure: String) -> some View {
        Section {
            Text(failure)
                .font(.subheadline)
                .foregroundStyle(FloeTheme.destructive)
        } header: {
            Text(copy("无法完成", "Something went wrong"))
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func checkActionLabel(_ idle: String, systemImage: String) -> some View {
        if isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(copy("正在检查…", "Checking…"))
            }
        } else {
            Label(idle, systemImage: systemImage)
        }
    }

    private func resetCheckedDestination() {
        selectionID = nil
        checkedChoiceID = nil
        acceptedLosses = false
        freshCheckRevision = nil
    }

    private func start(choice: Choice, acceptCapabilityLosses: Bool) {
        startRequested = true
        center.start(
            conversationID: conversationID,
            choice: choice,
            acceptCapabilityLosses: acceptCapabilityLosses)
        // A rejected gate sets only `failure` and starts no job; do not leave
        // the control in a permanent pending state.
        if !center.isMigrating(conversationID) {
            startRequested = false
        }
    }

    private func refresh() async {
        await center.load(conversationID)
        guard !Task.isCancelled, let snapshot else { return }
        // Never resurrect a persisted preview after a relaunch or a terminal
        // migration: the sheet always requires a fresh explicit Check.
        await resolveLegacyNames(snapshot.legacyChoices)
    }

    private func resolveLegacyNames(_ targets: [TaskExecutionTarget]) async {
        guard !targets.isEmpty else {
            legacyNames = [:]
            return
        }
        var names: [String: String] = [:]
        for target in targets {
            guard !Task.isCancelled else { return }
            guard let record = await environment.environmentRegistry.record(id: target.environmentID),
                  let name = record.name,
                  !name.isEmpty else { continue }
            names[target.environmentID] = name
        }
        legacyNames = names
    }

    // MARK: - Location presentation

    private func icon(for target: TaskExecutionTarget) -> String {
        switch target.backend {
        case .linuxVM: "shippingbox"
        case .macBridge: "desktopcomputer"
        case .remoteSSH: "network"
        }
    }

    private func locationTitle(for target: TaskExecutionTarget, choices: [Choice]) -> String {
        switch target.backend {
        case .linuxVM:
            return copy("Linux 虚拟机", "Linux virtual machine")
        case .macBridge:
            return copy("这台 Mac", "This Mac")
        case .remoteSSH:
            if let hostID = target.remoteHostID,
               let match = choices.first(where: { sshHostID($0) == hostID }) {
                return match.name
            }
            return copy("远程主机", "Remote host")
        }
    }

    private func locationDetail(for target: TaskExecutionTarget) -> String {
        let os = target.operatingSystem.isEmpty
            ? copy("未知系统", "Unknown system")
            : operatingSystemLabel(target.operatingSystem)
        let architecture = target.architecture.isEmpty ? copy("未知架构", "unknown architecture") : target.architecture
        var parts = ["\(os) · \(architecture)"]
        if target.backend == .remoteSSH {
            parts.append(copy("远程 SSH", "Remote SSH"))
        }
        return parts.joined(separator: " · ")
    }

    private func operatingSystemLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "macos", "darwin": return "macOS"
        case "linux": return "Linux"
        case "unknown": return copy("未知系统", "Unknown system")
        default: return raw
        }
    }

    private func destinationDetail(_ choice: Choice) -> String {
        switch choice.kind {
        case .linux:
            return copy("Linux 虚拟机", "Linux virtual machine")
        case .mac:
            return copy("这台 Mac 上的 macOS", "macOS on this Mac")
        case .ssh:
            return copy("通过 SSH 连接的远程主机", "Remote host over SSH")
        }
    }

    private func legacyTitle(_ target: TaskExecutionTarget, snapshot: Snapshot) -> String {
        if let name = legacyNames[target.environmentID] {
            return name
        }
        return locationTitle(for: target, choices: snapshot.choices)
    }

    private func legacyDetail(_ target: TaskExecutionTarget, snapshot: Snapshot) -> String {
        var detail = locationDetail(for: target)
        let title = locationTitle(for: target, choices: snapshot.choices)
        let collisions = snapshot.legacyChoices.filter {
            locationTitle(for: $0, choices: snapshot.choices) == title
        }.count
        if collisions > 1, legacyNames[target.environmentID] == nil {
            detail += " · " + String(target.environmentID.prefix(8))
        }
        return detail
    }

    private func currentChoiceID(in snapshot: Snapshot) -> String? {
        guard let binding = snapshot.binding else { return nil }
        switch binding.target.backend {
        case .linuxVM:
            return snapshot.choices.first { $0.kind == .linux }?.id
        case .macBridge:
            return snapshot.choices.first { $0.kind == .mac }?.id
        case .remoteSSH:
            guard let hostID = binding.target.remoteHostID else { return nil }
            return snapshot.choices.first { sshHostID($0) == hostID }?.id
        }
    }

    private func sshHostID(_ choice: Choice) -> UUID? {
        if case .ssh(let hostID) = choice.kind { return hostID }
        return nil
    }

    private func migrationChoice(for target: TaskExecutionTarget, choices: [Choice]) -> Choice? {
        switch target.backend {
        case .linuxVM:
            return choices.first { $0.kind == .linux }
                ?? Choice(id: "local",
                          name: copy("Linux 虚拟机", "Linux virtual machine"),
                          kind: .linux)
        case .macBridge:
            return choices.first { $0.kind == .mac }
                ?? Choice(id: "mac",
                          name: copy("这台 Mac", "This Mac"),
                          kind: .mac)
        case .remoteSSH:
            guard let hostID = target.remoteHostID else { return nil }
            return choices.first { sshHostID($0) == hostID }
                ?? Choice(id: hostID.uuidString,
                          name: locationTitle(for: target, choices: choices),
                          kind: .ssh(hostID))
        }
    }

    // MARK: - Files and dependencies

    private func fileSummary(_ snapshot: Snapshot) -> String {
        if snapshot.checking, snapshot.fileCount == 0, snapshot.fileBytes == 0 {
            return copy("正在统计…", "Counting…")
        }
        let count = snapshot.fileCount
        let bytes = ByteCountFormatter.string(fromByteCount: snapshot.fileBytes, countStyle: .file)
        if IDELanguageRunText.isChinese {
            return "\(count) 个文件 · \(bytes)"
        }
        return count == 1 ? "1 file · \(bytes)" : "\(count) files · \(bytes)"
    }

    private func dependencyVersionLabel(_ dependency: SkillMigrationDependency) -> String {
        guard let version = dependency.version, !version.isEmpty else { return dependency.name }
        return "\(dependency.name) \(version)"
    }

    private func dependencyContextLabel(_ dependency: SkillMigrationDependency) -> String {
        let need = dependency.required
            ? copy("必需", "required")
            : copy("可选", "optional")
        let kind: String
        if dependency.kind == "runtimeComponent" {
            kind = copy("运行时组件", "runtime component")
        } else {
            kind = dependency.kind
        }
        return "\(dependency.skillName) · \(kind) · \(need)"
    }

    private func modelManagedSummary(count: Int) -> String {
        if IDELanguageRunText.isChinese {
            return "另有 \(count) 个外部 Skill 没有已审核的依赖声明，迁移后仍由模型在现有权限下管理。"
        }
        return count == 1
            ? "1 more external Skill has no reviewed dependency declaration and remains model-managed under existing permissions."
            : "\(count) more external Skills have no reviewed dependency declaration and remain model-managed under existing permissions."
    }

    // MARK: - Phase presentation

    @ViewBuilder
    private func phaseSymbol(_ migration: TaskEnvironmentMigration) -> some View {
        if migration.phase == .completed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FloeTheme.success)
        } else if migration.phase == .failed || (migration.phase == .committed && migration.failure != nil) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FloeTheme.destructive)
        } else if migration.phase == .cancelled {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        } else if migration.phase == .committed {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(FloeTheme.primary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func phaseTitle(_ migration: TaskEnvironmentMigration) -> String {
        if migration.phase == .committed, migration.failure != nil {
            return copy("已切换，重新连接失败", "Switched; reconnect failed")
        }
        switch migration.phase {
        case .checking:
            return copy("正在检查", "Checking")
        case .waiting:
            return copy("等待当前操作结束", "Waiting for current work to finish")
        case .preparing:
            return copy("正在准备文件与依赖", "Preparing files and dependencies")
        case .verifying:
            return copy("正在校验文件", "Verifying files")
        case .verified:
            return copy("校验完成，正在切换", "Verified; switching")
        case .committed:
            return copy("已切换，请重新连接", "Switched; reconnect to finish")
        case .completed:
            return copy("迁移完成", "Move complete")
        case .failed:
            return copy("迁移失败", "Move failed")
        case .cancelled:
            return copy("已取消", "Cancelled")
        }
    }

    private func phaseFooter(_ migration: TaskEnvironmentMigration) -> String {
        if migration.phase == .committed, migration.failure != nil {
            return copy("运行位置已经切换，但重新连接失败。可以直接重新连接，不会再次复制文件。",
                        "The environment already switched, but reconnecting failed. Reconnect directly; files are not copied again.")
        }
        switch migration.phase {
        case .checking:
            return copy("正在确认原位置和可用空间；此阶段不会改动文件。",
                        "Confirming the source and available space; nothing is changed in this phase.")
        case .waiting:
            return copy("等待此任务正在进行的操作自然结束；不会中断正在运行的命令。",
                        "Waiting for this task's current work to finish naturally; running commands are not interrupted.")
        case .preparing:
            return copy("正在把此任务拥有的文件复制到新位置。未完成的工作仍保留在原位置。",
                        "Copying this task's files to the new location. Unfinished work stays at the original location.")
        case .verifying:
            return copy("正在逐项校验文件清单；校验通过后才会切换运行位置。",
                        "Verifying the file list item by item. The environment switches only after verification passes.")
        case .verified:
            return copy("文件已经校验，正在提交运行位置切换。",
                        "Files are verified; committing the environment switch.")
        case .committed:
            return copy("运行位置已经切换。重新连接即可继续，不会再次复制文件。",
                        "The environment already switched. Reconnect to continue; files are not copied again.")
        case .completed:
            return copy("迁移完成。之后的任务操作会在新位置执行。",
                        "Move complete. Later task work uses the new environment.")
        case .failed:
            return copy("原位置保持不变。检查目标位置后可以重试；要改到其他位置，请先取消这次迁移。",
                        "The original environment is unchanged. Check the destination to try again, or cancel this move before choosing another location.")
        case .cancelled:
            return copy("迁移已取消，原位置保持不变。",
                        "The move was cancelled; the original environment is unchanged.")
        }
    }

    private func migrationProgress(_ migration: TaskEnvironmentMigration) -> String? {
        guard migration.preparedFileCount > 0 || migration.preparedBytes > 0 else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: migration.preparedBytes, countStyle: .file)
        if IDELanguageRunText.isChinese {
            return "\(migration.preparedFileCount) 个文件 · \(bytes)"
        }
        return migration.preparedFileCount == 1
            ? "1 file · \(bytes)"
            : "\(migration.preparedFileCount) files · \(bytes)"
    }

    private func resumeTitle(_ phase: TaskEnvironmentMigration.Phase) -> String {
        switch phase {
        case .failed, .cancelled:
            return copy("重试", "Try again")
        case .committed:
            return copy("重新连接", "Reconnect")
        default:
            return copy("继续迁移", "Continue move")
        }
    }

    private func copy(_ zh: String, _ en: String) -> String {
        IDELanguageRunText.t(zh, en)
    }
}
#endif
