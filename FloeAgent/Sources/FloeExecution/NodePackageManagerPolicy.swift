import Foundation
import FloeCore

public enum NodePackageManager: String, Codable, CaseIterable, Sendable {
    case npm, pnpm
}

public enum NodePackageManagerPreference: String, Codable, CaseIterable, Sendable {
    case automatic, npm, pnpm
}

/// Read-only project hints. Environment installs never rewrite a project's lock.
public enum NodePackageManagerPolicy {
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
        let selected = declared ?? locks.first ?? "npm"
        guard let manager = NodePackageManager(rawValue: selected) else {
            throw FloeError.validationFailed("项目要求 \(selected)。本环境支持 npm / pnpm，请明确选择；原项目锁文件会保留。")
        }
        return manager
    }
}
