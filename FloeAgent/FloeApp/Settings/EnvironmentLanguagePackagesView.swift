// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeExecution

import FloeCore
struct EnvironmentLanguagePackagesView: View {
    let environmentID: String
    let language: EnvironmentLanguagePackageService.Language
    @State private var nodeSelection: EnvironmentLanguagePackageService.NodeManagerSelection?
    @State private var sources = LanguagePackageSources()
    @State private var editingSource = false
    @State private var sourceDraft = ""
    @State private var packages: [EnvironmentLanguagePackageService.Package] = []
    @State private var specification = ""
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    /// When the live guest list was last read; nil until the guest answered.
    /// A stopped guest keeps the previous rows, labelled with this time.
    @State private var collectedAt: Date?
    @State private var guestRunning: Bool?
    @State private var pendingRemoval: EnvironmentLanguagePackageService.Package?
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    private var running: Bool { jobs.running.contains(environmentID) }

    var body: some View {
        List {
            Section {
                Button {
                    sourceDraft = language == .python ? sources.pythonIndex : sources.nodeRegistry
                    editingSource = true
                } label: {
                    HStack {
                        Label("packages.registry.source", systemImage: "network")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(running || loading)
                Text(language == .python ? sources.pythonIndex : sources.nodeRegistry)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(language == .python
                     ? String(localized: "langpkg.python_note")
                     : String(localized: "langpkg.node_note"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("langpkg.runtime_note").font(.caption).foregroundStyle(.secondary)
            }
            if language == .node {
                Section("packages.node.manager") {
                    Picker("packages.node.manager", selection: Binding(
                        get: { nodeSelection?.preference ?? .automatic },
                        set: { value in Task { await setNodeManager(value) } }
                    )) {
                        Text("packages.node.auto").tag(NodePackageManagerPreference.automatic)
                        Text("npm").tag(NodePackageManagerPreference.npm)
                        Text("pnpm").tag(NodePackageManagerPreference.pnpm)
                    }.disabled(running || loading)
                    if let selected = nodeSelection?.resolved { LabeledContent("packages.node.effective", value: selected.rawValue) }
                    if let issue = nodeSelection?.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FloeTheme.destructive) }
                    Text("packages.node.policy").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("settings.environment_language_packages_view.install_dependencies") {
                TextField(language == .python ? "settings.environment_language_packages_view.for_example_beautifulsoup4_or_requests_2" : "settings.environment_language_packages_view.for_example_marked_or_marked_15", text: $specification)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                    .onSubmit { install() }
                Button("settings.environment_language_packages_view.install", systemImage: "arrow.down.circle") { install() }
                    .disabled(running || loading || (language == .node && nodeSelection?.resolved == nil) || specification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("settings.environment_language_packages_view.installation_writes_only_to_the_currently").font(.caption).foregroundStyle(.secondary)
            }
            if let message = jobs.messages[environmentID] {
                Section("settings.environment_language_packages_view.recent_tasks") {
                    Text(message).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(jobs.failures.contains(environmentID) ? FloeTheme.destructive : .secondary)
                    if running {
                        ProgressView("settings.environment_language_packages_view.updating_dependencies")
                        Button("action.cancel_task", role: .cancel) { jobs.cancel(id: environmentID) }
                    }
                }
            }
            if loading { ProgressView("settings.environment_language_packages_view.reading_dependencies") }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("action.reload") { Task { await reload() } }.disabled(running || loading)
                }
            }
            Section {
                HStack(spacing: 6) {
                    Image(systemName: guestRunning == true ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(guestRunning == true ? FloeTheme.success : .secondary)
                    Text(freshnessLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            packageSection(writableTitle, writable: true)
            packageSection(inheritedTitle, writable: false)
        }
        .navigationTitle(language.title)
        .searchable(text: $query, prompt: "settings.environment_language_packages_view.search_installed_dependencies")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
        .sheet(isPresented: $editingSource) {
            NavigationStack {
                Form {
                    Section("packages.registry.source") {
                        TextField("https://", text: $sourceDraft).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().keyboardType(.URL)
                        Button("packages.registry.restore") {
                            let defaults = LanguagePackageSources()
                            sourceDraft = language == .python ? defaults.pythonIndex : defaults.nodeRegistry
                        }
                    }
                    Text("packages.registry.policy").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(FloeTheme.destructive) }
                }
                .navigationTitle(FloeL10n.l("packages.registry.source"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { editingSource = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("workspace.workspace_canvas_view.save") { Task { await saveSource() } }.disabled(loading || sourceDraft.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("settings.environment_language_packages_view.uninstall_this_layer_s_dependency", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            if let package = pendingRemoval {
                Button(FloeL10n.l("settings.environment_language_packages_view.uninstall", package.name), role: .destructive) { change(package.name, remove: true); pendingRemoval = nil }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingRemoval = nil }
            }
        } message: { Text("settings.environment_language_packages_view.scripts_that_depend_on_this_package") }
    }

    private var writableTitle: String {
        language == .python
            ? String(localized: "langpkg.writable.python")
            : String(localized: "langpkg.writable.node")
    }
    private var inheritedTitle: String {
        String(localized: "langpkg.inherited")
    }
    /// Honest provenance + freshness line. The Linux guest answers live only
    /// while running; a stopped screen keeps the previous rows but says when
    /// they were last read instead of presenting them as current.
    private var freshnessLine: String {
        let time = collectedAt.map { DateFormatter.listTime.string(from: $0) } ?? "—"
        switch guestRunning {
        case true:
            return String.localizedStringWithFormat(String(localized: "langpkg.fresh.running"), time)
        case false:
            return String.localizedStringWithFormat(String(localized: "langpkg.fresh.stopped"), time)
        default:
            return String.localizedStringWithFormat(String(localized: "langpkg.fresh.waiting"), time)
        }
    }

    private func packageSection(_ title: String, writable: Bool) -> some View {
        Section(title) {
            let matches = packages.filter { $0.writable == writable && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            if matches.isEmpty && !loading && error == nil { Text(query.isEmpty ? "settings.environment_language_packages_view.no_dependencies" : "settings.environment_language_packages_view.no_matching_dependencies").foregroundStyle(.secondary) }
            ForEach(matches) { package in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.name).font(.headline)
                        Text(package.version).font(.caption).foregroundStyle(.secondary)
                        if !writable { Text(FloeL10n.l("settings.environment_language_packages_view.source", package.layerID)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if writable {
                        Button("settings.environment_language_packages_view.uninstall_2", role: .destructive) { pendingRemoval = package }.buttonStyle(.borderless).disabled(running || loading)
                    } else { Image(systemName: "arrow.down.forward").foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
        }
    }
    private func install() {
        let value = specification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !running, !loading else { return }
        change(value, remove: false)
    }
    private func change(_ value: String, remove: Bool) {
        let id = environmentID, selectedLanguage = language
        jobs.start(id: id, title: "\(remove ? FloeL10n.l("settings.environment_language_packages_view.uninstall_2") : FloeL10n.l("settings.environment_language_packages_view.install")) \(value)…") {
            let service = try FloePlatformServices.shared.languagePackageService()
            return try await service.change(environmentID: id, language: selectedLanguage, specification: value, remove: remove)
        }
    }
    @MainActor private func setNodeManager(_ value: NodePackageManagerPreference) async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            nodeSelection = try await FloePlatformServices.shared.languagePackageService().nodeManagerSelection(environmentID: environmentID, set: value)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveSource() async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            var next = sources
            if language == .python { next.pythonIndex = sourceDraft } else { next.nodeRegistry = sourceDraft }
            sources = try await FloePlatformServices.shared.languagePackageService().sources(environmentID: environmentID, set: next)
            error = nil; editingSource = false
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func reload() async {
        guard !loading, !running else { return }
        loading = true
        defer { loading = false }
        do {
            let service = try FloePlatformServices.shared.languagePackageService()
            sources = try await service.sources(environmentID: environmentID)
            if language == .node { nodeSelection = try await service.nodeManagerSelection(environmentID: environmentID) }
            // Real Guest identity/state via the same ownership seams the
            // environment manager uses; never inferred from the package rows.
            let owned = await FloePlatformServices.shared.linuxEnvironmentOwned(id: environmentID)
            let running = owned ? await FloePlatformServices.shared.linuxEnvironmentAvailable(id: environmentID) : false
            guestRunning = owned ? running : nil
            packages = try await service.packages(environmentID: environmentID, language: language)
            collectedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension DateFormatter {
    static let listTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
#endif
