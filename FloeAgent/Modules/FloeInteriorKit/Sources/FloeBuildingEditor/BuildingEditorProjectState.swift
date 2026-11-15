// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeInteriorCore
import FloeBuildingRecords
import FloeBuildingAssets
import FloeBuildingCAD

struct BuildingEditorRoomLink: Codable, Equatable, Sendable {
    var recordsRoomID: RoomID
    var nativeRoomID: UUID
    var lastSyncedName: String
}

/// One bounded, versioned reference index published with CAD, Records and the
/// actual offline asset files. Native geometry stays in CAD; observations and
/// adopted facts stay in Records. This is not a second editable geometry model.
struct BuildingEditorProjectState: Codable, Equatable, Sendable {
    static let maximumBytes=1024*1024
    var schemaVersion = 1
    var projectID: ProjectID
    var native: FloeBuildingCADManifest = .init()
    var roomLinks: [BuildingEditorRoomLink] = []
    var assetPins: [FurnitureAssetPin] = []
    /// Wall face finishes keyed by the native wall ID. Geometry stays in CAD;
    /// this is project metadata saved in the same immutable editor-state file.
    var wallFinishes: [InteriorWallFinishAssignment] = []
    /// Monotonic CAS token for wall geometry and face finishes. It advances on
    /// every accepted wall command, including finish-only edits that do not
    /// change the native building change count.
    var wallRevision: Int = 0

    init(projectID: ProjectID) {self.projectID=projectID}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, native, roomLinks, assetPins, wallFinishes, wallRevision
    }

    /// Additive decoding keeps older editor-state files readable. A missing
    /// wallFinishes array means "no finishes recorded", never a reset failure.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        projectID = try values.decode(ProjectID.self, forKey: .projectID)
        native = try values.decode(FloeBuildingCADManifest.self, forKey: .native)
        roomLinks = try values.decodeIfPresent([BuildingEditorRoomLink].self, forKey: .roomLinks) ?? []
        assetPins = try values.decodeIfPresent([FurnitureAssetPin].self, forKey: .assetPins) ?? []
        wallFinishes = try values.decodeIfPresent([InteriorWallFinishAssignment].self, forKey: .wallFinishes) ?? []
        wallRevision = try values.decodeIfPresent(Int.self, forKey: .wallRevision) ?? 0
    }

    func validate(expectedProjectID: ProjectID) throws {
        guard schemaVersion==1,native.schemaVersion==1,projectID==expectedProjectID else {
            throw BuildingProjectStateError.identityOrSchema
        }
        guard roomLinks.count<=10_000,assetPins.count<=2048,native.cabinets.count<=1024,
              native.furniture.count<=2048,native.sheets.count<=1024,
              native.cabinets.reduce(0,{$0+$1.panelBindings.count})<=10_000,
              wallFinishes.count<=2048 else {
            throw BuildingProjectStateError.budget
        }
        guard wallRevision >= 0, Set(wallFinishes.map(\.wallID)).count == wallFinishes.count else {
            throw BuildingProjectStateError.duplicateReference
        }
        for assignment in wallFinishes { _ = try assignment.validated() }
        guard Set(roomLinks.map(\.recordsRoomID)).count==roomLinks.count,
              Set(roomLinks.map(\.nativeRoomID)).count==roomLinks.count,
              Set(native.cabinets.map(\.cabinetID)).count==native.cabinets.count,
              Set(native.furniture.map(\.instanceID)).count==native.furniture.count else {
            throw BuildingProjectStateError.duplicateReference
        }
        struct Key: Hashable {var assetID:String;var version:String}
        var pins:[Key:FurnitureAssetPin]=[:]
        func hash(_ value:String)->Bool {
            value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}
        }
        for pin in assetPins {
            let key=Key(assetID:pin.assetID,version:pin.version)
            guard pins[key]==nil,!pin.assetID.isEmpty,!pin.version.isEmpty,
                  hash(pin.manifestSHA256),hash(pin.sourceSHA256),
                  pin.dependencySHA256.count<=2048,pin.dependencySHA256.values.allSatisfy(hash) else {
                throw BuildingProjectStateError.invalidPin
            }
            pins[key]=pin
        }
        for item in native.furniture {
            guard let pin=pins[Key(assetID:item.assetID,version:item.assetVersion)],
                  item.sourceSHA256==pin.sourceSHA256,item.dependencySHA256==pin.dependencySHA256,
                  item.instanceID==item.placementInput.instanceID,
                  item.assetID==item.placementInput.assetID,item.assetVersion==item.placementInput.assetVersion else {
                throw BuildingProjectStateError.invalidPin
            }
            try item.placementPlan.validateDerivedSnapshot(for:item.placementInput)
        }
        for sheet in native.sheets {
            guard native.cabinets.contains(where:{$0.cabinetID==sheet.cabinetID}) else {
                throw BuildingProjectStateError.orphanedSheet
            }
        }
    }

    func encoded() throws -> Data {
        try validate(expectedProjectID:projectID)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(self)
        guard data.count<=Self.maximumBytes else{throw BuildingProjectStateError.budget}
        return data
    }
    static func decode(_ data:Data,projectID:ProjectID) throws -> Self {
        guard data.count<=Self.maximumBytes else{throw BuildingProjectStateError.budget}
        let state=try JSONDecoder().decode(Self.self,from:data)
        try state.validate(expectedProjectID:projectID)
        return state
    }
}

enum BuildingProjectStateError: Error {
    case identityOrSchema,budget,duplicateReference,invalidPin,orphanedSheet
}
#endif
