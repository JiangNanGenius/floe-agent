// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore
import FloeBuildingRecords
import FloeBuildingWorkspace

/// Captured UI inputs for one project checkpoint. The host combines these
/// with the same workspace service and its live native document. Saving a
/// component in the working directory does not publish the whole project.
public struct BuildingWorkbenchCheckpoint: Sendable {
    public var projectID: ProjectID
    public var recordsRevision: Int
    public var selectedRoomID: RoomID?
    public var cabinetRecipe: CabinetRecipe
    public var cabinetNotes: [CabinetManualSheetNote]
    public var cabinetDimensionPresentation: [CabinetDimensionPresentation]
    public init(projectID:ProjectID,recordsRevision:Int,selectedRoomID:RoomID?=nil,
                cabinetRecipe:CabinetRecipe,cabinetNotes:[CabinetManualSheetNote]=[],
                cabinetDimensionPresentation:[CabinetDimensionPresentation]=[]) {
        self.projectID=projectID;self.recordsRevision=recordsRevision;self.selectedRoomID=selectedRoomID
        self.cabinetRecipe=cabinetRecipe;self.cabinetNotes=cabinetNotes;self.cabinetDimensionPresentation=cabinetDimensionPresentation
    }
}

/// Feature-local injection boundary. It owns neither navigation nor another
/// save button. The integrating project must supply its existing access grant
/// before constructing the service or these actions.
@MainActor
public struct BuildingWorkbenchProjectActions {
    public var hasUnpublishedChanges: () -> Bool
    public var checkpoint: (BuildingWorkbenchCheckpoint) async throws -> Void
    public var applyCabinet: (BuildingWorkbenchCheckpoint) async throws -> Void
    public var reopen: () async throws -> BuildingWorkbenchReopenOutcome
    public var close: (() async throws -> Void)?
    /// Reuse the host's existing assistant/task departure fence. Called only
    /// after the user chooses a close/reopen action, before saving or releasing
    /// the document. No additional edit-approval system is introduced.
    public var beforeDeparture: (Bool) async throws -> Bool
    public var departureEnded: () -> Void
    public var recordsChanged: (ProjectID, Int) -> Void
    public var roomSelectionChanged: (RoomID?) -> Void
    public var metadataRevision: () -> Int
    public var requestAssistant: (() -> Void)?
    public var requestSaveAs: (() -> Void)?
    public var requestFurnitureImport: (() -> Void)?
    public var projectOperationBusy: () -> Bool
    public var cancelProjectOperation: (() -> Void)?

    public init(
        hasUnpublishedChanges: @escaping () -> Bool,
        checkpoint: @escaping (BuildingWorkbenchCheckpoint) async throws -> Void,
        applyCabinet: @escaping (BuildingWorkbenchCheckpoint) async throws -> Void,
        reopen: @escaping () async throws -> BuildingWorkbenchReopenOutcome,
        close: (() async throws -> Void)? = nil,
        beforeDeparture: @escaping (Bool) async throws -> Bool = { _ in true },
        departureEnded: @escaping () -> Void = {},
        recordsChanged: @escaping (ProjectID, Int) -> Void = { _, _ in },
        roomSelectionChanged: @escaping (RoomID?) -> Void = { _ in },
        metadataRevision: @escaping () -> Int = { -1 },
        requestAssistant: (() -> Void)? = nil,
        requestSaveAs: (() -> Void)? = nil,
        requestFurnitureImport: (() -> Void)? = nil,
        projectOperationBusy: @escaping () -> Bool = { false },
        cancelProjectOperation: (() -> Void)? = nil
    ) {
        self.hasUnpublishedChanges = hasUnpublishedChanges
        self.checkpoint = checkpoint
        self.applyCabinet = applyCabinet
        self.reopen = reopen
        self.close = close
        self.beforeDeparture = beforeDeparture
        self.departureEnded = departureEnded
        self.recordsChanged = recordsChanged
        self.roomSelectionChanged = roomSelectionChanged
        self.metadataRevision = metadataRevision
        self.requestAssistant = requestAssistant
        self.requestSaveAs = requestSaveAs
        self.requestFurnitureImport = requestFurnitureImport
        self.projectOperationBusy = projectOperationBusy
        self.cancelProjectOperation = cancelProjectOperation
    }
}

public enum BuildingWorkbenchReopenOutcome: Equatable,Sendable {
    case reloadWorkspace
    /// The project owner replaced the mount and will reconstruct its feature
    /// surface. The old UI must not reopen its now-retired records actor.
    case replacedWorkspace
}
