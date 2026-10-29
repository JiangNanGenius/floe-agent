// FloeCore — validated overlay for remotely updateable prompt sections.
//
// Only three stable section IDs may ever be replaced by signed content: the
// per-task method, the communication discipline and the delivery contract.
// Permission approval, tool protocol, routing, failure handling, the harness
// envelope and every mode layer stay compiled into the app and are never
// replaceable or remotely updateable.
//
// Validation is explicit and total: unknown IDs, duplicate IDs, oversized
// sections, oversized totals, unknown variables and template expressions are
// rejected up front instead of being silently truncated or accepted.

import Foundation

public struct AgentPromptContentSection: Sendable, Equatable {
    public let id: String
    public let body: String

    public init(id: String, body: String) {
        self.id = id
        self.body = body
    }
}

public enum AgentPromptOverlayError: Error, Equatable, LocalizedError {
    case unknownSectionID(String)
    case duplicateSectionID(String)
    case emptyBody(String)
    case sectionTooLarge(id: String, limit: Int)
    case totalTooLarge(limit: Int)
    case unknownVariable(String)
    case expressionNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownSectionID(let id): "Unknown updateable prompt section: \(id)"
        case .duplicateSectionID(let id): "Duplicate prompt section: \(id)"
        case .emptyBody(let id): "Prompt section has an empty body: \(id)"
        case .sectionTooLarge(let id, let limit): "Prompt section \(id) exceeds \(limit) bytes"
        case .totalTooLarge(let limit): "Prompt overlay exceeds \(limit) bytes"
        case .unknownVariable(let name): "Prompt section uses an unknown variable: \(name)"
        case .expressionNotAllowed(let id): "Prompt section \(id) contains a template expression"
        }
    }
}

/// A validated, bounded overlay. Construction is the only way to obtain one,
/// so downstream code never has to re-check trust.
public struct AgentPromptOverlay: Sendable, Equatable, Hashable {
    public static let methodSectionID = "floe.prompts.core.method"
    public static let communicationSectionID = "floe.prompts.core.communication"
    public static let deliverySectionID = "floe.prompts.core.delivery"

    /// Only these IDs may replace their compiled counterpart. Tool
    /// discipline, permissions, approval and protocol sections are absent on
    /// purpose and therefore impossible to update remotely.
    public static let replaceableSectionIDs: Set<String> = [
        methodSectionID, communicationSectionID, deliverySectionID
    ]

    /// Variables a section may reference without any expression evaluation.
    /// Resolution is a plain literal substitution performed by the caller.
    public static let allowedVariables: Set<String> = ["app.name", "platform.name"]

    public static let maximumSectionBytes = 1_024
    /// Total overlay budget across all three replaceable sections. Kept
    /// below 3 × section budget so the total limit is actually reachable.
    public static let maximumTotalBytes = 2_048

    public private(set) var method: String?
    public private(set) var communication: String?
    public private(set) var delivery: String?

    public static let empty = AgentPromptOverlay()

    private init() {}

    public init(sections: [AgentPromptContentSection]) throws {
        guard sections.count <= Self.replaceableSectionIDs.count else {
            throw AgentPromptOverlayError.totalTooLarge(limit: Self.maximumTotalBytes)
        }
        var seen: Set<String> = []
        var total = 0
        var bodies: [String: String] = [:]
        for section in sections {
            guard Self.replaceableSectionIDs.contains(section.id) else {
                throw AgentPromptOverlayError.unknownSectionID(section.id)
            }
            guard seen.insert(section.id).inserted else {
                throw AgentPromptOverlayError.duplicateSectionID(section.id)
            }
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw AgentPromptOverlayError.emptyBody(section.id) }
            guard body.utf8.count <= Self.maximumSectionBytes else {
                throw AgentPromptOverlayError.sectionTooLarge(id: section.id, limit: Self.maximumSectionBytes)
            }
            if body.contains("{{") || body.contains("}}") || body.contains("${") {
                throw AgentPromptOverlayError.expressionNotAllowed(section.id)
            }
            // `{name}` placeholders are allowed only for the known literal
            // variables; no evaluation is ever performed.
            for match in Self.placeholderNames(in: body) where !Self.allowedVariables.contains(match) {
                throw AgentPromptOverlayError.unknownVariable(match)
            }
            total += body.utf8.count
            guard total <= Self.maximumTotalBytes else {
                throw AgentPromptOverlayError.totalTooLarge(limit: Self.maximumTotalBytes)
            }
            bodies[section.id] = body
        }
        method = bodies[Self.methodSectionID]
        communication = bodies[Self.communicationSectionID]
        delivery = bodies[Self.deliverySectionID]
    }

    /// Literal substitution of the two allowed variables. Never evaluates
    /// expressions; unknown braces are left untouched because construction
    /// already rejected them.
    public func resolved(_ body: String, appName: String, platformName: String) -> String {
        body
            .replacingOccurrences(of: "{app.name}", with: appName)
            .replacingOccurrences(of: "{platform.name}", with: platformName)
    }

    static func placeholderNames(in body: String) -> [String] {
        var names: [String] = []
        var index = body.startIndex
        while let open = body[index...].firstIndex(of: "{"),
              let close = body[open...].firstIndex(of: "}") {
            let name = String(body[body.index(after: open)..<close])
            if !name.isEmpty, !name.contains("{") { names.append(name) }
            index = body.index(after: close)
            if index >= body.endIndex { break }
        }
        return names
    }
}
