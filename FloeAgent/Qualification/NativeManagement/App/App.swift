import SwiftUI
import FloeCore
import FloePackages
import FloeEnvironments

@main struct ManagementSmokeApp: App {
    @AppStorage("floe.settings.appearance") private var appearanceValue = "system"
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if ProcessInfo.processInfo.arguments.contains("--thread") { ThreadFixtureView() }
                else if ProcessInfo.processInfo.arguments.contains("--appearance") {
                    Form {
                        AppearanceSettingsSection(selection: Binding(get: { AppearancePreference(rawValue: appearanceValue) ?? .system }, set: { appearanceValue = $0.rawValue }))
                        Section("工作区") { Label("Floe 项目", systemImage: "folder"); Label("最近任务", systemImage: "bubble.left.and.bubble.right") }
                        Section("执行环境") { NavigationLink("容器与软件包") { EnvironmentManagerView() } }
                    }.navigationTitle("通用")
                } else { EnvironmentManagerView() }
            }
            .preferredColorScheme(appearanceValue == "light" ? .light : appearanceValue == "dark" ? .dark : nil)
        }
    }
}

/// Fixture facade: the view and management API are production sources; only
/// app bootstrap/report enumeration are replaced with a deterministic sandbox.
final class FloePlatformServices: @unchecked Sendable {
    static let shared = FloePlatformServices()
    typealias PackageReport = EnvironmentManagementService.PackageReport
    typealias PackageAction = EnvironmentManagementService.PackageAction
    struct EnvironmentReport: Identifiable, Sendable {
        var id: String { record.id }
        let record: ContainerRecord
        let packages: [InstalledPackage]
        let bytes: Int64
        var issue: String? = nil
    }
    let roots: EnvironmentRoots
    let registry: EnvironmentRegistry
    let management: EnvironmentManagementService
    init() {
        roots = EnvironmentRoots(rootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("EnvironmentFixture"))
        registry = EnvironmentRegistry(roots: roots, baseRevision: "fixture-147")
        let lifecycle = ContainerLifecycle(roots: roots, registry: registry, cas: ContainerCAS(roots: roots), hooks: .init(stopSessions: { _ in }, cancelJobs: { await EnvironmentPackageJobs.shared.cancelAndWait(id: $0) }, terminateWorkers: { _ in }))
        management = EnvironmentManagementService(registry: registry, lifecycle: lifecycle, engine: AptEngine(downloader: .init { _, _ in throw URLError(.notConnectedToInternet) }))
    }
    func environmentReports() async throws -> [EnvironmentReport] {
        try await registry.prepare()
        _ = try await registry.ensureProjectContainer(workspaceID: "demo-a", workspaceRootPath: "/Synthetic/Floe 项目")
        _ = try await registry.ensureProjectContainer(workspaceID: "demo-b", workspaceRootPath: "/Synthetic/视频剪辑")
        _ = try await registry.ensureSessionContainer(conversationID: "字幕处理", workspaceID: "demo-a", workspaceRootPath: "/Synthetic/Floe 项目")
        return await registry.all().map { EnvironmentReport(record: $0, packages: [], bytes: 0) }
    }
    func languagePackageService() throws -> EnvironmentLanguagePackageService { EnvironmentLanguagePackageService() }
    func packageReport(id: String) async throws -> PackageReport { try await management.packageReport(id: id) }
    func managePackage(id: String, action: PackageAction) async throws -> String { try await management.managePackage(id: id, action: action) }
    func stopEnvironment(id: String) async throws { try await management.stopEnvironment(id: id) }
    func resumeEnvironment(id: String) async throws { try await management.resumeEnvironment(id: id) }
    func deleteEnvironment(id: String) async throws { try await management.deleteEnvironment(id: id) }
    func saveEnvironmentTemplate(id: String, name: String) async throws { try await management.saveEnvironmentTemplate(id: id, name: name) }
}

/// This visual fixture has no embedded language runtimes. Never simulate successful installs.
actor EnvironmentLanguagePackageService {
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case python, node
        var id: String { rawValue }
        var title: String { self == .python ? "Python · PyPI" : "Node.js · npm" }
    }
    struct Package: Identifiable, Sendable {
        let id: String; let name: String; let version: String; let layerID: String; let writable: Bool
    }
    func packages(environmentID: String, language: Language) async throws -> [Package] {
        throw FloeError.invalidConfiguration("此界面验证应用未附带语言运行时；安装验证使用完整 App")
    }
    func change(environmentID: String, language: Language, specification: String, remove: Bool) async throws -> String {
        throw FloeError.invalidConfiguration("此界面验证应用不能安装软件包")
    }
}
