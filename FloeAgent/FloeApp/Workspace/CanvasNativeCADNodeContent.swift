// SPDX-License-Identifier: MPL-2.0
// FloeApp — canvas body for a native, editable `.floecad` CAD node.
//
// Before this view a native CAD node fell through to the generic `.file`
// asset body: it rendered a document glyph over the raw MIME label
// ("image/png", header 产物/导入) even though its live asset is a VIEWPORT
// render of an editable parametric model. That presentation had two defects
// found in CUA:
//
//   1. The node did not look like the adopted CAD result — the user saw a
//      generic document icon instead of the actual viewport PNG thumbnail.
//   2. The "image/png · 产物/导入" badge implied the node's ORIGINAL was the
//      preview PNG. It is not: the editable source is the bound `.floecad`
//      package (canvas-owned on-device storage); the PNG is only its render.
//
// This view renders the actual viewport thumbnail through the SAME bounded,
// path-guarded asset thumbnail cache every image node uses (no parallel media
// subsystem), overlays an explicit "editable CAD · .floecad" badge, and shows
// an explicit placeholder when the render file is missing/unreadable. The
// double-tap / context-menu route opens the bound package; this view is
// presentation only and never resolves outside the app asset root.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct CanvasNativeCADNodeContent: View {
    let node: CanvasNode

    var body: some View {
        ZStack(alignment: .top) {
            thumbnail
            HStack {
                Label(
                    canvasLocalized("可编辑 CAD · .floecad", "Editable CAD · .floecad"),
                    systemImage: "cube.transparent"
                )
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                Spacer()
            }
            .padding(8)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        // Combine the thumbnail and badge so the host node card
        // (`canvas.node.<uuid>`) reads as one element whose label carries the
        // editable `.floecad` identity — never the asset's image/png MIME.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(canvasLocalized(
            "可编辑 CAD 模型 .floecad，视口缩略图",
            "Editable CAD model .floecad, viewport thumbnail"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        // The asset is the viewport render persisted into the material
        // library. Resolve it through the identical containment-guarded path
        // and bounded thumbnail cache as ordinary image nodes.
        if let url = CanvasAssetNodeContent.localURL(for: node),
           let image = CanvasImageThumbnailCache.thumbnail(for: url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemFill))
                .accessibilityHidden(true)
        } else {
            // Explicit, never a generic document icon: the bound render is
            // unavailable on this device (placeholder export or missing
            // material), but the node still opens its editable package.
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.largeTitle)
                    .foregroundStyle(FloeTheme.primary)
                Text(canvasLocalized("CAD 视口预览不可用", "CAD viewport preview unavailable"))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(".floecad")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(Color(uiColor: .secondarySystemFill))
        }
    }
}
#endif
