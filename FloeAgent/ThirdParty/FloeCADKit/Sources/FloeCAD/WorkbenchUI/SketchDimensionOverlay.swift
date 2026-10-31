//
//  SketchDimensionOverlay.swift
//  openshape3d
//
//  Light SwiftUI annotation layer for sketch dimensions (plan §C2, spec §2.2).
//  Draws a thin annotation line between the dimension's reference points and a
//  value label at the segment midpoint (projected from world space each camera
//  move via `cameraEpoch`). Tapping a label opens an inline numeric field;
//  committing sets the driving value and re-solves the sketch. Supports inline
//  arithmetic ("25.4/2") through `ExpressionEvaluator`.
//

import SwiftUI
import UIKit

// The Metal canvas has a fixed light gradient, even with dark UI chrome.
// Annotation ink follows that canvas, not the system foreground (white in dark mode).
struct SketchDimensionOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var diameterDragStarts: [String: CGPoint] = [:]
    @State private var diameterDragPreviews: [String: CGPoint] = [:]
    @State private var editorSize = CGSize(width: 280, height: 250)

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        // Dimensions used to be visible only while sketching, so leaving a
        // sketch hid the values that define it. `sketchDimensionLabels` now
        // decides what is visible — every sketch under "Always Show
        // Dimensions", otherwise the active and selected ones.
        //
        // Gate on the CONTENT, not the mode: this overlay is full-screen and
        // hit-testing, so rendering it while it has nothing to draw would put
        // an invisible layer over the viewport for taps to land in.
        let labels = viewModel.sketchDimensionLabels
        // Existence follows the MODE; hit-testing follows the content. Gating
        // existence on content tore this whole subtree down whenever the label
        // list went briefly empty — which it does mid-stroke, while a field
        // inside it was live. Keeping it mounted for the duration of a sketch
        // still avoids the invisible-layer problem, because an overlay with
        // nothing to draw simply stops taking taps.
        if viewModel.mode.isSketching || !labels.isEmpty {
            GeometryReader { geo in
            let presentations = labels.compactMap { presentation(for: $0, in: geo.size) }
            // Resolve overlapping projected anchors once per layout pass, in
            // document label order. Badges, their hit targets, the connector
            // and the inline editor all read the same placement below.
            let placements = SketchBadgeCollisionLayout.placements(
                for: presentations.map { $0.collisionItem },
                in: badgeLayoutBounds(in: geo.size))
            ZStack(alignment: .topLeading) {
                // Stems go behind EVERY badge. A displaced value can move
                // across an earlier badge's row; drawing its stem inside that
                // row would paint the connector over the earlier value. The
                // badges below cover the stem where it passes underneath.
                ForEach(presentations) { presentation in
                    if let center = placements[presentation.id]?.center,
                       center != presentation.defaultCenter {
                        displacedConnector(presentation, to: center)
                    }
                }
                ForEach(presentations) { presentation in
                    labelView(presentation,
                              placement: placements[presentation.id]?.center
                                  ?? presentation.defaultCenter)
                }
                // The editor lives HERE, not inside the ForEach. There is only
                // ever one, and building it per-label tied its identity — and
                // so its @State and @FocusState — to a row whose id is reused
                // ("candidate" is the same id for every freshly drawn shape).
                // Drawing a second shape therefore swapped the field's contents
                // underneath a live editing session and took the app down with
                // it. One field, one identity, outside the loop.
                if let worldAnchor = viewModel.pendingRectangleEditorAnchor ?? labels.first(where: {
                    $0.id == viewModel.editingDimension?.labelID
                })?.worldAnchor, let anchor = project(worldAnchor) {
                    // Open beside the badge the user tapped, including one the
                    // collision layout displaced, not the raw world anchor.
                    let editingID = viewModel.pendingRectangleEditorAnchor == nil
                        ? viewModel.editingDimension?.labelID : nil
                    DimensionField(viewModel: viewModel)
                        .id(viewModel.editingDimension?.sessionID)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { editorSize = $0 }
                        .position(editorPosition(
                            editingID.flatMap { placements[$0]?.center } ?? anchor,
                            in: geo.size))
                }
            }
            }
            .coordinateSpace(name: "SketchDimensionCanvas")
            .onChange(of: viewModel.selectedSketchEntityIDs) {
                diameterDragStarts.removeAll()
                diameterDragPreviews.removeAll()
            }
            .allowsHitTesting(!labels.isEmpty || viewModel.editingDimension != nil)
            // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
            // inset by default, which would draw every projected point ~85pt
            // below the geometry it annotates.
            // Keep container chrome full-bleed, but let the editor's available
            // height follow the software keyboard instead of placing it behind it.
            .ignoresSafeArea(.container)
        }
    }

    /// The constraint rail's horizontal footprint: the full rail on regular
    /// widths, its 44-pt menu button (plus margin) at compact width, and the
    /// bare margin outside a sketch.
    private var railInset: CGFloat {
        guard viewModel.mode.isSketching else { return 16 }
        return horizontalSizeClass == .compact ? 72 : 184
    }

    /// Keep a linear badge out from under the side controls: a line whose
    /// midpoint runs beneath the palette (either side) or the constraint rail
    /// used to put its badge there too, unreachable (QA-29, right-hand
    /// palette). The badge slides along its dimension line instead.
    private func badgeWithinCanvas(_ anchor: CGPoint, in size: CGSize) -> CGPoint {
        let palette: CGFloat = 96
        let rail = railInset
        let left = CADPreferences.shared.paletteOnRight ? rail : palette
        let right = CADPreferences.shared.paletteOnRight ? palette : rail
        let halfWidth: CGFloat = 40
        let low = left + halfWidth, high = size.width - right - halfWidth
        let x = high >= low ? min(max(anchor.x, low), high) : (low + high) / 2
        let y = min(max(anchor.y, 140), max(140, size.height - 110))
        return CGPoint(x: x, y: y)
    }

    /// Fit the entire editor between the drawing palette and constraint rail,
    /// not just its anchor. The old keyboard-era clamp hid the pad behind the
    /// rail and pulled bottom dimensions to the upper half of the canvas.
    private func editorPosition(_ anchor: CGPoint, in size: CGSize) -> CGPoint {
        let palette: CGFloat = 96
        let rail = railInset
        let left = CADPreferences.shared.paletteOnRight ? rail : palette
        let right = CADPreferences.shared.paletteOnRight ? palette : rail
        func fit(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            high >= low ? min(max(value, low), high) : (low + high) / 2
        }
        return CGPoint(
            x: fit(anchor.x, low: left + editorSize.width / 2,
                   high: size.width - right - editorSize.width / 2),
            y: fit(anchor.y, low: 170 + editorSize.height / 2,
                   high: size.height - 110 - editorSize.height / 2))
    }

    /// Room a collision-displaced badge may use. Same palette/rail margins the
    /// projection helpers already respect; an existing badge that already sits
    /// near an edge is never moved merely to satisfy this rectangle.
    private func badgeLayoutBounds(in size: CGSize) -> CGRect {
        let palette: CGFloat = 96
        let rail = railInset
        let left = CADPreferences.shared.paletteOnRight ? rail : palette
        let right = CADPreferences.shared.paletteOnRight ? palette : rail
        return CGRect(x: left, y: 140,
                      width: max(1, size.width - left - right),
                      height: max(1, size.height - 250))
    }

    /// Keep dimension badges clear of selected geometry's central control
    /// region, including while a draw tool hides the manipulation gizmo.
    /// Otherwise line-length badges collide with the line/constraint anchor.
    private var selectionAnchorPoint: CGPoint? {
        guard let centroid = viewModel.sketchSelectionCentroid,
              let plane = viewModel.activeSketch?.plane else { return nil }
        return project(plane.toWorld(centroid))
    }

    /// Points; roughly the handle's own touch target.
    private static let gizmoHandleRadius: CGFloat = 34

    /// Nudge a label clear of the gizmo handle rather than hiding it: for a
    /// single selected line the two coincide exactly (the handle sits at the
    /// centroid, which is also where the length reads), and suppressing the
    /// label there would make the dimension untappable precisely when it is
    /// most likely to be edited. Offsetting keeps both reachable.
    private func clearOfGizmo(_ point: CGPoint, along start: CGPoint,
                              _ end: CGPoint) -> CGPoint {
        guard let handle = selectionAnchorPoint,
              hypot(point.x - handle.x, point.y - handle.y) < Self.gizmoHandleRadius
        else { return point }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else {
            return CGPoint(x: point.x, y: point.y - Self.gizmoHandleRadius)
        }
        // Perpendicular to the dimension line, so the label still reads as
        // belonging to it.
        return CGPoint(x: point.x - dy / length * Self.gizmoHandleRadius,
                       y: point.y + dx / length * Self.gizmoHandleRadius)
    }

    private static let dimensionFont =
        UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
    private static let captionFont = UIFontMetrics(forTextStyle: .caption1)
        .scaledFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold))

    /// One label's projection and screen-space footprint, resolved once per
    /// overlay layout pass. The same values feed the badge position, the
    /// collision solver, the connector and the inline editor.
    private struct SketchLabelPresentation: Identifiable {
        let label: EditorViewModel.SketchDimensionLabel
        let start: CGPoint
        let end: CGPoint
        let arc: (points: [CGPoint], anchor: CGPoint, rotation: Double)?
        let radial: (tail: CGPoint, anchor: CGPoint, rotation: Double)?
        let diameter: SketchDiameterDimensionLayout?
        let linear: SketchLinearDimensionLayout?
        let isManual: Bool
        let isSelectedCircleRadius: Bool
        let defaultCenter: CGPoint
        let hitSize: CGSize
        let inkSize: CGSize
        let rotation: Double
        let leaderPoints: [CGPoint]

        var id: String { label.id }

        var collisionItem: SketchBadgeCollisionLayout.Item {
            SketchBadgeCollisionLayout.Item(
                id: id, center: defaultCenter, hitSize: hitSize,
                inkSize: inkSize, rotation: rotation, isFixed: isManual)
        }
    }

    /// The angle badge's visible text; measurement and rendering must use the
    /// same formatting, or the collision footprint drifts from the view.
    private func arcText(_ label: EditorViewModel.SketchDimensionLabel) -> String {
        label.displayValue.formatted(.number.precision(.fractionLength(0...2))) + "°"
    }

    private static func dimensionHitSize(text: String, horizontalPadding: CGFloat,
                                         extraWidth: CGFloat = 0) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: dimensionFont])
        return CGSize(width: ceil(max(44, measured.width + horizontalPadding)) + extraWidth,
                      height: 44)
    }

    private static func dimensionInkSize(text: String, horizontalPadding: CGFloat,
                                         verticalPadding: CGFloat,
                                         extraWidth: CGFloat = 0) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: dimensionFont])
        return CGSize(width: ceil(measured.width + horizontalPadding) + extraWidth,
                      height: ceil(measured.height + verticalPadding))
    }

    /// Project one label and measure the exact badge SwiftUI will position.
    /// No world geometry is changed; this only reports screen-space metrics.
    private func presentation(for label: EditorViewModel.SketchDimensionLabel,
                              in size: CGSize) -> SketchLabelPresentation? {
        guard let anchor = project(label.worldAnchor),
              let start = project(label.worldStart),
              let end = project(label.worldEnd) else { return nil }
        let arc = arcLeader(label)
        let isLinear = label.isStandaloneLineLength || label.isRectangleSize
        let interior = label.worldRectangleCenter.flatMap(project)
        // A dragged label (live preview, or a saved/selection-lived
        // placement) moves the whole leader, as native's does.
        let draggedLeader: CGFloat? = isLinear
            ? (diameterDragPreviews[label.id] ?? label.worldLinearLabelAnchor.flatMap(project)).flatMap {
                SketchLinearDimensionLayout.leaderOffset(start: start, end: end, textAnchor: $0, awayFrom: interior)
            } : nil
        let linear = isLinear
            ? SketchLinearDimensionLayout.make(start: start, end: end,
                leaderOffset: draggedLeader ?? (label.isProjectedLineLength ? 0 : label.isRectangleSize ? 100 : 60),
                awayFrom: interior) : nil
        let radial = label.isArcRadius ? radiusLeader(start, end, text: label.text, compact: label.isCircleRadius && ((label.dimensionID != nil && (label.hasCircleRadiusDirection || viewModel.mode.sketchTool == .circle)) || (viewModel.mode.sketchTool == .circle && viewModel.selectedCircleCenterID == label.refs.first?.entityID)), in: size) : nil
        let manualDiameterAnchor = diameterDragPreviews[label.id]
            ?? label.worldDiameterLabelAnchor.flatMap(project)
        let diameter = label.kind == .diameter ? diameterLayout(start, end, anchor: anchor, text: label.text, sketchID: label.sketchID,
            manualAnchor: manualDiameterAnchor, in: size) : nil
        let isSelectedCircleRadius = label.isCircleRadius && !viewModel.sketchTransformActive
            && (viewModel.mode.sketchTool == .circle || label.hasCircleRadiusDirection)
            && label.dimensionID.map { viewModel.selectedDimensionID == $0 } == true

        let defaultCenter: CGPoint
        let rotation: Double
        let hitSize: CGSize
        let inkSize: CGSize
        if label.isPolygonSideCount {
            defaultCenter = polygonCountAnchor(start: start, end: end, in: size)
            rotation = atan2(end.y - start.y, end.x - start.x) - .pi / 2
            hitSize = Self.dimensionHitSize(text: label.text, horizontalPadding: 0)
            inkSize = Self.dimensionInkSize(text: label.text, horizontalPadding: 0,
                                            verticalPadding: 0)
        } else if let arc {
            defaultCenter = arc.anchor
            rotation = arc.rotation
            let text = arcText(label)
            hitSize = Self.dimensionHitSize(text: text, horizontalPadding: 0)
            inkSize = Self.dimensionInkSize(text: text, horizontalPadding: 0,
                                            verticalPadding: 0)
        } else if let radial {
            defaultCenter = radial.anchor
            rotation = radial.rotation
            let measured = (label.text as NSString).size(withAttributes: [.font: Self.dimensionFont])
            if isSelectedCircleRadius {
                // The selected circle-radius badge adds a 44-pt lock button;
                // its white value background and that button are both ink.
                let buttonWidth = ceil(max(44, measured.width + 6))
                hitSize = CGSize(width: buttonWidth + 44, height: 44)
                inkSize = CGSize(width: buttonWidth + 44, height: 44)
            } else {
                hitSize = CGSize(width: ceil(max(44, measured.width)), height: 44)
                inkSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            }
        } else if let diameter {
            defaultCenter = diameter.anchor
            rotation = diameter.rotation
            hitSize = CGSize(width: max(44, diameter.targetSize.width),
                             height: max(44, diameter.targetSize.height))
            inkSize = Self.dimensionInkSize(text: label.text, horizontalPadding: 0,
                                            verticalPadding: 0)
        } else if let linear {
            defaultCenter = badgeWithinCanvas(linear.anchor, in: size)
            rotation = linear.rotation
            let padded = label.isRectangleSize && label.dimensionID != nil &&
                viewModel.selectedDimensionID == label.dimensionID &&
                viewModel.selectedMigratedRectangleCornerMarker != nil
            let horizontalPadding: CGFloat = padded ? 6 : 0
            let verticalPadding: CGFloat = padded ? 2 : 0
            hitSize = Self.dimensionHitSize(text: label.text,
                                            horizontalPadding: horizontalPadding)
            inkSize = Self.dimensionInkSize(text: label.text,
                                            horizontalPadding: horizontalPadding,
                                            verticalPadding: verticalPadding)
        } else {
            defaultCenter = clearOfGizmo(anchor, along: start, end)
            rotation = 0
            let measured = (label.text as NSString).size(withAttributes: [.font: Self.captionFont])
            let ink = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 6)
            hitSize = CGSize(width: max(44, ink.width), height: max(44, ink.height))
            inkSize = ink
        }

        let leaderPoints: [CGPoint]
        if let arc {
            leaderPoints = [start] + arc.points + [end]
        } else if let radial {
            leaderPoints = [start, radial.tail]
        } else if let diameter {
            leaderPoints = [diameter.start, diameter.tail]
        } else if let linear {
            leaderPoints = [label.worldLineStart.flatMap(project) ?? start,
                            linear.start, linear.end,
                            label.worldLineEnd.flatMap(project) ?? end]
        } else if label.isPolygonSideCount {
            leaderPoints = []
        } else {
            leaderPoints = [start, end]
        }
        // A live drag preview and a saved/manual placement are authored: the
        // collision solver may not overwrite them.
        let isManual = (linear != nil && draggedLeader != nil)
            || (label.kind == .diameter && manualDiameterAnchor != nil)
        return SketchLabelPresentation(
            label: label, start: start, end: end,
            arc: arc, radial: radial, diameter: diameter, linear: linear,
            isManual: isManual, isSelectedCircleRadius: isSelectedCircleRadius,
            defaultCenter: defaultCenter, hitSize: hitSize, inkSize: inkSize,
            rotation: rotation, leaderPoints: leaderPoints)
    }

    @ViewBuilder
    private func labelView(_ presentation: SketchLabelPresentation,
                           placement: CGPoint) -> some View {
        let label = presentation.label
        let start = presentation.start
        let end = presentation.end
        let arc = presentation.arc
        let radial = presentation.radial
        let diameter = presentation.diameter
        let linear = presentation.linear
        Group {
            if let arc {
                Path { path in
                    path.addLines(arc.points)
                    path.move(to: start)
                    path.addLine(to: arc.points[0])
                    path.move(to: end)
                    path.addLine(to: arc.points[arc.points.count - 1])
                }
                .stroke(Color.black, lineWidth: 1)
                .allowsHitTesting(false)
                Path { path in
                    addArrow(to: &path, tip: arc.points[0], toward: arc.points[1])
                    addArrow(to: &path, tip: arc.points[arc.points.count - 1],
                             toward: arc.points[arc.points.count - 2])
                }
                .fill(Color.black)
                .allowsHitTesting(false)
            } else if let radial {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: radial.tail)
                }
                .stroke(Color.black, lineWidth: 1)
                .allowsHitTesting(false)
                Path { path in
                    addArrow(to: &path, tip: end, toward: radial.tail == end ? start : radial.tail)
                }
                .fill(Color.black)
                .allowsHitTesting(false)
            } else if let diameter {
                Path { path in
                    path.move(to: diameter.start)
                    path.addLine(to: diameter.tail)
                }
                .stroke(Color.black, lineWidth: 1)
                .allowsHitTesting(false)
                Path { path in
                    let outside = diameter.tail != diameter.end
                    let startBody = outside
                        ? CGPoint(x: 2 * diameter.start.x - diameter.end.x,
                                  y: 2 * diameter.start.y - diameter.end.y) : diameter.end
                    let endBody = outside ? diameter.tail : diameter.start
                    addArrow(to: &path, tip: diameter.start, toward: startBody)
                    addArrow(to: &path, tip: diameter.end, toward: endBody)
                }
                .fill(Color.black)
                .allowsHitTesting(false)
            } else if let linear {
                Path { path in
                    path.move(to: label.worldLineStart.flatMap(project) ?? start)
                    path.addLine(to: linear.start)
                    path.addLine(to: linear.end)
                    path.addLine(to: label.worldLineEnd.flatMap(project) ?? end)
                }
                .stroke(Color.black, lineWidth: 1)
                .allowsHitTesting(false)
                Path { path in
                    addArrow(to: &path, tip: linear.start, toward: linear.end)
                    addArrow(to: &path, tip: linear.end, toward: linear.start)
                }
                .fill(Color.black)
                .allowsHitTesting(false)
            } else if !label.isPolygonSideCount {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
            }

            let conflicting = label.dimensionID.map {
                viewModel.sketchConflictAttribution.dimensionIDs.contains($0)
            } ?? false
            if viewModel.editingDimension?.labelID == label.id {
                // Being edited: the leader line above still draws, but the
                // badge gives way to the field, which `body` positions.
                EmptyView()
            } else if let radial, label.isCircleRadius,
                      !viewModel.sketchTransformActive,
                      (viewModel.mode.sketchTool == .circle || label.hasCircleRadiusDirection),
                      let dimensionID = label.dimensionID,
                      viewModel.selectedDimensionID == dimensionID {
                HStack(spacing: 0) {
                    Button { viewModel.beginDimensionEdit(label) } label: {
                        Text(label.text)
                            .font(.system(size: 16)).monospacedDigit()
                            .foregroundStyle(conflicting ? Color.red : Color.black)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(conflicting ? Color.red : Color.blue, lineWidth: 2))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(conflicting ? "DimensionLabelConflict" : "DimensionLabel")
                    Button { viewModel.deleteDimension(dimensionID) } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.black)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock radius")
                    .accessibilityIdentifier("CircleRadiusDimensionUnlock")
                }
                .overlay(alignment: .leading) {
                    if label.hasExpression {
                        Text("f(x)").font(.system(size: 13).italic())
                            .foregroundStyle(Color.gray).offset(x: -25)
                            .accessibilityHidden(true)
                    }
                }
                .rotationEffect(.radians(radial.rotation))
                .position(placement)
            } else {
                // Stage-2 conflict attribution: a dimension the solver could
                // not satisfy paints red — dueling lengths are the archetypal
                // sketch conflict, and the value badge is where the user
                // looks first.
                Button {
                    viewModel.beginDimensionEdit(label)
                } label: {
                    if label.isPolygonSideCount {
                        Text(label.text)
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(Color.black)
                            .rotationEffect(.radians(atan2(end.y - start.y, end.x - start.x) - .pi / 2))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    } else if let arc {
                        Text(arcText(label))
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(conflicting ? Color.red : Color.black)
                            .rotationEffect(.radians(arc.rotation))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    } else if let radial {
                        Text(label.text)
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(conflicting ? Color.red : Color.black)
                            .rotationEffect(.radians(radial.rotation))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    } else if let diameter {
                        Text(label.text)
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(conflicting ? Color.red : Color.black)
                            .fixedSize()
                            .rotationEffect(.radians(diameter.rotation))
                            .frame(width: diameter.targetSize.width, height: diameter.targetSize.height)
                            .contentShape(DiameterValueHitShape(center: CGPoint(
                                x: (start.x + end.x) / 2 - diameter.anchor.x + diameter.targetSize.width / 2,
                                y: (start.y + end.y) / 2 - diameter.anchor.y + diameter.targetSize.height / 2)))
                    } else if let linear {
                        let selectedCornerSize = label.isRectangleSize && label.dimensionID != nil &&
                            viewModel.selectedDimensionID == label.dimensionID &&
                            viewModel.selectedMigratedRectangleCornerMarker != nil
                        Text(label.text)
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(conflicting ? Color.red : Color.black)
                            .padding(.horizontal, selectedCornerSize ? 3 : 0)
                            .padding(.vertical, selectedCornerSize ? 1 : 0)
                            .background {
                                if selectedCornerSize {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.white)
                                }
                            }
                            .overlay {
                                if selectedCornerSize {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(conflicting ? Color.red : Color.blue, lineWidth: 2)
                                }
                            }
                            .rotationEffect(.radians(linear.rotation))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    } else {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(conflicting ? Color.red
                                        : label.dimensionID == nil
                                        ? Color.blue.opacity(0.4) : Color.blue,
                                        lineWidth: conflicting ? 2 : 1)
                        )
                        .foregroundStyle(conflicting ? Color.red
                                         : label.dimensionID == nil
                                         ? Color.secondary : Color.blue)
                        // Keep the visual badge compact but give finger taps
                        // a real hit region, including its padded corners.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
                .overlay(alignment: .leading) {
                    if label.hasExpression {
                        Text("f(x)")
                            .font(.system(size: 13).italic())
                            // Canvas stays light even when app chrome is dark.
                            .foregroundStyle(Color.gray)
                            .offset(x: -25)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(.plain)
                // Start a drag from the badge the user actually sees, not the
                // raw projected anchor. Otherwise a displaced badge jumps back
                // to its old leader position on the first touch and overwrites
                // the authored offset with that jump.
                .highPriorityGesture(diameterDrag(label, anchor: placement),
                    including: diameter != nil || linear != nil ? .all : .none)
                .position(placement)
                .accessibilityIdentifier(
                    conflicting ? "DimensionLabelConflict" : "DimensionLabel")
                if let linear, viewModel.canChooseLineDimensionKind(label) {
                    let textWidth = (label.text as NSString).size(
                        withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)]).width
                    Menu {
                        ForEach(viewModel.dimensionKindChoices, id: \.rawValue) { kind in
                            Button {
                                viewModel.chooseLineDimensionKind(kind, label: label)
                            } label: {
                                Label(kind == .distance ? "Absolute" : kind == .horizontal ? "Horizontal" : "Vertical",
                                      systemImage: kind == label.kind ? "checkmark" : "")
                            }
                            .accessibilityIdentifier("LineDistanceType-" + kind.rawValue)
                        }
                    } label: {
                        Image(systemName: label.kind == .vertical ? "arrow.up.and.down" :
                                label.kind == .horizontal ? "arrow.left.and.right" : "arrow.up.right.and.arrow.down.left")
                            .font(.system(size: 13)).foregroundStyle(Color.black)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Distance Type")
                    .accessibilityIdentifier("LineDistanceTypeBadge")
                    .position(x: placement.x - cos(linear.rotation) * (textWidth / 2 + 24),
                              y: placement.y - sin(linear.rotation) * (textWidth / 2 + 24))
                }
            }
        }
    }

    /// Connector for a collision-displaced badge, drawn behind every badge by
    /// the calling layer. It starts at the nearest point of the existing leader
    /// so the moved value still reads as attached to this dimension.
    private func displacedConnector(_ presentation: SketchLabelPresentation,
                                    to center: CGPoint) -> some View {
        let start = Self.closestPoint(on: presentation.leaderPoints,
                                      to: presentation.defaultCenter)
            ?? presentation.defaultCenter
        return Path { path in
            path.move(to: start)
            path.addLine(to: center)
        }
        .stroke(Color.black.opacity(0.75), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func polygonCountAnchor(start: CGPoint, end: CGPoint, in size: CGSize) -> CGPoint {
        let length = max(1, hypot(end.x - start.x, end.y - start.y))
        return CGPoint(x: min(max(96, end.x + (end.x - start.x) / length * 24), size.width - 96),
                       y: min(max(140, end.y + (end.y - start.y) / length * 24), size.height - 140))
    }

    /// The sampled native radius leader leaves the arc's start endpoint and
    /// continues outward. Shorten the extension near the viewport edge so its
    /// explicit dimension control remains reachable.
    private func radiusLeader(_ center: CGPoint, _ tip: CGPoint, text: String, compact: Bool, in size: CGSize)
        -> (tail: CGPoint, anchor: CGPoint, rotation: Double)? {
        let dx = tip.x - center.x, dy = tip.y - center.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        if compact {
            // Native Circle construction keeps the value over center-to-rim,
            // including after a numeric commit while Circle remains armed.
            var angle = atan2(Double(dy), Double(dx))
            if angle > .pi / 2 { angle -= .pi }
            else if angle < -.pi / 2 { angle += .pi }
            return (tip, CGPoint(x: (center.x + tip.x) / 2 + CGFloat(sin(angle)) * 20,
                                 y: (center.y + tip.y) / 2 - CGFloat(cos(angle)) * 20), angle)
        }
        var extensionLength: CGFloat = 220
        let rail: CGFloat = viewModel.sketchTransformActive ? 16 : railInset
        let left: CGFloat = CADPreferences.shared.paletteOnRight ? rail : 96
        let right: CGFloat = CADPreferences.shared.paletteOnRight ? 96 : rail
        let textWidth = (text as NSString).size(withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        ]).width
        // Reserve the rotated value's half-width, not just the leader endpoint.
        let horizontalInset = max(22, abs(ux) * textWidth / 2 + abs(uy) * 12)
        let bounds = CGRect(x: left + horizontalInset, y: 140,
                            width: max(1, size.width - left - right - 2 * horizontalInset),
                            height: max(1, size.height - 210))
        if ux > 0.001 { extensionLength = min(extensionLength, (bounds.maxX - tip.x) / ux) }
        if ux < -0.001 { extensionLength = min(extensionLength, (bounds.minX - tip.x) / ux) }
        if uy > 0.001 { extensionLength = min(extensionLength, (bounds.maxY - tip.y) / uy) }
        if uy < -0.001 { extensionLength = min(extensionLength, (bounds.minY - tip.y) / uy) }
        extensionLength = max(0, extensionLength)
        let tail = CGPoint(x: tip.x + ux * extensionLength, y: tip.y + uy * extensionLength)
        var rotation = atan2(Double(dy), Double(dx))
        if abs(dx) < length * 0.01 { rotation = -.pi / 2 }
        else if rotation > .pi / 2 { rotation -= .pi }
        else if rotation < -.pi / 2 { rotation += .pi }
        let anchor = CGPoint(x: tip.x + ux * extensionLength * 0.75 + CGFloat(sin(rotation)) * 20,
                             y: tip.y + uy * extensionLength * 0.75 - CGFloat(cos(rotation)) * 20)
        return (tail, anchor, rotation)
    }

    private func diameterLayout(_ start: CGPoint, _ end: CGPoint, anchor: CGPoint,
                                text: String, sketchID: SketchID, manualAnchor: CGPoint?, in size: CGSize) -> SketchDiameterDimensionLayout? {
        let rail: CGFloat = viewModel.mode.isSketching && !viewModel.sketchTransformActive ? 184 : 16
        let left = CADPreferences.shared.paletteOnRight ? rail : 96
        let right = CADPreferences.shared.paletteOnRight ? 96 : rail
        let bounds = CGRect(x: left, y: 140, width: max(1, size.width - left - right),
                            height: max(1, size.height - 250))
        let width = (text as NSString).size(withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        ]).width
        // A projected oblique circle is an ellipse: do not invent vertical
        // rim points from its horizontal projected radius. Top/Bottom cameras
        // deliberately clamp one degree shy of normal (elevationLimit = 89°).
        let headOn = viewModel.session.document.sketches.first(where: { $0.id == sketchID })
            .map { (viewModel.cameraControl?.offAxisDegrees(to: $0.plane) ?? 90) < 1.1 } ?? false
        return SketchDiameterDimensionLayout.make(start: start, end: end, anchor: anchor,
            clearance: viewModel.sketchTransformActive ? 60 : 20,
            available: bounds, textWidth: width, allowVertical: headOn, manualAnchor: manualAnchor,
            preferVertical: !viewModel.sketchTransformActive && viewModel.mode.sketchTool != .circle
                && viewModel.selectedCircleCenterID == nil && viewModel.retainedCircleCenterReadoutID == nil)
    }

    private func diameterDrag(_ label: EditorViewModel.SketchDimensionLabel,
                              anchor: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("SketchDimensionCanvas"))
            .onChanged { value in
                guard let sketch = viewModel.session.document.sketches.first(where: { $0.id == label.sketchID }),
                      (viewModel.cameraControl?.offAxisDegrees(to: sketch.plane) ?? 90) < 1.1 else { return }
                if diameterDragStarts[label.id] == nil { diameterDragStarts[label.id] = anchor }
                let origin = diameterDragStarts[label.id] ?? anchor
                diameterDragPreviews[label.id] = CGPoint(x: origin.x + value.translation.width,
                                                         y: origin.y + value.translation.height)
            }
            .onEnded { _ in
                defer {
                    diameterDragStarts[label.id] = nil
                    diameterDragPreviews[label.id] = nil
                }
                guard let point = diameterDragPreviews[label.id],
                      let sketch = viewModel.session.document.sketches.first(where: { $0.id == label.sketchID }),
                      let origin = project(sketch.plane.toWorld(.zero)),
                      let axisX = project(sketch.plane.toWorld(SIMD2(1, 0))),
                      let axisY = project(sketch.plane.toWorld(SIMD2(0, 1))),
                      let center = project((label.worldStart + label.worldEnd) / 2) else { return }
                // Invert the head-on projected sketch basis. The saved offset
                // follows its circle through camera zoom and translation.
                let ax = axisX.x - origin.x, ay = axisX.y - origin.y
                let bx = axisY.x - origin.x, by = axisY.y - origin.y
                let determinant = ax * by - ay * bx
                guard abs(determinant) > 0.00001 else { return }
                let dx = point.x - center.x, dy = point.y - center.y
                let offset = SIMD2(Double((dx * by - dy * bx) / determinant),
                                   Double((ax * dy - ay * dx) / determinant))
                viewModel.moveDimensionLabel(label, offset: offset)
            }
    }

    /// Native sweep leaders sit outside the arc with radial extensions and
    /// inward-facing arrowheads, rather than joining the endpoints by a chord.
    private func arcLeader(_ label: EditorViewModel.SketchDimensionLabel)
        -> (points: [CGPoint], anchor: CGPoint, rotation: Double)? {
        guard let worldCenter = label.worldArcCenter,
              let center = project(worldCenter), label.worldArcPoints.count > 2 else { return nil }
        let projected = label.worldArcPoints.compactMap(project)
        guard projected.count == label.worldArcPoints.count else { return nil }
        func offset(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return point }
            return CGPoint(x: point.x + dx / length * distance,
                           y: point.y + dy / length * distance)
        }
        let middle = projected.count / 2
        let before = projected[middle - 1], after = projected[middle + 1]
        var rotation = atan2(Double(after.y - before.y), Double(after.x - before.x))
        // Follow the tangent while keeping text upright on either half of a turn.
        if rotation > .pi / 2 { rotation -= .pi }
        if rotation < -.pi / 2 { rotation += .pi }
        return (projected.map { offset($0, by: 60) },
                // Keep the angle's touch target beyond the radial handle. Native's
                // sampled semicircle puts its angle text outside the leader.
                offset(projected[middle], by: viewModel.selectedSingleArc != nil ? 80 : 40), rotation)
    }

    /// Nearest point on the drawn leader, used to start a displaced badge's
    /// connector at the leader rather than in empty space.
    private static func closestPoint(on polyline: [CGPoint], to point: CGPoint) -> CGPoint? {
        guard let first = polyline.first else { return nil }
        guard polyline.count > 1 else { return first }
        var best = first
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 1..<polyline.count {
            let a = polyline[index - 1], b = polyline[index]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t: CGFloat = lengthSquared > 0.0001
                ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
                : 0
            let candidate = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    private func addArrow(to path: inout Path, tip: CGPoint, toward point: CGPoint) {
        let dx = point.x - tip.x, dy = point.y - tip.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let x = dx / length, y = dy / length
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x + x * 12 - y * 3,
                                y: tip.y + y * 12 + x * 3))
        path.addLine(to: CGPoint(x: tip.x + x * 12 + y * 3,
                                y: tip.y + y * 12 - x * 3))
        path.closeSubpath()
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }
}

