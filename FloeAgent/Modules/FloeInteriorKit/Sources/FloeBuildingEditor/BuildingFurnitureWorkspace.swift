// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import Observation
import FloeInteriorCore
import FloeBuildingAssets

struct BuildingFurnitureKey: Hashable {
    let assetID: String
    let version: String
    init(_ item: FurnitureAssetSummary) {assetID=item.assetID;version=item.version}
}

enum BuildingFurnitureInputError: Error {case incompleteNumber(String), sizingRequired, selectionRequired, wrongOfflinePin, packageFileBudget}

/// Project-owned UI state. Views may be reconstructed or switched without
/// losing input or restarting a library job. Closing drains this owner's job
/// before the integrating project releases its working resource directory.
@MainActor @Observable
final class BuildingFurnitureWorkspace {
    enum Operation: Equatable {case idle, loading, importing, placing}
    typealias Place = @MainActor (URL, FurniturePlacementInput, FurnitureAssetPin) async throws -> Void
    let library: FurnitureAssetLibrary
    let resourcesDirectory: URL
    private let placeNative: Place
    var rows: [FurnitureAssetSummary] = []
    var selection: BuildingFurnitureKey?
    var selectedBundle: FurnitureAssetBundle?
    var search = ""
    var xText = "0"
    var yText = "0"
    var elevationText = "0"
    var yawText = "0"
    var floorElevationMM = 0.0
    var roomID: UUID?
    var useCatalogDimensions = true
    var allowNonUniformScaling = false
    var sourceUnit: FurnitureLengthUnit?
    var anchor: FurnitureAnchor = .bottomCenter
    var operation: Operation = .idle
    var errorDetails: String?
    var completedPlacementID: UUID?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var closed = false

