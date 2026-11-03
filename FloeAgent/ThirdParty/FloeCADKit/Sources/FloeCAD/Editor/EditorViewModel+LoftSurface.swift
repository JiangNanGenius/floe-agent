import Foundation

nonisolated struct CADLoftSurfaceUISnapshot {
    var generation: Int
    var closedSections: [CADLoftSectionChoice]
    var openEdges: [CADSurfaceEdgeChoice]
    var sources: [CADSurfaceInputChoice]
}

@MainActor extension EditorViewModel {
    var canBeginNativeSurfaceEditor: Bool {
        guard !session.isReadOnly,session.document.features.rollbackIndex == nil else { return false }
        if session.document.bodies.contains(where:{ $0.surfaceBRep != nil }) { return true }
        return session.document.sketches.filter { sketch in
            sketch.entities.contains { entity in
                switch entity {
                case .line,.arc:return true
                case let .spline(_,_,closed):return !closed
                case let .exactCurve(_,definition):return !definition.interval.periodic
                default:return false
                }
            }
        }.count >= 2
    }
    func loftSurfaceJSON<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(value))) ?? NSNull()
    }
    func loftSurfaceUISnapshot(before feature: FeatureID? = nil) -> CADLoftSurfaceUISnapshot {
        let result: EvalResult?
        if let feature { result=session.inputState(before:feature) }
        else { result=session.previewLoftSurface() }
        var sketches=session.document.sketches
        if let result {
            for index in sketches.indices {
                if let plane=result.resolvedSketchSupportUpdates[sketches[index].id] { sketches[index].plane=plane }
                if let entities=result.resolvedSketchEntityUpdates[sketches[index].id] { sketches[index].entities=entities }
            }
        }
        return CADLoftSurfaceUISnapshot(generation:session.changeCount,
            closedSections:CADLoftSurfaceUIModel.closedSections(sketches:sketches),
            openEdges:CADLoftSurfaceUIModel.openEdges(sketches:sketches),
            sources:result.map { CADLoftSurfaceUIModel.sources(result:$0) } ?? [])
    }
    func performLoftSurfaceAction(_ action: String,args: [String:Any]) -> [String:Any] {
        guard let datumActionHandler else {
            return ["ok":false,"mutated":false,"error":"unavailable",
                "message":FloeCADStrings.text("cad.feature.editUnavailable","Reopen the document before editing a feature.")]
        }
        let reply=datumActionHandler(action,args)
        if reply["ok"] as? Bool == true { errorMessage=nil }
        else { errorMessage=reply["message"] as? String
            ?? FloeCADStrings.text("cad.loftSurface.failed","Couldn't apply these settings. Your design is unchanged.") }
        return reply
    }
    func applyNativeLoftSettings(_ id: FeatureID,sections: [ProfileRef],ruled: Bool,generation: Int) -> [String:Any] {
        guard let node=session.document.features.node(id),case let .loft(_,_,original)=node.kind else {
            return ["ok":false,"mutated":false,"error":"missing_loft"]
        }
        var definition=original ?? LoftDefinition()
        definition.ruled=ruled
        return performLoftSurfaceAction("loft.update",args:["feature_id":id.raw.uuidString,
            "expected_change_count":generation,"changes":["sections":loftSurfaceJSON(sections),
                "definition":loftSurfaceJSON(definition)]])
    }
    func applyNativeGuidedLoftSettings(_ id:FeatureID,sections:[ProfileRef],definition:LoftDefinition,generation:Int) async -> [String:Any] {
        guard let guidedLoftActionHandler else { return ["ok":false,"mutated":false,"error":"unavailable"] }
        return await guidedLoftActionHandler("loft.update",["feature_id":id.raw.uuidString,
            "expected_change_count":generation,"changes":["sections":loftSurfaceJSON(sections),"definition":loftSurfaceJSON(definition)]])
    }
    func configureNativeGuidedLoftDraft(sections:[ProfileRef],definition:LoftDefinition,generation:Int) async -> Bool {
        do {
            try definition.requireSupported(sectionCount:sections.count)
            if !definition.guides.isEmpty {
                let snapshot=try session.guidedLoftSnapshot(sections:sections,definition:definition)
                guard await CADGuidedLoftPreparation.prepare([snapshot]) else { return false }
            }
            if definition.hasEndpointConstraints {
                let snapshots=try session.endpointLoftSnapshots(sections:sections,definition:definition)
                guard await CADLoftEndpointPreparation.prepare(snapshots) else { return false }
            }
            guard !Task.isCancelled,session.changeCount == generation,documentClosedCheck?() != true else { return false }
            return configureNativeLoftDraft(sections:sections,ruled:definition.ruled,guides:definition.guides,start:definition.start,end:definition.end,expectedChangeCount:generation)
        } catch { return false }
    }
    func applyNativeSurface(_ definition: CADSurfaceDefinition,editing feature: FeatureID?,generation: Int) -> [String:Any] {
        var args: [String:Any]=["definition":loftSurfaceJSON(definition),"expected_change_count":generation]
        if let feature { args["feature_id"]=feature.raw.uuidString }
        let reply=performLoftSurfaceAction(feature == nil ? "surface.create" : "surface.update",args:args)
        if reply["ok"] as? Bool == true,let ids=reply["body_ids"] as? [String],let raw=ids.first.flatMap(UUID.init(uuidString:)) {
            let body=BodyID(raw:raw);selection=[body];mode = .selected(body);session.save()
        }
        return reply
    }
}