/// The inline numeric editor shown in place of a dimension label while editing.
/// The dimension editor: the value, then the pad that edits it.
///
/// The system keyboard is deliberately NOT raised. A dimension is typed with a
/// thumb while the other hand holds the model, and the iPad keyboard covers the
/// half of the screen the sketch is on — which is why `clearOfKeyboard` had to
/// exist at all. The pad is compact and sits with the value. The keyboard key
/// hands over to the real thing when someone wants to type a variable name or
/// a function, which a ten-key cannot express.
private struct DimensionField: View {
    @Bindable var viewModel: EditorViewModel
    private var usingSystemKeyboard: Bool {
        get { viewModel.dimensionUsesSystemKeyboard }
        nonmutating set { viewModel.dimensionUsesSystemKeyboard = newValue }
    }
    private var acceptsHardwareInput: Bool {
        usingSystemKeyboard || viewModel.editingDimension?.hardwareInitiated == true
    }
    @FocusState private var focused: Bool

    /// The text lives on `editingDimension`, not in `@State`. The overlay
    /// rebuilds its labels on every camera move and document revision, and a
    /// view-local copy is discarded whenever that changes this view's identity —
    /// which silently swallowed keypad taps. The edit session owns the text.
    /// What a variable minted from this field would be called. Shapr3D names it
    /// after the quantity ("length1"); the kind is the closest thing we have.
    private var suggestedVariableName: String {
        switch viewModel.editingDimension?.kind {
        case .radius: "radius"
        case .diameter: "diameter"
        case .angle: "angle"
        default: "length"
        }
    }

