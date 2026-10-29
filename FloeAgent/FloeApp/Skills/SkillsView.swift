#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence
import FloeSecurity
import FloeTools
import FloeSkills

import FloeCore
import UniformTypeIdentifiers

struct SkillsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @ObservedObject var center: SkillsCenter
    @ObservedObject private var updates: SkillUpdateCoordinator
    @ObservedObject private var mcpCenter: MCPSettingsCenter
    @State private var showingInstalled = false
    @State private var useMacOriginals = true
    @ObservedObject private var macBridge = MacBridgeConnectionCenter.shared
    @State private var searchText = ""
    /// Inline batch selection state. Only the intent lives here; every
    /// mutation runs service-owned through `SkillsCenter.runSkillBatch`.
    @State private var selection = SkillBatchSelection()
    @State private var confirmingBatchDelete = false
    /// The exact eligible items + digests frozen when the destructive
    /// confirmation opens; confirming executes THIS snapshot, never a
    /// recomputed selection.
    @State private var pendingBatchDeleteItems: [SkillBatchItem] = []
    @EnvironmentObject private var authoring: SkillAuthoringCoordinator
    @State private var pendingRemoval: PersistedSkill?
    @State private var updatingSkill: PersistedSkill?
    private enum MCPHubSheet: String, Identifiable {
        case connect, create
        var id: String { rawValue }
    }
    @State private var mcpSheet: MCPHubSheet?
    @State private var discoveryDetailID: String?
    /// Route to the service-owned hub download panel (closing it never
    /// touches the job; the hub chip reopens the SAME job).
    @State private var downloadPanel: SkillHubPanelRoute?
    /// Shared scripted auto-update policy; the same defaults value is managed
    /// by Settings → Content updates. Never a second copy.
    @AppStorage(ContentUpdateCenter.scriptedAutoInstallDefaultsKey)
    private var autoScriptedUpdates = false

    init(center: SkillsCenter, mcpCenter: MCPSettingsCenter = .shared) {
        self.center = center
        self.updates = center.updates
        self.mcpCenter = mcpCenter
    }

    /// The hub shows user skills plus the explicitly exposed built-ins
    /// (office/pdf/network); hidden built-ins stay readable via skill.read
    /// but never occupy hub space.
    private var visibleInstalled: [PersistedSkill] {
        let exposed = Set(DomainSkillLibrary.all.filter(\.exposed).map(\.id))
        return center.installed.filter { skill in
            guard searchText.isEmpty || skill.name.localizedStandardContains(searchText) else { return false }
            guard DomainSkillLibrary.all.contains(where: { $0.id == skill.id }) else { return true }
            return exposed.contains(skill.id)
        }
    }

    private func pluginSummary(_ definition: DomainSkillLibrary.Definition) -> String {
        switch definition.id {
        case "floe-office": String(localized: "plugins.office.summary")
        case "floe-pdf": String(localized: "plugins.pdf.summary")
        case "floe-network": String(localized: "plugins.network.summary")
        default: definition.description
        }
    }

    private var discoveryItems: [SkillHubDisplayItem] {
        let legacy = DomainSkillLibrary.all.filter(\.exposed).map { definition in
            let installed = center.installed.first { $0.id == definition.id }
            let action: SkillHubDisplayItem.Action
            if let installed {
                if center.availableVersion(for: installed) != nil { action = .update }
                else { action = installed.status == "enabled" ? .added : .enable }
            } else { action = .get }
            let category: SkillHubCategory = switch definition.id {
            case "floe-network": .development
            case "floe-video": .design
            default: .office
            }
            let symbol: String = switch definition.id {
            case "floe-pdf": "doc.richtext"
            case "floe-network": "network"
            case "floe-video": "film"
            default: "doc.text"
            }
            return SkillHubDisplayItem(
                id: definition.id, title: definition.name,
                summary: pluginSummary(definition), category: category,
                systemImage: symbol, action: action,
                actionEnabled: !center.isWorking && !updates.isRunning && !center.isBatchRunning
            )
        }
        let curated = center.curatedCards.map { card -> SkillHubDisplayItem in
            let entry = card.entry
            let category: SkillHubCategory = switch entry.category {
            case .officeDocuments: .office
            case .writingCommunication: .writing
            case .webDevelopment: .development
            case .researchData: .research
            case .designCreation: .design
            case .productRequirements: .product
            case .productivityOrganization: .productivity
            }
            let installed = center.installed.first { $0.id == entry.id }
            let action: SkillHubDisplayItem.Action
            if let installed {
                if center.availableVersion(for: installed) != nil { action = .update }
                else { action = installed.status == "enabled" ? .added : .enable }
            } else { action = card.showsInstallAction ? .get : .unavailable }
            return SkillHubDisplayItem(id: entry.id,
                title: entry.name.value(preferredLanguages: Locale.preferredLanguages),
                summary: entry.description.value(preferredLanguages: Locale.preferredLanguages),
                category: category, systemImage: "puzzlepiece.extension", action: action,
                actionEnabled: card.showsInstallAction && !center.isWorking && !updates.isRunning && !center.isBatchRunning)
        }
        let curatedIDs = Set(curated.map(\.id))
        return legacy.filter { !curatedIDs.contains($0.id) } + curated
    }

    private func performStoreAction(_ id: String) {
        if let skill = center.installed.first(where: { $0.id == id }) {
            if center.availableVersion(for: skill) != nil { center.startUpdating(skill) }
            else if skill.status != "enabled" { Task { await center.setEnabled(true, skill: skill) } }
            else { updatingSkill = skill }
        } else if center.curatedCards.contains(where: { $0.entry.id == id }) {
            // Official signed catalog: the human Get starts the verified
            // install directly as a service-owned job. A repeated tap reuses
            // the same job — it only reopens the panel.
            center.requestHubInstall(id: id)
            if center.hubInstallJobs[id] != nil { downloadPanel = SkillHubPanelRoute(skillID: id) }
        } else { Task { await center.installOfficialSkill(id: id) } }
    }

    private var connectorActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("skills.hub.connections").font(.title2.bold())
            VStack(spacing: 0) {
                Button("skills.hub.connect_mcp", systemImage: "network") { mcpSheet = .connect }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .accessibilityIdentifier("skills.mcp.connect")
                Divider()
                Button("skills.hub.create_mcp_service", systemImage: "plus.app") { mcpSheet = .create }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .accessibilityIdentifier("skills.mcp.create")
                Divider()
                NavigationLink {
                    ConnectorsView(sourceControl: environment.sourceControlCenter, mcpCenter: mcpCenter)
                } label: {
                    Label("connectors.manage", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
                .accessibilityIdentifier("skills.connectors")
            }
            .padding(.horizontal, 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("plugins.title", selection: $showingInstalled) {
                Text("plugins.discover").tag(false)
                Text("plugins.installed").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 10)
            if !authoring.shelfRecords.isEmpty {
                VStack(spacing: 12) { SkillAuthoringRows(coordinator: authoring) }
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            if MacBridgeConnectionCenter.isMac && macBridge.hasPairing {
                Picker("mac.skills.target", selection: $useMacOriginals) {
                    Text("mac.skills.original").tag(true)
                    Text("mac.skills.on_device").tag(false)
                }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 8)
            }
            if MacBridgeConnectionCenter.isMac && macBridge.hasPairing && useMacOriginals {
                MacOriginalSkillDirectory(installedOnly: showingInstalled, query: searchText)
            } else if !showingInstalled {
                SkillHubDiscoveryView(
                    items: discoveryItems, query: searchText,
                    onSelect: { discoveryDetailID = $0 }, onGet: performStoreAction,
                    connections: { connectorActions }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // The download is service-owned: this chip reappears for
                    // the SAME job after the panel, sheet or detail page closes.
                    if let job = center.hubChipJob {
                        SkillHubDownloadChip(center: center, skillID: job.skillID) {
                            downloadPanel = SkillHubPanelRoute(skillID: job.skillID)
                        }
                        .padding(.horizontal, 20).padding(.bottom, 8)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                }
            } else {
                List {
                    if visibleInstalled.isEmpty && mcpCenter.servers.isEmpty {
                        ContentUnavailableView("skills.empty", systemImage: "puzzlepiece.extension")
                    } else {
                        ForEach(visibleInstalled) { skill in
                            installedRow(skill)
                        }
                    }
                    if !mcpCenter.servers.isEmpty {
                        Section("connectors.mcp.title") {
                            ForEach(mcpCenter.servers.filter {
                                searchText.isEmpty || $0.displayName.localizedStandardContains(searchText)
                            }) { server in
                                NavigationLink {
                                    MCPServersView(center: mcpCenter)
                                } label: {
                                    Label(server.displayName, systemImage: "network")
                                }
                            }
                        }
                    }
                    Section {
                        NavigationLink {
                            ConnectorsView(sourceControl: environment.sourceControlCenter, mcpCenter: mcpCenter)
                        } label: { Label("connectors.manage", systemImage: "network") }
                        Toggle("skills.auto_scripted_updates.label", isOn: $autoScriptedUpdates)
                            .accessibilityIdentifier("skills.auto_scripted_updates")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { batchBar }
            }
            if !showingInstalled, let error = center.curatedCatalogError {
                HStack {
                    Text(error).foregroundStyle(.secondary).font(.footnote)
                        .accessibilityIdentifier("skills.catalog.error")
                    Button("action.retry") {
                        Task { await center.refreshCuratedCatalog(force: true) }
                    }
                    .disabled(center.isRefreshingCuratedCatalog)
                    .accessibilityIdentifier("skills.catalog.retry")
                }
                .padding(.horizontal)
            }
            if let error = center.catalogError {
                Text(error).foregroundStyle(.secondary).font(.footnote).padding(.horizontal)
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal)
            }
        }
        .overlay { if center.isWorking && !updates.isRunning { ProgressView().controlSize(.large) } }
        .navigationTitle("plugins.title")
        .searchable(text: $searchText, prompt: "plugins.search")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selection.active {
                    Button(selection.isEverythingSelected(visible: visibleInstalledIDs)
                           ? SkillBatchCopy.deselectAll : SkillBatchCopy.selectAll) {
                        if selection.isEverythingSelected(visible: visibleInstalledIDs) {
                            selection.deselectAll()
                        } else {
                            selection.selectAll(visible: visibleInstalledIDs)
                        }
                    }
                    .disabled(center.isBatchRunning || visibleInstalled.isEmpty)
                    .accessibilityIdentifier(SkillsSelectionAccessibility.selectAll)
                    Button(SkillBatchCopy.done) { selection.exit() }
                        .disabled(center.isBatchRunning)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.done)
                }
                Menu {
                    Button("plugins.import", systemImage: "square.and.arrow.down") {
                        Task { await authoring.open(kind: .importing) }
                    }
                    Button("skills.creator", systemImage: "plus") {
                        Task { await authoring.open(kind: .creation) }
                    }
                    Button("skills.hub.connect_mcp", systemImage: "network") { mcpSheet = .connect }
                    Button("skills.mcp.creation.title", systemImage: "plus.app") { mcpSheet = .create }
                } label: { Label("skills.hub.add", systemImage: "plus") }
                .accessibilityIdentifier("skills.add")
                .disabled(selection.active || center.isBatchRunning)
                Button { center.startCheckingUpdates() } label: {
                    if updates.isRunning { ProgressView() }
                    else { Label("skills.update.check", systemImage: "arrow.triangle.2.circlepath") }
                }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(Text("skills.update.check"))
                    .disabled(!center.canCheckUpdates || selection.active)
                    .accessibilityIdentifier("skills.updates.check_all")
                Button("skills.update.all", systemImage: "arrow.down.circle") { center.startUpdatingAll() }
                    .labelStyle(.iconOnly)
                    .disabled(!center.canUpdateAll || selection.active)
                    .accessibilityIdentifier("skills.updates.update_all")
            }
        }
        .task {
            await authoring.reload()
            // Open the trusted bundled seed on first entry so a historical
            // mistaken removal repairs here too, not only inside a task.
            await center.seedBuiltinDomainSkills()
            await center.load()
            // The official bundled channel and the curated signed channel are
            // independent stores: one slow or failing anonymous GitHub check
            // must never delay or block the other store feed.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await center.refreshOfficialCatalog() }
                group.addTask { await center.refreshCuratedCatalog() }
            }
        }
        .refreshable { await center.load(); center.startCheckingUpdates() }
        .onChange(of: updates.reviewSkillID) { _, id in
            if let id, let skill = center.installed.first(where: { $0.id == id }) { updatingSkill = skill }
        }
        .navigationDestination(item: $discoveryDetailID) { id in
            if let item = discoveryItems.first(where: { $0.id == id }) {
                SkillHubDetailView(
                    center: center, item: item,
                    onStoreAction: performStoreAction,
                    onOpenUpdateDetails: {
                        if let skill = center.installed.first(where: { $0.id == id }) {
                            updatingSkill = skill
                        }
                    }
                )
            }
        }
        .sheet(item: $downloadPanel) { route in
            SkillHubInstallPanel(center: center, skillID: route.skillID)
        }
        .sheet(item: $mcpSheet) { destination in
            switch destination {
            case .connect:
                MCPServerEditor(center: mcpCenter, server: nil)
            case .create:
                MCPServiceCreationView(
                    coordinator: environment.mcpServiceCreationCoordinator,
                    backend: environment.mcpServiceCreationBackend,
                    openTask: { id in mcpSheet = nil; router.openConversation(id) }
                )
            }
        }
        .sheet(item: $updatingSkill) { skill in SkillGitHubUpgradeSheet(center: center, skill: skill) }
        .sheet(item: $center.pendingInstallation, onDismiss: { Task { await center.cancelPendingInstallation() } }) { pending in
            SkillInstallReviewSheet(center: center, pending: pending)
        }
        .alert("skills.remove.title", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("action.cancel", role: .cancel) { pendingRemoval = nil }
            Button("action.delete", role: .destructive) {
                if let skill = pendingRemoval { Task { await center.remove(skill) } }
                pendingRemoval = nil
            }
        }
        // One confirmation for the whole destructive batch. It runs the
        // exact items frozen when the dialog opened, never a reselection.
        .confirmationDialog(
            Text(SkillBatchCopy.deleteConfirmTitle(pendingBatchDeleteItems.count)),
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: {
                let items = pendingBatchDeleteItems
                pendingBatchDeleteItems = []
                center.runSkillBatch(operation: .delete, items: items)
            }) {
                Text(SkillBatchCopy.deleteButton(pendingBatchDeleteItems.count))
            }
            Button("action.cancel", role: .cancel) { pendingBatchDeleteItems = [] }
        }
        // Search prunes selections that are no longer visible.
        .onChange(of: searchText) { _, _ in
            selection.prune(toVisible: Set(visibleInstalledIDs))
        }
        // Truthful per-item results: resolved rows leave, failures stay.
        .onChange(of: center.lastBatchSummary) { _, summary in
            guard let summary else { return }
            selection.apply(summary: summary)
        }
        .onChange(of: showingInstalled) { _, installed in
            if !installed {
                selection.exit()
                pendingBatchDeleteItems = []
            }
        }
    }
    @ViewBuilder
    private func updateAction(for skill: PersistedSkill) -> some View {
        let state = center.updateState(for: skill)
        if state?.phase == .checking || state?.phase == .updating {
            ProgressView().controlSize(.small)
                .accessibilityLabel(FloeL10n.l(state?.phase == .checking ? "skills.update.checking" : "skills.update.updating"))
        } else if state?.phase == .reviewRequired {
            Button("skills.update.review") {
                if center.pendingUpgrade?.snapshot.package.manifest.id == skill.id { updatingSkill = skill }
                else { center.startUpdating(skill, forReview: true) }
            }
            .buttonStyle(.borderless)
            .disabled((!center.canCheckUpdates && center.pendingUpgrade?.snapshot.package.manifest.id != skill.id)
                      || selection.active)
            .accessibilityIdentifier("skills.updates.review.\(skill.id)")
        } else if center.availableVersion(for: skill) != nil {
            Button("skills.update.now") { center.startUpdating(skill) }
                .buttonStyle(.borderless)
                .disabled(!center.canCheckUpdates || selection.active)
                .accessibilityIdentifier("skills.updates.update.\(skill.id)")
        } else if state?.phase == .failed {
            Button("action.retry") { center.retryUpdateCheck(skill) }
                .buttonStyle(.borderless)
                .disabled(!center.canCheckUpdates || selection.active)
        }
    }

    @ViewBuilder
    private func updateStatus(for skill: PersistedSkill) -> some View {
        if let state = center.updateState(for: skill) {
            if state.phase == .upToDate {
                Label("skills.skills_view.already_the_latest_version", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Inline batch selection (Installed list)

    private var visibleInstalledIDs: [String] { visibleInstalled.map(\.id) }

    /// Mixed selections delete only the non-preinstalled rows; the button,
    /// its count and the confirmation all reflect exactly this eligible
    /// count. A builtin-only selection shows no delete affordance at all.
    private var deleteEligibleCount: Int {
        visibleInstalled.count { skill in
            selection.isRowSelected(skill.id) && !SkillBatchSelectionPolicy.isPreinstalled(skill.id)
        }
    }

    @ViewBuilder
    private func installedRow(_ skill: PersistedSkill) -> some View {
        let preinstalled = SkillBatchSelectionPolicy.isPreinstalled(skill.id)
        let selected = selection.isRowSelected(skill.id)
        let rowIssue: String? = {
            guard selection.active, selected,
                  let result = center.lastBatchSummary?.results.first(where: { $0.item.id == skill.id }),
                  !result.outcome.isResolved else { return nil }
            return result.outcome.issueText
        }()
        HStack(alignment: .top, spacing: 12) {
            if selection.active {
                Button {
                    selection.toggle(skill.id)
                } label: {
                    SkillSelectionCircle(selected: selected)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(selected ? SkillBatchCopy.deselectRow : SkillBatchCopy.selectRow))
                .accessibilityIdentifier(SkillsSelectionAccessibility.rowCircle(skill.id))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading) {
                        if selection.active {
                            // Selection intercepts row opening; the row body
                            // becomes inert and taps toggle the circle.
                            Text(skill.name).font(.headline).foregroundStyle(.primary)
                        } else {
                            Button { updatingSkill = skill } label: {
                                Text(skill.name).font(.headline).foregroundStyle(.primary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(center.isWorking || updates.isRunning || center.isBatchRunning)
                            .accessibilityIdentifier("skills.details.\(skill.id)")
                        }
                        HStack(spacing: 6) {
                            Text("v\(skill.version)").font(.caption).foregroundStyle(.secondary)
                            SkillOriginPill(origin: center.origin(of: skill))
                                .accessibilityIdentifier("skills.origin.\(skill.id)")
                            if preinstalled {
                                Text(SkillBatchCopy.builtInTag)
                                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    Spacer()
                    updateAction(for: skill)
                    Toggle("skills.enabled", isOn: Binding(
                        get: { skill.status == "enabled" },
                        set: { value in Task { await center.setEnabled(value, skill: skill) } }
                    )).labelsHidden().frame(minWidth: 44, minHeight: 44)
                        .disabled(center.isWorking || updates.isRunning || selection.active || center.isBatchRunning)
                }
                if let definition = DomainSkillLibrary.all.first(where: { $0.id == skill.id }) {
                    Text(pluginSummary(definition)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                updateStatus(for: skill)
                if let rowIssue {
                    Text(rowIssue).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.rowIssue(skill.id))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.active { selection.toggle(skill.id) }
        }
        .highPriorityGesture(
            LongPressGesture(
                minimumDuration: InlineSelectionTiming.longPressDuration,
                maximumDistance: InlineSelectionTiming.longPressMaximumDistance
            )
            .onEnded { _ in
                // Consume the recognized press before the child details
                // button can open its sheet, matching conversation rows.
                guard !selection.active, !center.isBatchRunning else { return }
                selection.enter(selecting: skill.id)
            }
        )
        .swipeActions {
            if !selection.active, !preinstalled, !center.isBatchRunning {
                Button("action.delete", role: .destructive) { pendingRemoval = skill }
                    .disabled(updates.isRunning || center.isWorking)
            }
        }
    }

    @ViewBuilder
    private var batchBar: some View {
        if showingInstalled && selection.active {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Text(SkillBatchCopy.selectedCount(selection.ids.count))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.count)
                    Spacer()
                    if center.isBatchRunning {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier(SkillsSelectionAccessibility.batchProgress)
                    }
                    Button(SkillBatchCopy.enable) {
                        center.runSkillBatch(operation: .enable, items: selectedBatchItems(for: .enable))
                    }
                        .disabled(center.isBatchRunning)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.batchEnable)
                    Button(SkillBatchCopy.disable) {
                        center.runSkillBatch(operation: .disable, items: selectedBatchItems(for: .disable))
                    }
                        .disabled(center.isBatchRunning)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.batchDisable)
                    if deleteEligibleCount > 0 {
                        Button(role: .destructive) {
                            // Freeze the eligible items and count NOW; the
                            // confirmation executes exactly this snapshot.
                            pendingBatchDeleteItems = selectedBatchItems(for: .delete)
                            confirmingBatchDelete = true
                        } label: {
                            Text(SkillBatchCopy.deleteButton(deleteEligibleCount))
                        }
                        .disabled(center.isBatchRunning)
                        .accessibilityIdentifier(SkillsSelectionAccessibility.batchDelete)
                    }
                }
                if let summary = center.lastBatchSummary, !summary.isEmpty {
                    Text(SkillBatchCopy.resultLine(summary))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if summary.failedCount > 0 || summary.unverifiedCount > 0 || summary.notAttemptedCount > 0 {
                        Text(SkillBatchCopy.keepFailedSelected)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// Snapshots the selected rows for one batch operation at submission
    /// time (click, or the destructive confirmation's open). Each item
    /// carries the CURRENT visible row's digest: that frozen CAS revision is
    /// what the service command must hit, so a package replaced in another
    /// window fails honestly instead of being acted on silently. Delete
    /// submissions exclude preinstalled IDs entirely.
    private func selectedBatchItems(for operation: SkillBatchOperation) -> [SkillBatchItem] {
        var seen: Set<String> = []
        return visibleInstalled.compactMap { skill in
            guard selection.isRowSelected(skill.id), seen.insert(skill.id).inserted else { return nil }
            let preinstalled = SkillBatchSelectionPolicy.isPreinstalled(skill.id)
            if operation == .delete, preinstalled { return nil }
            return SkillBatchItem(
                id: skill.id,
                title: skill.name,
                preinstalled: preinstalled,
                expectedDigest: skill.rewrittenDigest
            )
        }
    }

    /// Imports a traditional skill folder (SKILL.md, optional floe.json,
    /// scripts/references/assets/agents). The source directory is copied to a
    /// temporary location; installation never executes scripts and never
    /// writes Floe metadata back into the user's folder.
    private func importTraditionalFolder(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skill-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: url, to: temporary)
            guard let source = URL(string: "floe-folder://local/\(url.lastPathComponent)") else { return }
            await center.installTraditionalPackage(at: temporary, sourceURL: source)
        } catch {
            center.errorMessage = error.localizedDescription
        }
    }
}

/// Existing origin/readiness classifier retained for presentation tests.
/// `.check` means checkable by the global action; the row does not render a
/// per-plugin Check button.
enum SkillUpdateRowAction: Equatable, Sendable {
    /// The signed catalog proves a newer official version for this row.
    case update(toVersion: String)
    /// A checkable remote source exists; no newer version is currently proven.
    case check
    /// No real update source; never advertise an update affordance.
    case noAction
}

/// Pure installed-row presentation policy. Availability (`availableVersion`)
/// and origin come from the center's verified gates, and a non-newer package
/// is still rejected by the unchanged upgrade transaction guard; this decides
/// only which honest label an already-trusted row state may show. An update
/// label appears exactly when the signed catalog offers a newer official
/// version. Otherwise official rows check against the hub only when the
/// catalog actually publishes their ID (bundled guides change with the app,
/// not on demand), community rows check only when a reviewed upgrade journal
/// or a github.com install binding proves a reachable source, and creator,
/// folder-import and unprovenance local rows show no update affordance.
func skillUpdateRowAction(
    skillID: String,
    availableVersion: String?,
    origin: SkillOrigin,
    sourceURL: String?,
    hubSkillIDs: Set<String>,
    hasGitHubUpgradeSource: Bool
) -> SkillUpdateRowAction {
    if let availableVersion { return .update(toVersion: availableVersion) }
    let knownRemoteGitHub = hasGitHubUpgradeSource || (sourceURL?.hasPrefix("https://github.com/") ?? false)
    switch origin {
    case .official: return hubSkillIDs.contains(skillID) ? .check : .noAction
    case .external, .unknown: return knownRemoteGitHub ? .check : .noAction
    case .internalCreated: return .noAction
    }
}

/// Compact secondary provenance tag beside a skill's name/version. Labels
/// come from the shared localization catalog (`skills.origin.*`).
private struct SkillOriginPill: View {
    let origin: SkillOrigin
    var body: some View {
        Text(FloeL10n.l(origin.badgeKey))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(FloeL10n.l(origin.badgeKey))
    }
}

private struct SkillGitHubUpgradeSheet: View {
    @ObservedObject var center: SkillsCenter
    let skill: PersistedSkill
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRollback = false
    @State private var confirmingRemoval = false
    /// A detail sheet can only review its own row's staged candidate.
    private var candidate: SkillUpgradeCandidate? {
        guard center.pendingUpgrade?.snapshot.package.manifest.id == skill.id else { return nil }
        return center.pendingUpgrade
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("skills.update.installed", value: "v\(skill.version)")
                    if let candidate {
                        LabeledContent("skills.update.available", value: "v\(candidate.snapshot.package.manifest.version)")
                        if !candidate.addedCapabilities.isEmpty || !candidate.addedTools.isEmpty {
                            Label("skills.skills_view.this_update_requires_new_access_permissions", systemImage: "hand.raised")
                                .font(.callout)
                        }
                        if candidate.changedFiles.isEmpty {
                            Label("skills.skills_view.already_the_latest_version", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        Button("skills.update.now") {
                            Task {
                                await center.applyReviewedUpgrade()
                                if center.errorMessage == nil { dismiss() }
                            }
                        }.disabled(candidate.changedFiles.isEmpty || center.isBatchRunning)
                    } else if center.updateState(for: skill)?.phase == .upToDate {
                        Label("skills.skills_view.already_the_latest_version", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("skills.update.details") {
                    Text(skill.sourceURL ?? "App / local").font(.caption).textSelection(.enabled)
                    if center.origin(of: skill) != .internalCreated,
                       !OfficialSkillHub.skillIDs.contains(skill.id) {
                        NavigationLink("skills.source.edit") {
                            SkillUpdateSourceEditor(center: center, skill: skill)
                        }
                    }
                    if let candidate {
                        LabeledContent("Commit", value: candidate.commit)
                        if let notes = candidate.releaseNotes[Locale.current.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"] {
                            Text(notes).font(.callout)
                        }
                        LabeledContent("skills.skills_view.new_capabilities", value: candidate.addedCapabilities.sorted().joined(separator: ", "))
                        LabeledContent("skills.skills_view.new_tools", value: candidate.addedTools.sorted().joined(separator: ", "))
                        ForEach(candidate.changedFiles, id: \.self) { file in
                            DisclosureGroup(file) {
                                Text("Before").font(.caption.bold())
                                Text(preview(candidate.installedSnapshot.files[file])).font(.caption.monospaced())
                                Text("After").font(.caption.bold())
                                Text(preview(candidate.snapshot.files[file])).font(.caption.monospaced())
                            }
                        }
                    }
                    if center.rollbackEligibleDigests[skill.id] == skill.rewrittenDigest {
                        Button("skills.update.rollback", role: .destructive) { confirmingRollback = true }
                    }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                // Preinstalled guides ship with the app: the detail sheet
                // offers no removal at all (rollback inside the upgrade
                // disclosure stays available when a real backup exists).
                if DomainSkillLibrary.all.first(where: { $0.id == skill.id }) == nil {
                    Section {
                        Button("action.delete", role: .destructive) { confirmingRemoval = true }
                            .disabled(center.updates.isRunning || center.isBatchRunning)
                    }
                }
                if let error = center.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(center.isWorking || center.isBatchRunning)
            .overlay { if center.isWorking || center.isBatchRunning { ProgressView() } }
            .navigationTitle(skill.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { if candidate != nil { center.cancelUpgrade() }; dismiss() }.disabled(center.isWorking) } }
            .confirmationDialog("skills.skills_view.restore_previous_content_and_grants", isPresented: $confirmingRollback) {
                Button("skills.skills_view.roll_back", role: .destructive) { Task { await center.rollbackLatestUpgrade(skill: skill); if center.errorMessage == nil { dismiss() } } }
                                .disabled(center.isBatchRunning)
            }
            .confirmationDialog("skills.remove.title", isPresented: $confirmingRemoval) {
                Button("action.delete", role: .destructive) {
                    if candidate != nil { center.cancelUpgrade() }
                    Task {
                        await center.remove(skill)
                        if center.errorMessage == nil { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(center.isWorking)
            .onDisappear { if !center.isWorking && candidate != nil { center.cancelUpgrade() } }
        }
    }

    private func preview(_ data: Data?) -> String {
        guard let data else { return "(absent)" }
        guard let text = String(data: data, encoding: .utf8) else { return "Binary resource: \(data.count) bytes" }
        return text
    }
}

private struct SkillUpdateSourceEditor: View {
    @ObservedObject var center: SkillsCenter
    let skill: PersistedSkill
    @Environment(\.dismiss) private var dismiss
    @State private var owner = ""
    @State private var repository = ""
    @State private var ref = ""
    @State private var path = ""
    @State private var inputError: String?

    var body: some View {
        Form {
            TextField("skills.source.owner", text: $owner)
            TextField("skills.source.repository", text: $repository)
            TextField("skills.source.ref", text: $ref)
            TextField("skills.source.path", text: $path)
            if let error = inputError ?? center.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("skills.source.edit")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") {
                    do {
                        let source = try GitHubSkillSource(owner: owner, repository: repository, ref: ref, path: path)
                        inputError = nil
                        Task {
                            await center.configureUpdateSource(skill: skill, source: source)
                            if center.errorMessage == nil { dismiss() }
                        }
                    } catch { inputError = FloeL10n.l("skills.source.invalid") }
                }
                .disabled(owner.isEmpty || repository.isEmpty || ref.isEmpty || path.isEmpty || center.isWorking || center.updates.isRunning)
            }
        }
        .onAppear {
            if let source = center.updateSource(for: center.installed.first(where: { $0.id == skill.id }) ?? skill) {
                owner = source.owner; repository = source.repository; ref = source.ref; path = source.path
            }
        }
    }
}

/// Account integrations are not installable skill Markdown. Keep existing
/// account stores and Keychain identities intact when changing navigation.
struct ConnectorsView: View {
    @ObservedObject var sourceControl: SourceControlCenter
    @ObservedObject var mcpCenter: MCPSettingsCenter

    var body: some View {
        List {
            Section("connectors.services") {
                NavigationLink { MailSettingsView() } label: {
                    Label("mail.settings.title", systemImage: "envelope")
                }
                .accessibilityIdentifier("connectors.mail")
                NavigationLink {
                    GitHubSettingsView(center: sourceControl)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GitHub")
                            Text(sourceControl.account.map { String(localized: "connectors.connected") + " · \($0.login)" }
                                 ?? String(localized: "connectors.github.disconnected"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                }
                .accessibilityIdentifier("connectors.github")
            }
            Section {
                NavigationLink {
                    MCPServersView(center: mcpCenter)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("connectors.mcp.title")
                            Text(String.localizedStringWithFormat(String(localized: "connectors.mcp.enabled_count"), mcpCenter.servers.filter(\.enabled).count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "network") }
                }
                .accessibilityIdentifier("connectors.mcp")
            } header: { Text("connectors.tool_sources") }
            footer: {
                Text("connectors.footer")
            }
        }
        .navigationTitle("connectors.title")
        .task { await sourceControl.loadConnection() }
    }
}

@MainActor
final class MCPSettingsCenter: ObservableObject {
    enum ConnectionState: Equatable {
        case inactive
        case connecting
        case ready(Int)
        case failed(String)
    }

    static let shared = MCPSettingsCenter()
    private static let defaultsKey = "floe.mcp.remoteServers.v1"
    private static let keychainService = "org.floeagent.ios.mcp"

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var stateByServerID: [UUID: ConnectionState] = [:]
    @Published private(set) var toolsByServerID: [UUID: [MCPDiscoveredTool]] = [:]
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore
    private let keychain: KeychainStore
    private var clients: [UUID: MCPRemoteClient] = [:]
    private var refreshGenerationByServerID: [UUID: UInt64] = [:]
    private var activated = false

    init(
        defaults: UserDefaults = .standard,
        cloud: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.keychain = KeychainStore(service: Self.keychainService, synchronizable: true)
        reload()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.servers
                self.reload()
                self.reconcileRuntime(previous: previous)
                self.activate(force: true)
            }
        }
        cloud.synchronize()
    }

    func activate(force: Bool = false) {
        guard force || !activated else { return }
        activated = true
        Task { [weak self] in
            guard let self else { return }
            for server in self.servers where server.enabled {
                await self.refresh(serverID: server.id)
            }
        }
    }

    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws {
        try server.validate()
        let previous = servers.first(where: { $0.id == server.id })
        let account = credentialAccount(server)
        if let credential, !credential.isEmpty {
            try keychain.store(account: account, secret: Data(credential.utf8))
        } else if server.authentication != .none,
                  (try? keychain.read(account: account)) == nil {
            throw MCPClientError.authenticationRequired
        }
        if server.authentication == .none {
            try? keychain.delete(account: account)
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if let previous, credentialAccount(previous) != account {
            try? keychain.delete(account: credentialAccount(previous))
        }
        try? keychain.delete(account: legacyCredentialAccount(server.id))
        persist()
        if server.enabled {
            await refresh(serverID: server.id)
        } else {
            MCPRemoteToolSource.unregister(configuration: server)
            if let client = clients.removeValue(forKey: server.id) {
                Task { await client.disconnect() }
            }
            stateByServerID[server.id] = .inactive
            toolsByServerID[server.id] = []
        }
    }

    func setEnabled(_ enabled: Bool, serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].enabled = enabled
        let server = servers[index]
        persist()
        if enabled {
            Task { await refresh(serverID: serverID) }
        } else {
            invalidateRefresh(serverID: serverID)
            MCPRemoteToolSource.unregister(configuration: server)
            if let client = clients.removeValue(forKey: serverID) {
                Task { await client.disconnect() }
            }
            stateByServerID[serverID] = .inactive
        }
    }

    func setToolEnabled(_ enabled: Bool, remoteName: String, serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        if enabled {
            servers[index].disabledRemoteToolNames.remove(remoteName)
        } else {
            servers[index].disabledRemoteToolNames.insert(remoteName)
        }
        persist()
        let server = servers[index]
        if let client = clients[serverID], let tools = toolsByServerID[serverID] {
            MCPRemoteToolSource.register(configuration: server, client: client, tools: tools)
        }
    }

    func remove(serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        MCPRemoteToolSource.unregister(configuration: server)
        servers.removeAll { $0.id == serverID }
        if let client = clients.removeValue(forKey: serverID) {
            Task { await client.disconnect() }
        }
        toolsByServerID.removeValue(forKey: serverID)
        stateByServerID.removeValue(forKey: serverID)
        invalidateRefresh(serverID: serverID)
        try? keychain.delete(account: credentialAccount(server))
        try? keychain.delete(account: legacyCredentialAccount(serverID))
        persist()
    }

    func refresh(serverID: UUID) async {
        guard let server = servers.first(where: { $0.id == serverID }), server.enabled else { return }
        let generation = beginRefresh(serverID: serverID)
        stateByServerID[serverID] = .connecting
        errorMessage = nil
        let previousClient = clients[serverID]
        do {
            let credentialData = try? keychain.read(account: credentialAccount(server))
            let credential = credentialData.map { String(decoding: $0, as: UTF8.self) }
            let client = try MCPRemoteClient(configuration: server, credential: credential)
            let tools = try await client.discoverTools()
            guard refreshGenerationByServerID[serverID] == generation,
                  servers.first(where: { $0.id == serverID }) == server else {
                // Superseded by a newer refresh: tear the new client down and do
                // not touch the current registration.
                await client.disconnect()
                return
            }
            clients[serverID] = client
            toolsByServerID[serverID] = tools
            MCPRemoteToolSource.register(configuration: server, client: client, tools: tools)
            stateByServerID[serverID] = .ready(tools.count)
            if let previousClient, previousClient !== client {
                await previousClient.disconnect()
            }
        } catch {
            guard refreshGenerationByServerID[serverID] == generation else { return }
            MCPRemoteToolSource.unregister(configuration: server)
            clients.removeValue(forKey: serverID)
            // A failed refresh must not leave its half-open client or a prior
            // client's session alive.
            if let previousClient {
                await previousClient.disconnect()
            }
            stateByServerID[serverID] = .failed(error.localizedDescription)
            errorMessage = "\(server.displayName)：\(error.localizedDescription)"
        }
    }

    func hasStoredCredential(serverID: UUID) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }) else { return false }
        return (try? keychain.read(account: credentialAccount(server))) != nil
    }

    /// Snapshot the exact remote-tool names that may enter a Canvas Agent
    /// run. Keeping this decision in one policy builder prevents the canvas
    /// UI from accidentally treating every ordinary-Agent MCP registration
    /// as canvas-authorized.
    func canvasAllowedToolNames() -> Set<String> {
        CanvasAgentToolPolicy.allowedToolNames(
            servers: servers,
            discoveredTools: toolsByServerID
        )
    }

    private func reload() {
        let data = cloud.data(forKey: Self.defaultsKey) ?? defaults.data(forKey: Self.defaultsKey)
        servers = data.flatMap { try? JSONDecoder().decode([MCPServerConfiguration].self, from: $0) } ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        cloud.set(data, forKey: Self.defaultsKey)
        cloud.synchronize()
    }

    private func reconcileRuntime(previous: [MCPServerConfiguration]) {
        let currentByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for old in previous {
            guard let current = currentByID[old.id], current.enabled, current == old else {
                invalidateRefresh(serverID: old.id)
                MCPRemoteToolSource.unregister(configuration: old)
                clients.removeValue(forKey: old.id)
                toolsByServerID.removeValue(forKey: old.id)
                stateByServerID[old.id] = currentByID[old.id] == nil ? nil : .inactive
                continue
            }
        }
    }

    private func beginRefresh(serverID: UUID) -> UInt64 {
        let next = (refreshGenerationByServerID[serverID] ?? 0) &+ 1
        refreshGenerationByServerID[serverID] = next
        return next
    }

    private func invalidateRefresh(serverID: UUID) {
        refreshGenerationByServerID[serverID] = (refreshGenerationByServerID[serverID] ?? 0) &+ 1
    }

    /// Bind secret lookup to both the stable server identity and its network
    /// origin. Editing or cloud-syncing an endpoint therefore requires a
    /// credential stored for the new destination instead of silently sending
    /// the old secret to it.
    private func credentialAccount(_ server: MCPServerConfiguration) -> String {
        let scheme = server.endpoint.scheme?.lowercased() ?? "https"
        let host = server.endpoint.host?.lowercased() ?? "invalid"
        let port = server.endpoint.port ?? (scheme == "https" ? 443 : 80)
        return "mcp.\(server.id.uuidString).\(scheme).\(host).\(port)"
    }

    private func legacyCredentialAccount(_ serverID: UUID) -> String {
        "mcp.\(serverID.uuidString)"
    }
}

private struct MCPServersView: View {
    @ObservedObject var center: MCPSettingsCenter
    @State private var editingServer: MCPServerConfiguration?
    @State private var showingNewServer = false

    var body: some View {
        List {
            Section {
                if center.servers.isEmpty {
                    ContentUnavailableView("skills.skills_view.no_mcp_server_added_yet",
                        systemImage: "network",
                        description: Text("skills.skills_view.add_a_standard_remote_mcp_so")
                    )
                }
                ForEach(center.servers) { server in
                    Button { editingServer = server } label: {
                        HStack(spacing: 12) {
                            Image(systemName: stateIcon(center.stateByServerID[server.id]))
                                .foregroundStyle(stateColor(center.stateByServerID[server.id]))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.displayName).foregroundStyle(.primary)
                                Text(server.endpoint.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(stateText(center.stateByServerID[server.id]))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { server.enabled },
                                set: { center.setEnabled($0, serverID: server.id) }
                            )).labelsHidden()
                        }
                    }
                    .swipeActions {
                        Button("workspace.workspace_canvas_view.delete", role: .destructive) { center.remove(serverID: server.id) }
                    }
                }
            } footer: {
                Text("skills.skills_view.supports_standard_streamable_http_remote_tools")
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("connectors.mcp.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("portforward.add", systemImage: "plus") { showingNewServer = true }
            }
        }
        .sheet(isPresented: $showingNewServer) {
            MCPServerEditor(center: center, server: nil)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditor(center: center, server: server)
        }
        .onAppear { center.activate() }
    }

    private func stateText(_ state: MCPSettingsCenter.ConnectionState?) -> String {
        switch state {
        case .inactive, nil: FloeL10n.l("skills.skills_view.not_connected")
        case .connecting: FloeL10n.l("skills.skills_view.reading_tools")
        case .ready(let count): FloeL10n.plural("skills.skills_view.tools_available", count: count)
        case .failed(let message): FloeL10n.l("skills.skills_view.connection_failed", message)
        }
    }

    private func stateIcon(_ state: MCPSettingsCenter.ConnectionState?) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .inactive, nil: "circle"
        }
    }

    private func stateColor(_ state: MCPSettingsCenter.ConnectionState?) -> Color {
        switch state {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: MCPSettingsCenter
    @State private var server: MCPServerConfiguration
    @State private var endpointText: String
    @State private var credential = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(center: MCPSettingsCenter, server: MCPServerConfiguration?) {
        self.center = center
        let value = server ?? MCPServerConfiguration(
            displayName: "",
            endpoint: URL(string: "https://example.com/mcp")!,
            enabled: true
        )
        _server = State(initialValue: value)
        _endpointText = State(initialValue: server?.endpoint.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("notes.notes_root_view.name", text: $server.displayName)
                    TextField("https://…/mcp", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("skills.skills_view.enabled", isOn: $server.enabled)
                    Toggle("skills.skills_view.allow_canvas_to_use", isOn: $server.allowInCanvas)
                } header: {
                    Text("skills.skills_view.server")
                } footer: {
                    Text("skills.skills_view.mcp_is_off_by_default_for")
                }
                Section("workspace.file_inspector_view.authentication") {
                    Picker("hosts.auth", selection: $server.authentication) {
                        Text("workspace.workspace_canvas_view.none").tag(MCPServerConfiguration.Authentication.none)
                        Text("Bearer Token").tag(MCPServerConfiguration.Authentication.bearerToken)
                        Text("skills.skills_view.custom_request_headers").tag(MCPServerConfiguration.Authentication.customHeader)
                    }
                    if server.authentication == .customHeader {
                        TextField("skills.skills_view.request_header_name", text: $server.credentialHeaderName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if server.authentication != .none {
                        SecureField(
                            center.hasStoredCredential(serverID: server.id) ? "skills.skills_view.enter_new_credentials_to_replace_the" : "providers.credentials",
                            text: $credential
                        )
                        if center.hasStoredCredential(serverID: server.id) {
                            Label("skills.skills_view.credentials_saved_securely_in_keychain", systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("skills.skills_view.network_security") {
                    Toggle("skills.skills_view.allow_insecure_http_trusted_lan_only", isOn: $server.allowInsecureHTTP)
                }
                if let tools = center.toolsByServerID[server.id], !tools.isEmpty {
                    Section("skills.skills_view.tools") {
                        ForEach(tools, id: \.remoteName) { tool in
                            Toggle(isOn: Binding(
                                get: { !server.disabledRemoteToolNames.contains(tool.remoteName) },
                                set: {
                                    if $0 { server.disabledRemoteToolNames.remove(tool.remoteName) }
                                    else { server.disabledRemoteToolNames.insert(tool.remoteName) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.displayName ?? tool.remoteName)
                                    Text(tool.toolDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(server.displayName.isEmpty ? "skills.skills_view.add_mcp" : server.displayName)
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("skills.skills_view.save_and_connect") { save() }
                        .disabled(server.displayName.trimmingCharacters(in: .whitespaces).isEmpty || endpointText.isEmpty)
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = FloeL10n.l("skills.skills_view.enter_a_valid_mcp_url")
            return
        }
        server.endpoint = endpoint
        isSaving = true
        Task {
            do {
                try await center.upsert(server, credential: credential.isEmpty ? nil : credential)
                dismiss()
            } catch {
                validationMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct SkillInstallReviewSheet: View {
    @ObservedObject var center: SkillsCenter
    let pending: SkillsCenter.PendingInstallation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("skills.review.source") { Text(pending.sourceURL.absoluteString).font(.footnote) }
                Section("skills.review.permissions") {
                    if pending.capabilityNames.isEmpty { Text("skills.review.none") }
                    ForEach(pending.capabilityNames, id: \.self) { Text($0) }
                }
                if !pending.toolNames.isEmpty {
                    Section("skills.review.tools") { ForEach(pending.toolNames, id: \.self) { Text($0) } }
                }
                if pending.containsScripts {
                    Section("skills.skills_view.python_scripts_audited_at_install") {
                        ForEach((pending.snapshot.map { Array($0.files.keys) } ?? Array(pending.files.keys))
                            .filter { $0.hasPrefix("scripts/") }.sorted(), id: \.self) {
                            Label($0, systemImage: "doc.text")
                                .font(FloeTheme.Typography.evidence)
                        }
                    }
                }
                if !pending.manifest.pythonPackages.isEmpty {
                    Section("skills.skills_view.pure_python_dependencies_audited_at_install") {
                        ForEach(pending.manifest.pythonPackages, id: \.spec) { package in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.spec).font(FloeTheme.Typography.evidence)
                                Text(package.purpose)
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("skills.skills_view.only_pinned_version_pypi_none_any")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("skills.review.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { Task { await center.cancelPendingInstallation(); dismiss() } }
                        .accessibilityIdentifier("skills.review.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") { Task { await center.confirmPendingInstallation(); dismiss() } }
                        .accessibilityIdentifier("skills.review.install")
                }
            }
        }
    }
}

private struct SkillCreatorSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("skills.name", text: $name)
                TextField("skills.description", text: $description, axis: .vertical)
                TextField("skills.instructions", text: $instructions, axis: .vertical).lineLimit(6...14)
            }
            .navigationTitle("skills.creator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.create(name: name, description: description, instructions: instructions); if center.errorMessage == nil { dismiss() } }
                    }.disabled(name.isEmpty || description.isEmpty || instructions.isEmpty || center.isWorking)
                }
            }
        }
    }
}

private struct SkillFinderSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rewriteModelID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("skills.finder.source")
                } footer: {
                    Text("skills.finder.footer")
                }
                if SkillBulkUpdatePlan.githubReference(url) == nil {
                  Picker("skills.finder.model", selection: $rewriteModelID) {
                    ForEach(center.rewriteModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                }
            }
            .navigationTitle("skills.finder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.installFromFinder(urlText: url, rewriteModelID: rewriteModelID); if center.errorMessage == nil { dismiss() } }
                    }.disabled(url.isEmpty || (SkillBulkUpdatePlan.githubReference(url) == nil && rewriteModelID == nil) || center.isWorking)
                }
            }
            .onAppear { if rewriteModelID == nil { rewriteModelID = center.defaultRewriteModelID ?? center.rewriteModels.first?.id } }
        }
    }
}
#endif
