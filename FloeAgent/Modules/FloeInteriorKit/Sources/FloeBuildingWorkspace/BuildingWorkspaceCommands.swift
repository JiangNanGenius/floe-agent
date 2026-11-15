// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords

/// Typed component commands for a future adapter to the App's existing tools.
/// Imported text never supplies filesystem roots, SQL, tool grants or revisions.
/// The authorized host binds projectID and its current expectedRevision.
public enum BuildingWorkspaceCommand: Codable, Sendable {
    case search(query: String, limit: Int, offset: Int)
    case observations(roomID: RoomID)
    case recordObservations([ObservationDraft])
    case adoptObservation(ObservationID)
}
public enum BuildingWorkspaceCommandResult: Codable, Sendable {
    case searchHits([RecordSearchHit])
    case observations([ObservationRecord])
    case recorded(ProjectMutation<[ObservationRecord]>)
    case adopted(ProjectMutation<AdoptedValueRecord>)
}
