// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeEnvironments
import FloeExecution
import FloePackages
import FloeTools

/// Jobs survive navigation and are drained by the environment lifecycle before deletion.
@MainActor final class EnvironmentPackageJobs: ObservableObject {
    static let shared = EnvironmentPackageJobs()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(id: String, title: String, action: FloePlatformServices.PackageAction) {
        start(id: id, title: title) { try await FloePlatformServices.shared.managePackage(id: id, action: action) }
    }

    func start(id: String, title: String, operation: @escaping @Sendable () async throws -> String) {
        guard !running.contains(id) else { return }
        running.insert(id)
        messages[id] = title
        failures.remove(id)
        tasks[id] = Task {
            do { messages[id] = try await operation() }
            catch is CancellationError { messages[id] = "任务已取消；重新读取依赖以确认当前状态" }
            catch { messages[id] = error.localizedDescription; failures.insert(id) }
            running.remove(id)
            tasks[id] = nil
            revision += 1
        }
    }
    func cancel(id: String) {
        guard let task = tasks[id] else { return }
        messages[id] = "正在取消并等待事务结束…"
        task.cancel()
    }
    func cancelAndWait(id: String) async {
        guard let task = tasks[id] else { return }
        cancel(id: id)
        await task.value
    }
}

struct EnvironmentManagerView: View {
    var ownerTitles: [String: String] = [:]
    @State private var reports: [FloePlatformServices.EnvironmentReport] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared

    var body: some View {
        List {
            Section {
                Text("会话 → 项目 → 共享 → 基础").font(.headline)
                Text("依赖按层查找，安装只写入所选环境。容器用于管理依赖、数据和生命周期。").font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    ToolRouteCatalogView(catalog: .bundled())
                } label: {
                    Label("environment.tools.routes.title", systemImage: "terminal")
                }
                Text("environment.tools.routes.summary")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("environment.capabilities.title") {
                NavigationLink {
                    WasmCapabilityCatalogView()
                } label: {
                    Label("environment.capabilities.entry", systemImage: "puzzlepiece.extension")
                }
                Text("environment.capabilities.summary")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("读取环境与容量…") }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("重试") { Task { await reload() } }
                }
            }
            ForEach(ContainerKind.allCases, id: \.self) { kind in
                let matches = reports.filter { $0.record.kind == kind && (query.isEmpty || displayName(for: $0).localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)) }
                if !matches.isEmpty {
                    Section(Self.title(kind)) {
                        ForEach(matches) { report in
                            NavigationLink {
                                EnvironmentDetailView(report: report, displayName: displayName(for: report))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: Self.icon(kind)).foregroundStyle(FloeTheme.primary).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(displayName(for: report)).font(.headline)
                                        Text(report.issue == nil ? "\(report.packages.count) 个本层依赖 · \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))" : "读取失败 · 点击查看恢复信息")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(report.record.requiresRebuild ? "需要重建依赖" : Self.state(report.record.state)).font(.caption)
                                    }
                                    if jobs.running.contains(report.id) { Spacer(); ProgressView().accessibilityLabel("软件包任务正在运行") }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            if !loading && reports.isEmpty && error == nil {
                ContentUnavailableView("尚无项目或会话环境", systemImage: "shippingbox", description: Text("打开工作区或在会话中运行本地工具后，对应环境会出现在这里。"))
            }
        }
        .navigationTitle("environment.manager.title")
        .searchable(text: $query, prompt: "搜索环境名称或 ID")
        .refreshable { await reload() }
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading) }
        .task { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
    }

    private func displayName(for report: FloePlatformServices.EnvironmentReport) -> String {
        if let name = report.record.name { return name }
        if let owner = report.record.ownerID, let title = ownerTitles[owner] { return title }
        return Self.title(report.record.kind) + " · " + String(report.id.prefix(8))
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { reports = try await FloePlatformServices.shared.environmentReports(); error = nil }
        catch { self.error = String(describing: error) }
    }
    static func title(_ kind: ContainerKind) -> String {
        switch kind { case .session: "会话"; case .project: "项目"; case .shared: "共享依赖"; case .template: "模板" }
    }
    static func icon(_ kind: ContainerKind) -> String {
        switch kind { case .session: "bubble.left.and.bubble.right"; case .project: "folder"; case .shared: "square.stack.3d.up"; case .template: "doc.on.doc" }
    }
    static func state(_ state: ContainerState) -> String {
        switch state { case .active: "可用"; case .stopped: "已停止"; case .deleting: "正在删除" }
    }
}

