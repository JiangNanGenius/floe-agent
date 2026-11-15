// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeBuildingUI
import FloeBuildingCAD

/// The existing host authorization binds tools to this immutable mount context.
/// A close/reopen retires it. Old assistant callbacks cannot follow a mutable
/// session pointer into the replacement document or its Records connection.
@MainActor
public final class BuildingEditorToolContext {
    public let projectID:ProjectID
    private let mountID:UUID
    private weak var owner:BuildingEditorProjectSession?
    init(owner:BuildingEditorProjectSession) {self.owner=owner;projectID=owner.projectID;mountID=owner.mountID}
    private func current() throws -> BuildingEditorProjectSession {
        guard let owner,!owner.closed,owner.mountID==mountID else{throw BuildingEditorProjectError.closed}
        return owner
    }
    public var nativeDocument:FloeCADDocument {get throws {try current().nativeDocument}}
    public var recordActions:[BuildingWorkspaceActionDescriptor] {BuildingWorkspaceActionCatalog.actions}
    public func recordsSnapshot() async throws -> BuildingWorkspaceSnapshot {
        let value=try await current().recordsSnapshot();_=try current();return value
    }
    public func sourceContent(_ versionID:SourceVersionID) async throws -> SourceVersionContent {
        let value=try await current().sourceContent(versionID);_=try current();return value
    }
    public func executeRecordCommand(_ command:BuildingWorkspaceCommand,expectedRevision:Int?=nil) async throws -> BuildingWorkspaceCommandResult {
        let value=try await current().executeRecordCommand(command,expectedRevision:expectedRevision);_=try current();return value
    }
    public func createRoomRecord(name:String,expectedRevision:Int) async throws -> RoomID {
        let value=try await current().createRoomRecord(name:name,expectedRevision:expectedRevision);_=try current();return value
    }
    public func importSource(_ request:SourceImportRequest,expectedRevision:Int) async throws -> BuildingWorkspaceSourceImport {
        let value=try await current().importSource(request,expectedRevision:expectedRevision);_=try current();return value
    }
    public func intakeCSV(_ data:Data,originalName:String,expectedRevision:Int,targetID:BOMTargetID?=nil,idempotencyKey:String?=nil) async throws -> BuildingWorkspaceDraft {
        let value=try await current().intakeCSV(data,originalName:originalName,expectedRevision:expectedRevision,
            targetID:targetID,idempotencyKey:idempotencyKey);_=try current();return value
    }
    public func applyCabinet(_ request:BuildingWorkbenchCheckpoint) async throws {
        try await current().applyCabinet(request);_=try current()
    }
    public func makeSheets(cabinetID:UUID) async throws {try await current().makeSheets(cabinetID:cabinetID);_=try current()}
    public func exportCabinet(cabinetID:UUID) async throws -> (URL,FloeBuildingCADDeliveryReceipt) {
        let value=try await current().exportCabinet(cabinetID:cabinetID);_=try current();return value
    }
    public func projectDrawingPages() throws->[BuildingEditorDrawingPageOption] {try current().projectDrawingPages()}
    public func exportProject(pageID:UUID?=nil) async throws -> (URL,FloeBuildingCADDeliveryReceipt) {
        let value=try await current().exportProject(pageID:pageID);_=try current();return value
    }
}
#endif
