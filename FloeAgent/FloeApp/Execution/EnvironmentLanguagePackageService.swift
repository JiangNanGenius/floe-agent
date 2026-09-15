// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools

/// Explicit environment selection; operations share lifecycle leases with Agent tools.
actor EnvironmentLanguagePackageService {
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case python, node
        var id: String { rawValue }
        var title: String { self == .python ? "Python · PyPI" : "Node.js · npm / pnpm" }
    }
    struct Package: Identifiable, Sendable {
        var id: String { layerID + ":" + name }
        let name: String
        let version: String
        let layerID: String
        let writable: Bool
    }
    private let coordinator: EnvironmentExecutionCoordinator
    private let python: ManagedPythonInstallService?
    private var busy: Set<String> = []
    init(coordinator: EnvironmentExecutionCoordinator, python: ManagedPythonInstallService?) {
        self.coordinator = coordinator; self.python = python
    }

    func packages(environmentID: String, language: Language) async throws -> [Package] {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed("依赖事务尚未结束") }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: CancellationToken())
        do {
            guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration("环境未解析") }
            if language == .node { try nodeInstaller().recover(environment) }
            else if let python { try await python.recover(environment: environment) }
            var result: [Package] = []
            for (index, layer) in environment.layerURLs.enumerated() {
                let root = try contained(language == .python ? "usr/lib/floe-python/site-packages" : "usr/lib/node_modules", in: layer)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                var directories: [URL] = []
                for entry in entries {
                    if language == .python {
                        if entry.lastPathComponent.hasSuffix(".dist-info") { directories.append(entry) }
                    } else if entry.lastPathComponent.hasPrefix("@") {
                        _ = try contained(entry.lastPathComponent, in: root)
                        directories += try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                    } else if !entry.lastPathComponent.hasPrefix(".") { directories.append(entry) }
                }
                for directory in directories {
                    // Older uninstallers left empty dist-info directories.
                    // They carry no installed package; tolerate those remnants
                    // while still reporting incomplete, nonempty metadata.
                    if language == .python {
                        let checked = try contained(directory.lastPathComponent, in: root)
                        if try FileManager.default.contentsOfDirectory(atPath: checked.path).isEmpty { continue }
                    }
                    let relative = String(directory.path.dropFirst(root.path.count + 1)) + (language == .python ? "/METADATA" : "/package.json")
                    let metadata = try contained(relative, in: root)
                    let data = try boundedData(metadata)
                    let name: String, version: String
                    if language == .python {
                        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                        name = lines.first { $0.hasPrefix("Name: ") }.map { String($0.dropFirst(6)) } ?? directory.deletingPathExtension().lastPathComponent
                        version = lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst(9)) } ?? "未知"
                    } else {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        guard let packageName = json?["name"] as? String, let packageVersion = json?["version"] as? String else {
                            throw FloeError.validationFailed("软件包清单不完整：\(directory.lastPathComponent)")
                        }
                        name = packageName; version = packageVersion
                    }
                    result.append(Package(name: name, version: version, layerID: layer.lastPathComponent,
                                          writable: index == 0 && layer.standardizedFileURL == environment.writableLayerURL.standardizedFileURL))
                }
            }
            await lease.finish()
            return result.sorted { ($0.writable ? "0" : "1") + $0.name < ($1.writable ? "0" : "1") + $1.name }
        } catch { await lease.finish(); throw error }
    }

    func change(environmentID: String, language: Language, specification: String, remove: Bool) async throws -> String {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed("此环境正在安装或卸载依赖") }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: token)
            do {
                guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration("环境未解析") }
                let output: String
                if language == .python {
                    guard let python else { throw FloeError.invalidConfiguration("此构建未提供 Python 运行时") }
                    let outcome = remove
                        ? await python.uninstall(distribution: specification, environment: environment, cancellation: token)
                        : await python.install(specs: [specification], timeout: 180, cancellation: token, environment: environment)
                    switch outcome {
                    case .ok(let text): output = text
                    case .failed(let message): throw FloeError.validationFailed(message)
                    case .timedOut(let partial): throw FloeError.validationFailed("安装超时，重新读取依赖后可重试。\n" + partial)
                    case .cancelled: throw CancellationError()
                    }
                } else {
                    let preference = try readNodePreference(environment)
                    let manager = try NodePackageManagerPolicy.resolve(preference: preference, workspace: lease.context.workspaceRootURL)
                    output = try await nodeInstaller().change(environment, specification: specification, remove: remove, manager: manager, cancellation: token)
                }
                await lease.finish()
                return output.isEmpty ? "依赖已更新" : output
            } catch { await lease.finish(); throw error }
        } onCancel: { token.cancel() }
    }

    struct NodeManagerSelection: Sendable {
        var preference: NodePackageManagerPreference
        var resolved: NodePackageManager?
        var issue: String?
    }

    func nodeManagerSelection(environmentID: String, set preference: NodePackageManagerPreference? = nil) async throws -> NodeManagerSelection {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed("依赖事务尚未结束") }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: CancellationToken())
        do {
            guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration("环境未解析") }
            if let preference {
                let file = try contained("var/node-package-manager.json", in: environment.writableLayerURL)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(preference).write(to: file, options: .atomic)
            }
            let selected = try readNodePreference(environment)
            let result: NodeManagerSelection
            do { result = .init(preference: selected, resolved: try NodePackageManagerPolicy.resolve(preference: selected, workspace: lease.context.workspaceRootURL)) }
            catch { result = .init(preference: selected, issue: error.localizedDescription) }
            await lease.finish()
            return result
        } catch { await lease.finish(); throw error }
    }

    private func readNodePreference(_ environment: ToolEnvironment) throws -> NodePackageManagerPreference {
        let file = try contained("var/node-package-manager.json", in: environment.writableLayerURL)
        guard FileManager.default.fileExists(atPath: file.path) else { return .automatic }
        return try JSONDecoder().decode(NodePackageManagerPreference.self, from: boundedData(file))
    }

    private func contained(_ relative: String, in root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed("依赖路径越出环境") }
        return candidate
    }
    private func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
            throw FloeError.validationFailed("软件包清单缺失或过大")
        }
        return try Data(contentsOf: url)
    }

    private func nodeInstaller() throws -> ManagedNodeInstallService {
        guard let npm = FloeNodeBundledToolPath("npm"), IOSSystemNodeRuntime.shared.isAvailable else {
            throw FloeError.invalidConfiguration("npm 运行时尚未就绪")
        }
        return ManagedNodeInstallService(runtime: IOSSystemNodeRuntime.shared, npmEntry: npm, pnpmEntry: FloeNodeBundledToolPath("pnpm")) { environment, directory in
            IOSSystemNodeRuntime.defaultEnvironment(containerRoot: environment.writableLayerURL, workspaceRoot: directory)
        }
    }
}
