// FloeSkills — domain codec for signed content packages.
//
// The update core owns signature/version/archive trust; each domain owns its
// own schema and capability checks. This codec covers the content-hub kinds
// that ship declarative JSON (prompts/providers/models/help/templates) with
// no executable code. Providers keep their own stricter validator on the app
// side; this is the shared structural gate that runs before activation.

import Foundation
import FloeCore

public struct ContentPackageCodec: Sendable {
    public let kind: SignedContentKind

    public init(kind: SignedContentKind) {
        self.kind = kind
    }

    public static let maximumContentJSONBytes = 262_144
    public static let maximumDocuments = 32
    public static let maximumSections = 64
    public static let maximumDocumentBytes = 1_048_576

    /// Validates one staged package against its signed entry. Throws a
    /// `SkillValidationError`-shaped domain failure; callers map it to the
    /// content-update failure surface.
    public func validate(entry: SignedContentEntry, files: [String: Data]) throws {
        guard entry.kind == kind else { throw ContentPackageError.kindMismatch }
        guard let contentData = files["content.json"],
              contentData.count <= Self.maximumContentJSONBytes else {
            throw ContentPackageError.missingContent
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                throw ContentPackageError.invalidContent("top-level value must be an object")
            }
            object = decoded
        } catch let error as ContentPackageError {
            throw error
        } catch {
            throw ContentPackageError.invalidContent("content.json must be valid JSON")
        }
        guard object["schemaVersion"] as? Int == 1 else {
            throw ContentPackageError.invalidContent("schemaVersion must be 1")
        }
        guard object["id"] as? String == entry.id else {
            throw ContentPackageError.invalidContent("id must match the signed entry")
        }
        guard object["version"] as? String == entry.version else {
            throw ContentPackageError.invalidContent("version must match the signed entry")
        }
        if let declaredKind = object["kind"] as? String, declaredKind != kind.rawValue {
            throw ContentPackageError.invalidContent("kind must match the signed entry")
        }
        let hasScripts = files.keys.contains { $0.hasPrefix("scripts/") }
        guard hasScripts == entry.containsScripts else {
            throw ContentPackageError.invalidContent("containsScripts must match the archive")
        }
        guard !hasScripts || entry.requiredCapabilities.contains(SkillCapability.localPython.rawValue)
            || entry.requiredCapabilities.contains(SkillCapability.remoteExecution.rawValue) else {
            throw ContentPackageError.invalidContent("scripted content requires an explicit capability")
        }
        for (path, data) in files where path != "content.json" {
            guard data.count <= Self.maximumDocumentBytes else {
                throw ContentPackageError.invalidContent("payload exceeds the 1 MiB document limit: \(path)")
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard !["dylib", "so", "wasm", "framework", "bundle", "a", "o", "dmg", "ipa", "zip"].contains(ext) else {
                throw ContentPackageError.invalidContent("payload type is not allowed in declarative content: \(path)")
            }
        }
        switch kind {
        case .prompts:
            try validatePrompts(object)
        case .help:
            try validateReferencedFiles(object, keys: ["documents"], files: files)
        case .templates:
            try validateReferencedFiles(object, keys: ["template"], files: files)
        case .providers, .models:
            try validateLocalizedField(object["notice"])
        }
    }

    /// Readable prompt-section projection for the Internal Prompts review UI.
    public static func promptSections(in files: [String: Data]) -> [PromptSection] {
        guard let data = files["content.json"],
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = object["sections"] as? [[String: Any]] else { return [] }
        return sections.compactMap { section in
            guard let id = section["id"] as? String,
                  let title = section["title"] as? [String: String],
                  let body = section["body"] as? [String: String] else { return nil }
            return PromptSection(id: id, title: title, body: body)
        }
    }

    public struct PromptSection: Sendable, Equatable {
        public let id: String
        public let title: [String: String]
        public let body: [String: String]
    }

