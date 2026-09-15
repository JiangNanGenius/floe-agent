// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

/// Staged, recoverable registry installs for JavaScript-only dependencies.
public struct ManagedNodeInstallService: Sendable {
    private let runtime: any NodeRuntime
    private let npm: String
    private let pnpm: String?
    private let environmentDefaults: @Sendable (ToolEnvironment, URL) -> [String: String]
    public init(runtime: any NodeRuntime, npmEntry: String, pnpmEntry: String? = nil,
                environmentDefaults: @escaping @Sendable (ToolEnvironment, URL) -> [String: String] = { _, _ in [:] }) {
        self.runtime = runtime; self.npm = npmEntry; self.pnpm = pnpmEntry; self.environmentDefaults = environmentDefaults
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

    private struct NodeJournal: Codable { var phase: String; let hadOriginal: Bool }
    private func transactionRoot(_ environment: ToolEnvironment) throws -> URL {
        try contained("var/floe-node-transaction", in: environment.writableLayerURL)
    }
    /// A previous process may have died between the two renames. Restore the old generation.
    public func recover(_ environment: ToolEnvironment) throws {
        let fm = FileManager.default, transaction = try transactionRoot(environment)
        guard fm.fileExists(atPath: transaction.path) else { return }
        let journalURL = try contained("journal.json", in: transaction)
        guard fm.fileExists(atPath: journalURL.path) else {
            throw FloeError.validationFailed("npm 暂存目录缺少恢复记录；保留文件，请检查环境")
        }
        let journal = try JSONDecoder().decode(NodeJournal.self, from: boundedData(journalURL))
        let backup = try contained("backup", in: transaction)
        let destination = try contained("usr/lib/node_modules", in: environment.writableLayerURL)
        guard ["prepared", "committing", "committed"].contains(journal.phase) else { throw FloeError.validationFailed("npm 恢复记录无效") }
        if journal.phase == "committing" {
            if fm.fileExists(atPath: backup.path) {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: backup, to: destination)
            } else if !journal.hadOriginal, fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        }
        try fm.removeItem(at: transaction)
    }

