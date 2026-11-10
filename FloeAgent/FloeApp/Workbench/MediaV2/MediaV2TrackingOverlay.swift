// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2TrackingOverlay: View {
    @Bindable var session: MediaV2Session
    var body: some View {
        SwiftUI.Canvas { context,size in
            guard let selected = session.selectedClip, !selected.track.isMuted,
                  let binding = selected.clip.videoTracking?.source,
                  (session.document.assetRevisions?[binding.assetID] ?? 0) == binding.assetRevision,
                  session.document.asset(binding.assetID)?.contentHash == nil || session.document.asset(binding.assetID)?.contentHash == binding.contentHash,
                  let canvas = session.document.canvas,
                  let corners = try? MediaVideoMotionMath.trackingCorners(clip: selected.clip,canvas: canvas,timelineSeconds: session.playhead),
                  corners.count == 4 else { return }
            var path = Path()
            path.move(to: CGPoint(x: corners[0].x*size.width,y: corners[0].y*size.height))
            for p in corners.dropFirst() { path.addLine(to: CGPoint(x: p.x*size.width,y: p.y*size.height)) }
            path.closeSubpath()
            context.stroke(path,with: .color(.black.opacity(0.7)),lineWidth: 3)
            context.stroke(path,with: .color(.yellow),style: StrokeStyle(lineWidth: 1.5,dash: [6,3]))
        }.allowsHitTesting(false).clipped().accessibilityHidden(true)
    }
}
#endif
