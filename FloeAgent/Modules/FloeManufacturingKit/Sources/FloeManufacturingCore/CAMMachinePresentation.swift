// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CAMPreviewMachineKind:String,Sendable { case lathe,vertical3Axis,acTableTable }

/// Presentation of the qualified, zero-pivot OpenMill table-table chain.
/// This does not add generic machine IK or manufacturer/safety geometry.
public struct CAMMachinePresentation:Sendable {
    public var kind:CAMPreviewMachineKind
    public var stockMinMM:[Double]
    public var stockMaxMM:[Double]
    public var worldFromWorkpiece:CellRigidTransform
    public var aAxisFrame:CellRigidTransform
    public var joints:[Double]?
    public var machineToolTipMM:[Double]?
    public var machineToolAxis:[Double]?
    public var gaugeLengthMM:Double?

    static func study(_ study:ManufacturingStudy,tools:[CAMPreviewTool]) throws -> Self {
        let bounds = study.stock.bounds
        var value = Self(kind:study.turning.enabled ? .lathe : study.acMotion != nil ? .acTableTable : .vertical3Axis,
            stockMinMM:bounds.min,stockMaxMM:bounds.max,worldFromWorkpiece:.identity,aAxisFrame:.identity)
        value.gaugeLengthMM = tools.first?.gaugeLengthMM ?? tools.first?.definition?.assembly?.holderProfile.last?.axialMM
        guard value.kind == .acTableTable,let motion = study.acMotion,let joint = tools.first?.joints,joint.count==5 else { return value }
        let a = joint[3]*Double.pi/180,c = joint[4]*Double.pi/180
        let ca = cos(a),sa = sin(a),cc = cos(c),sc = sin(c)
        // Exact pinned chain: machine = Rx(A) Rz(C) workpiece, pivot = 0.
        value.worldFromWorkpiece = .init(rotation:[cc,-sc,0,ca*sc,ca*cc,-sa,sa*sc,sa*cc,ca],translationMM:[0,0,0])
        value.aAxisFrame = .init(rotation:[1,0,0,0,ca,-sa,0,sa,ca],translationMM:[0,0,0])
        value.joints = joint;value.gaugeLengthMM = motion.toolLengthMM
        value.machineToolTipMM = [joint[0],joint[1],joint[2]-motion.toolLengthMM]
        value.machineToolAxis = [0,0,1]
        return value
    }
}