private struct EnvironmentDetailView: View {
    /// One distribution package reported by the Linux guest's own dpkg
    /// database; the list is display formatting over real guest state.
    private struct LinuxPackage: Identifiable, Equatable {
        let name: String
        let version: String
        var id: String { name }
    }
    /// One shortcut in the maintained Linux recommendation list. `package` is
    /// the real Debian binary package name passed verbatim to the guest's
    /// apt-get; `commands` names the guest commands that package normally
    /// provides, so nobody has to type a command where APT expects a package
    /// name (xz-utils provides xz, openssh-client provides ssh/scp).
    private struct LinuxRecommendation: Identifiable, Equatable {
        let package: String
        let commands: [String]
        var id: String { package }
    }
    /// Short maintained list of common Debian packages; bilingual display
    /// strings stay in Localizable.xcstrings. Whether an entry can actually be
    /// installed depends on the guest's configured APT sources and is resolved
    /// by the guest's own apt-get, so this list is a starting point, not a
    /// verified compatibility matrix.
    private static let recommendedLinuxPackages: [LinuxRecommendation] = [
        LinuxRecommendation(package: "7zip", commands: ["7z"]),
        LinuxRecommendation(package: "bash", commands: ["bash"]),
        LinuxRecommendation(package: "bzip2", commands: ["bzip2"]),
        LinuxRecommendation(package: "coreutils", commands: ["nohup"]),
        LinuxRecommendation(package: "git", commands: ["git"]),
        LinuxRecommendation(package: "openssh-client", commands: ["ssh", "scp", "sftp"]),
        LinuxRecommendation(package: "procps", commands: ["ps"]),
        LinuxRecommendation(package: "sqlite3", commands: ["sqlite3"]),
        LinuxRecommendation(package: "unzip", commands: ["unzip"]),
        LinuxRecommendation(package: "util-linux", commands: ["setsid"]),
        LinuxRecommendation(package: "xz-utils", commands: ["xz"]),
        LinuxRecommendation(package: "zip", commands: ["zip"]),
        LinuxRecommendation(package: "zsh", commands: ["zsh"]),
    ]
    let report: FloePlatformServices.EnvironmentReport
    let displayName: String
    @State private var current: FloePlatformServices.EnvironmentReport?
    @State private var packages: FloePlatformServices.PackageReport?
    @State private var error: String?
    @State private var busy = false
    @State private var templateName = ""
    @State private var confirmDelete = false
    @State private var query = ""
    @State private var linuxAvailable = false
    @State private var linuxOwned = false
    @State private var linuxPackages: [LinuxPackage] = []
    @State private var linuxLoading = false
    @State private var linuxError: String?
    @State private var pendingLinuxRemoval: String?
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    // Linux guest backend selection and real guest/image state. The picker
    // writes through FloePlatformServices.setEnvironmentExecutionBackend, so
    // the same code path the shell entry uses; status comes from the running
    // service, never from the record alone.
    @State private var backendSelection: EnvironmentExecutionBackend = .native
    @State private var backendApplied: EnvironmentExecutionBackend = .native
    @State private var backendBusy = false
    @State private var guestStatus: LinuxGuestStatus?
    @State private var imageStorageAvailable = false
    @Environment(\.dismiss) private var dismiss
    private var record: ContainerRecord { (current ?? report).record }
    private var writable: Bool { record.kind.isWritableLayer && record.state == .active && !record.requiresRebuild && !busy && !jobs.running.contains(report.id) }
    private var backendEditable: Bool { record.kind.isWritableLayer && record.state != .deleting && !backendBusy }
    /// One App-shared install job per pinned image id, never per environment:
    /// the image is shared storage, so tapping download in a second
    /// environment must join the running task instead of starting another.
    private static let imageJobPrefix = "linux-image:"
    private var imageJobID: String? {
        guard let imageID = guestStatus?.imageID else { return nil }
        return Self.imageJobPrefix + imageID
    }
    /// The pinned image is missing or failed digest verification and this
    /// build distributes it: the one state where the install/retry entry is
    /// actionable. The id comes from the guest descriptor, never user input.
    private var canInstallGuestImage: Bool {
        guard let status = guestStatus, status.imageDistributable == true else { return false }
        return status.imageInstalled != true || status.imageVerificationFailure != nil
    }
    /// backendUserMessage is the honest reason a Linux guest cannot run yet
    /// (missing/unqualified image, no distributable archive).
    private var backendUserMessage: String? {
        guard backendSelection == .linuxVM else { return nil }
        guard let status = guestStatus else { return String(localized: "environment.backend.checking") }
        if status.running { return nil }
        if let failure = status.imageVerificationFailure { return failure }
        if status.imageInstalled == false { return String(localized: "environment.backend.image_missing") }
        return status.lastError
    }