    /// View-local, deliberately. A `Binding` that wrote straight into
    /// `editingDimension` put an `@Observable` write on the TextField's update
    /// path: a render could write, invalidating the view that had just produced
    /// it, and the app spun until the watchdog killed it — no crash log, just a
    /// relaunch onto the gallery. (The swallowed keypad taps that first sent me
    /// to a model-backed binding were `contentShape`, not state.)
    @State private var text: String = ""
    @State private var initialValueSelected = true

    var body: some View {
        content
            .onAppear {
                text = viewModel.editingDimension?.text ?? ""
                initialValueSelected = viewModel.editingDimension?.hardwareInitiated != true
                if acceptsHardwareInput { focused = true }
            }
            .onChange(of: text) { _, value in
                // Seeding a reopened keyboard editor is not a user keystroke.
                if usingSystemKeyboard, value != viewModel.editingDimension?.text {
                    initialValueSelected = false
                }
                if let sessionID = viewModel.editingDimension?.sessionID {
                    viewModel.updateDimensionDraft(value, sessionID: sessionID)
                }
            }
            // A second shape reopens the field under the SAME label id
            // ("candidate"), so `onAppear` does not fire again — re-seed when
            // the edit itself moves.
            .onChange(of: viewModel.editingDimension?.labelID) { _, _ in
                text = viewModel.editingDimension?.text ?? ""
            }
            .onChange(of: viewModel.editingDimension?.refs.count) { _, _ in
                text = viewModel.editingDimension?.text ?? ""
            }
    }

