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
        guard manifest.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.package_json_is_outside_the_workspace")) }
        var declared: String?
        if FileManager.default.fileExists(atPath: manifest.path) {
            let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_097_152,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.could_not_read_the_project_package"))
            }
            if let value = json["packageManager"] {
                guard let value = value as? String, let separator = value.firstIndex(of: "@") else {
                    throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_packagemanager_format_is_invalid"))
                }
                declared = String(value[..<separator])
            }
        }
        guard locks.count <= 1, declared == nil || locks.isEmpty || locks.contains(declared!) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_s_packagemanager_conflicts_with"))
        }
        let selected = declared ?? locks.first
        guard let selected else { return .npm }
        guard let manager = NodePackageManager(rawValue: selected) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_requires_this_environment_supports", selected))
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
            throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.enter_an_npm_package_name_optionally"))
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
            throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.in_managed_environments_use_npm_pnpm"))
        }
        guard installing || removing else {
            if command.hasPrefix("-"), args.contains(where: { ["install", "i", "add", "remove", "rm", "uninstall"].contains($0) }) {
                throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.put_install_remove_after_the_manager"))
            }
            return nil
        }
        args.removeFirst()
        args.removeAll { ["-g", "--global", "--save", "--save-dev", "-D", "--save-prod", "-P", "--ignore-scripts", "--no-audit", "--no-fund"].contains($0) }
        guard !args.contains(where: { $0.hasPrefix("-") }) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.install_location_and_scripts_are_managed"))
        }
        if args.isEmpty && !removing {
            let root = workspace.resolvingSymlinksInPath().standardizedFileURL
            let manifest = directory.appendingPathComponent("package.json").resolvingSymlinksInPath().standardizedFileURL
            guard manifest.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_manifest_is_outside_the")) }
            let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_package_json_cannot_be"))
            }
            var dependencies: [String: String] = [:]
            for key in ["dependencies", "devDependencies"] {
                if let value = json[key] {
                    guard let entries = value as? [String: String] else { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_dependency_manifest_is_invalid")) }
                    for (name, version) in entries {
                        if let existing = dependencies[name], existing != version { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.the_project_dependencies_have_a_conflict") + name) }
                        dependencies[name] = version
                    }
                }
            }
            args = dependencies.sorted { $0.key < $1.key }.map { $0.key + "@" + $0.value }
        } else if args.isEmpty { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.specify_the_package_name_to_uninstall")) }
        guard args.count <= 256 else { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.at_most_256_dependencies_can_be")) }
        for spec in args { try validateSpecification(spec, remove: removing) }
        return Change(specifications: args, remove: removing)
    }
}
