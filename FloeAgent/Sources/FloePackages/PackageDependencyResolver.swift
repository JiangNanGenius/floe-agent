import Foundation
import FloeCore

/// Deterministic dependency resolution. Unsupported dependency syntax and conflicting
/// constraints fail before any files change; dependency order precedes dependants.
public enum PackageDependencyResolver {
    public struct Requirement: Sendable {
        public var name: String
        public var relation: String?
        public var version: String?

        public init(_ text: String) throws {
            let pattern = #"^([a-z0-9][a-z0-9+.-]*)(?::(?:any|native))?(?:\s*\((<<|<=|=|>=|>>)\s*([^\s)]+)\))?$"#
            let expression = try NSRegularExpression(pattern: pattern)
            let text = text.trimmingCharacters(in: .whitespaces)
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                throw FloeError.validationFailed("Unsupported package dependency: \(text)")
            }
            func capture(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            name = capture(1)!; relation = capture(2); version = capture(3)
        }

        public func accepts(_ installed: String) -> Bool {
            guard let version, let relation else { return true }
            let order = DebVersion.compare(installed, version)
            switch relation {
            case "=": return order == .equal
            case ">>": return order == .newer
            case ">=": return order != .older
            case "<<": return order == .older
            case "<=": return order != .newer
            default: return false
            }
        }
    }

    public static func groups(_ text: String?) throws -> [[Requirement]] {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try text.split(separator: ",", omittingEmptySubsequences: false).map { group in
            try group.split(separator: "|", omittingEmptySubsequences: false).map { try Requirement(String($0)) }
        }
    }

    public static func resolve(_ names: [String], available: [AptPackage], installed: [String: String], architecture: String) throws -> [AptPackage] {
        let available = available.filter { $0.architecture == "all" || $0.architecture == architecture }
        var selected: [String: AptPackage] = [:]
        var visiting = Set<String>()
        var ordered: [AptPackage] = []
        func candidates(_ requirement: Requirement) throws -> [AptPackage] {
            try available.filter { package in
                if package.name == requirement.name { return requirement.accepts(package.version) }
                return try groups(package.provides).flatMap { $0 }.contains { provided in
                    provided.name == requirement.name && (requirement.version == nil || provided.version.map(requirement.accepts) == true)
                }
            }.sorted { DebVersion.compare($0.version, $1.version) == .newer }
        }
        func visit(_ requirement: Requirement, explicit: Bool) throws {
            if let existing = selected[requirement.name] {
                guard !visiting.contains(requirement.name) else { throw AptEngine.AptError.conflict("dependency cycle at \(requirement.name)") }
                guard requirement.accepts(existing.version) else { throw AptEngine.AptError.conflict("incompatible version constraints for \(requirement.name)") }
                return
            }
            if !explicit, let version = installed[requirement.name], requirement.accepts(version) { return }
            guard let package = try candidates(requirement).first else {
                if let version = installed[requirement.name], requirement.accepts(version) { return }
                throw AptEngine.AptError.unresolved(requirement.name)
            }
            if let existing = selected[package.name] {
                guard existing.version == package.version else { throw AptEngine.AptError.conflict("conflicting provider versions for \(requirement.name)") }
                return
            }
            if installed[package.name] == package.version { return }
            guard visiting.insert(package.name).inserted else { throw AptEngine.AptError.conflict("dependency cycle at \(package.name)") }
            selected[package.name] = package
            for alternatives in try groups(package.preDepends) + groups(package.depends) {
                let chosen = try alternatives.first { dependency in
                    if let selected = selected[dependency.name] { return dependency.accepts(selected.version) }
                    if let version = installed[dependency.name], dependency.accepts(version) { return true }
                    return try !candidates(dependency).isEmpty
                }
                guard let chosen else { throw AptEngine.AptError.unresolved(alternatives.map(\.name).joined(separator: " | ")) }
                try visit(chosen, explicit: false)
            }
            visiting.remove(package.name)
            ordered.append(package)
        }
        for name in names {
            let components = name.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let requirement = try Requirement(components.count == 2 ? "\(components[0]) (= \(components[1]))" : name)
            try visit(requirement, explicit: true)
        }
        let final = installed.merging(selected.mapValues(\.version)) { _, next in next }
        for package in ordered {
            for requirement in try groups(package.conflicts).flatMap({ $0 }) + groups(package.breaks).flatMap({ $0 }) {
                if requirement.name != package.name, let version = final[requirement.name], requirement.accepts(version) {
                    throw AptEngine.AptError.conflict("\(package.name) conflicts with \(requirement.name) \(version)")
                }
            }
        }
        return ordered
    }
}