    /// Resign the live responder before an action that ends
    /// `editingDimension` and removes this field. @FocusState alone lands on
    /// the next SwiftUI transaction; the UIKit call is immediate.
    private func resignFocusBeforeTeardown() {
        focused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// Commit without tearing a focused UITextField out of the view graph.
    /// `commitDimensionEdit` clears `editingDimension`, which removes this
    /// editor. Removing the first responder during that same display-list
    /// update trips `UIFocusSystem._focusEnvironmentWillDisappear`'s assertion
    /// (actual84b: SIGABRT immediately after DimensionCommit, before the
    /// refusal notice). Resign FIRST, let that focus transaction land on the
    /// next main-queue turn, then commit exactly once for the session that
    /// asked for it. A stale draft is never applied to a different dimension.
    private func commitKeepingFocusStable() {
        guard let sessionID = viewModel.editingDimension?.sessionID else { return }
        let draft = text
        let restoresKeyboard = acceptsHardwareInput
        resignFocusBeforeTeardown()
        DispatchQueue.main.async {
            // Click-away, Cancel, or another badge may have ended or replaced
            // the edit before this turn. Never commit into a reopened session.
            guard viewModel.editingDimension?.sessionID == sessionID else { return }
            viewModel.commitDimensionEdit(draft)
            // An invalid draft keeps the same editor open. Restore the input
            // method the user was already using; a successful or refused size
            // has already closed the session, so this cannot reopen it.
            if restoresKeyboard,
               viewModel.editingDimension?.sessionID == sessionID,
               viewModel.editingDimension?.validationMessage != nil {
                focused = true
            }
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            valueRow
            if !usingSystemKeyboard {
                NumericKeypad(
                    text: $text,
                    isLocked: viewModel.editingDimension?.dimensionID != nil,
                    lockEnabled: viewModel.canToggleDimensionLock(text),
                    initialValueSelected: $initialValueSelected,
                    // The lock key closes the editor through
                    // `toggleDimensionLock`; resign before that synchronous
                    // teardown too (it can be reached from a focused
                    // hardware-keyboard edit).
                    onToggleLock: {
                        resignFocusBeforeTeardown()
                        viewModel.toggleDimensionLock(text)
                    },
                    onCommit: { commitKeepingFocusStable() },
                    onSwitchToSystemKeyboard: {
                        usingSystemKeyboard = true
                        focused = true
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if let message = viewModel.editingDimension?.validationMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.black)
                            .padding(10)
                            .frame(width: 244, alignment: .leading)
                            .background(Color(red: 0.98, green: 0.92, blue: 0.69),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityIdentifier("DimensionValidationMessage")
                            .allowsHitTesting(false)
                    }
                }
            }
            if usingSystemKeyboard, let message = viewModel.editingDimension?.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.black)
                    .padding(8)
                    .frame(width: 244)
                    .background(Color(red: 0.98, green: 0.92, blue: 0.69),
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("DimensionValidationMessage")
            }
        }
    }