    /// Builds the validated runtime overlay for one locale from an installed
    /// prompt package. Validation (allowed IDs, per-section and total budget,
    /// variables, no expressions) happens in `AgentPromptOverlay`; an invalid
    /// package throws instead of being partially injected or truncated.
    public static func runtimePromptOverlay(
        in files: [String: Data],
        locale: String
    ) throws -> AgentPromptOverlay {
        let primary = locale.hasPrefix("zh") ? "zh-Hans" : "en"
        let sections = promptSections(in: files).compactMap { section -> AgentPromptContentSection? in
            let body = section.body[primary] ?? section.body["en"] ?? ""
            guard !body.isEmpty else { return nil }
            return AgentPromptContentSection(id: section.id, body: body)
        }
        guard !sections.isEmpty else { return .empty }
        do {
            return try AgentPromptOverlay(sections: sections)
        } catch {
            throw ContentPackageError.invalidContent(error.localizedDescription)
        }
    }

    // MARK: - Kind schemas

    private func validatePrompts(_ object: [String: Any]) throws {
        guard let sections = object["sections"] as? [[String: Any]] else {
            throw ContentPackageError.invalidContent("prompts require a sections array")
        }
        guard !sections.isEmpty, sections.count <= Self.maximumSections else {
            throw ContentPackageError.invalidContent("prompts require 1...\(Self.maximumSections) sections")
        }
        var ids: Set<String> = []
        for section in sections {
            guard let id = section["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  ids.insert(id).inserted else {
                throw ContentPackageError.invalidContent("prompt section ids must be unique and bounded")
            }
            if let title = section["title"] as? [String: Any] {
                try validateLocalized(title, field: "title")
            }
            guard let body = section["body"] as? [String: Any] else {
                throw ContentPackageError.invalidContent("prompt sections require a body")
            }
            try validateLocalized(body, field: "body")
            if let variables = section["variables"] as? [String] {
                guard variables.count <= 16, variables.allSatisfy({ $0.count <= 64 }) else {
                    throw ContentPackageError.invalidContent("prompt variables must be bounded")
                }
                for variable in variables where !AgentPromptOverlay.allowedVariables.contains(variable) {
                    throw ContentPackageError.invalidContent("unknown prompt variable \(variable)")
                }
            }
        }
        // The same overlay contract the runtime enforces: only replaceable
        // IDs, bounded single sections and totals, and no expressions.
        let runtimeSections: [AgentPromptContentSection] = sections.compactMap { section in
            guard let id = section["id"] as? String,
                  let body = section["body"] as? [String: Any],
                  let en = body["en"] as? String else { return nil }
            return AgentPromptContentSection(id: id, body: en)
        }
        do {
            _ = try AgentPromptOverlay(sections: runtimeSections)
        } catch {
            throw ContentPackageError.invalidContent(error.localizedDescription)
        }
    }

    private func validateReferencedFiles(_ object: [String: Any], keys: [String], files: [String: Data]) throws {
        var referenced: [String] = []
        for key in keys {
            if let value = object[key] as? String { referenced.append(value) }
            if let value = object[key] as? [String: String] { referenced.append(contentsOf: value.values) }
        }
        guard referenced.count <= Self.maximumDocuments else {
            throw ContentPackageError.invalidContent("too many referenced documents")
        }
        for path in referenced {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/").contains(".."),
                  files[path] != nil else {
                throw ContentPackageError.invalidContent("referenced document is missing: \(path)")
            }
        }
    }

    private func validateLocalizedField(_ value: Any?) throws {
        guard let value else { return }
        guard let dictionary = value as? [String: Any] else {
            throw ContentPackageError.invalidContent("localized field must be an object")
        }
        try validateLocalized(dictionary, field: "localized")
    }

    private func validateLocalized(_ dictionary: [String: Any], field: String) throws {
        guard !dictionary.isEmpty, dictionary.count <= 8 else {
            throw ContentPackageError.invalidContent("\(field) must contain 1...8 locales")
        }
        for (locale, value) in dictionary {
            guard let text = value as? String, !text.isEmpty,
                  locale.utf8.count <= 32, text.utf8.count <= 8_192 else {
                throw ContentPackageError.invalidContent("\(field) values must be non-empty bounded text")
            }
        }
        for required in ["en", "zh-Hans"] where dictionary[required] == nil {
            throw ContentPackageError.invalidContent("\(field) requires en and zh-Hans")
        }
    }
}

public enum ContentPackageError: Error, Equatable, LocalizedError {
    case kindMismatch
    case missingContent
    case invalidContent(String)

    public var errorDescription: String? {
        switch self {
        case .kindMismatch: "Content package kind does not match its update feed"
        case .missingContent: "Content package is missing content.json"
        case .invalidContent(let reason): "Invalid content package: \(reason)"
        }
    }
}
