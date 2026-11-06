// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A read-only value resolved through the source job and original path metadata,
/// including Cell jobs whose tool/operation IDs may coincide across channels.
public struct CAMOperationInspection:Sendable {
    public let chapter:CAMPreviewChapter
    public let study:ManufacturingStudy
    public let operation:ManufacturingCAM.Operation?
    public let tool:ManufacturingCAM.Tool?
    public let turning:Bool
    public let turningSetup:TurningSetup?
    public let metric:CAMPreviewProgram.Metric
    public let legacyMilling:Bool
}

public extension CAMPreviewProgram {
    func inspection(forChapterID id:String)->CAMOperationInspection? {
        guard let chapter = chapters.first(where:{ $0.id == id }),
              let path = paths.first(where:{ chapter.pathIDs.contains($0.id) }),
              let source = inspectionSource(jobID:chapter.jobID,pathIndex:path.pathIndex) else { return nil }
        let original = source.path,study = source.study,turning = original.kind.hasPrefix("turning-")
        return .init(chapter:chapter,study:study,
            operation:study.cam?.operations.first { $0.id == original.operationID },
            tool:study.cam?.tools.first { $0.id == original.toolID },turning:turning,
            turningSetup:turning ? (source.appliedTurningSetup ?? study.configuredTurningSetup):nil,metric:metric,
            legacyMilling:original.kind == "milling-slot" && study.milling.enabled)
    }
}
