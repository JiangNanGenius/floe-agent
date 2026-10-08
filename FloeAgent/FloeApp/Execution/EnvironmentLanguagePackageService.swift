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
    /// Linux guest ownership. Phase 2: language packages live only inside the
    /// environment's guest (shared Python venv, environment
    /// `usr/lib/node_modules`). A native-backend environment keeps its
    /// preserved installs readable and reports that mutation requires the
    /// Linux backend; there is no host-side installer anymore.
    private let linux: LinuxGuestLanguagePackages?
    private var busy: Set<String> = []
    init(coordinator: EnvironmentExecutionCoordinator, python: ManagedPythonInstallService?,
         linux: LinuxGuestLanguagePackages? = nil) {
        self.coordinator = coordinator; self.python = python; self.linux = linux
    }

    func packages(environmentID: String, language: Language) async throws -> [Package] {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_dependency_transaction_has_not_finished")) }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: CancellationToken())
        do {
            guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.environment_unresolved")) }
            if let linux, await linux.owns(environmentID: environmentID) {
                // The readback comes from the same guest installation the
                // shell and the installers use. A stopped guest reports the
                // honest "start the Linux environment" error instead of
                // scanning host-layer paths that the guest does not own.
                let result: [Package]
                switch language {
                case .python:
                    result = try await linux.pythonInventory(environment: environment, cancellation: CancellationToken())
                        .map { Package(name: $0.name, version: $0.version,
                                       layerID: $0.writable ? "python/venv" : "guest-system",
                                       writable: $0.writable) }
                case .node:
                    result = try await linux.nodeInventory(environment: environment, cancellation: CancellationToken())
                        .map { Package(name: $0.name, version: $0.version,
                                       layerID: "usr/lib/node_modules", writable: true) }
                }
                await lease.finish()
                return result.sorted { ($0.writable ? "0" : "1") + $0.name < ($1.writable ? "0" : "1") + $1.name }
            }
            if language == .node { try LegacyNodeInstallRecovery.recover(environment) }
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
                        version = lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst(9)) } ?? FloeL10n.l("execution.environment_language_package_service.unknown_2")
                    } else {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        guard let packageName = json?["name"] as? String, let packageVersion = json?["version"] as? String else {
                            throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_package_manifest_is_incomplete", directory.lastPathComponent))
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
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.dependencies_are_being_installed_or_removed")) }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: token)
            do {
                guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.environment_unresolved")) }
                let output: String
                if language == .python {
                    guard let python else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.this_build_does_not_provide_a")) }
                    if let linux, await linux.owns(environmentID: environmentID) {
                        try await ensureGuestRunning(environmentID: environmentID)
                    }
                    let outcome = remove
                        ? await python.uninstall(distribution: specification, environment: environment, cancellation: token)
                        : await python.install(specs: [specification], timeout: 180, cancellation: token, environment: environment)
                    switch outcome {
                    case .ok(let text): output = text
                    case .failed(let message): throw FloeError.validationFailed(message)
                    case .timedOut(let partial): throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.installation_timed_out_reload_dependencies_and") + partial)
                    case .cancelled: throw CancellationError()
                    }
                } else {
                    let preference = try readNodePreference(environment)
                    let manager = try NodePackageManagerPolicy.resolve(preference: preference, workspace: lease.context.workspaceRootURL)
                    if let linux, await linux.owns(environmentID: environmentID) {
                        try await ensureGuestRunning(environmentID: environmentID)
                        output = try await linux.nodeChange(
                            environment: environment,
                            specifications: [specification],
                            remove: remove,
                            manager: manager,
                            cancellation: token
                        )
                    } else {
                        // No host Node runtime remains; the preserved installs
                        // stay readable and the layer files are untouched.
                        throw FloeError.validationFailed(ManagedPythonInstallService.linuxRequiredMessage)
                    }
                }
                await lease.finish()
                return output.isEmpty ? FloeL10n.l("execution.environment_language_package_service.dependencies_updated") : output
            } catch { await lease.finish(); throw error }
        } onCancel: { token.cancel() }
    }

    /// Shell already owns the execution lease. Acquiring a management lease
    /// here would wait on itself; serialize with UI transactions using busy.
    func changeNodeFromShell(environment: ToolEnvironment, change: NodePackageManagerPolicy.Change,
                             manager: NodePackageManager, cancellation: CancellationToken) async throws -> String {
        guard !busy.contains(environment.id) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.dependencies_are_being_installed_or_removed")) }
        busy.insert(environment.id)
        defer { busy.remove(environment.id) }
        if let linux, await linux.owns(environmentID: environment.id) {
            try await ensureGuestRunning(environmentID: environment.id)
            return try await linux.nodeChange(
                environment: environment,
                specifications: change.specifications,
                remove: change.remove,
                manager: manager,
                cancellation: cancellation
            )
        }
        throw FloeError.validationFailed(ManagedPythonInstallService.linuxRequiredMessage)
    }

    /// Lazy activation for package operations: an owned-but-stopped guest is
    /// started on demand so installs never fail on "not running" alone.
    private func ensureGuestRunning(environmentID: String) async throws {
        try await FloePlatformServices.shared.activateLinuxGuestWithPreparation(id: environmentID)
    }

    func pythonFromShell(environment: ToolEnvironment, operation: ManagedPythonPackageSpecParser.ShellOperation,
                         cancellation: CancellationToken) async throws -> String {
        guard !busy.contains(environment.id) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.dependencies_are_being_installed_or_removed")) }
        guard let python else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.this_build_does_not_provide_a")) }
        busy.insert(environment.id)
        defer { busy.remove(environment.id) }
        if let linux, await linux.owns(environmentID: environment.id) {
            try await ensureGuestRunning(environmentID: environment.id)
        }
        let outcome: ManagedPythonInstallService.Outcome
        switch operation {
        case .install(let specs): outcome = await python.install(specs: specs, timeout: 180, cancellation: cancellation, environment: environment)
        case .remove(let name): outcome = await python.uninstall(distribution: name, environment: environment, cancellation: cancellation)
        case .inspect(let command, let arguments):
            outcome = await python.inspect(command: command, arguments: arguments, environment: environment, cancellation: cancellation)
        }
        switch outcome {
        case .ok(let output): return output
        case .failed(let message): throw FloeError.validationFailed(message)
        case .timedOut(let output): throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.pip_timed_out_the_dependency_transaction") + output)
        case .cancelled: throw CancellationError()
        }
    }

    struct NodeManagerSelection: Sendable {
        var preference: NodePackageManagerPreference
        var resolved: NodePackageManager?
        var issue: String?
    }

    func sources(environmentID: String, set value: LanguagePackageSources? = nil) async throws -> LanguagePackageSources {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_dependency_transaction_has_not_finished")) }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: CancellationToken())
        do {
            guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.environment_unresolved")) }
            if let value { try value.save(in: environment.writableLayerURL) }
            let result = try LanguagePackageSources.load(in: environment.writableLayerURL)
            await lease.finish()
            return result
        } catch { await lease.finish(); throw error }
    }

    func nodeManagerSelection(environmentID: String, set preference: NodePackageManagerPreference? = nil) async throws -> NodeManagerSelection {
        guard !busy.contains(environmentID) else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_dependency_transaction_has_not_finished")) }
        busy.insert(environmentID)
        defer { busy.remove(environmentID) }
        let lease = try await coordinator.acquireManagement(environmentID: environmentID, cancellation: CancellationToken())
        do {
            guard let environment = lease.context.environment else { throw FloeError.invalidConfiguration(FloeL10n.l("execution.environment_language_package_service.environment_unresolved")) }
            if let preference {
                let file = try contained("var/node-package-manager.json", in: environment.writableLayerURL)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(preference).write(to: file, options: .atomic)
            }
            let selected = try readNodePreference(environment)
            let result: NodeManagerSelection
            do {
                let resolved = try NodePackageManagerPolicy.resolve(preference: selected, workspace: lease.context.workspaceRootURL)
                if let linux, await linux.owns(environmentID: environmentID) {
                    if await linux.isRunning(environmentID: environmentID) {
                        let managers = await linux.nodeManagers(environmentID: environmentID, cancellation: CancellationToken())
                        if resolved == .pnpm, managers.pnpmPath == nil {
                            // pnpm is never installed implicitly; an explicit
                            // selection reports the missing guest manager
                            // before any change is attempted.
                            result = .init(preference: selected, resolved: resolved,
                                           issue: FloeL10n.l("execution.environment_language_package_service.pnpm_was_not_found_in_the"))
                        } else {
                            result = .init(preference: selected, resolved: resolved)
                        }
                    } else {
                        result = .init(preference: selected, resolved: nil,
                                       issue: FloeL10n.l("execution.environment_language_package_service.the_linux_environment_is_not_running"))
                    }
                } else {
                    // Native backend: the manager is resolved for the record,
                    // but installs run only inside the Linux guest.
                    result = .init(preference: selected, resolved: resolved,
                                   issue: FloeL10n.l("execution.environment_language_package_service.the_current_environment_uses_the_native"))
                }
            } catch { result = .init(preference: selected, issue: error.localizedDescription) }
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
        guard candidate.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_dependency_path_is_outside_the")) }
        return candidate
    }
    private func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_package_manifest_is_missing_or"))
        }
        return try Data(contentsOf: url)
    }

}
