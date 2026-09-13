// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

/// Staged, recoverable registry installs for JavaScript-only dependencies.
public struct ManagedNodeInstallService: Sendable {
    private let runtime: any NodeRuntime
    private let npm: String
    private let environmentDefaults: @Sendable (ToolEnvironment, URL) -> [String: String]
    public init(runtime: any NodeRuntime, npmEntry: String,
                environmentDefaults: @escaping @Sendable (ToolEnvironment, URL) -> [String: String] = { _, _ in [:] }) {
        self.runtime = runtime; self.npm = npmEntry; self.environmentDefaults = environmentDefaults
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

    public func change(_ environment: ToolEnvironment, specification: String, remove: Bool, cancellation: CancellationToken) async throws -> String {
        // Package names and registry versions only; no paths, Git URLs or shell argument parsing.
        let pattern = remove ? #"^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$"# : #"^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*(?:@[A-Za-z0-9.*~^+_-][A-Za-z0-9.*~^+_-]*)?$"#
        guard specification.range(of: pattern, options: .regularExpression) != nil else { throw FloeError.validationFailed("请输入 npm 包名，可附加 @版本；不接受路径或 Git URL") }
        try recover(environment)
        let fm = FileManager.default, transaction = try transactionRoot(environment)
        let destination = try contained("usr/lib/node_modules", in: environment.writableLayerURL)
        let prefix = transaction.appendingPathComponent("stage")
        let staged = prefix.appendingPathComponent("lib/node_modules")
        let backup = transaction.appendingPathComponent("backup")
        var journal = NodeJournal(phase: "prepared", hadOriginal: fm.fileExists(atPath: destination.path))
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let journalURL = transaction.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            if journal.hadOriginal {
                try validateNodeTree(destination)
                try fm.copyItem(at: destination, to: staged)
            } else { try fm.createDirectory(at: staged, withIntermediateDirectories: true) }
            if remove, !fm.fileExists(atPath: staged.appendingPathComponent(specification).path) {
                throw FloeError.validationFailed("所选包未安装在本层；继承依赖应在其所属环境中卸载")
            }
            var variables = environmentDefaults(environment, prefix)
                .merging(environment.variables) { _, resolved in resolved }
            variables["npm_config_userconfig"] = transaction.appendingPathComponent("empty.npmrc").path
            variables["npm_config_globalconfig"] = transaction.appendingPathComponent("empty-global.npmrc").path
            let request = NodeRunRequest(entryScript: npm,
                arguments: [remove ? "uninstall" : "install", "--global", "--prefix", prefix.path,
                    "--ignore-scripts", "--bin-links=false", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org/", specification],
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
            try validateNodeTree(staged)
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
