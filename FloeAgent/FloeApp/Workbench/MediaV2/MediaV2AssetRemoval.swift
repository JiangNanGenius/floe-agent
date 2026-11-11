// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeWorkbench

@MainActor
struct MediaV2AssetActions: View {
    let session: MediaV2Session
    let asset: MediaAssetReference
    var body: some View {
        Menu {
            Button(WorkbenchText.t("移出工程", "Remove from project"), role: .destructive) { session.removeAsset(asset) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(WorkbenchText.t("素材操作", "Asset actions"))
            .accessibilityIdentifier("media.asset.actions.\(asset.id.uuidString)")
            .disabled(session.saving || session.processingTool)
    }
}

extension MediaV2Session {
    func reconcileSelection() {
        let layers = Set(document.layers.map(\.id))
        selectedLayerIDs.formIntersection(layers)
        if let selectedLayerID, !layers.contains(selectedLayerID) {
            self.selectedLayerID = nil
            selection = nil; polygonPoints = []; imageWarpDraft = nil
            cloneSourcePoint = nil; cloneDestinationOrigin = nil
        }
        let clips = Set(document.trackGraph.tracks.flatMap(\.clips).map(\.id))
        selectedClipIDs.formIntersection(clips)
        if let selectedClipID, !clips.contains(selectedClipID) { self.selectedClipID = nil }
        if let selectedTrackID, document.trackGraph.track(selectedTrackID) == nil { self.selectedTrackID = nil }
    }
    func removeAsset(_ asset: MediaAssetReference) {
        var input = MediaV2ToolInput(); input.objectID = asset.id; input.expectedRevision = document.revision
        let toolID = document.kind.rawValue + ".remove-asset"
        Task {
            do { _ = try await performTool(toolID, input: input) }
            catch MediaPreparedAssetRemovalError.inUse(let uses) {
                let names = uses.prefix(6).map { use in
                    let label: String
                    switch use.kind {
                    case .source: label = WorkbenchText.t("原始素材", "Original source")
                    case .layer: label = WorkbenchText.t("图层", "Layer")
                    case .clip: label = WorkbenchText.t("片段", "Clip")
                    case .compound: label = WorkbenchText.t("复合片段", "Compound clip")
                    case .colorReference: label = WorkbenchText.t("色彩参考", "Color reference")
                    case .unknownContent: label = WorkbenchText.t("尚未识别的内容", "Unrecognized content")
                    }
                    return "\(label)：\(use.name)"
                }.joined(separator: "；")
                diagnostic = WorkbenchText.t("此素材仍用于\(names)。请先移除使用对象。", "This asset is still used by \(names). Remove its uses first.")
            } catch { diagnostic = error.localizedDescription }
        }
    }
}
#endif