    /// Retain the whole ordinary expression instead of scrolling it inside the
    /// old fixed 96-point slot. Very long formulas still scroll; the bounded
    /// width lets editorPosition keep the entire row clear of the side rails.
    private var expressionWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(320, max(192, ceil(measured) + 20))
    }

    private var valueRow: some View {
        HStack(spacing: 4) {
            // A real TextField either way: with the pad it is a display that
            // shows the caret and takes hardware-keyboard keys, and it is the
            // same element the UI suite reads the value from.
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .frame(width: expressionWidth)
                .focused($focused)
                // While the pad is the input method the field is a READOUT: it
                // must not take taps (that would raise the system keyboard the
                // pad exists to replace) and it must not join the focus system.
                .allowsHitTesting(acceptsHardwareInput)
                .focusable(acceptsHardwareInput)
                .submitLabel(.done)
                .onSubmit { commitKeepingFocusStable() }
                .accessibilityIdentifier("DimensionField")
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                    guard usingSystemKeyboard, initialValueSelected,
                          let field = notification.object as? UITextField,
                          field.text == text else { return }
                    // SwiftUI establishes the caret after the begin-editing
                    // notification. Select only this editor's untouched seed
                    // after that focus turn; real drafts keep their insertion point.
                    DispatchQueue.main.async {
                        guard field.isFirstResponder, initialValueSelected,
                              field.text == text else { return }
                        field.selectAll(nil)
                    }
                }

            Group {
                // Shapr3D puts a variables affordance in the value field itself,
                // left of the keyboard toggle: it offers to mint a variable from
                // what you typed, and to reference one you already have.
                Menu {
                    let current = text
                    Button("Create “\(suggestedVariableName) = \(current)”") {
                        if let name = viewModel.createVariable(
                            holding: current, preferredName: suggestedVariableName) {
                            text = name
                        }
                    }
                    .disabled(current.trimmingCharacters(in: .whitespaces).isEmpty)

                    let names = viewModel.variableNames
                    if names.isEmpty {
                        Text("No available variables")
                    } else {
                        Section("Variables") {
                            ForEach(names, id: \.self) { name in
                                Button(name) { text = name }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "function")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("DimensionVariables")
            }

            if !usingSystemKeyboard {
                Button {
                    usingSystemKeyboard = true
                    focused = true
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DimensionSystemKeyboard")
            } else {
                Button {
                    focused = false
                    usingSystemKeyboard = false
                } label: {
                    Image(systemName: "123.rectangle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Numeric keypad")
                .accessibilityIdentifier("DimensionNumericKeyboard")
                // With the system keyboard up the pad is gone, so the commit
                // control has to live here instead.
                Button {
                    commitKeepingFocusStable()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DimensionCommit")
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 2))
    }
}

/// A padded diameter value must not take the center's touch/drag. Retain the
/// value's target everywhere else, including manually displaced labels.
private struct DiameterValueHitShape: Shape {
    var center: CGPoint
    func path(in rect: CGRect) -> Path {
        let cut = rect.intersection(CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
        var path = Path()
        guard !cut.isNull, !cut.isEmpty else { path.addRect(rect); return path }
        for region in [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)
        ] where !region.isEmpty { path.addRect(region) }
        return path
    }
}
