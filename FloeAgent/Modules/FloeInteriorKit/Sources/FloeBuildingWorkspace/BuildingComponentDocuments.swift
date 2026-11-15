// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords

public enum BuildingComponentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case cabinet, smartHome, radio, lighting, hvac
    var title: String { "floe-component:" + rawValue }
    var filename: String { rawValue + ".floe-component.json" }
}
public struct BuildingComponentDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projectID: ProjectID
    public var kind: BuildingComponentKind
    public var payload: Data
    public init(projectID: ProjectID, kind: BuildingComponentKind, payload: Data) {
        schemaVersion = 1; self.projectID = projectID; self.kind = kind; self.payload = payload
    }
}

public enum BuildingComponentBase: Codable, Equatable, Sendable {
    case absent
    case version(SourceVersionID)
}
public struct BuildingComponentSnapshot: Sendable {
    public var payload: Data?
    public var base: BuildingComponentBase
}
public struct BuildingWorkspaceLoadedProject: Sendable {
    public var snapshot: BuildingWorkspaceSnapshot
    public var components: [BuildingComponentKind: BuildingComponentSnapshot]
}
public struct BuildingWorkspaceComponentSave: Sendable {
    public var snapshot: BuildingWorkspaceSnapshot
    /// The committed version, never a later read of an unrelated writer's version.
    public var base: BuildingComponentBase
}

public struct BuildingWorkspaceSourceImport: Sendable {
    public var snapshot: BuildingWorkspaceSnapshot
    public var source: SourceRecord
    public var version: SourceVersion
}
public struct BuildingWorkspaceRoomMutation: Sendable {
    public var snapshot: BuildingWorkspaceSnapshot
    public var room: RoomRecord
}

public struct BuildingWorkspaceIntakeError: Error, Sendable {
    public var archived: BuildingWorkspaceSourceImport
    public var underlying: any Error
}
