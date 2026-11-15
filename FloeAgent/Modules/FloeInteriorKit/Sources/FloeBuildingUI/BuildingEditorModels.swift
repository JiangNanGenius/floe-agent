// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Observation
import FloeInteriorCore
import FloeBuildingRecords
import FloeBuildingSystems
import FloeBuildingAnalysis
import FloeBuildingWorkspace

@MainActor @Observable
final class BuildingDesignEditor<Value: Codable & Equatable & Sendable> {
    private var history: BuildingEditorHistory<Value>
    private let seed: Value
    var base: BuildingComponentBase = .absent
    init(_ seed: Value) { self.seed=seed; history = .init(value: seed) }
    var value: Value { get { history.value } set { _ = history.edit(newValue) } }
    var isDirty: Bool { history.isDirty }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var needsSave: Bool { history.isDirty || !history.hasPersistedVersion }
    func undo() { _ = history.undo() }
    func redo() { _ = history.redo() }
    func beginSave() -> BuildingEditorSave<Value>? { history.beginSave() }
    @discardableResult func saved(_ capture: BuildingEditorSave<Value>, base: BuildingComponentBase) -> Bool {
        guard history.acknowledgeSave(capture) else { return false }
        self.base=base; return true
    }
    func failed(_ capture: BuildingEditorSave<Value>) { _ = history.failSave(capture) }
    func restore(_ state: BuildingComponentSnapshot?) throws {
        if let data=state?.payload {
            let value=try JSONDecoder().decode(Value.self,from:data)
            history.replaceFromStorage(value,isPersisted:true)
        } else { history.replaceFromStorage(seed,isPersisted:false) }
        base=state?.base ?? .absent
    }
    func encoded() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        return try encoder.encode(value)
    }
}

typealias CabinetEditorValue = BuildingCabinetDesign
struct LightingEditorValue: Codable, Equatable, Sendable {
    var profile:IESPhotometry?
    var profileName=""
    var widthM=4.0;var depthM=4.0;var lampHeightM=2.7;var workplaneHeightM=0.8;var output=1.0
    func request(revision:Int) throws -> LightingAnalysisRequest {
        guard let profile else{throw BuildingAnalysisError.invalidInput("IES photometry required")}
        return .init(projectRevision:revision,luminaires:[.init(id:"L1",positionM:.init(widthM/2,depthM/2,lampHeightM),outputScale:output,photometry:profile)],
            workplane:.init(originM:.init(0,0,workplaneHeightM),widthM:widthM,heightM:depthM,columns:25,rows:25))
    }
}

@MainActor @Observable
final class BuildingWorkbenchEditors {
    let cabinet=BuildingDesignEditor(CabinetEditorValue())
    var smartHome=BuildingDesignEditor(SmartHomePlan(projectID:UUID()))
    let radio:BuildingDesignEditor<RadioEstimateRequest>
    let lighting=BuildingDesignEditor(LightingEditorValue())
    let hvac=BuildingDesignEditor(HVACDesignLoadRequest(roomID:"synthetic-room",projectRevision:0,mode:.cooling,
        indoorC:24,outdoorC:35,envelope:[.init(id:"synthetic-envelope",areaM2:30,transmittanceWPerM2K:1.5,evidenceID:"synthetic-envelope@1")],
        outdoorAirM3PerS:0.03,airDensityKgPerM3:1.2,airHeatCapacityJPerKgK:1005,internalSensibleW:300,solarSensibleW:200,
        explicitLatentW:0,conditionsEvidenceID:"synthetic-design-conditions@1"))
    var cabinetAssembly:CabinetAssembly?
    var cabinetSheet:CabinetCombinationSheet?
    var smartValidation:SystemPlanValidation?
    var radioResult:RadioEstimateResult?
    var radioInput:RadioEstimateRequest?
    var lightingResult:LightingAnalysisResult?
    var lightingInput:LightingAnalysisRequest?
    var lightingPreviewOutput:Double?
    var hvacResult:HVACDesignLoadResult?
    init() {
        var seed=RadioSampleFixtures.twoRoomRequest()
        seed.receiverPlane = .init(originM:.init(0,-3,1.2),right:.init(1,0,0),up:.init(0,1,0),widthM:12,heightM:6,columns:41,rows:21)
        radio=BuildingDesignEditor(seed)
    }
    var dirtyCount:Int { [cabinet.isDirty,smartHome.isDirty,radio.isDirty,lighting.isDirty,hvac.isDirty].filter{$0}.count }
    func restore(_ loaded:BuildingWorkspaceLoadedProject) throws {
        // Decode all first. A malformed saved design must not partially clear
        // the user's current editors during a failed reopen.
        let decoder=JSONDecoder()
        if let d=loaded.components[.cabinet]?.payload {let v=try decoder.decode(CabinetEditorValue.self,from:d);try v.recipe.validate()}
        if let d=loaded.components[.smartHome]?.payload {
            let v=try SmartHomePlan.reopen(d)
            guard v.projectID==loaded.snapshot.project.id.rawValue else{throw BuildingWorkspaceError.wrongProject}
        }
        if let d=loaded.components[.radio]?.payload {_=try decoder.decode(RadioEstimateRequest.self,from:d)}
        if let d=loaded.components[.lighting]?.payload {let v=try decoder.decode(LightingEditorValue.self,from:d);try v.profile?.validate()}
        if let d=loaded.components[.hvac]?.payload {_=try decoder.decode(HVACDesignLoadRequest.self,from:d)}
        try cabinet.restore(loaded.components[.cabinet]);try smartHome.restore(loaded.components[.smartHome])
        try radio.restore(loaded.components[.radio]);try lighting.restore(loaded.components[.lighting]);try hvac.restore(loaded.components[.hvac])
        if loaded.components[.smartHome]?.payload==nil {
            smartHome.value.projectID=loaded.snapshot.project.id.rawValue
            smartHome.value.roomIDs=loaded.snapshot.rooms.map{$0.id.rawValue}
            // Establish an unsaved seed bound to this actual project.
            let seed=smartHome.value
            smartHome=Self.reboundSmartHome(seed)
        }
        cabinetAssembly=nil;cabinetSheet=nil;smartValidation=nil;radioResult=nil;radioInput=nil
        lightingResult=nil;lightingInput=nil;lightingPreviewOutput=nil;hvacResult=nil
    }
    private static func reboundSmartHome(_ value:SmartHomePlan)->BuildingDesignEditor<SmartHomePlan> {BuildingDesignEditor(value)}
}
