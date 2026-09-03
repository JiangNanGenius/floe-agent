// FloeApp — Atomic saved-image generation commit planning.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import Foundation
import FloeCore

/// Builds the one canvas patch that publishes a saved image-generation batch.
/// Provider assets exist before this point, but none of them becomes visible
/// on the canvas until every prepared result can be committed together.
struct CanvasSavedImageBatchCommitPlan: Sendable, Hashable {
    var resultNodeIDs: [UUID]
    var sourceNodeIDs: [UUID]
    var groupID: UUID?
    var operations: [CanvasPatchOperation]
}

enum CanvasGenerationStatePatchPlanner {
    static func operations(
        state: CanvasGenerationTaskState,
        nodeIDs: [UUID],
        error: String? = nil
    ) -> [CanvasPatchOperation] {
        var seen = Set<UUID>()
        return nodeIDs.filter { seen.insert($0).inserted }.map { nodeID in
            CanvasPatchOperation(
                kind: .update,
                nodeID: nodeID,
                metadata: [
                    "generationState": state.rawValue,
                    "generationError": error ?? "",
                    "generationErrorDetail": error ?? ""
                ]
            )
        }
    }
}

enum CanvasSavedImageBatchCommitPlanner {
    static func plan(
        configurationNodeID: UUID,
        preparedResultNodeIDs: [UUID],
        assets: [CanvasAssetReference],
        configuration: CanvasGenerationConfiguration,
        sourceNodeIDs: [UUID],
        generationAttemptID: String,
        groupID proposedGroupID: UUID? = nil
    ) throws -> CanvasSavedImageBatchCommitPlan {
        let resultNodeIDs = try CanvasGenerationOutputContract.resultNodeIDs(
            expectedCount: configuration.count,
            actualCount: assets.count,
            preparedResultNodeIDs: preparedResultNodeIDs
        )
        guard !generationAttemptID.isEmpty else {
            throw FloeError.validationFailed("Canvas generation attempt id is missing")
        }

        var seenSourceNodeIDs = Set<UUID>()
        let sourceNodeIDs = sourceNodeIDs.filter {
            $0 != configurationNodeID && seenSourceNodeIDs.insert($0).inserted
        }
        let groupID = resultNodeIDs.count > 1 ? (proposedGroupID ?? UUID()) : nil
        let resultList = resultNodeIDs.map(\.uuidString).joined(separator: ",")
        let sourceList = sourceNodeIDs.map(\.uuidString).joined(separator: ",")
        var operations: [CanvasPatchOperation] = []

        for (index, pair) in zip(resultNodeIDs, assets).enumerated() {
            let (resultNodeID, asset) = pair
            var metadata = configuration.metadata
            metadata.merge([
                "generationState": CanvasGenerationTaskState.ready.rawValue,
                "generationAttemptID": generationAttemptID,
                "generationResultNodeIDs": resultList,
                "generationSourceNodeIDs": sourceList,
                "generationTaskNodeID": configurationNodeID.uuidString,
                "generationGroupID": groupID?.uuidString ?? "",
                "generationError": "",
                "generationErrorDetail": "",
                "imageGroupPrimary": index == 0 ? "true" : "false",
                "artifactOrigin": "generated"
            ]) { _, new in new }
            operations.append(CanvasPatchOperation(
                kind: .update,
                nodeID: resultNodeID,
                nodeKind: .image,
                text: assets.count > 1 ? "生成图片 \(index + 1)" : "生成图片",
                asset: asset,
                metadata: metadata
            ))
        }

        if let groupID {
            operations.append(CanvasPatchOperation(
                kind: .group,
                nodeID: groupID,
                nodeIDs: resultNodeIDs
            ))
        }

        var taskMetadata = configuration.metadata
        taskMetadata.merge([
            "generationState": CanvasGenerationTaskState.ready.rawValue,
            "generationAttemptID": generationAttemptID,
            "generationResultNodeIDs": resultList,
            "generationSourceNodeIDs": sourceList,
            "generationGroupID": groupID?.uuidString ?? "",
            "generationError": "",
            "generationErrorDetail": ""
        ]) { _, new in new }
        operations.append(CanvasPatchOperation(
            kind: .update,
            nodeID: configurationNodeID,
            metadata: taskMetadata
        ))

        return CanvasSavedImageBatchCommitPlan(
            resultNodeIDs: resultNodeIDs,
            sourceNodeIDs: sourceNodeIDs,
            groupID: groupID,
            operations: operations
        )
    }
}
#endif