    init(library: FurnitureAssetLibrary, resourcesDirectory: URL, place: @escaping Place) {
        self.library=library;self.resourcesDirectory=resourcesDirectory;self.placeNative=place
    }
    var busy: Bool {operation != .idle}
    var visibleRows: [FurnitureAssetSummary] {
        let q=search.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? rows : rows.filter{[$0.name,$0.assetID,$0.category ?? ""].contains{$0.localizedCaseInsensitiveContains(q)}}
    }
    private func launch(_ next: Operation, work: @escaping @MainActor () async throws -> Void) {
        guard !closed,!busy else{return}
        let id=UUID();operationID=id;operation=next;errorDetails=nil;completedPlacementID=nil
        task=Task { @MainActor in
            defer {if operationID==id{operation = .idle;operationID=nil;task=nil}}
            do {try await work()}
            catch {
                guard !closed,operationID==id,!Task.isCancelled else{return}
                errorDetails=error.localizedDescription
            }
        }
    }
    private func requireActive() throws {try Task.checkCancellation();if closed{throw CancellationError()}}
    func reload() {
        launch(.loading){
            let rows=try await self.library.list();try self.requireActive();self.rows=rows
        }
    }
    func select(_ row: FurnitureAssetSummary) {
        launch(.loading){
            let bundle=try await self.library.open(assetID:row.assetID,version:row.version)
            try self.requireActive()
            self.selection = .init(row);self.selectedBundle=bundle
            self.sourceUnit=bundle.manifest.sourceBoundsUnit
            self.useCatalogDimensions=bundle.manifest.declaredDimensions != nil
            self.allowNonUniformScaling=false
        }
    }
    func importStarter() {
        launch(.importing){
            let source=try BuildingStarterFurniture.armchair()
            let version=try await source.importInto(self.library)
            try self.requireActive()
            let rows=try await self.library.list()
            let bundle=try await self.library.open(assetID:version.manifest.assetID,version:version.manifest.version)
            try self.requireActive()
            self.rows=rows
            self.selection = .init(.init(manifest:version.manifest))
            self.selectedBundle=bundle
            self.sourceUnit=nil;self.useCatalogDimensions=true;self.allowNonUniformScaling=true
        }
    }
    /// The folder was explicitly chosen by the user. The caller chooses an
    /// exact OBJ when several exist; this never picks a guessed first file.
    func importOBJ(folder: URL, relativePath: String, name: String,
                   unit: FurnitureLengthUnit?,orientation: FurnitureSourceOrientation,
                   declaredDimensions: FurnitureDeclaredDimensions? = nil) {
        guard !closed,!busy else{return}
        // Acquire before returning to the sheet: its own grant may be released
        // immediately after this call, before the Task starts executing.
        let access=folder.startAccessingSecurityScopedResource()
        launch(.importing){
            defer {if access{folder.stopAccessingSecurityScopedResource()}}
            let version=try await self.library.importOBJ(sourceRootURL:folder,relativePath:relativePath,
                assetID:"user."+UUID().uuidString.lowercased(),version:"1",name:name,category:nil,
                provenance:.userProvided(source:"User-selected OBJ package"),
                declaredDimensions:declaredDimensions,sourceBoundsUnit:unit,sourceOrientation:orientation)
            try self.requireActive()
            let rows=try await self.library.list()
            let bundle=try await self.library.open(assetID:version.manifest.assetID,version:version.manifest.version)
            try self.requireActive()
            self.rows=rows
            self.selection = .init(.init(manifest:version.manifest))
            self.selectedBundle=bundle
            self.sourceUnit=unit;self.useCatalogDimensions=declaredDimensions != nil;self.allowNonUniformScaling=false
        }
    }
    func place() {
        launch(.placing){
            guard let bundle=self.selectedBundle else{throw BuildingFurnitureInputError.selectionRequired}
            let pose=try self.pose()
            let sizing=try self.sizing(bundle.manifest)
            let room=self.roomID,id=UUID()
            let pin=try bundle.pin()
            let destination=self.resourcesDirectory.appendingPathComponent(pin.manifestSHA256,isDirectory:true)
            let offline: FurnitureAssetOfflineCopy
            if FileManager.default.fileExists(atPath:destination.path) {
                let verify=Task.detached {
                    let value=try FurnitureAssetOfflineCopy(rootURL:destination)
                    guard value.pin==pin else{throw BuildingFurnitureInputError.wrongOfflinePin}
                    _=try value.verify();try Task.checkCancellation();return value
                }
                offline=try await withTaskCancellationHandler {try await verify.value} onCancel:{verify.cancel()}
            } else {offline=try await self.library.makeOfflineCopy(pin:pin,to:destination)}
            try self.requireActive()
            let input=try offline.placementInput(instanceID:id,roomID:room,pose:pose,sizing:sizing)
            let url=try offline.mainFileURL()
            try await self.placeNative(url,input,pin)
            try self.requireActive();self.completedPlacementID=id
        }
    }
    private func number(_ value: String, field: String) throws -> Double {
        guard let n=Double(value.trimmingCharacters(in:.whitespacesAndNewlines)),n.isFinite,abs(n)<=1e9 else {
            throw BuildingFurnitureInputError.incompleteNumber(field)
        }
        return n
    }
    private func pose() throws -> FurniturePose {
        .init(planXMM:try number(xText,field:"x"),planYMM:try number(yText,field:"y"),
              floorElevationMM:floorElevationMM,elevationAboveFloorMM:try number(elevationText,field:"elevation"),
              yawDegrees:try number(yawText,field:"yaw"),anchor:anchor)
    }
    private func sizing(_ manifest: FurnitureAssetManifest) throws -> FurnitureSizing {
        if useCatalogDimensions,let dimensions=manifest.declaredDimensions {
            return .catalogDimensions(dimensions.millimetres,allowNonUniformScaling:allowNonUniformScaling)
        }
        guard let sourceUnit else{throw BuildingFurnitureInputError.sizingRequired}
        return .sourceUnits(millimetresPerUnit:sourceUnit.millimetresPerUnit)
    }
    func cancel() {task?.cancel()}
    func waitForIdle() async {let owned=task;await owned?.value}
    func stop() async {
        closed=true;task?.cancel()
        let owned=task
        await owned?.value
        operation = .idle;operationID=nil;task=nil
    }
}
#endif
