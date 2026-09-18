import Foundation
import FloeCore

public enum NodePackageManager: String, Codable, CaseIterable, Sendable {
    case npm, pnpm
}

public enum NodePackageManagerPreference: String, Codable, CaseIterable, Sendable {
    case automatic, npm, pnpm
}

/// Who selected the manager for one package change.
public enum NodePackageManagerRequest: Sendable {
    /// The typed shell command named the manager (`npm install`, `pnpm add`).
    /// It is authoritative: the configured default and the project's lock
    /// file are automatic-selection hints, never grounds to run a different
    /// manager behind the user's back.
    case explicit(NodePackageManager)
    /// A UI or agent install that did not name a manager. Only this path may
    /// consult the configured preference and the project's declaration/lock.
    case automatic(preference: NodePackageManagerPreference)
}

/// Read-only project hints. Environment installs never rewrite a project's lock.
public enum NodePackageManagerPolicy {
    /// Resolves an automatic (unnamed) selection: the configured environment
    /// preference, then the project's declared `packageManager` or single lock
    /// file, then npm.
    public static func resolve(preference: NodePackageManagerPreference, workspace: URL?) throws -> NodePackageManager {
        if preference == .npm { return .npm }
        if preference == .pnpm { return .pnpm }
        guard let workspace else { return .npm }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        var locks: Set<String> = []
        for (name, manager) in [("package-lock.json", "npm"), ("npm-shrinkwrap.json", "npm"), ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn")] {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { locks.insert(manager) }
        }
        let manifest = root.appendingPathComponent("package.json").resolvingSymlinksInPath()
        guard manifest.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed("package.json 越出工作区") }
        var declared: String?
        if FileManager.default.fileExists(atPath: manifest.path) {
            let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_097_152,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                throw FloeError.validationFailed("无法读取项目 package.json")
            }
            if let value = json["packageManager"] {
                guard let value = value as? String, let separator = value.firstIndex(of: "@") else {
                    throw FloeError.validationFailed("项目 packageManager 格式无效")
                }
                declared = String(value[..<separator])
            }
        }
        guard locks.count <= 1, declared == nil || locks.isEmpty || locks.contains(declared!) else {
            throw FloeError.validationFailed("项目的 packageManager 与锁文件冲突。请整理项目，或明确选择本环境使用的 npm / pnpm；环境安装不会改写项目锁文件。")
        }
        let selected = declared ?? locks.first
        guard let selected else { return .npm }
        guard let manager = NodePackageManager(rawValue: selected) else {
            throw FloeError.validationFailed("项目要求 \(selected)。本环境支持 npm / pnpm，请明确选择；原项目锁文件会保留。")
        }
        return manager
    }

    /// Resolves one package change. Explicit shell commands are returned
    /// unchanged; only `.automatic` consults the preference and the project.
    public static func resolve(_ request: NodePackageManagerRequest, workspace: URL?) throws -> NodePackageManager {
        switch request {
        case .explicit(let manager):
            return manager
        case .automatic(let preference):
            return try resolve(preference: preference, workspace: workspace)
        }
    }
}

public extension NodePackageManagerPolicy {
    struct Change: Sendable {
        public let specifications: [String]
        public let remove: Bool
    }

    static func validateSpecification(_ value: String, remove: Bool = false) throws {
        let pattern = remove
            ? #"^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$"#
            : #"^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*(?:@[A-Za-z0-9.*~^+_><=-][A-Za-z0-9.*~^+_><=| -]*)?$"#
        guard value.utf8.count <= 512, value.range(of: pattern, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("请输入 npm 包名，可附加 @版本范围；不接受路径或 Git URL")
        }
    }

    /// Mutating Shell commands use the same environment transaction as settings.
    /// package.json is read, never rewritten; a project install adds its declared
    /// dependencies to this environment rather than changing the workspace files.
    static func shellChange(arguments: [String], directory: URL, workspace: URL) throws -> Change? {
        var args = arguments
        while args.first == "-g" || args.first == "--global" { args.removeFirst() }
        guard let command = args.first else { return nil }
        let installing = ["install", "i", "add"].contains(command)
        let removing = ["uninstall", "un", "remove", "rm"].contains(command)
        if ["ci", "update", "up", "dedupe", "rebuild", "link", "unlink"].contains(command) {
            throw FloeError.validationFailed("受管理环境请使用 npm/pnpm install 或 remove；项目锁文件不会在这里改写")
        }
        guard installing || removing else {
            if command.hasPrefix("-"), args.contains(where: { ["install", "i", "add", "remove", "rm", "uninstall"].contains($0) }) {
                throw FloeError.validationFailed("请将 install/remove 放在管理器名称后；安装位置由当前环境决定")
            }
            return nil
        }
        args.removeFirst()
        args.removeAll { ["-g", "--global", "--save", "--save-dev", "-D", "--save-prod", "-P", "--ignore-scripts", "--no-audit", "--no-fund"].contains($0) }
        guard !args.contains(where: { $0.hasPrefix("-") }) else {
            throw FloeError.validationFailed("安装位置和安装脚本由环境管理；不支持此命令选项")
        }
        if args.isEmpty && !removing {
            let root = workspace.resolvingSymlinksInPath().standardizedFileURL
            let manifest = directory.appendingPathComponent("package.json").resolvingSymlinksInPath().standardizedFileURL
            guard manifest.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed("项目清单越出当前工作区") }
            let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                throw FloeError.validationFailed("项目 package.json 不可读取或过大")
            }
            var dependencies: [String: String] = [:]
            for key in ["dependencies", "devDependencies"] {
                if let value = json[key] {
                    guard let entries = value as? [String: String] else { throw FloeError.validationFailed("项目依赖清单无效") }
                    for (name, version) in entries {
                        if let existing = dependencies[name], existing != version { throw FloeError.validationFailed("项目依赖存在冲突：" + name) }
                        dependencies[name] = version
                    }
                }
            }
            args = dependencies.sorted { $0.key < $1.key }.map { $0.key + "@" + $0.value }
        } else if args.isEmpty { throw FloeError.validationFailed("请指定要卸载的包名") }
        guard args.count <= 256 else { throw FloeError.validationFailed("一次最多更新 256 个依赖") }
        for spec in args { try validateSpecification(spec, remove: removing) }
        return Change(specifications: args, remove: removing)
    }
}