    var body: some View {
        List {
            Section("environment.manager.selected") {
                LabeledContent("类型", value: EnvironmentManagerView.title(record.kind))
                LabeledContent("状态", value: EnvironmentManagerView.state(record.state))
                if let issue = (current ?? report).issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
                LabeledContent((current ?? report).issue == nil ? "本层容量" : "上次记录的容量", value: ByteCountFormatter.string(fromByteCount: (current ?? report).bytes, countStyle: .file))
                if record.requiresRebuild { Label(record.rebuildReason ?? "依赖需要重建；数据已保留", systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.pending) }
                DisclosureGroup("环境标识与归属") {
                    Text(record.id).textSelection(.enabled)
                    if let owner = record.ownerID { LabeledContent("所属项目或会话", value: owner) }
                    if let parent = record.parentID { LabeledContent("父环境", value: parent) }
                    LabeledContent("基础层版本", value: record.baseRevision)
                }.font(.caption)
            }
            if busy { ProgressView("正在处理…") }
            // Execution backend: native stays the default; Linux runs the
            // shell/Python/services inside this environment's TinyEMU guest.
            // The status text below is the real guest/image state, including
            // the exact reason a guest cannot start.
            Section("environment.backend.title") {
                Picker("environment.backend.picker", selection: $backendSelection) {
                    Text("environment.backend.native").tag(EnvironmentExecutionBackend.native)
                    Text("environment.backend.linux").tag(EnvironmentExecutionBackend.linuxVM)
                }
                .pickerStyle(.segmented)
                .disabled(!backendEditable)
                .onChange(of: backendSelection) { _, newValue in
                    guard newValue != backendApplied else { return }
                    apply(backend: newValue)
                }
                if backendSelection == .linuxVM {
                    if let status = guestStatus {
                        LabeledContent("environment.backend.status", value: status.running ? String(localized: "environment.backend.status.running") : String(localized: "environment.backend.status.stopped"))
                        if let imageID = status.imageID {
                            LabeledContent("environment.backend.image", value: imageID)
                        }
                        if status.running, let startedAt = status.startedAt {
                            LabeledContent("environment.backend.started", value: startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let message = backendUserMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(FloeTheme.pending)
                        }
                        if status.imageDistributable != true {
                            Text("environment.backend.distribution_hint")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if status.running {
                            Button("environment.backend.stop", systemImage: "stop") { apply(backend: .linuxVM, stopOnly: true) }
                                .disabled(backendBusy)
                        } else {
                            Button("environment.backend.start", systemImage: "play") { apply(backend: .linuxVM) }
                                .disabled(backendBusy || status.imageInstalled == false || status.imageVerificationFailure != nil)
                        }
                        // The pinned guest image is App-shared storage, not an
                        // environment layer. When this build can distribute it
                        // and it is missing (or failed digest verification),
                        // the real install path is reachable from here: fixed
                        // catalog id, no URL input, service-owned task.
                        if canInstallGuestImage, imageStorageAvailable {
                            imageInstallControls
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text("environment.backend.native_hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView("正在处理…") }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive); Button("action.reload") { Task { await reload() } } } }
            if let message = jobs.messages[report.id] {
                Section("environment.packages.tasks") {
                    Text(message).font(.subheadline).textSelection(.enabled)
                        .foregroundStyle(jobs.failures.contains(report.id) ? FloeTheme.destructive : .primary)
                    if jobs.running.contains(report.id) {
                        ProgressView("正在处理所选环境")
                        Button("action.cancel_task", role: .cancel) { jobs.cancel(id: report.id) }
                    }
                }
            }
            Section {
                NavigationLink {
                    LocalServicesView(environmentID: report.id)
                } label: {
                    Label("services.title", systemImage: "server.rack")
                }
            }
            Section("语言依赖") {
                ForEach(EnvironmentLanguagePackageService.Language.allCases) { language in
                    NavigationLink {
                        EnvironmentLanguagePackagesView(environmentID: report.id, language: language)
                    } label: {
                        Label(language.title, systemImage: language == .python ? "terminal" : "curlybraces")
                    }
                }
                Text("environment.packages.language.summary")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("environment.packages.linux.title") {
                if linuxAvailable {
                    Text("environment.packages.linux.origin").font(.caption).foregroundStyle(.secondary)
                    Button("environment.packages.refresh", systemImage: "arrow.clockwise") {
                        runLinux(["apt-get", "update"], String(localized: "environment.packages.linux.refresh_title"))
                    }.disabled(!writable)
                    Text("environment.packages.linux.recommended.title").font(.subheadline.weight(.semibold))
                    Text("environment.packages.linux.recommended.summary").font(.caption).foregroundStyle(.secondary)
                    ForEach(Self.recommendedLinuxPackages.filter { matches($0.package) }) { recommendation in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommendation.package).font(.subheadline)
                                Text(Self.recommendedDetail(recommendation)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let version = installedLinuxVersion(of: recommendation.package) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("environment.capabilities.installed").font(.caption).foregroundStyle(FloeTheme.success)
                                    Text(version).font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Button("environment.packages.install") { installLinuxPackage(recommendation.package) }
                                    .buttonStyle(.borderless).disabled(!writable || linuxLoading)
                            }
                        }.font(.subheadline)
                    }
                    if let linuxError {
                        Label(linuxError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(FloeTheme.destructive)
                    }
                    if linuxLoading { ProgressView("environment.packages.linux.loading") }
                    Text("environment.packages.linux.installed.title").font(.subheadline.weight(.semibold))
                    if linuxPackages.isEmpty && linuxError == nil && !linuxLoading {
                        Text("environment.packages.linux.empty").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(linuxPackages.filter { matches($0.name) }) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.name)
                                Text(package.version).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("action.uninstall", role: .destructive) { pendingLinuxRemoval = package.name }
                                .buttonStyle(.borderless).disabled(!writable)
                        }.font(.subheadline)
                    }
                } else {
                    Label(LocalizedStringKey(linuxOwned
                            ? "environment.packages.linux.not_running"
                            : "environment.packages.linux.required"),
                          systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("environment.packages.linux.split").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let packages, !packages.installed.isEmpty || !packages.inherited.isEmpty {
                Section("environment.packages.installed") {
                    Text("environment.packages.layer.summary").font(.caption).foregroundStyle(.secondary)
                    ForEach(packages.installed.filter { matches($0.name) }, id: \.name) { package in
                        LabeledContent { Text(package.version).foregroundStyle(.secondary) } label: { Label(package.name, systemImage: "shippingbox") }
                    }
                    ForEach(packages.inherited.filter { matches($0.name) }, id: \.name) { package in
                        LabeledContent { Text("\(package.version) · \(package.layer.rawValue)").foregroundStyle(.secondary) } label: { Label(package.name, systemImage: "arrow.down.forward") }
                    }
                }
            }
            if record.kind.isWritableLayer {
                Section("environment.lifecycle.title") {
                    Button(record.state == .stopped ? "恢复环境" : "停止此环境的任务", systemImage: record.state == .stopped ? "play" : "stop") {
                        perform {
                            if record.state == .stopped { try await FloePlatformServices.shared.resumeEnvironment(id: report.id) }
                            else { try await FloePlatformServices.shared.stopEnvironment(id: report.id) }
                        }
                    }.disabled(busy || record.state == .deleting)
                    TextField("environment.template.name", text: $templateName)
                    Button("environment.template.save", systemImage: "doc.on.doc") {
                        perform { try await FloePlatformServices.shared.saveEnvironmentTemplate(id: report.id, name: templateName); templateName = "" }
                    }.disabled(busy || jobs.running.contains(report.id) || record.state != .stopped || record.requiresRebuild || templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("先停止环境，再保存模板，确保依赖副本一致。").font(.caption).foregroundStyle(.secondary)
                    Button("environment.delete.action", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
            }
        }
        .navigationTitle(record.name ?? displayName)
        .searchable(text: $query, prompt: "搜索软件包")
        .task {
            await reload()
            backendSelection = record.executionBackend ?? .native
            backendApplied = backendSelection
            await reloadGuestStatus()
        }
        .refreshable { await reload() }
        .onChange(of: jobs.revision) { Task { await reload(); await reloadGuestStatus() } }
        .confirmationDialog(
            pendingLinuxRemoval.map { String(format: String(localized: "environment.packages.linux.remove_confirm"), $0) } ?? "",
            isPresented: Binding(get: { pendingLinuxRemoval != nil }, set: { if !$0 { pendingLinuxRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("environment.packages.linux.remove_action", role: .destructive) {
                if let name = pendingLinuxRemoval {
                    runLinux(["apt-get", "remove", "-y", name],
                             String(format: String(localized: "environment.packages.linux.remove_title"), name))
                }
                pendingLinuxRemoval = nil
            }
            Button("action.cancel", role: .cancel) { pendingLinuxRemoval = nil }
        } message: { Text("environment.packages.linux.remove_message") }
        .confirmationDialog("删除此容器？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("environment.delete.stop_and_delete", role: .destructive) {
                perform { try await FloePlatformServices.shared.deleteEnvironment(id: report.id); dismiss() }
            }
        } message: { Text("将停止此环境的任务并删除其依赖和容器数据。有子会话的项目须先清理子会话；停止失败时保留数据。") }
    }
    private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }

    /// Download/retry entry for the pinned App-shared guest image. While the
    /// shared job runs, every environment opened on the same image id shows
    /// the same busy state and cannot start a second download.
    @ViewBuilder
    private var imageInstallControls: some View {
        if let jobID = imageJobID {
            if jobs.running.contains(jobID) {
                ProgressView("environment.backend.image_downloading")
                Button("action.cancel_task", role: .cancel) { jobs.cancel(id: jobID) }
                    .font(.caption)
            } else {
                if let message = jobs.messages[jobID], !message.isEmpty {
                    Text(message).font(.caption).textSelection(.enabled)
                        .foregroundStyle(jobs.failures.contains(jobID) ? FloeTheme.destructive : .secondary)
                }
                if jobs.failures.contains(jobID) {
                    Button("environment.backend.image_retry", systemImage: "arrow.down.circle") { installGuestImage() }
                        .disabled(backendBusy)
                } else {
                    Button("environment.backend.image_download", systemImage: "arrow.down.circle") { installGuestImage() }
                        .disabled(backendBusy)
                }
            }
        }
    }

    /// Starts the one App-shared download job for the pinned image id. The
    /// task lives in EnvironmentPackageJobs.shared, so leaving this view does
    /// not cancel it; a second environment tapping the same id joins it.
    private func installGuestImage() {
        guard let imageID = guestStatus?.imageID else { return }
        let jobID = Self.imageJobPrefix + imageID
        jobs.start(id: jobID,
                   title: String(format: String(localized: "environment.backend.image_download_title"), imageID)) {
            do {
                let installed = try await FloePlatformServices.shared.installLinuxGuestImage(id: imageID)
                return String(format: String(localized: "environment.backend.image_installed"), installed)
            } catch {
                // The image service wraps every download failure, including a
                // cancelled transfer. A user cancel is reported as a cancel so
                // the shared task state stays honest.
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    /// nil until the guest's dpkg database reports the recommended package as
    /// installed; architecture-qualified names keep their ":" qualifier.
    private func installedLinuxVersion(of package: String) -> String? {
        linuxPackages.first { $0.name == package || $0.name.hasPrefix(package + ":") }?.version
    }

    /// "Provides: xz" — display formatting of the command list only. The
    /// guest receives the real package name above, never a command name.
    private static func recommendedDetail(_ recommendation: LinuxRecommendation) -> String {
        String(format: String(localized: "environment.packages.linux.recommended.provides"),
               recommendation.commands.joined(separator: ", "))
    }

    /// Standard apt semantics: the selected recommended package name passes
    /// through to the guest verbatim (only `-y` is added because this UI has
    /// no terminal). The guest's own apt-get resolves whether it can install.
    private func installLinuxPackage(_ package: String) {
        runLinux(["apt-get", "install", "-y", package],
                 String(format: String(localized: "environment.packages.linux.install_title"), package))
    }

    private func runLinux(_ argv: [String], _ title: String) {
        let id = report.id
        jobs.start(id: id, title: title) {
            let token = CancellationToken()
            return try await withTaskCancellationHandler {
                let result = try await FloePlatformServices.shared.runLinuxCommand(
                    id: id, argv: argv, timeout: 600, cancellation: token)
                let output = [result.stdout, result.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                guard result.exitCode == 0 else {
                    throw FloeError.validationFailed(output.isEmpty
                        ? "\(String(localized: "environment.packages.linux.command_failed")) (exit \(result.exitCode))"
                        : output)
                }
                return output.isEmpty ? title : output
            } onCancel: { token.cancel() }
        }
    }

    /// Reads the guest's real dpkg database. Parsing dpkg-query output is
    /// display formatting; package decisions stay inside the guest.
    @MainActor private func refreshLinuxPackages() async {
        linuxLoading = true
        defer { linuxLoading = false }
        do {
            let result = try await FloePlatformServices.shared.runLinuxCommand(
                id: report.id,
                argv: ["dpkg-query", "-W", "-f=${binary:Package}\\t${Version}\\t${Status}\\n"],
                timeout: 60)
            guard result.exitCode == 0 else {
                linuxPackages = []
                linuxError = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "dpkg-query exit \(result.exitCode)"
                return
            }
            linuxPackages = Self.parseDpkgQuery(result.stdout)
            linuxError = nil
        } catch {
            linuxPackages = []
            linuxError = error.localizedDescription
        }
    }

    private static func parseDpkgQuery(_ output: String) -> [LinuxPackage] {
        output.split(separator: "\n").compactMap { line -> LinuxPackage? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  fields[2].trimmingCharacters(in: .whitespaces) == "install ok installed" else { return nil }
            return LinuxPackage(name: fields[0], version: fields[1])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor private func reload() async {
        do {
            packages = try await FloePlatformServices.shared.packageReport(id: report.id)
            current = try await FloePlatformServices.shared.environmentReports().first { $0.id == report.id }
            linuxAvailable = await FloePlatformServices.shared.linuxEnvironmentAvailable(id: report.id)
            linuxOwned = await FloePlatformServices.shared.linuxEnvironmentOwned(id: report.id)
            if linuxAvailable { await refreshLinuxPackages() } else { linuxPackages = []; linuxError = nil }
            error = nil
        } catch { self.error = String(describing: error) }
    }
    @MainActor private func reloadGuestStatus() async {
        imageStorageAvailable = FloePlatformServices.shared.linuxGuestImageStorageAvailable()
        guestStatus = await FloePlatformServices.shared.linuxEnvironmentStatus(id: report.id)
    }
    /// Applies a backend choice through the same platform service the shell
    /// entry uses; failures (unqualified image, guest start failure) surface
    /// with their real reason and the record keeps the selection.
    @MainActor private func apply(backend: EnvironmentExecutionBackend, stopOnly: Bool = false) {
        backendBusy = true
        Task {
            defer { backendBusy = false }
            do {
                if stopOnly {
                    try await FloePlatformServices.shared.stopEnvironment(id: report.id)
                } else {
                    try await FloePlatformServices.shared.setEnvironmentExecutionBackend(id: report.id, backend: backend)
                }
                backendApplied = backend
                backendSelection = backend
                await reload()
                await reloadGuestStatus()
            } catch {
                self.error = String(describing: error)
                // A failed guest start can leave the requested backend already
                // recorded (for example when the image is missing). Re-read
                // the record before deciding what the picker shows, so the
                // Linux section — including the image download entry — stays
                // reachable instead of snapping back to a native selection
                // the record no longer has.
                await reload()
                await reloadGuestStatus()
                let recorded = (current ?? report).record.executionBackend ?? .native
                backendApplied = recorded
                backendSelection = recorded
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await operation(); await reload() } catch { self.error = String(describing: error) }
        }
    }
}

/// Read-only view of the reviewed shell/apt tool routes. Only direct commands
/// and installed signed artifacts run on device; remote and unsupported
/// entries are shown with the reason nothing is installed.
struct ToolRouteCatalogView: View {
    let catalog: ToolCapabilityCatalog

    var body: some View {
        List {
            Section {
                Text("environment.tools.routes.summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ToolCapabilityCatalog.Route.allCases, id: \.self) { route in
                let entries = catalog.tools.filter { $0.route == route }
                if !entries.isEmpty {
                    Section(Self.routeTitle(route)) {
                        ForEach(entries) { tool in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(tool.displayName)
                                    Spacer()
                                    statusBadge(tool)
                                }
                                if !tool.commands.isEmpty {
                                    Text(tool.commands.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let gap = tool.artifactGap {
                                    Text(gap).font(.caption2).foregroundStyle(FloeTheme.pending)
                                }
                                if let alternative = tool.localAlternative {
                                    Text(alternative).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("environment.tools.routes.title")
    }

    @ViewBuilder
    private func statusBadge(_ tool: ToolCapabilityCatalog.Entry) -> some View {
        if tool.available {
            Label("environment.tools.routes.available", systemImage: "checkmark.circle.fill")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.success)
        } else if tool.installable {
            Label("environment.tools.routes.installable", systemImage: "arrow.down.circle")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.primary)
        } else if tool.route == .floePrecompiled {
            Label("environment.tools.routes.pending", systemImage: "clock")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
        } else {
            Label("environment.tools.routes.not_installed", systemImage: "minus.circle")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    static func routeTitle(_ route: ToolCapabilityCatalog.Route) -> LocalizedStringKey {
        switch route {
        case .direct: return "environment.tools.routes.direct"
        case .floePrecompiled: return "environment.tools.routes.floe_precompiled"
        case .remote: return "environment.tools.routes.remote"
        case .unsupported: return "environment.tools.routes.unsupported"
        }
    }
}

/// App-wide signed WASM catalog jobs. The task is owned here, not by the
/// view, so a download survives navigation; the store still serializes
/// operations per package and verifies the artifact before activation.
@MainActor final class WasmCapabilityJobs: ObservableObject {
    static let shared = WasmCapabilityJobs()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var failures: Set<String> = []
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(id: String, title: String, operation: @escaping @Sendable () async throws -> String) {
        guard !running.contains(id) else { return }
        running.insert(id)
        messages[id] = title
        failures.remove(id)
        tasks[id] = Task {
            do { messages[id] = try await operation() }
            catch is CancellationError { messages[id] = String(localized: "environment.capabilities.cancelled") }
            catch { messages[id] = error.localizedDescription; failures.insert(id) }
            running.remove(id)
            tasks[id] = nil
            revision += 1
        }
    }

    func cancel(id: String) {
        guard let task = tasks[id] else { return }
        messages[id] = String(localized: "environment.capabilities.cancelling")
        task.cancel()
    }
}

/// The recommended signed WASI catalog: list, download+install and remove.
/// Install goes through SignedWasmCapabilityStore, which downloads the
/// SHA-256-pinned artifact through the app's bounded HTTP transport and only
/// activates it after verification. Python, Node and Debian packages stay in
/// their own entries and never appear here.
struct WasmCapabilityCatalogView: View {
    @State private var installed: [String: String] = [:]
    @State private var loading = false
    @State private var error: String?
    @ObservedObject private var jobs = WasmCapabilityJobs.shared

    private var store: SignedWasmCapabilityStore? { FloeShellCommandRegistry.shared.wasm }

    var body: some View {
        List {
            Section {
                Text("environment.capabilities.summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if loading { ProgressView("environment.capabilities.loading") }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("action.reload") { Task { await reload() } }
                }
            }
            if let store {
                if store.catalog.packages.isEmpty {
                    ContentUnavailableView("environment.capabilities.empty.title", systemImage: "puzzlepiece.extension",
                                           description: Text("environment.capabilities.empty"))
                } else {
                    ForEach(store.catalog.packages, id: \.id) { entry in
                        row(entry)
                    }
                }
            } else {
                ContentUnavailableView("environment.capabilities.unavailable.title", systemImage: "puzzlepiece.extension",
                                       description: Text("environment.capabilities.unavailable"))
            }
        }
        .navigationTitle("environment.capabilities.title")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: jobs.revision) { Task { await reload() } }
    }

    @ViewBuilder
    private func row(_ entry: SignedWasmCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.id).font(.headline)
                Spacer()
                if installed[entry.id] != nil {
                    Label("environment.capabilities.installed", systemImage: "checkmark.circle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                } else {
                    Label("environment.tools.routes.not_installed", systemImage: "arrow.down.circle")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.primary)
                }
            }
            Text("\(entry.command) · \(entry.version)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if installed[entry.id] != nil {
                    Button("environment.capabilities.remove", role: .destructive) { remove(entry) }
                        .buttonStyle(.borderless)
                        .disabled(jobs.running.contains(entry.id))
                } else {
                    Button("environment.capabilities.install") { install(entry) }
                        .buttonStyle(.bordered)
                        .disabled(jobs.running.contains(entry.id))
                }
                if jobs.running.contains(entry.id) {
                    ProgressView()
                    Button("action.cancel") { jobs.cancel(id: entry.id) }
                        .buttonStyle(.borderless)
                }
            }
            .font(.subheadline)
            if let message = jobs.messages[entry.id] {
                Text(message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(jobs.failures.contains(entry.id) ? FloeTheme.destructive : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func install(_ entry: SignedWasmCatalog.Entry) {
        guard let store else { return }
        jobs.start(id: entry.id,
                   title: String(format: String(localized: "environment.capabilities.install_title"), entry.id)) {
            let token = CancellationToken()
            return try await withTaskCancellationHandler {
                try await store.install(id: entry.id, cancellation: token)
                return String(format: String(localized: "environment.capabilities.installed_message"), entry.id)
            } onCancel: { token.cancel() }
        }
    }

    private func remove(_ entry: SignedWasmCatalog.Entry) {
        guard let store else { return }
        jobs.start(id: entry.id,
                   title: String(format: String(localized: "environment.capabilities.remove_title"), entry.id)) {
            try await store.remove(id: entry.id)
            return String(format: String(localized: "environment.capabilities.removed_message"), entry.id)
        }
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let store else {
            installed = [:]
            error = nil
            return
        }
        installed = await store.installedVersions()
        error = nil
    }
}
#endif
