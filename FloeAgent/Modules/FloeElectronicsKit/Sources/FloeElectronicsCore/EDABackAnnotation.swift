// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDABackAnnotationOptions: Codable, Hashable, Sendable {
    public var references: Bool
    public var values: Bool
    public var footprintAssignments: Bool
    public init(references: Bool = true, values: Bool = true, footprintAssignments: Bool = true) {
        self.references = references; self.values = values; self.footprintAssignments = footprintAssignments
    }
}

public struct EDABackAnnotationChange: Codable, Hashable, Identifiable, Sendable {
    public let footprintID: UUID
    public let before: EDAComponent
    public let after: EDAComponent
    public var id: UUID { before.id }
}

public struct EDABackAnnotationIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Sendable {
        case unlinkedFootprint, missingComponent, multipleFootprints, invalidReference
        case duplicateReference, incompatibleFootprint
    }
    public let code: Code
    public let blocking: Bool
    public let componentID: UUID?
    public let footprintID: UUID?
    public let reference: String
}

public struct EDABackAnnotationPreview: Codable, Sendable {
    public let projectID: UUID
    public let revision: String
    public let boardID: UUID
    public let options: EDABackAnnotationOptions
    public let changes: [EDABackAnnotationChange]
    public let issues: [EDABackAnnotationIssue]
    public var canApply: Bool { !issues.contains(where: \.blocking) }
}

/// A preview is bound to the entire inspected original, not merely a revision
/// number supplied by a caller. Only the planner can create an applicable plan.
public struct EDABackAnnotationPlan: Sendable {
    public let preview: EDABackAnnotationPreview
    public var sourceRevision: UInt64 { source.revision }
    fileprivate let source: EDAProject
}

public enum EDABackAnnotation {
    /// Match by the existing component link. Never infer a link from a display
    /// reference, reconstruct wiring from copper, or move/reroute board objects.
    /// The common editing transaction still invalidates derived copper fills.
    public static func plan(_ project: EDAProject, boardID: UUID,
                            options: EDABackAnnotationOptions = .init(),
                            cancelled: @Sendable () -> Bool = { false }) throws -> EDABackAnnotationPlan {
        guard !cancelled() else { throw EDAError.cancelled }
        try EDAValidation.validate(project)
        guard let board = project.boards.first(where: { $0.id == boardID }) else { throw EDAError.missing("board") }
        let components = Dictionary(uniqueKeysWithValues: project.components.map { ($0.id, $0) })
        let symbols = Dictionary(uniqueKeysWithValues: project.symbols.map { ($0.id, $0) })
        let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
        var changes: [EDABackAnnotationChange] = [], issues: [EDABackAnnotationIssue] = []
        var seen: Set<UUID> = [], proposed = components, changedReferences: Set<UUID> = []
        for footprint in board.footprints {
            guard !cancelled() else { throw EDAError.cancelled }
            guard let componentID = footprint.componentID else {
                issues.append(.init(code: .unlinkedFootprint, blocking: false, componentID: nil,
                                    footprintID: footprint.id, reference: footprint.reference)); continue
            }
            guard let component = components[componentID] else {
                issues.append(.init(code: .missingComponent, blocking: false, componentID: componentID,
                                    footprintID: footprint.id, reference: footprint.reference)); continue
            }
            guard seen.insert(componentID).inserted else {
                issues.append(.init(code: .multipleFootprints, blocking: true, componentID: componentID,
                                    footprintID: footprint.id, reference: footprint.reference)); continue
            }
            var next = component
            if options.references, component.reference != footprint.reference {
                let reference = footprint.reference
                if reference.isEmpty || reference != reference.trimmingCharacters(in: .whitespacesAndNewlines)
                    || reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    issues.append(.init(code: .invalidReference, blocking: true, componentID: componentID,
                                        footprintID: footprint.id, reference: component.reference))
                } else {
                    next.reference = reference; changedReferences.insert(componentID)
                }
            }
            if options.values { next.value = footprint.value }
            if options.footprintAssignments, component.footprintID != footprint.definitionID {
                let requiredPins = Set((symbols[component.symbolID]?.pins ?? []).filter { $0.type != .noConnect }.map(\.number))
                let padNumbers = Set((definitions[footprint.definitionID]?.pads ?? []).map(\.number))
                if !requiredPins.isSubset(of: padNumbers) {
                    issues.append(.init(code: .incompatibleFootprint, blocking: true, componentID: componentID,
                                        footprintID: footprint.id, reference: component.reference))
                } else { next.footprintID = footprint.definitionID }
            }
            proposed[componentID] = next
            if next != component { changes.append(.init(footprintID: footprint.id, before: component, after: next)) }
        }
        // Evaluate the final set together: a legal R1 <-> R2 swap must not be
        // rejected because one half would temporarily collide during a loop.
        let groups = Dictionary(grouping: proposed.values.filter { !$0.reference.isEmpty }, by: { $0.reference.uppercased() })
        for key in groups.keys.sorted() {
            guard !cancelled() else { throw EDAError.cancelled }
            let group = groups[key]!
            if group.count > 1 && group.contains(where: { changedReferences.contains($0.id) }) {
                for component in group.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    issues.append(.init(code: .duplicateReference, blocking: true, componentID: component.id,
                                        footprintID: board.footprints.first(where: { $0.componentID == component.id })?.id,
                                        reference: component.reference))
                }
            }
        }
        guard !cancelled() else { throw EDAError.cancelled }
        return .init(preview: .init(projectID: project.id, revision: String(project.revision), boardID: boardID,
                                   options: options, changes: changes, issues: issues), source: project)
    }

    public static func apply(_ plan: EDABackAnnotationPlan, to editor: inout EDAEditingSession,
                             cancelled: @Sendable () -> Bool = { false }) throws {
        guard !cancelled() else { throw EDAError.cancelled }
        guard plan.source.id == editor.project.id, plan.source.revision == editor.project.revision else {
            throw EDAError.staleRevision(expected: plan.source.revision, actual: editor.project.revision)
        }
        guard plan.source == editor.project else { throw EDAError.invalid("back annotation original changed") }
        guard plan.preview.canApply else { throw EDAError.invalid("unresolved back annotation conflicts") }
        try editor.transaction(expectedRevision: plan.source.revision, cancelled: cancelled) { candidate in
            for change in plan.preview.changes {
                guard let index = candidate.components.firstIndex(where: { $0.id == change.id }),
                      candidate.components[index] == change.before else { throw EDAError.invalid("back annotation component changed") }
                candidate.components[index] = change.after
            }
        }
    }
}
