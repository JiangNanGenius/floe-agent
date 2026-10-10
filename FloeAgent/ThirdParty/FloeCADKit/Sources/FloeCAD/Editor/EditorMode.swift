//
//  EditorMode.swift
//  openshape3d
//

import Foundation

enum SketchTool: String, CaseIterable {
    case line
    case rect
    case circle
    case arc
    case ellipse
    case polygon
    /// Tap-to-trim: no drawing; taps delete the entity span under them.
    case trim
    /// Text (plan §B7, spec §1.12): taps place the text dialog's glyph
    /// outlines at the tapped point.
    case text
    /// Project (plan §B8, spec §1.13 v1): taps on a visible body flatten its
    /// feature edges onto the active sketch plane.
    case project
    /// Offset Edge (spec §1.9): no drawing — taps pick the entities to offset
    /// (Single or Chain, see `SketchOffsetType`), a live preview follows the
    /// distance, and Apply commits the offset copies into the sketch.
    case offset
}

/// A 3D-create operation armed from the body-mode "Modify" palette group. The
/// user picks the operation first, then taps a sketch region to apply it —
/// tracked by `EditorViewModel.pendingCreateTool` (not an `EditorMode` case, so
/// it doesn't ripple through every mode switch). Extrude is the default a plain
/// region tap already gives; the others route into their existing pick flows.
enum CreateTool: String, CaseIterable {
    case extrude, revolve, sweep, loft, helix
}

/// An edge blend (Phase E, spec §4.3): chamfer flattens the corner, fillet
/// rounds it. Both pick convex edges then apply one shared size.
enum BlendKind: String, CaseIterable {
    case chamfer, fillet
    var title: String { self == .chamfer ? "Chamfer" : "Fillet" }
    /// The size label shown in the blend bar / History (setback vs radius).
    var valueLabel: String { self == .chamfer ? "Setback" : "Radius" }
}

enum EditorMode: Equatable {
    case idle
    /// A legacy primitive body is selected with editable dimensions.
    case editingPrimitive(BodyID)
    /// A whole body is selected (double-tap); move gizmo shown.
    case selected(BodyID)
    /// A planar face is selected (single tap on a body); push/pull it.
    case faceSelected(BodyID)
    /// A sketch tool is armed but no plane is chosen yet: the origin plane
    /// tiles are shown; tapping one (or a face/construction plane/the ground)
    /// starts the sketch there.
    case pickingSketchPlane(tool: SketchTool)
    /// Sketching on a plane. `tool: nil` = no drawing tool armed (the active
    /// tool was tapped off): taps select, drags on geometry edit, and
    /// empty-space drags orbit the camera — so the plane can be viewed from
    /// any angle mid-sketch (Shapr3D).
    case sketching(SketchID, tool: SketchTool?)
    /// Pulling a profile into a solid (extrude or revolve tool active).
    case extruding
    /// Revolve armed: waiting for a tap on a sketch line to use as the axis.
    case pickingRevolveAxis
    /// Sweep armed: taps on open sketch entities (lines/arcs) chain into the
    /// sweep path.
    case pickingSweepPath
    /// Loft armed: taps on profile fills append loft sections in order.
    case pickingLoftProfiles
    /// Waiting for the second body of a boolean operation.
    case pickingBooleanTool(BooleanKind, target: BodyID)
    /// Split armed: waiting for a cutter tap — a world/construction plane
    /// tile, or a sketch profile fill (through-extruded cutter).
    case pickingSplitCutter(target: BodyID)
    /// Re-picking the BODY operand of an existing mirror / pattern /
    /// transform node (History "Edit Body"): the next tapped body becomes
    /// the node's operand and the rebuild replays it.
    case pickingFeatureBody(FeatureID)
    /// Re-picking the FACE operand of an existing push/pull / move / scale /
    /// rotate-face node (History "Edit Face"): the next tapped planar face
    /// on the node's body — resolved on the body the feature CONSUMED —
    /// becomes its face.
    case pickingFeatureFace(FeatureID)
    /// Re-picking the PROFILE of an existing extrude / draft extrude /
    /// revolve / sweep node (History "Edit Profile"): the next tapped sketch
    /// fill becomes its profile (and its sketch the plane).
    case pickingFeatureProfile(FeatureID)
    /// Pattern bar active (linear/circular); parameters live in
    /// `EditorViewModel.patternState`, instances preview as ghosts.
    case patterning
    /// Rotate Around Axis (spec §5.3): waiting for an axis pick (sketch line
    /// tap or a world-axis button), then live angle entry/drag.
    case rotatingAroundAxis
    /// Translate (spec §5.2): tap a source snap point, then a destination;
    /// the selection shifts by the exact delta.
    case translating
    /// Align v1 (spec §5.5): tap a snap point on the body to move, then the
    /// destination point; that body translates so the points coincide.
    case aligning
    /// Measure tool: taps pick notable points; two picks show a distance.
    case measuring
    /// Section View armed (spec §16.1): the plane tiles are shown; tapping a
    /// world/construction plane tile or a planar face sets the section plane.
    case pickingSectionPlane
    /// Insert Image (plan §B10, spec §6.3): picked image bytes are waiting in
    /// `EditorViewModel.pendingImageData`; the plane tiles are shown, and the
    /// tapped plane (ground when the tap misses every tile) hosts the image.
    case pickingImagePlane
    /// Chamfer/Fillet armed (spec §4.3): taps toggle convex edges of a body
    /// into `EditorViewModel.blendSelectedEdges`; the blend bar sets the size.
    case pickingBlendEdges(BlendKind)
    /// Shell armed (spec §4.4): taps toggle the planar faces to cut open in
    /// `EditorViewModel.shellSelectedFaces`; the shell bar sets the wall
    /// thickness. Zero open faces is valid — a fully enclosed hollow.
    case pickingShellFaces
    /// Delete Face armed (spec §4.16): taps toggle faces into
    /// `EditorViewModel.deleteFaceTargets`; Apply removes them and lets the
    /// neighbouring surfaces heal. B-rep only — a mesh has no surfaces to
    /// extend, so there is nothing to heal with.
    case pickingDeleteFaces
    /// Replace Face armed (spec §4.12): the first tap picks the planar face to
    /// move, the second picks the face whose plane it moves onto. Flip
    /// Alignment chooses the side when both readings are valid.
    case pickingReplaceFace
    /// Add Axis armed (spec §6.2): taps pick the references the axis is
    /// derived from — a linear edge, a cylindrical face, or one or two planar
    /// faces. See `EditorViewModel.axisPicks`.
    case pickingAxisReferences

    var isSketching: Bool {
        if case .sketching = self { return true }
        return false
    }

    /// The armed sketch tool, or nil when not sketching / no tool armed.
    /// (`.sketching`'s tool is optional: with none armed, empty-space drags
    /// orbit instead of drawing, so a plane can be sketched from any angle.)
    var sketchTool: SketchTool? {
        if case .sketching(_, let tool) = self { return tool }
        return nil
    }
}

enum BooleanKind: String {
    case union
    case subtract
    case intersect
}

/// Manual boolean-result override for the extrude/revolve commit (Shapr3D's
/// Boolean badge). `.auto` keeps the sample-point behavior.
enum BooleanOverride: String, CaseIterable {
    case auto = "Auto"
    case newBody = "New Body"
    case union = "Union"
    case subtract = "Subtract"
    case intersect = "Intersect"
}
