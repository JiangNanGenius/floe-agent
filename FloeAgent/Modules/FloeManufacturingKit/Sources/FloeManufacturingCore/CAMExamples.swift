// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension ManufacturingCAM.Tool {
    static func researchExample(id:String = UUID().uuidString.lowercased(),kind:String = "flatEndMill") -> Self {
        var tool = Self(id:id,name:kind == "drill" ? "Ø2 drill" : kind == "ballNose" ? "Ø4 ball nose" : "Ø4 end mill",kind:kind,diameterMM:kind == "drill" ? 2 : 4,cuttingLengthMM:12)
        tool.flutes = kind == "drill" ? 2 : 4
        if kind == "drill" { tool.tipAngleDegrees = 118 }
        return tool
    }
}
public extension ManufacturingStudy {
    static func turnMillCAM() -> Self {
        var study = shaft(milled:true); study.name = "单主轴车铣工序"
        // 39*39*64 cells fits the existing 131072-cell local budget. A 1 mm
        // grid is visibly too coarse for the small stepped/slot features.
        // This explicit example setting never replaces imported job inputs.
        study.stock.resolutionMM = 0.625
        // Explicit demonstration inputs, not speeds inferred for imported jobs.
        study.turningSetup = .init()
        study.turningSetup?.insertRotationDegrees = 35
        study.turningCutting = .init(spindleMode:.fixedRPM,feedMode:.mmPerMinute,spindleRPM:900,
            surfaceSpeedMPerMinute:120,maxSpindleRPM:2500,feedMMPerRevolution:0.1)
        let mill = ManufacturingCAM.Tool.researchExample(id:"live-mill-4")
        let drill = ManufacturingCAM.Tool.researchExample(id:"axial-drill-2",kind:"drill")
        var side = ManufacturingCAM.Operation(id:"side-face",name:"径向面铣",strategy:"face",toolID:mill.id)
        side.frame = .init(originMM:[10,0,7],axis:[1,0,0],xDirection:[0,0,1])
        side.minUVMM = [-3,-2]; side.maxUVMM = [3,2]; side.depthMM = 1
        side.stepOverMM = 1.5; side.stepDownMM = 0.5
        side.cutting = .init(mode:"perMinute",toolSpindleRPM:2500,feedPerToothMM:0.025,feedPerRevolutionMM:0.1)
        var hole = ManufacturingCAM.Operation(id:"axial-hole",name:"轴向啄钻",strategy:"drill",toolID:drill.id)
        hole.frame.originMM = [0,0,38]; hole.holesUVMM = [[0,0]]; hole.depthMM = 4
        hole.cycle = "peck"; hole.peckDepthMM = 1
        hole.cutting = .init(mode:"perMinute",toolSpindleRPM:1800,feedPerToothMM:0.025,feedPerRevolutionMM:0.1)
        study.cam = .init(tools:[mill,drill],operations:[side,hole])
        return study
    }
    /// Deliberately small feature fixture, not cutting recommendations.
    static func featureCAM() -> Self {
        var study = shaft(); study.name = "多工序方料"
        study.source = .init(documentID:"fixture:cam-feature-block-r4",revision:1,contentSHA256:digest(Data("cam-feature-block-20x16x8-r4".utf8)))
        study.turning.enabled = false; study.stock.shape = "box"
        study.stock.minMM = [-10,-8,0]; study.stock.maxMM = [10,8,8]
        study.stock.zMinMM = 0; study.stock.zMaxMM = 8; study.stock.radiusMM = 12
        study.profile = [.init(12,0),.init(12,8)]
        study.fixtures = [.init(id:"vise",minMM:[-12,-10,-4],maxMM:[12,10,-1])]
        let mill = ManufacturingCAM.Tool.researchExample(id:"mill-4")
        let drill = ManufacturingCAM.Tool.researchExample(id:"drill-2",kind:"drill")
        var face = ManufacturingCAM.Operation(id:"face-1",name:"端面",strategy:"face",toolID:mill.id)
        face.frame.originMM = [0,0,8]; face.minUVMM = [-10,-8]; face.maxUVMM = [10,8]
        face.depthMM = 1; face.stepDownMM = 1; face.stepOverMM = 2
        var pocket = ManufacturingCAM.Operation(id:"pocket-1",name:"圆形型腔",strategy:"pocket",toolID:mill.id)
        pocket.frame.originMM = [0,0,7]; pocket.centerUVMM = [-4,0]; pocket.radiusMM = 4
        pocket.depthMM = 2; pocket.stepDownMM = 1; pocket.stepOverMM = 1.5
        pocket.cutting = .init(mode:"perTooth",toolSpindleRPM:2000,feedPerToothMM:0.025,feedPerRevolutionMM:0.1)
        var holes = ManufacturingCAM.Operation(id:"holes-1",name:"停留双孔",strategy:"drill",toolID:drill.id)
        holes.frame.originMM = [0,0,7]; holes.holesUVMM = [[5,-4],[5,4]]
        holes.depthMM = 3; holes.stepDownMM = 1; holes.cycle = "counterBore"; holes.peckDepthMM = 1; holes.dwellSeconds = 0.2
        study.cam = .init(tools:[mill,drill],operations:[face,pocket,holes])
        return study
    }
    static func surfaceCAM() -> Self {
        var study = featureCAM(); study.name = "曲面栅格"
        let tool = ManufacturingCAM.Tool.researchExample(id:"ball-4",kind:"ballNose")
        var op = ManufacturingCAM.Operation(id:"surface-1",name:"倾斜面栅格",strategy:"surfaceRaster",toolID:tool.id)
        op.frame.originMM = [0,0,8]; op.minUVMM = [-6,-4]; op.maxUVMM = [6,4]
        op.depthMM = 4; op.stepOverMM = 2
        let mesh = ManufacturingCAM.Mesh(vertices:[[-10,-8,4],[-10,8,4],[10,-8,6],[10,8,6]],triangles:[[0,2,1],[1,2,3]])
        study.cam = .init(tools:[tool],operations:[op],partMesh:mesh)
        study.source = .init(documentID:"fixture:cam-sloped-surface-r4",revision:1,contentSHA256:digest((try? encoder.encode(mesh)) ?? Data()))
        return study
    }
    static func selectedTurning() -> Self {
        var study = shaft(); study.name = "可选车削工序"
        var setup = TurningSetup(); setup.faceEnabled = false; setup.horizontalFeedMMPerMinute = 80; setup.verticalFeedMMPerMinute = 160
        study.turningSetup = setup
        return study
    }
}