    private func validateNodeTree(_ root: URL) throws {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
            throw FloeError.validationFailed("npm 未产生可读取的安装目录")
        }
        while let file = files.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw FloeError.validationFailed("此 npm 包包含符号链接，尚不支持在受管理环境安装") }
            if ["node", "so", "dylib", "dll", "exe", "a"].contains(file.pathExtension.lowercased()) {
                throw FloeError.validationFailed("此 npm 包包含原生二进制，需要经过 ABI 验证的预构建版本")
            }
            if file.lastPathComponent == "package.json", values.isRegularFile == true,
               let json = try JSONSerialization.jsonObject(with: boundedData(file)) as? [String: Any],
               let scripts = json["scripts"] as? [String: Any],
               ["preinstall", "install", "postinstall"].contains(where: { scripts[$0] != nil }) {
                throw FloeError.validationFailed("此 npm 包需要安装脚本，尚未接入受管理安装：\(json["name"] as? String ?? "unknown")")
            }
        }
    }

    public func change(_ environment: ToolEnvironment, specification: String, remove: Bool, manager: NodePackageManager = .npm, cancellation: CancellationToken) async throws -> String {
        try await change(environment, specifications: [specification], remove: remove, manager: manager, cancellation: cancellation)
    }

    public func change(_ environment: ToolEnvironment, specifications: [String], remove: Bool, manager: NodePackageManager = .npm, cancellation: CancellationToken) async throws -> String {
        // Validate every argument before touching a prior dependency generation.
        guard specifications.count <= 256 else { throw FloeError.validationFailed("一次最多更新 256 个依赖") }
        for specification in specifications { try NodePackageManagerPolicy.validateSpecification(specification, remove: remove) }
        let managerEntry: String
        switch manager {
        case .npm: managerEntry = npm
        case .pnpm:
            guard let pnpm else { throw FloeError.validationFailed("此构建没有可用的 pnpm") }
            managerEntry = pnpm
        }
        try recover(environment)
        let fm = FileManager.default, transaction = try transactionRoot(environment)
        let destination = try contained("usr/lib/node_modules", in: environment.writableLayerURL)
        let prefix = transaction.appendingPathComponent("stage")
        let staged = prefix.appendingPathComponent("node_modules")
        let backup = transaction.appendingPathComponent("backup")
        var journal = NodeJournal(phase: "prepared", hadOriginal: fm.fileExists(atPath: destination.path))
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let journalURL = transaction.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            var dependencies: [String: String] = [:]
            let metadataName = ".floe-install"
            let previousMetadata = destination.appendingPathComponent(metadataName)
            if journal.hadOriginal {
                try validateNodeTree(destination)
                if fm.fileExists(atPath: previousMetadata.appendingPathComponent("dependencies.json").path) {
                    dependencies = try JSONDecoder().decode([String: String].self, from: boundedData(previousMetadata.appendingPathComponent("dependencies.json")))
                } else {
                    // Legacy global installs: each top-level package was explicitly
                    // installed. Preserve it as a direct dependency during migration.
                    var entries = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                    for scope in entries.filter({ $0.lastPathComponent.hasPrefix("@") }) {
                        entries += try fm.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil)
                    }
                    for directory in entries where !directory.lastPathComponent.hasPrefix(".") && !directory.lastPathComponent.hasPrefix("@") {
                        let manifest = directory.appendingPathComponent("package.json")
                        guard let json = try JSONSerialization.jsonObject(with: boundedData(manifest)) as? [String: Any],
                              let name = json["name"] as? String, let version = json["version"] as? String else {
                            throw FloeError.validationFailed("现有依赖缺少有效清单")
                        }
                        dependencies[name] = version
                    }
                }
            }
            for specification in specifications {
                if remove {
                    guard dependencies.removeValue(forKey: specification) != nil else {
                        throw FloeError.validationFailed("此包不是本层直接安装的依赖；请先检查依赖它的软件包")
                    }
                } else {
                    let split = specification.dropFirst().lastIndex(of: "@")
                    let name = split.map { String(specification[..<$0]) } ?? specification
                    let version = split.map { String(specification[specification.index(after: $0)...]) } ?? "latest"
                    dependencies[name] = version
                }
            }
            for (name, version) in dependencies {
                try NodePackageManagerPolicy.validateSpecification(name + "@" + version, remove: false)
            }
            let manifest: [String: Any] = ["name": "floe-managed-environment", "version": "1.0.0", "private": true, "dependencies": dependencies]
            try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: prefix.appendingPathComponent("package.json"))
            let lockName = manager == .npm ? "package-lock.json" : "pnpm-lock.yaml"
            let oldLock = previousMetadata.appendingPathComponent(lockName)
            if fm.fileExists(atPath: oldLock.path) {
                try boundedData(oldLock).write(to: prefix.appendingPathComponent(lockName))
            }
            var variables = environmentDefaults(environment, prefix)
                .merging(environment.variables) { _, resolved in resolved }
            variables["CI"] = "1"
            variables["npm_config_prefix"] = prefix.path
            variables["npm_config_global"] = "false"
            variables["npm_config_userconfig"] = transaction.appendingPathComponent("empty.npmrc").path
            variables["npm_config_globalconfig"] = transaction.appendingPathComponent("empty-global.npmrc").path
            variables["npm_config_manage_package_manager_versions"] = "false"
            let common = ["install", "--ignore-scripts", "--registry=https://registry.npmjs.org/"]
            let options = manager == .npm ? ["--bin-links=false", "--no-audit", "--no-fund"] :
                ["--config.node-linker=hoisted", "--package-import-method=copy", "--no-frozen-lockfile", "--config.bin-links=false", "--config.verify-deps-before-run=never"]
            let request = NodeRunRequest(entryScript: managerEntry, arguments: common + options,
                workingDirectory: prefix, environment: variables, timeout: 180)
            let result = await runtime.run(request, cancellation: cancellation)
            let output: String
            switch result {
            case .exited(let code, let stdout, let stderr, _, _):
                guard code == 0 else { throw FloeError.validationFailed("npm 退出码 \(code)\n" + stdout + "\n" + stderr) }
                output = stdout + (stderr.isEmpty ? "" : "\n" + stderr)
            case .failed(let message): throw FloeError.validationFailed(message)
            case .timedOut(let stdout, let stderr, _): throw FloeError.validationFailed("npm 超时，原有依赖已保留\n" + stdout + "\n" + stderr)
            case .cancelled: throw CancellationError()
            }
            try cancellation.throwIfCancelled()
            if dependencies.isEmpty && !fm.fileExists(atPath: staged.path) { try fm.createDirectory(at: staged, withIntermediateDirectories: true) }
            try validateNodeTree(staged)
            let metadata = staged.appendingPathComponent(metadataName)
            try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
            try JSONEncoder().encode(dependencies).write(to: metadata.appendingPathComponent("dependencies.json"))
            let newLock = prefix.appendingPathComponent(lockName)
            if fm.fileExists(atPath: newLock.path) { try boundedData(newLock).write(to: metadata.appendingPathComponent(lockName)) }
            try Data(manager.rawValue.utf8).write(to: metadata.appendingPathComponent("manager"))
            journal.phase = "committing"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if journal.hadOriginal { try fm.moveItem(at: destination, to: backup) }
            try fm.moveItem(at: staged, to: destination)
            journal.phase = "committed"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try recover(environment)
            return output
        } catch {
            do { try recover(environment) }
            catch { throw FloeError.validationFailed("npm 恢复未完成，暂存数据已保留：\(error.localizedDescription)") }
            throw error
        }
    }
}
