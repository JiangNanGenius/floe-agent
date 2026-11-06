// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ManufacturingResult {
    func validateCAM(for study:ManufacturingStudy) throws {
        func require(_ value:Bool,_ message:String) throws {
            if !value { throw ManufacturingError.native("CAM result: "+message) }
        }
        if let setup = study.turningSetup, study.turning.enabled {
            guard let turningSetupReceipt else { throw ManufacturingError.native("native turning setup receipt missing") }
            try turningSetupReceipt.validate(expected:setup)
            let expectedKinds = [(setup.faceEnabled,"turning-face"),(setup.roughEnabled,"turning-rough"),(setup.profileEnabled,"turning-profile")]
            for (enabled,kind) in expectedKinds {
                try require(enabled || !paths.contains { $0.kind == kind },"disabled turning operation produced motion")
            }
        } else { try require(turningSetupReceipt == nil,"unexpected turning setup receipt") }
        let ops = study.cam?.enabledOperations ?? []
        let camPaths = paths.filter { $0.kind.hasPrefix("cam-") }
        if ops.isEmpty {
            try require(camPaths.isEmpty && (camReport?.isEmpty ?? true) && (sampledCamPoses ?? 0) == 0,"unexpected CAM output")
            return
        }
        guard let reports = camReport, let sampledCamPoses else { throw ManufacturingError.native("native component did not execute requested CAM operations") }
        try require(reports.map(\.operationID) == ops.map(\.id),"operation coverage/order")
        try require(sampledCamPoses > 0 && sampledCamPoses <= study.budget.maxPoses,"sampled pose budget")
        var lastOrder = -1
        for path in camPaths {
            guard let opIndex = ops.firstIndex(where:{ $0.id == path.operationID }), let toolID = path.toolID,
                  let move = path.moveType, ["cut","plunge","rapid","retract","dwell"].contains(move),
                  path.kind == "cam-"+move else { throw ManufacturingError.native("CAM path identity/move type") }
            try require(opIndex >= lastOrder && toolID == ops[opIndex].toolID,"path order/tool reference")
            lastOrder = opIndex
            try require(!path.points.isEmpty,"empty CAM motion")
            guard let axes = path.toolAxes else { throw ManufacturingError.native("CAM path tool axes missing") }
            try require(axes.count == path.points.count && axes.allSatisfy { CAMCheck.point($0) && abs(CAMCheck.norm($0)-1) <= 1e-5 },"tool axis coverage")
            if let joints = path.joints {
                try require(joints.count == path.points.count && joints.allSatisfy { $0.count == 5 && $0.allSatisfy { $0.isFinite && abs($0) <= 100_000 } },"joint coverage")
            }
            try require((ops[opIndex].acSeed == nil) == (path.joints == nil),"A/C solution coverage")
            if move == "dwell" {
                try require(path.dwellSeconds?.isFinite == true && (path.dwellSeconds ?? 0) > 0 && path.points.allSatisfy { $0 == path.points[0] },"dwell duration/stationary motion")
            } else {
                try require(path.points.count >= 2 && path.feedMMPerMinute?.isFinite == true && (path.feedMMPerMinute ?? 0) > 0 && (path.feedMMPerMinute ?? 0) <= 1_000_000 && path.dwellSeconds == nil,"linear motion feed")
            }
        }
        guard let firstIndex = stages.firstIndex(where:{ $0.name == "cam-"+ops[0].id }) else { throw ManufacturingError.native("CAM material stage missing") }
        var previousRemaining:Double? = firstIndex > 0 ? stages[firstIndex-1].remainingMM3 : initialMM3
        for (op,report) in zip(ops,reports) {
            let ownPaths = camPaths.filter { $0.operationID == op.id }
            try require(report.strategy == op.strategy && report.toolID == op.toolID && !ownPaths.isEmpty,"operation strategy/tool/paths")
            try require(report.generatedPoints == ownPaths.reduce(0) { $0+$1.points.count } && report.generatedPoints > 0 && report.cutPoses > 0 && report.cutPoses <= sampledCamPoses,"generated/cutting pose counts")
            try require(report.remainingMM3.isFinite && report.removedMM3.isFinite && report.remainingMM3 >= 0 && report.removedMM3 >= 0 && report.remainingMM3 <= initialMM3,"operation material quantities")
            try require(stages.contains { $0.name == "cam-"+op.id && $0.remainingMM3 == report.remainingMM3 },"operation/material stage coverage")
            if let previousRemaining { try require(abs(previousRemaining-report.remainingMM3-report.removedMM3) <= max(0.01,initialMM3*1e-8),"material chronology") }
            previousRemaining = report.remainingMM3
            guard let tool = study.cam?.tools.first(where:{ $0.id == op.toolID }) else { throw ManufacturingError.native("missing CAM tool") }
            func has(_ part:String,_ target:String,_ component:String) -> Bool {
                collisions.contains { ($0.operation == op.id || $0.operation == "cam:"+op.id) && $0.toolPart == part && $0.targetKind == target && $0.component == component }
            }
            let bodyParts:[String]
            if let assembly = tool.assembly {
                bodyParts = (assembly.holderProfile.first!.axialMM-tool.cuttingLengthMM > 1e-9 ? ["shank"]:[])+["holder"]
                try require(assemblyQueryCount != nil,"CAM assembly query receipt")
                for part in bodyParts { try require(has(part,"stock","remaining-stock"),"missing CAM body/current-stock query") }
            } else { bodyParts = [] }
            for fixture in study.fixtures {
                for part in ["cutter"]+bodyParts { try require(has(part,"fixture",fixture.id),"missing CAM part/fixture query") }
            }
            try require(!report.sources.isEmpty && report.sources.allSatisfy { !$0.isEmpty },"algorithm sources")
        }
        if study.acMotion == nil, let previousRemaining { try require(abs(previousRemaining-remainingMM3) <= max(0.01,initialMM3*1e-8),"final material state") }
    }
}
