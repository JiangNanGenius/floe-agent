// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Only sketch mutations enter the relation rebuild. Renames, materials,
/// camera state and unrelated body commands never trigger a full replay.
@MainActor
enum SketchCurveCommandScope {
    static func sketchIDs(of command: DocumentCommand) -> Set<SketchID> {
        switch command {
        case let value as CompositeCommand:
            return value.commands.reduce(into: []) { $0.formUnion(sketchIDs(of: $1)) }
        case let value as AddSketchEntityCommand: return [value.sketchID]
        case let value as AddSketchEntitiesCommand: return [value.sketchID]
        case let value as UpdateSketchEntityCommand: return [value.sketchID]
        case let value as UpdateSketchEntitiesCommand: return [value.sketchID]
        case let value as ReplaceSketchGeometryCommand: return [value.before.id]
        case let value as AddSketchConstraintCommand: return [value.sketchID]
        case let value as RemoveSketchConstraintCommand: return [value.sketchID]
        case let value as AddSketchDimensionCommand: return [value.sketchID]
        case let value as UpdateSketchDimensionCommand: return [value.sketchID]
        case let value as RemoveSketchDimensionCommand: return [value.sketchID]
        case let value as RemoveSketchEntitiesCommand: return [value.sketchID]
        case let value as TrimCommand: return [value.sketchID]
        case let value as MirrorSketchEntitiesCommand: return [value.sketchID]
        case let value as DisconnectSketchEndpointsCommand: return [value.sketchID]
        default: return []
        }
    }
}
