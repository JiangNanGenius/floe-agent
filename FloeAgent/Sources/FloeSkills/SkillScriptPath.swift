import Foundation
import FloeCore

/// One path contract for tool validation and App-side bundle assembly.
public enum SkillScriptPath {
    public static func relativeToScripts(_ input: String) throws -> String {
        guard !input.isEmpty, !input.hasPrefix("/"), !input.hasPrefix("~"),
              !input.contains("\\"), !input.contains("\0") else {
            throw FloeError.validationFailed("Skill Python script path is unsafe")
        }
        var parts = input.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "scripts" { parts.removeFirst() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts.last?.lowercased().hasSuffix(".py") == true else {
            throw FloeError.validationFailed("Skill Python script path is unsafe")
        }
        return parts.joined(separator: "/")
    }

    public static func destination(for input: String, in scriptsRoot: URL) throws -> URL {
        let relative = try relativeToScripts(input)
        let root = scriptsRoot.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.appendingPathComponent(relative, isDirectory: false)
            .resolvingSymlinksInPath().standardizedFileURL
        // URL.path may retain a directory slash on some Foundation versions;
        // compare actual components instead of manufacturing a double slash.
        let rootParts = root.pathComponents.filter { !$0.isEmpty }
        let destinationParts = destination.pathComponents.filter { !$0.isEmpty }
        guard destinationParts.count > rootParts.count,
              Array(destinationParts.prefix(rootParts.count)) == rootParts else {
            throw FloeError.validationFailed("Skill Python script path is unsafe")
        }
        return destination
    }
}
